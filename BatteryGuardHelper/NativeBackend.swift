// NativeBackend.swift — 네이티브 백엔드 (PowerUIAgent 상한 동기화).
//
// 이 기기의 주 백엔드. macOS가 상한을 강제하므로 수면 중에도 유지되고,
// 엔진은 상한이 설정되어 있는지만 주기적으로 재확인한다 (관리형).
//
// 두 경로 (BATT_NATIVE_RESEARCH.md §2 검증됨):
//  - 80–100%: PowerUI 슬라이더 API (setMCLLimit:). root 불필요.
//  - 10–99% (실질적으로 80% 미만): 설정 직접 쓰기 — root 데몬이
//    com.apple.smartcharging.topoffprotection 도메인에 MCLFeatureState=1,
//    mclLimitValue=N을 쓰고 com.apple.smartcharging.defaultschanged notify를 보낸다.
// 80–100%에서 슬라이더 API가 실패하면 설정 경로로 폴백한다 (§9.1.8).
//
// 등록 확인은 pmset -g battlimit 파싱으로 별도 수행한다 (checkRegistration).
// 배터리 전원에서는 macOS가 약 5분 후 등록을 철회하므로, 전원 분리 시
// 등록 없음은 정상이다 — 엔진이 isOnAC를 보고 판단한다.

import Darwin
import Foundation

public final class NativeBackend: ChargeBackend {
    public let kind: BackendKind = .native

    private let store: DaemonStore
    private let logger: GuardLogger
    private var powerUI: PowerUIClient?

    private var domain: CFString { GuardConstants.topOffProtectionDomain as CFString }

    public init(store: DaemonStore, logger: GuardLogger) {
        self.store = store
        self.logger = logger
    }

    // MARK: - Probe

    public func probe() -> Bool {
        // 1) 슬라이더 API 가용성 (isMCLSupported).
        if powerUI == nil { powerUI = PowerUIClient() }
        if let client = powerUI, client.isSupported() {
            logger.info("네이티브 프로브: PowerUI 슬라이더 API 가용")
            return true
        }
        // 2) 슬라이더 API가 안 되면 설정 도메인 읽기 가능 여부로 판단한다.
        //    (쓰기 가능 여부는 실제 설정 시에 확인된다.)
        if readSettings() != nil {
            logger.info("네이티브 프로브: 슬라이더 API 불가, 설정 도메인 읽기 가능")
            return true
        }
        logger.warn("네이티브 프로브 실패: 슬라이더 API·설정 도메인 모두 불가")
        return false
    }

    // MARK: - Set limit

    public func setLimit(_ limit: Int, isCalibrating: Bool) -> BackendResult {
        guard (1...100).contains(limit) else { return .failed("상한 범위 밖: \(limit)") }
        if isCalibrating {
            // 보정 중에는 도메인 읽기가 오염된다 (PowerUIAgent가 state=0, limit=100을
            // 씀 — 2026-11-16 실측). 원래 값 저장을 건너뛴다; 보정이 끝난 뒤 다음
            // 적용 때 저장된다. 상한 쓰기 자체는 그대로 진행한다.
            logger.info("보정 중 — 원래 값 저장 건너뜀")
        } else {
            saveOriginalsIfNeeded()
        }

        // 100% (Top Up·완충): 설정 경로는 1–99 범위라 100을 쓸 수 없으므로 슬라이더만 쓴다.
        // 슬라이더가 안 되면 에이전트 비활성화(=상한 없음)로 동등한 효과를 낸다.
        if limit == 100 {
            if let client = powerUIClient(), client.setLimit(100) {
                logger.logWrite("네이티브 완충 설정 (슬라이더 API 100%)")
                updateShadow(limit: 100)
                return .applied
            }
            if let client = powerUIClient(), client.disable() {
                logger.logWrite("네이티브 완충 설정 (에이전트 비활성화로 상한 해제)")
                updateShadow(limit: 100)
                return .applied
            }
            return .failed("완충 설정 실패 (슬라이더·비활성화 모두 실패)")
        }

        // 80–99%: 슬라이더 API 우선, 실패 시 설정 경로로 폴백.
        if limit >= 80 {
            if let client = powerUIClient(), client.setLimit(limit) {
                logger.logWrite("네이티브 상한 \(limit)% 설정 (슬라이더 API)")
                if verifyViaSettingsOrSlider(expected: limit) {
                    updateShadow(limit: limit)
                    return .applied
                }
                logger.warn("슬라이더 API 쓰기 후 확인 실패 — 설정 경로로 폴백")
            } else {
                logger.warn("슬라이더 API setLimit 실패 — 설정 경로로 폴백")
            }
        }

        // 설정 경로 (80% 미만 필수, 80–99% 폴백).
        guard writeSettings(featureState: 1, limitValue: limit) else {
            return .failed("설정 경로 쓰기 실패 (상한 \(limit)%)")
        }
        logger.logWrite("네이티브 상한 \(limit)% 설정 (설정 경로)")
        updateShadow(limit: limit)
        return .applied
    }

