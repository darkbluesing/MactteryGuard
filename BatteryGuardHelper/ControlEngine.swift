// ControlEngine.swift — 충전 제어 루프 + 상태 머신 (데몬의 심장).
//
// 설계 §6. 10초 폴링, 60초 재조정(reconcile), 히스테리시스 상한/하한(기본 80/75),
// 섀도 상태, FAIL-OPEN을 구현한다. 유일한 쓰기 주체다 (앱은 절대 쓰지 않는다).
//
// 상태 전이 (설계 §6.3):
//   IDLE ⇄ CHARGING ⇄ HOLDING, HOLDING → CALIBRATING → DISCHARGE_BACK → HOLDING.
//   모든 상태에서 오류 시 FAIL_OPEN(충전 허용 복원), 어댑터 분리 시 IDLE.
//   보정 중에는 어떤 쓰기도 하지 않는다 (§7.2).
//
// 백엔드별 동작:
//  - Native (관리형): 상한을 설정해 두면 macOS가 강제한다. 엔진은 설정 유지 여부만
//    재확인하고, charging/holding 상태는 정보 표시용으로 %에서 파생한다.
//  - Adapter (능동형): 엔진이 매 틱 %를 보고 CHIE를 토글한다.
//
// Top Up (§14.10): 상한을 100%로 올리고, 100% 도달 후 어댑터 분리·재연결 시
// 또는 topUpAutoReturnHours(기본 24시간) 경과 시 원래 상한으로 복귀한다.
//
// 안전망:
//  - 쓰기 속도 제한: 10초 틱 + 섀도 상태로 동일 쓰기 반복을 막는다 (§9.2).
//  - 연속 3회 쓰기 실패 → FAIL_OPEN, 사용자 수동 재개까지 자동 재시도 중단.
//  - 20% 미만에서는 충전을 차단하지 않는다. 어댑터 절단은 10% 하한 (AdapterBackend).
//  - 수면 갭 감지: 틱이 60초 이상 건너뛰어지면 복귀한 것으로 간주해 즉시 재확인한다.
//  - XPC 24시간 단절 후 자동 해제(§9.1 초안)는 구현하지 않는다 — §14.9(앱 종료 후에도
//    데몬이 계속 유지)가 우선한다. 데몬은 마지막 유효 설정으로 무기한 제어한다.

import Foundation

@MainActor
public final class ControlEngine {
    // MARK: - Constants

    /// 제어 틱 간격 (10초, 설계 §6.1).
    private static let tickInterval: TimeInterval = 10
    /// 재조정 주기 (틱 횟수: 6틱 = 60초).
    private static let reconcileEveryTicks = 6
    /// 연속 실패 허용 횟수 (3회 → FAIL_OPEN).
    private static let maxConsecutiveErrors = 3
    /// 방전 최대 지속 시간 (2시간, 설계 §7.3 초안).
    private static let maxDischargeDuration: TimeInterval = 2 * 60 * 60
    /// 수면 갭 판정 임계값 (틱이 이보다 늦어지면 복귀한 것으로 간주).
    private static let sleepGapThreshold: TimeInterval = 60

    // MARK: - Dependencies

    private let store: DaemonStore
    private let logger: GuardLogger
    private let reader = BatteryReader()
    private let detector: CalibrationDetector
    private let sleepMonitor: SleepWakeMonitor
    private let nativeBackend: NativeBackend
    private let adapterBackend: AdapterBackend

    // MARK: - State

    private(set) var settings: GuardSettings
    private var backend: ChargeBackend?
    private var backendKind: BackendKind = .unknown
    private var backendDetails: String = ""
    private var state: ControlState = .idle
    private var paused: Bool = false
    private var calibrationActive = false
    private var calibrationSource: String?
    private var limitRegistered: Bool?
    private var registrationPending = false
    private var topUp: TopUpState = .inactive
    private var topUpStartedAt: Date?
    private var topUpSavedLimit: Int?
    private var lastACConnected: Bool?
    private var lastReading: BatteryReading?
    private var consecutiveErrors = 0
    private var lastWriteDescription: String?
    private var lastError: String?
    private var lastTick: Date?
    private var tickCount = 0
    private var timer: Timer?
    private var started = false

