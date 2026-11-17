import Foundation
import ServiceManagement

/// Step 2 — LaunchDaemon 등록 관리 (SMAppService).
/// register()는 관리자 인증 프롬프트를 띄울 수 있으며,
/// 승인 대기 상태(.requiresApproval)면 사용자가 시스템 설정 →
/// 일반 → 로그인 항목 및 확장 프로그램에서 직접 승인해야 한다.
/// 참고: 데몬 plist가 앱 번들 Contents/Library/LaunchDaemons/ 안에 있어야 하며,
/// 없으면 상태가 .notFound가 되고 register()가 실패한다 (패키징 담당).
@MainActor
final class DaemonRegistration {
    private let service = SMAppService.daemon(plistName: GuardConstants.daemonPlistName)

    /// 현재 등록 상태 (동기 조회).
    var status: SMAppService.Status {
        service.status
    }

    /// 충전 제어를 켤 수 있는 상태인지 (등록되어 있고 승인까지 완료됨).
    var isRegistered: Bool {
        status == .enabled
    }

    var displayName: String {
        Self.displayName(for: status)
    }

    /// 데몬을 LaunchDaemon으로 등록한다. 관리자 인증이 필요할 수 있다.
    /// SMAppService는 등록이 성공해도 "Operation not permitted"를 던지는 경우가
    /// 있다 (2026-11-16 실측 2회 — 에러 후에도 데몬이 등록·실행됨). 에러가 나면
    /// 상태를 다시 확인해 .enabled면 성공으로 본다.
    func register() throws {
        do {
            try service.register()
        } catch {
            if status == .enabled { return }
            throw error
        }
    }

    /// 데몬 등록을 해제한다. 호출 전에 AppState가 XPC uninstall로 충전 복원을 요청한다.
    func unregister() throws {
        try service.unregister()
    }

    /// 등록 상태의 UI 표시용 문자열.
    static func displayName(for status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "미등록"
        case .enabled: return "등록됨"
        case .requiresApproval: return "승인 대기 중"
        case .notFound: return "찾을 수 없음"
        @unknown default: return "알 수 없음"
        }
    }
}