    public func currentLimit() -> Int? {
        // 슬라이더 getter가 있으면 그걸 우선 사용한다 (에이전트가 로드한 유효 목표).
        if let client = powerUI, let limit = client.getLimit() {
            return limit
        }
        return readSettings()?.limitValue
    }

    // MARK: - Restore (FAIL-OPEN) / Suspend

    /// 영구 복원: 원래 값으로 되돌리고 원래 값 기록을 지운다 (제거 시에만 사용).
    public func restore() -> Bool {
        restoreCharging(clearOriginals: true)
    }

    /// 일시 중단: 원래 값으로 되돌리되 기록은 보존한다
    /// (일시정지·제어 해제·종료·FAIL-OPEN 시 — 다음 적용 때 재캡처하지 않는다).
    public func suspend() -> Bool {
        restoreCharging(clearOriginals: false)
    }

    private func restoreCharging(clearOriginals: Bool) -> Bool {
        let originals = loadTrustworthyOriginals()
        var ok = true

        if let originals {
            if originals.existed {
                // 원래 값이 있었으면 그대로 되돌린다 (없었던 키는 제거).
                ok = writeSettings(
                    featureState: originals.featureState, limitValue: originals.limitValue
                )
                logger.logWrite("네이티브 상한 원래 값으로 복원 (state=\(originals.featureState.map(String.init) ?? "없음"), limit=\(originals.limitValue.map(String.init) ?? "없음"))")
            } else {
                // 원래 설정이 없었으면: 우리 키를 제거하고 에이전트 비활성화로 등록을 지운다.
                let removed = writeSettings(featureState: nil, limitValue: nil)
                var disabled = true
                if let client = powerUIClient() {
                    // 에이전트가 비활성 상태라고 믿을 때만 disableMCL:이 등록을 지우므로,
                    // 필요 시 enable 후 disable한다 (연구 노트 §2.5).
                    if !client.isEnabled() { _ = client.enable() }
                    disabled = client.disable()
                }
                ok = removed && disabled
                logger.logWrite("네이티브 상한 해제 (원래 설정 없음 — 키 제거 + 에이전트 비활성화)")
            }
        } else {
            // 원래 값을 캡처한 적 없음 (보정 중 저장 건너뜀 등) — 현재 상한을 그대로 둔다.
            // 추측으로 상한을 지우면 사용자의 내장 80% 제한까지 날아갈 수 있다.
            logger.warn("원래 값 기록 없음 — 현재 상한을 그대로 둔다 (복원 생략)")
        }

        if ok {
            if clearOriginals { store.clearOriginals() }
            updateShadow(limit: nil)
        } else {
            logger.error("네이티브 상한 복원 실패")
        }
        return ok
    }

    // MARK: - Verify

    public func verify(expectedLimit: Int) -> Bool {
        verifyViaSettingsOrSlider(expected: expectedLimit)
    }

    private func verifyViaSettingsOrSlider(expected: Int) -> Bool {
        if let client = powerUI, let current = client.getLimit() {
            return current == expected
        }
        guard let settings = readSettings() else { return false }
        return settings.featureState == 1 && settings.limitValue == expected
    }

    // MARK: - Registration check (pmset)

    /// pmset -g battlimit로 등록 상태를 확인한다. 엔진이 reconcile 틱에서 호출한다.
    public func checkRegistration() -> PmsetRegistration {
        PmsetParser.registration()
    }

    // MARK: - Settings path (CFPreferences + notify)

    private struct SettingsValues {
        var featureState: Int?
        var limitValue: Int?
    }