    /// 관찰 기반 보정 감지용: (시각, 잔량) 기록. 차단 중 상승을 본다.
    private var observationHistory: [(date: Date, percent: Int)] = []
    private var observationRises = 0
    private var dischargeStartedAt: Date?
    /// 되돌리기 대기 시작 (macOS 드레인 위임 시 2시간 상한용).
    private var dischargeWaitStartedAt: Date?

    // MARK: - Init

    public init(store: DaemonStore, logger: GuardLogger) {
        self.store = store
        self.logger = logger
        self.settings = store.loadSettings() ?? GuardSettings()
        self.detector = CalibrationDetector(logger: logger)
        self.sleepMonitor = SleepWakeMonitor(logger: logger)
        self.nativeBackend = NativeBackend(store: store, logger: logger)
        self.adapterBackend = AdapterBackend(store: store, logger: logger, reader: reader)
    }

    // MARK: - Lifecycle

    /// 데몬 시작: 백엔드 선택 → 안전 기준 상태 → 제어 루프 시작.
    public func start() {
        guard !started else { return }
        started = true
        logger.info("MactteryGuard 데몬 시작 (버전 \(GuardConstants.version), 제어 \(settings.controlEnabled ? "켜짐" : "꺼짐"), 상한 \(settings.upperLimit)%)")
        selectBackend()
        // 안전 기준 상태: 이전 실행에서 어댑터가 차단된 채 남아 있으면 먼저 허용으로 되돌린다.
        // (Native 상한은 멱등하게 재적용되므로 별도 복원이 필요 없다.)
        if backendKind == .adapter {
            _ = adapterBackend.restore()
        }
        applyCurrentSettings(reason: "데몬 시작")
        sleepMonitor.onWillSleep = { [weak self] in
            Task { @MainActor [weak self] in self?.handleWillSleep() }
        }
        sleepMonitor.onWake = { [weak self] in
            Task { @MainActor [weak self] in self?.handleWake() }
        }
        _ = sleepMonitor.start()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // 첫 틱을 즉시 수행한다 (10초 대기 없음).
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 종료 시 동기 복원. 시그널 핸들러가 MainActor 태스크에서 호출한다.
    /// (데몬이 종료되는 중이므로 상태 업데이트는 하지 않고 백엔드 복원만 수행한다.)
    @discardableResult
    public func shutdownRestore() -> Bool {
        let nativeOK = backend?.suspend() ?? true
        let adapterOK = adapterBackend.restore()
        logger.info("종료 복원 완료 (네이티브 \(nativeOK ? "성공" : "실패"), 어댑터 \(adapterOK ? "성공" : "실패"))")
        return nativeOK && adapterOK
    }

    // MARK: - Backend selection

    /// 런타임 가용성 프로브로 백엔드를 선택한다 (버전 분기 없음).
    /// 순서: Native(주) → Adapter(폴백). 둘 다 불가면 제어 불가(읽기 전용).
    private func selectBackend() {
        var details: [String] = []
        // 정보용 키 존재 확인 (제어 선택에는 쓰지 않는다).
        if let smc = SMCClient() {
            let legacyKeys = ["CH0B", "CH0C"].map { smc.isUsable(key: $0) ? "\($0) 가용" : "\($0) 부재" }
            let firmwareKeys = ["bfF0"].map { smc.isUsable(key: $0) ? "\($0) 가용" : "\($0) 부재" }
            details += legacyKeys + firmwareKeys
        }

        if nativeBackend.probe() {
            backend = nativeBackend
            backendKind = .native
            details.append("Native 가용")
        } else if adapterBackend.probe() {
            backend = adapterBackend
            backendKind = .adapter
            details.append("Native 불가, Adapter(CHIE) 가용")
        } else {
            backend = nil
            backendKind = .unsupported
            details.append("Native·Adapter 모두 불가")
            lastError = "충전 제어를 할 수 없습니다 (네이티브·어댑터 백엔드 모두 가용하지 않음)"
            logger.error("백엔드 선택 실패: 제어 불가")
        }
        // Adapter 가용 여부는 되돌리기(CHIE)에도 쓰이므로 별도 기록한다.
        if backendKind == .native {
            details.append(adapterBackend.probe() ? "CHIE 가용 (되돌리기 가능)" : "CHIE 불가 (되돌리기 불가)")
        }
        backendDetails = details.joined(separator: " · ")
        logger.info("백엔드 선택: \(backendKind.displayName) (\(backendDetails))")
    }

    // MARK: - Main loop

    private func tick() {
        let now = Date()
        // 수면 갭 감지: 틱이 60초 이상 늦어지면 수면에서 복귀한 것으로 간주한다.
        if let last = lastTick, now.timeIntervalSince(last) > Self.sleepGapThreshold {
            logger.info("수면 갭 감지 (\(Int(now.timeIntervalSince(last)))초) — 복귀 재확인")
            reconcile(force: true)
        }
        lastTick = now
        tickCount += 1

        guard let reading = reader.read(includeDetails: false) else {
            logger.warn("배터리 읽기 실패 (틱 건너뜀)")
            return
        }
        lastReading = reading
        let acChanged = trackACChange(isOnAC: reading.isOnAC)

        // 제어 비활성/일시정지/상한 100%면 대기 상태로, 충전 허용을 보장한다.
        guard settings.controlEnabled, !paused, settings.upperLimit < 100 else {
            ensureIdle(reading: reading)
            return
        }
        guard backend != nil else {
            // 백엔드 없음: 읽기 전용. 상태를 idle로 유지한다.
            transition(to: .idle)
            return
        }

        // 보정 감지 (쓰기 전에 반드시 확인).
        updateCalibration(reading: reading)
        if calibrationActive {
            transition(to: .calibrating)
            return // 보정 중에는 어떤 쓰기도 하지 않는다.
        }
        // 보정이 막 끝났고 잔량이 상한 위면 되돌리기로 전이한다.
        if state == .calibrating {
            if reading.percent > settings.upperLimit {
                transition(to: .dischargeBack)
                dischargeStartedAt = Date()
                dischargeWaitStartedAt = Date()
                logger.info("보정 종료 — 되돌리기 시작 (잔량 \(reading.percent)% → 상한 \(settings.upperLimit)%)")
            } else {
                transition(to: .idle)
            }
        }

        // Top Up 처리.
        if topUp != .inactive {
            handleTopUp(reading: reading, acChanged: acChanged)
            if topUp != .inactive { return } // Top Up 중에는 일반 제어를 건너뛴다.
        }

        // 어댑터 분리 시 제어 일시정지 (복원하지 않음 — 배터리 사용 중).
        guard reading.isOnAC else {
            transition(to: .idle)
            return
        }

        // 20% 미만: 어떤 경우에도 충전을 차단하지 않는다.
        if reading.percent < GuardConstants.neverBlockBelowPercent {
            if backendKind == .adapter {
                _ = adapterBackend.setAdapterEnabled(true, percent: reading.percent)
            }
            transition(to: .charging)
            return
        }

        // 되돌리기 중.
        if state == .dischargeBack {
            handleDischargeBack(reading: reading)
            if state == .dischargeBack {
                maybeReconcile(reading: reading)
                return
            }
            // 되돌리기 완료 시 아래 일반 제어로 이어진다.
        }

        // 일반 제어 (백엔드별).
        switch backendKind {
        case .native:
            // 관리형: 상한이 설정되어 있는지만 보장한다. 상태는 정보 표시용.
            ensureNativeLimit()
            transition(to: reading.percent >= settings.upperLimit ? .holding : .charging)
        case .adapter:
            handleAdapterHysteresis(reading: reading)
        default:
            transition(to: .idle)
        }

        maybeReconcile(reading: reading)
    }

    private func maybeReconcile(reading: BatteryReading) {
        if tickCount % Self.reconcileEveryTicks == 0 {
            reconcile(force: false)
        }
    }

    // MARK: - Idle / pause

    /// 제어 비활성 상태 보장: 상한이 적용돼 있으면 충전 허용으로 되돌린다.
    private func ensureIdle(reading: BatteryReading) {
        if state != .idle {
            transition(to: paused ? .paused : .idle)
        }
        // 적용 중인 상한이 있으면 해제한다 (일시정지는 suspend로 원래 값 기록 보존).
        let shadow = store.loadShadow()
        let limitApplied = shadow?.nativeLimit != nil || shadow?.adapterEnabled == false
        guard limitApplied else { return }
        if paused {
            _ = backend?.suspend()
        } else {
            // 제어 해제 시에도 원래 값 기록은 보존한다 (제거 시에만 지운다).
            _ = backend?.suspend()
        }
        // 어댑터가 되돌리기용으로 차단돼 있으면 함께 복원한다.
        if backendKind == .native {
            _ = adapterBackend.restore()
        }
    }

    // MARK: - Calibration

    private func updateCalibration(reading: BatteryReading) {
        // 1) notify 상태 (매 틱).
        var source: String?
        if detector.notifyOverrideActive() == true {
            source = "notify"
        }
        // 2) OSLogStore (내부 60초 스로틀).
        if source == nil, detector.logSignalPresent() {
            source = "log"
        }
        // 3) 관찰 기반: 차단 중 잔량 상승 2회 연속.
        if source == nil, checkObservation(reading: reading) {
            source = "관찰"
        }

        if let source {
            if !calibrationActive {
                calibrationActive = true
                calibrationSource = source
                logger.info("보정 감지 (신호: \(source)) — 쓰기 중단")
            }
        } else {
            // 신호 소멸: 보정 종료. (notify 0 + 최근 로그 신호 없음.)
            if calibrationActive {
                calibrationActive = false
                calibrationSource = nil
                observationRises = 0
                observationHistory.removeAll()
                logger.info("보정 신호 소멸")
            }
        }
    }

    /// 관찰 기반 감지: holding/dischargeBack 상태에서 60초 간격으로 잔량이 오르면 의심.
    private func checkObservation(reading: BatteryReading) -> Bool {
        guard state == .holding || state == .dischargeBack else {
            observationHistory.removeAll()
            observationRises = 0
            return false
        }
        let now = Date()
        observationHistory.append((date: now, percent: reading.percent))
        observationHistory.removeAll { now.timeIntervalSince($0.date) > 180 }
        // 55초 이상 지난 기록과 비교한다.
        guard let old = observationHistory.first(where: { now.timeIntervalSince($0.date) >= 55 }) else {
            return false
        }
        if reading.percent > old.percent {
            observationRises += 1
            observationHistory.removeAll()
            logger.info("관찰: 차단 중 잔량 상승 (\(old.percent)% → \(reading.percent)%, \(observationRises)회)")
            return observationRises >= 2
        } else {
            observationRises = 0
            return false
        }
    }

    // MARK: - Discharge back

    private func handleDischargeBack(reading: BatteryReading) {
        let limit = settings.upperLimit
        // 안전장치: 하한 이하로 내려가면 즉시 중단한다 (상한 도달 검사보다 먼저 — 하한 이하는
        // 상한 이하이기도 하므로, 순서를 바꾸면 이 분기가 도달 불가(dead code)가 된다).
        if reading.percent <= settings.lowerLimit {
            logger.warn("되돌리기 중단: 잔량 \(reading.percent)%가 하한(\(settings.lowerLimit)%) 이하")
            finishDischargeBack(reading: reading)
            transition(to: .charging)
            return
        }
        // 완료: 상한 도달.
        if reading.percent <= limit {
            finishDischargeBack(reading: reading)
            return
        }
        // 어댑터 분리 시 중단 (방전이 무의미).
        if !reading.isOnAC {
            finishDischargeBack(reading: reading)
            transition(to: .idle)
            return
        }
        // 2시간 상한.
        if let started = dischargeStartedAt ?? dischargeWaitStartedAt,
           Date().timeIntervalSince(started) > Self.maxDischargeDuration {
            logger.warn("되돌리기 2시간 상한 초과 — 중단 (잔량 \(reading.percent)%)")
            finishDischargeBack(reading: reading)
            transition(to: .holding)
            return
        }

        if backendKind == .adapter {
            // Adapter 모드: 절단 유지가 곧 방전이다.
            _ = adapterBackend.setAdapterEnabled(false, percent: reading.percent)
        } else if settings.forceDischargeEnabled {
            // Native + 옵트인: CHIE 절단으로 강제 방전한다.
            if !adapterBackend.setAdapterEnabled(false, percent: reading.percent) {
                // 절단 실패 (클램셸 등): 이번 틱은 건너뛰고 다음 틱에 재시도한다.
                logger.info("되돌리기 절단 보류 (클램셸/하한 가드)")
            }
        } else {
            // Native + 옵트인 꺼짐: macOS 자체 드레인에 위임한다 (쓰지 않고 대기).
            // 드레인이 시작됐는지(잔량 하락)는 다음 틱에서 본다.
        }
    }

    private func finishDischargeBack(reading: BatteryReading) {
        // 되돌리기용 절단을 해제한다.
        _ = adapterBackend.restore()
        dischargeStartedAt = nil
        dischargeWaitStartedAt = nil
        if reading.percent <= settings.upperLimit {
            transition(to: .holding)
        }
    }

    // MARK: - Native / Adapter control

    private func ensureNativeLimit() {
        let limit = settings.upperLimit
        let shadow = store.loadShadow()
        if shadow?.nativeLimit == limit {
            return // 이미 적용됨 — 쓰지 않는다.
        }
        applyLimit(limit, reason: "상한 적용")
    }

    /// 현재 보정 중인지 (라이브 notify 신호 또는 마지막으로 확인된 상태).
    /// 원래 값 저장 게이트용 — 상태머신 전이는 틱 이후라 늦을 수 있다.
    private var isCalibratingNow: Bool {
        if detector.notifyOverrideActive() == true { return true }
        return calibrationActive
    }

    private func applyLimit(_ limit: Int, reason: String) {
        guard let backend else { return }
        // 섀도 상태: 이미 적용된 상한이면 쓰지 않는다 (불필요한 쓰기 방지).
        if backendKind == .native, store.loadShadow()?.nativeLimit == limit {
            return
        }
        switch backend.setLimit(limit, isCalibrating: isCalibratingNow) {
        case .applied:
            consecutiveErrors = 0
            lastWriteDescription = "\(timestampString()) 상한 \(limit)% 설정 (\(reason))"
            lastError = nil
        case .pending:
            consecutiveErrors = 0
            registrationPending = true
        case .failed(let message):
            recordError("상한 설정 실패: \(message)")
        }
    }

    private func handleAdapterHysteresis(reading: BatteryReading) {
        let upper = settings.upperLimit
        let lower = settings.lowerLimit
        switch state {
        case .charging, .idle:
            if reading.percent >= upper {
                if adapterBackend.setAdapterEnabled(false, percent: reading.percent) {
                    consecutiveErrors = 0
                    transition(to: .holding)
                } else {
                    // 절단 거부 (클램셸 등)는 오류가 아니다 — 다음 틱에 재시도한다.
                    transition(to: .charging)
                }
            } else {
                // 충전 허용 상태 유지.
                _ = adapterBackend.setAdapterEnabled(true, percent: reading.percent)
                transition(to: .charging)
            }
        case .holding:
            if reading.percent <= lower {
                if adapterBackend.setAdapterEnabled(true, percent: reading.percent) {
                    consecutiveErrors = 0
                    transition(to: .charging)
                } else {
                    recordError("어댑터 허용 실패 (하한 도달)")
                }
            } else if reading.percent >= upper {
                // 절단 상태 재확인 (클램셸 복귀·외부 간섭 대응).
                _ = adapterBackend.setAdapterEnabled(false, percent: reading.percent)
            }
        default:
            break
        }
    }

    // MARK: - Top Up

    private func handleTopUp(reading: BatteryReading, acChanged: Bool) {
        guard let startedAt = topUpStartedAt, let savedLimit = topUpSavedLimit else {
            topUp = .inactive
            return
        }
        // 100% 도달 확인.
        if topUp == .active, reading.percent >= 100 {
            topUp = .reached
            logger.info("Top Up 100% 도달 — 복귀 대기 (재연결 또는 \(settings.topUpAutoReturnHours)시간 경과 시)")
        }
        // 복귀 트리거 1: 어댑터 분리 후 재연결 (100% 도달 후).
        if topUp == .reached, acChanged, reading.isOnAC {
            logger.info("Top Up 복귀: 어댑터 재연결")
            endTopUp(restoreTo: savedLimit)
            return
        }
        // 복귀 트리거 2: 시간 경과 (도달 여부와 무관).
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed > TimeInterval(settings.topUpAutoReturnHours * 60 * 60) {
            logger.info("Top Up 복귀: \(settings.topUpAutoReturnHours)시간 경과")
            endTopUp(restoreTo: savedLimit)
            return
        }
        // Top Up 유지: 상한 100% 보장. 섀도와 다를 때만 쓴다 (매 틱 쓰기 방지).
        if topUp == .active {
            if backendKind == .native {
                if store.loadShadow()?.nativeLimit != 100 {
                    _ = backend?.setLimit(100, isCalibrating: isCalibratingNow)
                }
            } else {
                // Adapter: 충전 허용 유지 (이미 허용이면 쓰지 않는다).
                _ = adapterBackend.setAdapterEnabled(true, percent: reading.percent)
            }
        }
    }

    private func endTopUp(restoreTo limit: Int) {
        topUp = .inactive
        topUpStartedAt = nil
        topUpSavedLimit = nil
        transition(to: .idle)
        applyLimit(limit, reason: "Top Up 종료 — 원래 상한 복귀")
    }

    // MARK: - Reconcile

    private func reconcile(force: Bool) {
        guard settings.controlEnabled, !paused, backend != nil else { return }
        guard state != .calibrating else { return } // 보정 중에는 건드리지 않는다.
        // Top Up 중에는 상한 검증을 건너뛴다 (100%는 별도 관리).
        if topUp == .inactive {
            if backend?.verify(expectedLimit: settings.upperLimit) == false {
                logger.warn("재조정: 백엔드 상태 불일치 — 상한 재적용")
                applyLimit(settings.upperLimit, reason: "재조정")
            }
        }
        // 네이티브 등록 확인 (pmset). 배터리 전원에서는 등록 철회가 정상이라 미확인으로 둔다.
        if backendKind == .native {
            if lastReading?.isOnAC == true {
                switch nativeBackend.checkRegistration() {
                case .registered(let limit):
                    limitRegistered = (limit == settings.upperLimit)
                    registrationPending = (limit != settings.upperLimit)
                    if limit != settings.upperLimit {
                        logger.warn("등록된 상한(\(limit)%)이 설정(\(settings.upperLimit)%)과 다름")
                    }
                case .none:
                    limitRegistered = false
                    registrationPending = true
                case .unknown(let raw):
                    limitRegistered = nil
                    if !raw.isEmpty {
                        logger.debug("pmset 파싱 불가 — 원시 출력: \(raw.prefix(200))")
                    }
                }
            } else {
                limitRegistered = nil
                registrationPending = false
            }
        }
        if force {
            logger.debug("재조정 수행 (강제)")
        }
    }

    // MARK: - Sleep / wake

    private func handleWillSleep() {
        logger.info("수면 직전: 어댑터 허용 복원")
        adapterBackend.prepareForSleep()
    }

    private func handleWake() {
        logger.info("복귀 감지 — 즉시 재확인")
        lastTick = Date()
        reconcile(force: true)
        tick()
    }

    // MARK: - Errors / FAIL-OPEN

    private func recordError(_ message: String) {
        consecutiveErrors += 1
        lastError = message
        logger.error("\(message) (연속 \(consecutiveErrors)회)")
        if consecutiveErrors >= Self.maxConsecutiveErrors {
            failOpen(reason: message)
        }
    }

    /// FAIL-OPEN: 충전 허용으로 복원하고 자동 재시도를 중단한다.
    private func failOpen(reason: String) {
        logger.error("FAIL-OPEN: \(reason) — 충전 허용 복원")
        _ = backend?.suspend()
        _ = adapterBackend.restore()
        consecutiveErrors = 0
        transition(to: .failOpen)
    }

    // MARK: - XPC-facing actions

    /// 설정 적용 (XPC applySettings). 검증·저장·적용한다.
    public func applySettings(_ newSettings: GuardSettings) -> Result<Void, Error> {
        let validated = newSettings.validated()
        let wasEnabled = settings.controlEnabled
        settings = validated
        store.saveSettings(validated)
        logger.info("설정 적용: 제어 \(validated.controlEnabled ? "켜짐" : "꺼짐"), 상한 \(validated.upperLimit)%, 강제 방전 \(validated.forceDischargeEnabled ? "켜짐" : "꺼짐")")

        // 오류 상태에서 설정이 바뀌면 재개를 허용한다.
        if state == .failOpen {
            consecutiveErrors = 0
            lastError = nil
            transition(to: .idle)
        }
        // 강제 방전이 꺼졌는데 되돌리기 중이면 중단한다 (다음 틱이 상태를 바로잡는다).
        if !validated.forceDischargeEnabled, state == .dischargeBack, backendKind == .native {
            _ = adapterBackend.restore()
            dischargeStartedAt = nil
            dischargeWaitStartedAt = nil
            transition(to: .idle)
        }
        // 제어 껐다 켜지면 즉시 적용한다.
        if validated.controlEnabled, !wasEnabled {
            paused = false
            applyCurrentSettings(reason: "설정 변경 — 제어 켜짐")
        } else if !validated.controlEnabled, wasEnabled {
            applyCurrentSettings(reason: "설정 변경 — 제어 꺼짐")
        } else if validated.controlEnabled {
            applyCurrentSettings(reason: "설정 변경")
        }
        tick()
        return .success(())
    }

    /// 현재 설정에 맞게 백엔드를 한 번 적용한다.
    private func applyCurrentSettings(reason: String) {
        guard let backend else { return }
        if !settings.controlEnabled || settings.upperLimit >= 100 {
            // 적용한 것이 있을 때만 복원한다 (섀도가 깨끗하면 건드리지 않는다).
            let shadow = store.loadShadow()
            if shadow?.nativeLimit != nil || shadow?.adapterEnabled == false {
                _ = backend.suspend()
                _ = adapterBackend.restore()
            }
            transition(to: .idle)
            return
        }
        applyLimit(settings.upperLimit, reason: reason)
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            _ = backend?.suspend()
            _ = adapterBackend.restore()
            transition(to: .paused)
            logger.info("제어 일시정지 — 충전 허용 복원")
        } else {
            consecutiveErrors = 0
            lastError = nil
            transition(to: .idle)
            logger.info("제어 재개")
            tick()
        }
    }

