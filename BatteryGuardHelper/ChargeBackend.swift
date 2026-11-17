// ChargeBackend.swift — 충전 제어 백엔드 추상화.
//
// 백엔드는 "상한을 강제하는 방법"의 구현체다. 제어 엔진(ControlEngine)은
// 이 프로토콜만 보고 동작하므로, 백엔드 교체가 엔진 로직에 영향을 주지 않는다.
// (설계 §5.3: v1은 Native + Adapter만 구현하고, Legacy/Firmware은 인터페이스만 둔다.)
//
// 두 가지 실행 형태 (BATT_NATIVE_RESEARCH.md §5.5):
//  - 관리형 (Native): 상한을 설정해 두면 macOS가 강제한다. 엔진은 주기적으로
//    설정이 유지되는지 재확인(reconcile)만 한다.
//  - 능동형 (Adapter): 엔진이 배터리 %를 읽고 히스테리시스 루프로 스위치를 토글한다.

import Foundation

/// 백엔드 동작 결과.
public enum BackendResult: Equatable {
    /// 적용 완료 (확인됨).
    case applied
    /// 적용 요청은 됐으나 등록·반영 대기 중 (오류 아님, 다음 패스에서 재확인).
    case pending
    /// 실패 (사유 포함).
    case failed(String)
}

/// 충전 제어 백엔드 프로토콜. 모든 메서드는 동기 호출이다.
/// (데몬 제어 루프는 메인 스레드에서 동기적으로 동작한다.)
public protocol ChargeBackend: AnyObject {
    var kind: BackendKind { get }

    /// 이 백엔드가 현재 기기에서 가용한지 런타임 프로브한다.
    /// 버전 분기는 하지 않는다 — 키·서비스 가용성만 본다.
    func probe() -> Bool

    /// 상한을 설정한다 (단위 %).
    /// - Parameter isCalibrating: 보정 중이면 원래 값 저장을 건너뛴다
    ///   (보정 중 도메인 읽기는 오염됨 — 2026-11-16 실측).
    /// - Returns: .applied(확인됨) / .pending(등록 대기) / .failed(사유).
    func setLimit(_ limit: Int, isCalibrating: Bool) -> BackendResult

    /// 현재 적용 중인 상한을 읽는다. 알 수 없으면 nil.
    func currentLimit() -> Int?

    /// 충전 허용 상태로 복원한다 (FAIL-OPEN).
    /// Native: 사용자가 원래 쓰던 상한으로 복원 (없으면 해제).
    /// Adapter: 어댑터 허용(00)으로 복원.
    /// - Returns: 복원 성공 여부.
    func restore() -> Bool

    /// 일시 중단: 충전 허용 상태로 복원하되, 원래 값 기록은 보존한다
    /// (일시정지 등 나중에 제어를 재개할 때 필요).
    /// 기본 구현은 restore()와 동일하다. Native만 따로 구현한다.
    func suspend() -> Bool

    /// 기대 상태와 실제 상태가 일치하는지 재확인한다 (60초 reconcile용).
    /// 불일치하면 false를 반환하고, 엔진이 재적용한다.
    func verify(expectedLimit: Int) -> Bool
}

/// v1에서 구현하지 않는 백엔드용 스텁. probe()가 항상 false를 반환하므로
/// 선택 로직에서 절대 선택되지 않는다. 인터페이스 자리만 차지한다.
public final class UnavailableBackend: ChargeBackend {
    public let kind: BackendKind

    public init(kind: BackendKind) {
        self.kind = kind
    }

    public func probe() -> Bool { false }
    public func setLimit(_ limit: Int, isCalibrating: Bool) -> BackendResult {
        .failed("\(kind.displayName) 백엔드는 v1에서 구현되지 않았습니다")
    }
    public func currentLimit() -> Int? { nil }
    public func restore() -> Bool { true }
    public func suspend() -> Bool { true }
    public func verify(expectedLimit: Int) -> Bool { false }
}

/// suspend() 기본 구현: 별도 구현이 없는 백엔드는 restore()와 동일하다.
public extension ChargeBackend {
    func suspend() -> Bool { restore() }
}
