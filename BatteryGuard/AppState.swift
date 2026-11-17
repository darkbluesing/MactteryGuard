import Foundation
import AppKit
import Combine
import ServiceManagement

/// Step 2 — 앱 상태 허브. 배터리 모니터·설정·데몬 클라이언트·데몬 등록을 소유한다.
/// 10초마다 배터리 갱신 + 데몬 상태 폴링(getState) + 등록 상태 확인을 함께 수행한다.
/// 설정의 원본(source of truth)은 앱의 AppSettings이며, 변경 시 데몬에 전송한다.
/// 데몬이 보이지 않을 때는 전송을 시도하지 않는다 (미등록 상태에서의 오류 스팸 방지).
@MainActor
final class AppState: ObservableObject {
    /// 배터리 상태 (팝오버·메뉴바 라벨이 읽는다).
    let monitor = BatteryMonitor()
    /// 사용자 설정 (팝오버의 토글·슬라이더가 바인딩한다).
    let settings = AppSettings()

    private let client = DaemonClient()
    private let registration = DaemonRegistration()
    private let logger = GuardLogger(directory: GuardLogger.appDirectory(), filePrefix: "mactteryguard")

    /// 마지막으로 받은 데몬 상태. 데몬에 연결되지 않으면 nil이다.
    @Published private(set) var daemonState: DaemonState?
    /// 데몬 XPC 연결 가능 여부.
    @Published private(set) var daemonAvailable = false
    /// LaunchDaemon 등록 상태.
    @Published var registrationStatus: SMAppService.Status = .notRegistered
    /// 앱 측 마지막 오류 (설정 전송·등록·액션 실패). UI에 빨간색으로 표시한다.
    /// 데몬 측 오류는 daemonState?.lastError로 별도 표시한다.
    @Published private(set) var lastError: String?
    /// 등록·완충·제거 등 비동기 액션 진행 중 (버튼 비활성화용).
    @Published private(set) var isBusy = false

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        registrationStatus = registration.status
        logger.info("MactteryGuard 앱 시작 (버전 \(GuardConstants.version))")