    public func chargeToFullOnce() -> Result<Void, Error> {
        guard settings.controlEnabled else {
            return .failure(GuardXPCError.error(
                code: GuardXPCError.invalidSettings, description: "충전 제어가 꺼져 있습니다"
            ))
        }
        guard backend != nil else {
            return .failure(GuardXPCError.error(
                code: GuardXPCError.internalError, description: "사용 가능한 백엔드가 없습니다"
            ))
        }
        if topUp != .inactive {
            return .success(()) // 이미 진행 중이면 성공으로 간주한다.
        }
        topUpSavedLimit = settings.upperLimit
        topUpStartedAt = Date()
        topUp = .active
        transition(to: .charging)
        logger.info("Top Up 시작 (현재 상한 \(settings.upperLimit)% 저장, 100%로 충전)")
        _ = backend?.setLimit(100, isCalibrating: isCalibratingNow)
        return .success(())
    }

    public func cancelTopUp() {
        guard topUp != .inactive, let savedLimit = topUpSavedLimit else { return }
        logger.info("Top Up 취소 — 상한 \(savedLimit)%로 복귀")
        endTopUp(restoreTo: savedLimit)
    }

    /// 제거 준비: 충전 허용 복원. 성공 시 앱이 데몬 unregister를 수행한다.
    public func uninstall() -> Bool {
        logger.info("제거 요청 — 충전 허용 복원 중")
        let nativeOK = backend?.restore() ?? true
        let adapterOK = adapterBackend.restore()
        stop()
        return nativeOK && adapterOK
    }

