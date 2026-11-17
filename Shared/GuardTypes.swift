// GuardTypes.swift — MactteryGuard 앱·데몬 공용 타입 계약.
//
// 이 파일은 앱 타깃과 헬퍼 데몬 타깃 양쪽에 컴파일된다.
// XPC 프로토콜과 설정·상태 모델의 유일한 정의이며, 양쪽이 반드시
// 같은 버전을 쓴다. 타입을 바꾸면 양쪽이 함께 바뀐다.

import Foundation

// MARK: - 상수

/// 프로젝트 전역 상수 (문자열·식별자).
public enum GuardConstants {
    /// XPC Mach 서비스 이름 = 데몬 LaunchDaemon Label과 동일해야 한다.
    public static let machServiceName = "com.loveaimg.mactteryguard.helper"
    /// SMAppService 등록용 plist 이름 (확장자 제외).
    /// SMAppService.daemon(plistName:)에 넘기는 이름. 확장자 .plist를 포함한
    /// 전체 파일명이어야 한다 — 확장자가 없으면 register()가
    /// "Unable to read plist" 오류로 실패한다.
    public static let daemonPlistName = "com.loveaimg.mactteryguard.helper.plist"
    public static let appBundleID = "com.loveaimg.mactteryguard"
    /// 데몬·앱 공통 버전 (마케팅 버전과 맞춘다).
    public static let version = "0.2.0"

    /// 네이티브 설정 경로 도메인 (BATT_NATIVE_RESEARCH.md §2.3 검증됨).
    public static let topOffProtectionDomain = "com.apple.smartcharging.topoffprotection"
    /// 설정 변경 후 PowerUIAgent에 다시 읽히게 하는 notify 이름.
    public static let settingsChangedNotify = "com.apple.smartcharging.defaultschanged"
    /// macOS 보정 완충 오버라이드 상태 notify 이름 (권한 없이 읽기 가능).
    public static let calibrationOverrideNotify = "com.apple.system.powersources.chargingtofulloverride"

    /// 어댑터 절단 하한 (chargnr 안전 규칙): 잔량이 이하면 어떤 설정으로도 어댑터를 차단하지 않는다.
    public static let adapterCutFloorPercent = 10
    /// 충전 차단 금지 하한 (설계 §9.3): 잔량이 이하면 어떤 경우에도 충전을 차단하지 않는다.
    public static let neverBlockBelowPercent = 20
}

// MARK: - 설정

/// 사용자 설정. 앱(UserDefaults)과 데몬(/Library/Application Support/MactteryGuard/)이
/// 같은 모델을 쓰며, 앱 → 데몬으로는 XPC applySettings로 전달한다.
/// 데몬은 수신 시 `validated()`로 범위를 다시 검증한다 (신뢰하지 않는다).
public struct GuardSettings: Codable, Equatable, Sendable {
    /// 충전 제어 활성화. 초기값 false — 사용자가 켜기 전에는 어떤 쓰기도 하지 않는다.
    public var controlEnabled: Bool = false
    /// 충전 상한 (%). 범위 50...100, 기본 80 (§14.1, §14.5).
    /// 100이면 제어 비활성화와 동일하게 취급한다 (충전 허용 복원).
    public var upperLimit: Int = 80
    /// 히스테리시스 폭 (%). v1은 5로 고정 (§14.2). 하한 = 상한 − 폭.
    public var lowerOffset: Int = 5
    /// 강제 방전(되돌리기) 옵트인. 기본 false (§14.6). 켤 때만 CHIE 방전을 쓴다.
    public var forceDischargeEnabled: Bool = false
    /// 앱 종료 시 충전 제한 해제. 기본 false = 앱을 종료해도 데몬이 계속 유지 (§14.9).
    public var releaseOnQuit: Bool = false
    /// Top Up 후 원래 설정으로 자동 복귀하는 시간 (시간 단위, 기본 24, §14.10).
    public var topUpAutoReturnHours: Int = 24

    public static let minUpperLimit = 50
    public static let maxUpperLimit = 100

    /// 히스테리시스 하한 (%).
    public var lowerLimit: Int { max(10, upperLimit - lowerOffset) }

    public init() {}

    /// 범위 밖 값을 안전한 값으로 교정한다. 데몬은 XPC로 받은 설정을 반드시 이걸로 검증한다.
    public func validated() -> GuardSettings {
        var copy = self
        copy.upperLimit = min(Self.maxUpperLimit, max(Self.minUpperLimit, copy.upperLimit))
        copy.lowerOffset = min(20, max(1, copy.lowerOffset))
        copy.topUpAutoReturnHours = min(72, max(1, copy.topUpAutoReturnHours))
        return copy
    }
}

// MARK: - 백엔드·제어 상태

