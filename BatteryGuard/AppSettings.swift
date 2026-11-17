import Foundation
import Combine

/// UserDefaults 키. AppDelegate(종료 시 해제 여부 확인)도 같은 키를 쓰므로
/// 파일 스코프에 둔다 (@MainActor 클래스 안에 두면 비격리 접근이 안 된다).
private enum AppSettingsKey {
    static let controlEnabled = "bg.controlEnabled"
    static let upperLimit = "bg.upperLimit"
    static let forceDischargeEnabled = "bg.forceDischargeEnabled"
    static let releaseOnQuit = "bg.releaseOnQuit"
    static let topUpAutoReturnHours = "bg.topUpAutoReturnHours"
}

/// Step 2 — UserDefaults 기반 사용자 설정.
/// 앱 설정의 원본(source of truth)이며, AppState가 변경을 감지해 데몬에 전송한다.
/// 기본값은 GuardSettings 기본값과 동일하다 (§14.1: 상한 80%, §14.6: 강제 방전 OFF,
/// §14.9: 앱 종료 시 유지, §14.10: Top Up 자동 복귀 24시간).
@MainActor
final class AppSettings: ObservableObject {
    @Published var controlEnabled: Bool {
        didSet { UserDefaults.standard.set(controlEnabled, forKey: AppSettingsKey.controlEnabled) }
    }
    @Published var upperLimit: Int {
        didSet { UserDefaults.standard.set(upperLimit, forKey: AppSettingsKey.upperLimit) }
    }
    @Published var forceDischargeEnabled: Bool {
        didSet { UserDefaults.standard.set(forceDischargeEnabled, forKey: AppSettingsKey.forceDischargeEnabled) }
    }
    @Published var releaseOnQuit: Bool {
        didSet { UserDefaults.standard.set(releaseOnQuit, forKey: AppSettingsKey.releaseOnQuit) }
    }
    @Published var topUpAutoReturnHours: Int {
        didSet { UserDefaults.standard.set(topUpAutoReturnHours, forKey: AppSettingsKey.topUpAutoReturnHours) }
    }

    init() {
        let defaults = GuardSettings()
        UserDefaults.standard.register(defaults: [
            AppSettingsKey.controlEnabled: defaults.controlEnabled,
            AppSettingsKey.upperLimit: defaults.upperLimit,
            AppSettingsKey.forceDischargeEnabled: defaults.forceDischargeEnabled,
            AppSettingsKey.releaseOnQuit: defaults.releaseOnQuit,
            AppSettingsKey.topUpAutoReturnHours: defaults.topUpAutoReturnHours,
        ])
        let stored = UserDefaults.standard
        controlEnabled = stored.bool(forKey: AppSettingsKey.controlEnabled)
        // 손상된 저장값을 방어적으로 범위 안으로 교정한다.
        upperLimit = min(
            GuardSettings.maxUpperLimit,
            max(GuardSettings.minUpperLimit, stored.integer(forKey: AppSettingsKey.upperLimit))
        )
        forceDischargeEnabled = stored.bool(forKey: AppSettingsKey.forceDischargeEnabled)
        releaseOnQuit = stored.bool(forKey: AppSettingsKey.releaseOnQuit)
        topUpAutoReturnHours = stored.integer(forKey: AppSettingsKey.topUpAutoReturnHours)
    }

    /// 데몬 전송용 GuardSettings로 변환한다. lowerOffset은 v1 고정값 5를 쓴다 (§14.2).
    func toGuardSettings() -> GuardSettings {
        var settings = GuardSettings()
        settings.controlEnabled = controlEnabled
        settings.upperLimit = upperLimit
        settings.forceDischargeEnabled = forceDischargeEnabled
        settings.releaseOnQuit = releaseOnQuit
        settings.topUpAutoReturnHours = topUpAutoReturnHours
        return settings.validated()
    }

    /// GuardSettings 값을 앱 설정으로 불러온다 (각 프로퍼티의 didSet이 UserDefaults에 저장한다).
    /// lowerOffset은 v1 고정값이라 적용하지 않는다.
    func apply(_ settings: GuardSettings) {
        let validated = settings.validated()
        controlEnabled = validated.controlEnabled
        upperLimit = validated.upperLimit
        forceDischargeEnabled = validated.forceDischargeEnabled
        releaseOnQuit = validated.releaseOnQuit
        topUpAutoReturnHours = validated.topUpAutoReturnHours
    }

    /// 종료 처리(AppDelegate)용: 앱 인스턴스 없이 저장된 releaseOnQuit만 읽는다.
    /// UserDefaults는 스레드 안전하므로 비격리(nonisolated) 접근이 안전하다.
    nonisolated static var storedReleaseOnQuit: Bool {
        UserDefaults.standard.bool(forKey: AppSettingsKey.releaseOnQuit)
    }
}
