// NotifyAPI.swift — notify(3) 상태 API에 대한 동적 접근.
//
// notify_register_check / notify_get_state / notify_cancel / notify_post는
// <notify.h>에 선언되어 있지만 Swift의 Darwin 모듈에 노출되지 않는다
// (import Darwin을 추가해도 "cannot find in scope" — 2026-11-16 빌드에서 확인).
// 브릿징 헤더 대신 libSystem에서 dlsym으로 가져온다 (PowerUIClient과 같은 패턴).
// 심볼이 없으면 nil을 반환하고 호출자는 폴백 경로로 간다.

import Darwin

/// notify(3) 상태 API. libSystem에 항상 존재하므로 실질적으로 nil이 되지 않지만,
/// 혹시라도 조회에 실패하면 nil을 반환해 호출자가 폴백할 수 있게 한다.
enum NotifyAPI {
    typealias RegisterCheckFn = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> UInt32
    typealias GetStateFn = @convention(c) (Int32, UnsafeMutablePointer<UInt64>) -> UInt32
    typealias CancelFn = @convention(c) (Int32) -> UInt32
    typealias PostFn = @convention(c) (UnsafePointer<CChar>) -> UInt32

    static let registerCheck: RegisterCheckFn? = lookup("notify_register_check")
    static let getState: GetStateFn? = lookup("notify_get_state")
    static let cancel: CancelFn? = lookup("notify_cancel")
    static let post: PostFn? = lookup("notify_post")

    private static func lookup<T>(_ name: String) -> T? {
        // RTLD_DEFAULT는 ((void *) -2) 매크로라 Swift 모듈에 노출되지 않는다.
        // bitPattern으로 직접 만든다 (0이 아니므로 nil이 되지 않는다).
        // static 프로퍼티로 두면 Swift 6에서 Sendable이 아닌 전역 상태로
        // 에러가 나므로, 매번 지역 변수로 만든다 (호출은 시작 시 4번뿐이다).
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = name.withCString({ dlsym(handle, $0) }) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}