/// 충전 제어 백엔드 종류. 런타임 가용성 프로브로만 결정한다 (버전 분기 금지).
public enum BackendKind: String, Codable, Sendable {
    /// 아직 프로브 전.
    case unknown
    /// PowerUIAgent 상한 동기화 (이 기기의 주 백엔드).
    case native
    /// 어댑터(CHIE) 토글 (폴백·되돌리기).
    case adapter
    /// CH0B/CH0C 직접 토글. v1 미구현 (인터페이스만 존재).
    case legacy
    /// bfF0/bfD0/bfE0 펌웨어 상·하한. v1 미구현 (인터페이스만 존재).
    case firmware
    /// 어떤 백엔드도 가용하지 않음 — 읽기 전용 모드.
    case unsupported

    public var displayName: String {
        switch self {
        case .unknown: return String(localized: "확인 중")
        case .native: return String(localized: "네이티브 (macOS 상한)")
        case .adapter: return String(localized: "어댑터 (CHIE)")
        case .legacy: return String(localized: "레거시 (SMC)")
        case .firmware: return String(localized: "펌웨어")
        case .unsupported: return String(localized: "제어 불가")
        }
    }
}

/// 제어 상태 머신 상태 (설계 §6.3).
public enum ControlState: String, Codable, Sendable {
    /// 제어 비활성 (한도 100% / 일시정지 / 어댑터 분리 / 제어 꺼짐).
    case idle
    /// 충전 허용 중 (잔량 < 상한).
    case charging
    /// 충전 차단 중 (상한 도달, 하한까지 대기).
    case holding
    /// macOS 보정 중 — 어떤 쓰기도 하지 않는다.
    case calibrating
    /// 보정 종료 후 상한까지 되돌리는 중.
    case dischargeBack
    /// 오류로 충전 허용 복원됨 — 사용자 수동 재개 필요.
    case failOpen
    /// 사용자가 일시정지함.
    case paused

    public var displayName: String {
        switch self {
        case .idle: return String(localized: "대기 중")
        case .charging: return String(localized: "충전 중")
        case .holding: return String(localized: "상한 유지 중")
        case .calibrating: return String(localized: "macOS 보정 중")
        case .dischargeBack: return String(localized: "상한으로 되돌리는 중")
        case .failOpen: return String(localized: "오류 — 충전 허용됨")
        case .paused: return String(localized: "일시정지됨")
        }
    }
}

/// 1회 완충(Top Up) 상태 (§14.10).
public enum TopUpState: String, Codable, Sendable {
    /// Top Up 비활성.
    case inactive
    /// Top Up 진행 중 (상한 100%로 충전 중).
    case active
    /// 100% 도달 — 어댑터 재연결 또는 시간 경과 시 원래 상한으로 복귀 대기.
    case reached

    public var displayName: String {
        switch self {
        case .inactive: return String(localized: "꺼짐")
        case .active: return String(localized: "1회 완충 중")
        case .reached: return String(localized: "100% 도달 — 복귀 대기")
        }
    }
}

// MARK: - 배터리 읽기

/// 배터리 상태 (정상/보통/교체 권장/알 수 없음).
/// IOPS "BatteryHealth"(Good/Fair/Poor) 또는 IORegistry PermanentFailureStatus에서 매핑한다.
public enum BatteryCondition: String, Sendable {
    case normal
    case fair
    case poor
    case unknown

    public var displayName: String {
        switch self {
        case .normal: return String(localized: "정상")
        case .fair: return String(localized: "보통")
        case .poor: return String(localized: "교체 권장")
        case .unknown: return String(localized: "알 수 없음")
        }
    }
}

/// 배터리 스냅샷 한 번분. 앱 표시용과 데몬 제어 판단용이 같은 모델을 쓴다.
public struct BatteryReading: Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var isOnAC: Bool
    /// 충전 중이면 완충까지, 방전 중이면 방전까지 남은 시간(분). 알 수 없으면 nil.
    public var timeRemainingMinutes: Int?
    /// 사이클 수 (상세 읽기 시에만 채워진다).
    public var cycleCount: Int?
    /// 배터리 상태 (상세 읽기 시에만 채워진다).
    public var condition: BatteryCondition?
    /// 최대 용량 (%) = FullChargeCapacity / DesignCapacity (상세 읽기 시에만 채워진다).
    public var maxCapacityPercent: Int?
    /// 배터리 온도 (°C, 상세 읽기 시에만 채워진다).
    public var temperatureCelsius: Double?
    /// 온도를 읽은 출처 ("IORegistry" / "IOPS" / "SMC TB0T"). 디버깅용.
    public var temperatureSource: String?
    public var timestamp: Date

    public init(
        percent: Int,
        isCharging: Bool,
        isOnAC: Bool,
        timeRemainingMinutes: Int? = nil,
        cycleCount: Int? = nil,
        condition: BatteryCondition? = nil,
        maxCapacityPercent: Int? = nil,
        temperatureCelsius: Double? = nil,
        temperatureSource: String? = nil,
        timestamp: Date = Date()
    ) {
        self.percent = percent
        self.isCharging = isCharging
        self.isOnAC = isOnAC
        self.timeRemainingMinutes = timeRemainingMinutes
        self.cycleCount = cycleCount
        self.condition = condition
        self.maxCapacityPercent = maxCapacityPercent
        self.temperatureCelsius = temperatureCelsius
        self.temperatureSource = temperatureSource
        self.timestamp = timestamp
    }
}