    private func readSettings() -> SettingsValues? {
        let state = CFPreferencesCopyValue(
            "MCLFeatureState" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? NSNumber
        let limit = CFPreferencesCopyValue(
            "mclLimitValue" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? NSNumber
        // 두 키 모두 없으면 도메인 자체가 없는 것일 수 있다 — nil로 구분한다.
        // (값이 0인 것과 키가 없는 것은 다르다.)
        if state == nil && limit == nil {
            // 키가 없어도 도메인 접근 자체는 됐을 수 있다. 호출자는 nil을
            // "읽을 값 없음"으로 취급한다.
            return SettingsValues(featureState: nil, limitValue: nil)
        }
        return SettingsValues(
            featureState: state?.intValue, limitValue: limit?.intValue
        )
    }

    /// 설정 경로 쓰기. featureState/limitValue가 nil이면 해당 키를 제거한다.
    /// 쓰기 → 동기화 → notify → read-back 검증 순서.
    private func writeSettings(featureState: Int?, limitValue: Int?) -> Bool {
        // 설정 경로는 root 도메인에 써야 PowerUIAgent(root)가 본다.
        // root가 아니면 이 경로는 동작하지 않는다.
        guard geteuid() == 0 else {
            logger.error("설정 경로 쓰기 불가: 데몬이 root로 실행되지 않음 (euid=\(geteuid()))")
            return false
        }

        // 에이전트가 비활성이면 설정만으로는 ChargingToFull에서 탈출하지 못할 수 있다.
        // 활성화되어 있을 때는 enableMCL:을 건너뛴다 (80% 기본값으로 덮어쓰는 것을 피함).
        if featureState == 1, let client = powerUIClient(), !client.isEnabled() {
            _ = client.enable()
        }

        if let state = featureState {
            CFPreferencesSetValue(
                "MCLFeatureState" as CFString, NSNumber(value: state),
                domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            )
        } else {
            CFPreferencesSetValue(
                "MCLFeatureState" as CFString, nil,
                domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            )
        }
        if let limit = limitValue {
            CFPreferencesSetValue(
                "mclLimitValue" as CFString, NSNumber(value: limit),
                domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            )
        } else {
            CFPreferencesSetValue(
                "mclLimitValue" as CFString, nil,
                domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            )
        }
        let synced = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard synced else {
            logger.error("설정 경로 동기화(CFPreferencesSynchronize) 실패")
            return false
        }
        // PowerUIAgent에 다시 읽히게 한다.
        guard let post = NotifyAPI.post else {
            logger.error("notify_post 심볼 조회 실패 — 설정 변경 알림 불가")
            return false
        }
        let notifyStatus = GuardConstants.settingsChangedNotify.withCString { post($0) }
        guard notifyStatus == 0 else {
            logger.error("설정 변경 notify 전송 실패 (status=\(notifyStatus))")
            return false
        }
        // Read-back 검증.
        guard let back = readSettings() else { return false }
        if back.featureState != featureState || back.limitValue != limitValue {
            logger.error("설정 경로 read-back 불일치 (기대 state=\(featureState.map(String.init) ?? "없음") limit=\(limitValue.map(String.init) ?? "없음"), 실제 state=\(back.featureState.map(String.init) ?? "없음") limit=\(back.limitValue.map(String.init) ?? "없음"))")
            return false
        }
        return true
    }

    /// 처음 오버라이드하기 전에 사용자의 원래 값을 저장한다 (제거·해제 시 복원용).
    private func saveOriginalsIfNeeded() {
        guard loadTrustworthyOriginals() == nil else { return }
        let current = readSettings() ?? SettingsValues(featureState: nil, limitValue: nil)
        // (0,100)은 보정 오버라이드 흔적일 수 있어 원래 값으로 저장하지 않는다.
        if current.featureState == 0 && current.limitValue == 100 {
            logger.warn("원래 값 저장 건너뜀 (읽은 값이 state=0, limit=100 — 보정 흔적 의심)")
            return
        }
        store.saveOriginalsIfAbsent(
            MCLOriginals(featureState: current.featureState, limitValue: current.limitValue)
        )
        logger.info("원래 네이티브 상한 저장 (state=\(current.featureState.map(String.init) ?? "없음"), limit=\(current.limitValue.map(String.init) ?? "없음"))")
    }

    /// 신뢰할 수 있는 원래 값만 돌려준다. 보정 중 오염된 기록(state=0, limit=100)은
    /// 사용자의 원래 설정이 아니므로 버리고 nil을 돌려준다 (2026-11-16 실측).
    private func loadTrustworthyOriginals() -> MCLOriginals? {
        guard let originals = store.loadOriginals() else { return nil }
        if originals.featureState == 0 && originals.limitValue == 100 {
            logger.warn("오염된 원래 값 기록 버림 (state=0, limit=100 — 보정 오버라이드 흔적)")
            store.clearOriginals()
            return nil
        }
        return originals
    }

    private func powerUIClient() -> PowerUIClient? {
        if powerUI == nil { powerUI = PowerUIClient() }
        return powerUI
    }

    private func updateShadow(limit: Int?) {
        var shadow = store.loadShadow() ?? ShadowState()
        shadow.nativeLimit = limit
        shadow.updatedAt = Date()
        store.saveShadow(shadow)
    }
}