        // 모니터·설정 변경을 AppState 관찰자에게 전파한다 (메뉴바 라벨·팝오버 갱신).
        monitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 설정 변경 시 0.5초 디바운스 후 데몬에 전송한다 (슬라이더 드래그 중 스팸 방지).
        settings.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.pushSettings()
                }
            }
            .store(in: &cancellables)

        // Timer 블록은 @Sendable이라 MainActor 홉을 거쳐 refreshNow()를 부른다.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshNow()
            }
        }
        Task { @MainActor [weak self] in
            await self?.refreshNow()
        }
    }

    // MARK: - 폴링

    /// 배터리 갱신 + 등록 상태 확인 + 데몬 상태 폴링을 한 번 수행한다.
    /// 팝오버가 열릴 때도 호출되어 즉시 최신 상태를 보여준다.
    func refreshNow() async {
        monitor.refresh()
        registrationStatus = registration.status
        await pollDaemon()
    }

    private func pollDaemon() async {
        // 미등록 상태에서는 XPC를 시도하지 않는다 — Mach 서비스가 없어
        // reply가 오지 않고 호출이 타임아웃까지 멈춘다.
        guard registrationStatus != .notRegistered else {
            daemonAvailable = false
            daemonState = nil
            return
        }
        do {
            let state = try await client.getState()
            let wasAvailable = daemonAvailable
            daemonState = state
            daemonAvailable = true
            if !wasAvailable {
                logger.info("데몬 연결됨 (백엔드: \(state.backend.displayName))")
                await syncSettingsWithDaemon()
            }
        } catch {
            // 미등록 상태에서는 매 틱 실패가 정상이므로, 연결이 끊긴 전이에만 로그를 남긴다.
            if daemonAvailable {
                logger.warn("데몬 연결 끊김: \(error.localizedDescription)")
            }
            daemonAvailable = false
            daemonState = nil
        }
    }

    /// 데몬이 (다시) 보이면 앱 설정을 데몬에 동기화한다.
    /// 종료 시 해제(releaseOnQuit)로 일시정지됐던 경우, 앱이 돌아왔으므로 제어를 재개한다.
    private func syncSettingsWithDaemon() async {
        if settings.controlEnabled {
            // 일시정지 상태가 아니어도 무해한 no-op이다. 실패는 무시한다
            // (설정 전송이 뒤이어 제어를 바로잡는다).
            try? await client.setPaused(false)
        }
        await pushSettings()
    }

    /// 현재 앱 설정을 데몬에 전송한다. 데몬이 보이지 않으면 조용히 건너뛴다.
    private func pushSettings() async {
        guard daemonAvailable else { return }
        do {
            try await client.applySettings(settings.toGuardSettings())
            lastError = nil
            logger.debug("설정 전송 완료 (제어 \(settings.controlEnabled ? "켬" : "끔"), 상한 \(settings.upperLimit)%)")
        } catch {
            lastError = "설정 전송 실패: \(error.localizedDescription)"
            logger.error("설정 전송 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - 설정 변경 (팝오버 바인딩이 호출한다; 데몬 전송은 디바운스 구독이 담당)

    func setControlEnabled(_ enabled: Bool) {
        settings.controlEnabled = enabled
        logger.info("충전 제어 \(enabled ? "켬" : "끔") (상한 \(settings.upperLimit)%)")
    }

    func setUpperLimit(_ value: Int) {
        let clamped = min(GuardSettings.maxUpperLimit, max(GuardSettings.minUpperLimit, value))
        guard settings.upperLimit != clamped else { return }
        settings.upperLimit = clamped
    }

    func setForceDischargeEnabled(_ enabled: Bool) {
        settings.forceDischargeEnabled = enabled
        logger.info("강제 방전 \(enabled ? "켬" : "끔")")
    }

    func setReleaseOnQuit(_ enabled: Bool) {
        settings.releaseOnQuit = enabled
    }

    // MARK: - 데몬 등록

    /// 데몬을 LaunchDaemon으로 등록한다. 관리자 인증 프롬프트가 뜰 수 있다.
    func registerDaemon() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if registration.status == .enabled {
                registrationStatus = .enabled
                logger.info("데몬이 이미 등록되어 있습니다.")
            } else {
                try registration.register()
                registrationStatus = registration.status
                logger.info("데몬 등록 완료 (상태: \(registration.displayName))")
            }
            lastError = nil
            await refreshNow()
        } catch {
            registrationStatus = registration.status
            lastError = "등록 실패: \(error.localizedDescription)"
            logger.error("데몬 등록 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - 액션

    /// 1회 100% 완충 시작. 100% 도달 후 어댑터 재연결 또는 시간 경과 시 원래 상한으로 복귀한다 (§14.10).
    func chargeToFullOnce() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.chargeToFullOnce()
            lastError = nil
            logger.info("1회 완충 요청 완료")
            await pollDaemon()
        } catch {
            lastError = "1회 완충 실패: \(error.localizedDescription)"
            logger.error("1회 완충 실패: \(error.localizedDescription)")
        }
    }

    /// 진행 중인 Top Up 취소 (원래 상한으로 즉시 복귀).
    func cancelTopUp() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.cancelTopUp()
            lastError = nil
            logger.info("1회 완충 취소 완료")
            await pollDaemon()
        } catch {
            lastError = "1회 완충 취소 실패: \(error.localizedDescription)"
            logger.error("1회 완충 취소 실패: \(error.localizedDescription)")
        }
    }

    /// 제어 일시정지/재개. 일시정지 시 데몬이 충전 허용 상태로 복원한다.
    func setPaused(_ paused: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.setPaused(paused)
            lastError = nil
            logger.info("제어 일시정지 \(paused ? "켬" : "끔")")
            await pollDaemon()
        } catch {
            lastError = "일시정지 변경 실패: \(error.localizedDescription)"
            logger.error("일시정지 변경 실패: \(error.localizedDescription)")
        }
    }

    /// MactteryGuard 제거: (1) 데몬 XPC uninstall로 충전 복원 확인,
    /// (2) LaunchDaemon 등록 해제 순으로 수행한다.
    /// XPC가 실패해도 제거는 계속한다 — 데몬이 이미 죽어 있으면 복원할 대상이 없고,
    /// 사용자를 제거 불가 상태에 가둬서는 안 된다. 실패는 lastError에 남긴다.
    func uninstall() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.uninstall()
            logger.info("데몬 제거 준비 완료 (충전 복원 확인)")
        } catch {
            logger.warn("데몬 제거 준비 실패 (계속 진행): \(error.localizedDescription)")
            lastError = "충전 복원 확인 실패: \(error.localizedDescription)"
        }
        let status = registration.status
        if status == .enabled || status == .requiresApproval {
            do {
                try registration.unregister()
                registrationStatus = registration.status
            } catch {
                lastError = "등록 해제 실패: \(error.localizedDescription)"
                logger.error("데몬 등록 해제 실패: \(error.localizedDescription)")
                return
            }
        } else {
            registrationStatus = status
        }
        daemonAvailable = false
        daemonState = nil
        settings.controlEnabled = false
        logger.info("MactteryGuard 제거 완료")
    }

    // MARK: - 기타

    /// 로그 폴더(~/Library/Logs/MactteryGuard/)를 Finder에서 연다 (§14.8).
    func openLogsFolder() {
        NSWorkspace.shared.open(GuardLogger.appDirectory())
    }

    /// 승인 대기(.requiresApproval) 안내용: 시스템 설정 로그인 항목 화면을 연다.
    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