    // MARK: - State snapshot

    public func currentState() -> DaemonState {
        let reading = lastReading ?? reader.read(includeDetails: false)
            ?? BatteryReading(percent: 0, isCharging: false, isOnAC: false)
        return DaemonState(
            backend: backendKind,
            controlState: state,
            calibrationActive: calibrationActive,
            calibrationSource: calibrationSource,
            percent: reading.percent,
            isCharging: reading.isCharging,
            isOnAC: reading.isOnAC,
            limitRegistered: limitRegistered,
            registrationPending: registrationPending,
            topUp: topUp,
            lastWriteDescription: lastWriteDescription,
            lastError: lastError,
            backendDetails: backendDetails,
            settings: settings,
            daemonVersion: GuardConstants.version,
            timestamp: Date()
        )
    }

    // MARK: - Helpers

    private func transition(to newState: ControlState) {
        guard state != newState else { return }
        logger.info("상태 전이: \(state.displayName) → \(newState.displayName)")
        state = newState
        if newState != .dischargeBack {
            dischargeStartedAt = nil
            dischargeWaitStartedAt = nil
        }
    }

    /// AC 연결 상태 변화 감지. 변화가 있으면 true.
    private func trackACChange(isOnAC: Bool) -> Bool {
        defer { lastACConnected = isOnAC }
        guard let last = lastACConnected else { return false }
        return last != isOnAC
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
