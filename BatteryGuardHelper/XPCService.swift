// XPCService.swift — 데몬 측 XPC 리스너 + 프로토콜 구현.
//
// launchd가 관리하는 Mach 서비스(com.loveaimg.mactteryguard.helper)로 들어오는
// 앱의 요청을 받는다. 리스너 델리게이트와 프로토콜 구현체를 겸한다.
// XPC 콜백은 임의 큐에서 오므로, 모든 처리는 MainActor 태스크로 넘겨
// 제어 엔진과 같은 격리 영역에서 수행한 뒤 reply한다.
//
// 보안: 데몬은 요청 값을 무조건 신뢰하지 않는다. 설정은 GuardSettings.validated()로
// 범위를 검증한 뒤에만 적용한다 (ControlEngine.applySettings). XPC 연결 자체는
// launchd Mach 서비스 계층이 관리한다. v1에서는 연결 프로세스의 코드 서명을
// 별도 검증하지 않는다 (로컬 머신의 낮은 위험으로 판단, IMPLEMENTATION_NOTES 참조).

import Foundation

/// 비-Sendable 값을 Sendable 컨텍스트(Task)로 전달하기 위한 래퍼.
/// XPC reply 블록은 NSXPCConnection이 소유하고 어느 스레드에서든 한 번만
/// 호출하도록 설계됐으며 가변 공유 상태를 캡처하지 않으므로, MainActor
/// 태스크에서 호출해도 안전하다. (@objc 프로토콜의 reply 파라미터에는
/// @Sendable을 붙일 수 없어 래퍼가 필요하다.)
private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// XPCService는 @unchecked Sendable이다. 가변 상태(encoder/decoder)는
// 모든 프로토콜 메서드가 MainActor 태스크 안에서만 쓰므로 직렬화되고,
// NSXPCListener 자체는 스레드 안전하게 설계됐다. main.swift의 전역 let
// 바인딩과 Task 캡처(Swift 6 Sendable 규칙)에 필요하다.
public final class XPCService: NSObject, NSXPCListenerDelegate, MactteryGuardHelperProtocol, @unchecked Sendable {
    private let engine: ControlEngine
    private let logger: GuardLogger
    private let listener: NSXPCListener
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(engine: ControlEngine, logger: GuardLogger) {
        self.engine = engine
        self.logger = logger
        self.listener = NSXPCListener(machServiceName: GuardConstants.machServiceName)
        super.init()
        listener.delegate = self
    }

    public func resume() {
        listener.resume()
        logger.info("XPC 리스너 시작 (\(GuardConstants.machServiceName))")
    }

    public func suspend() {
        listener.suspend()
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: MactteryGuardHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        logger.debug("XPC 연결 수락")
        return true
    }

    // MARK: - MactteryGuardHelperProtocol

    public func getState(reply: @escaping (Data?, NSError?) -> Void) {
        let replyBox = SendableBox(reply)
        Task { @MainActor in
            let state = self.engine.currentState()
            do {
                let data = try self.encoder.encode(state)
                replyBox.value(data, nil)
            } catch {
                replyBox.value(nil, GuardXPCError.error(
                    code: GuardXPCError.internalError,
                    description: "상태 인코딩 실패: \(error.localizedDescription)"
                ))
            }
        }
    }

    public func applySettings(_ settingsData: Data, reply: @escaping (NSError?) -> Void) {
        let replyBox = SendableBox(reply)
        Task { @MainActor in
            do {
                let settings = try self.decoder.decode(GuardSettings.self, from: settingsData)
                switch self.engine.applySettings(settings) {
                case .success:
                    replyBox.value(nil)
                case .failure(let error as NSError):
                    replyBox.value(error)
                }
            } catch {
                self.logger.warn("설정 디코드 실패: \(error.localizedDescription)")
                replyBox.value(GuardXPCError.error(
                    code: GuardXPCError.invalidSettings,
                    description: "설정 형식이 올바르지 않습니다"
                ))
            }
        }
    }

    public func chargeToFullOnce(reply: @escaping (NSError?) -> Void) {
        let replyBox = SendableBox(reply)
        Task { @MainActor in
            switch self.engine.chargeToFullOnce() {
            case .success:
                replyBox.value(nil)
            case .failure(let error as NSError):
                replyBox.value(error)
            }
        }
    }

    public func cancelTopUp(reply: @escaping (NSError?) -> Void) {
        let replyBox = SendableBox(reply)
        Task { @MainActor in
            self.engine.cancelTopUp()
            replyBox.value(nil)
        }
    }

    public func setPaused(_ paused: Bool, reply: @escaping (NSError?) -> Void) {
        let replyBox = SendableBox(reply)
        Task { @MainActor in
            self.engine.setPaused(paused)
            replyBox.value(nil)
        }
    }

    public func uninstall(reply: @escaping (NSError?) -> Void) {
        let replyBox = SendableBox(reply)
        Task { @MainActor in
            let ok = self.engine.uninstall()
            if ok {
                replyBox.value(nil)
            } else {
                replyBox.value(GuardXPCError.error(
                    code: GuardXPCError.internalError,
                    description: "충전 허용 복원에 실패했습니다"
                ))
            }
        }
    }
}
