// SleepWakeMonitor.swift — 수면/복귀 알림 구독 (데몬용).
//
// 데몬은 앱과 달리 NSWorkspace 알림을 쓸 수 없으므로 (GUI 세션 밖에서 동작),
// IOKit 전원 알림(IORegisterForSystemPower)을 직접 구독한다.
//  - 수면 직전 (kIOMessageSystemWillSleep): 어댑터 모드면 어댑터를 다시 켠다
//    (수면 중 절단 상태로 방전되는 것을 방지, chargnr·batt 공통 원칙).
//    반드시 IOAllowPowerChange를 호출해야 시스템이 잠든다.
//  - 복귀 (kIOMessageSystemHasPoweredOn): 즉시 재확인·재적용 (복귀 시 reconcile).
//  - 수면 가능 여부 (kIOMessageCanSystemSleep): 허용한다 (수면을 막지 않는다).
//
// 안전망: 제어 루프 자체도 틱 간격으로 수면 갭을 감지한다 (60초 이상 건너뛰면
// 복귀한 것으로 간주해 재확인). 알림 구독이 실패해도 루프가 커버한다.

import Foundation
import IOKit
import IOKit.pwr_mgt

private let kIOMessageCanSystemSleep: UInt32 = 0x00010010
private let kIOMessageSystemWillSleep: UInt32 = 0x00010011
private let kIOMessageSystemHasPoweredOn: UInt32 = 0x00010020

public final class SleepWakeMonitor {
    public var onWillSleep: (() -> Void)?
    public var onWake: (() -> Void)?

    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private let logger: GuardLogger

    public init(logger: GuardLogger) {
        self.logger = logger
    }

    deinit {
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
        }
    }

    /// 전원 알림 구독 시작. 실패하면 false (루프의 갭 감지가 대신한다).
    @discardableResult
    public func start() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        var notifierObject: io_object_t = 0
        let root = IORegisterForSystemPower(context, &port, sleepWakeCallback, &notifierObject)
        guard root != 0, let port else {
            logger.warn("수면/복귀 알림 구독 실패 — 루프 갭 감지로 대체")
            return false
        }
        self.rootPort = root
        self.notificationPort = port
        self.notifier = notifierObject
        // 콜백을 메인 큐에서 받는다 (엔진은 @MainActor).
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        logger.info("수면/복귀 알림 구독 시작")
        return true
    }

    fileprivate func handle(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case kIOMessageCanSystemSleep:
            // 수면을 막지 않는다. 허용 응답이 없으면 시스템이 30초 대기 후 강제 수면한다.
            IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
        case kIOMessageSystemWillSleep:
            onWillSleep?()
            IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
        case kIOMessageSystemHasPoweredOn:
            onWake?()
        default:
            break
        }
    }
}

/// C 콜백 트램펄린. context에 SleepWakeMonitor의 비소유 참조가 들어 있다.
/// (모니터는 엔진이 데몬 수명 동안 소유하므로, 콜백 시점에 살아 있음이 보장된다.)
/// 파라미터 라벨이 없는 것이 @convention(c) 콜백 타입과 일치한다.
private func sleepWakeCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<SleepWakeMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handle(messageType: messageType, messageArgument: messageArgument)
}