// MARK: - 데몬 상태 (XPC로 앱에 전달)

/// 데몬 상태 스냅샷. XPC getState의 응답으로 JSON 인코딩되어 전달된다.
public struct DaemonState: Codable, Sendable {
    public var backend: BackendKind
    public var controlState: ControlState
    public var calibrationActive: Bool
    /// 보정을 감지한 신호 ("notify" / "log" / "관찰" 등). 없으면 nil.
    public var calibrationSource: String?
    public var percent: Int
    public var isCharging: Bool
    public var isOnAC: Bool
    /// pmset -g battlimit 기준 상한 등록 여부. nil = 확인 불가(미확인).
    public var limitRegistered: Bool?
    /// 네이티브 등록 대기 중 (등록이 늦어지는 정상 상태).
    public var registrationPending: Bool
    public var topUp: TopUpState
    /// 마지막 쓰기 설명 (예: "2026-11-16 04:30:12 상한 80% 설정 (상태 전이)").
    public var lastWriteDescription: String?
    /// 마지막 오류 설명. 없으면 nil.
    public var lastError: String?
    /// 백엔드 프로브 결과 요약 (예: "Native 가용, CHIE 가용, CH0B 부재").
    public var backendDetails: String
    /// 데몬이 현재 적용 중인 설정.
    public var settings: GuardSettings
    public var daemonVersion: String
    public var timestamp: Date

    public init(
        backend: BackendKind = .unknown,
        controlState: ControlState = .idle,
        calibrationActive: Bool = false,
        calibrationSource: String? = nil,
        percent: Int = 0,
        isCharging: Bool = false,
        isOnAC: Bool = false,
        limitRegistered: Bool? = nil,
        registrationPending: Bool = false,
        topUp: TopUpState = .inactive,
        lastWriteDescription: String? = nil,
        lastError: String? = nil,
        backendDetails: String = "",
        settings: GuardSettings = GuardSettings(),
        daemonVersion: String = GuardConstants.version,
        timestamp: Date = Date()
    ) {
        self.backend = backend
        self.controlState = controlState
        self.calibrationActive = calibrationActive
        self.calibrationSource = calibrationSource
        self.percent = percent
        self.isCharging = isCharging
        self.isOnAC = isOnAC
        self.limitRegistered = limitRegistered
        self.registrationPending = registrationPending
        self.topUp = topUp
        self.lastWriteDescription = lastWriteDescription
        self.lastError = lastError
        self.backendDetails = backendDetails
        self.settings = settings
        self.daemonVersion = daemonVersion
        self.timestamp = timestamp
    }
}

// MARK: - XPC 프로토콜

/// 앱 ↔ 데몬 XPC 인터페이스 (설계 §4.3).
/// 설정·상태는 JSON Data로 주고받는다 (커스텀 클래스 없이 plist 안전 타입만 사용).
/// 데몬은 모든 요청의 값을 범위 검증한 뒤에만 수행한다.
@objc public protocol MactteryGuardHelperProtocol {
    /// 현재 데몬 상태 스냅샷 (DaemonState JSON).
    func getState(reply: @escaping (Data?, NSError?) -> Void)
    /// 설정 적용 (GuardSettings JSON). 데몬이 검증·저장·적용한다.
    func applySettings(_ settingsData: Data, reply: @escaping (NSError?) -> Void)
    /// 1회 100% 완충 시작. 100% 도달 후 재연결/시간 경과 시 원래 상한으로 복귀한다.
    func chargeToFullOnce(reply: @escaping (NSError?) -> Void)
    /// 진행 중인 Top Up 취소 (원래 상한으로 즉시 복귀).
    func cancelTopUp(reply: @escaping (NSError?) -> Void)
    /// 제어 일시정지/재개. 일시정지 시 충전 허용 상태로 복원한다.
    func setPaused(_ paused: Bool, reply: @escaping (NSError?) -> Void)
    /// 제거 준비: 충전 허용 복원 후 성공을 반환한다. 앱이 이어서 데몬 unregister를 수행한다.
    func uninstall(reply: @escaping (NSError?) -> Void)
}

/// XPC 오류 도메인·코드 (앱·데몬 공용).
public enum GuardXPCError {
    public static let domain = "com.loveaimg.mactteryguard.helper"
    /// 설정 JSON 디코드 실패 또는 범위 밖 값.
    public static let invalidSettings = 1
    /// 데몬 내부 오류 (백엔드 실패 등).
    public static let internalError = 2
    /// 데몬이 아직 시작되지 않았거나 제어 루프가 준비되지 않음.
    public static let notReady = 3

    public static func error(code: Int, description: String) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
