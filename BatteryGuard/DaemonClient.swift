import Foundation

/// Step 2 — 데몬 XPC 클라이언트. 앱 → 데몬 통신의 유일한 통로.
/// NSXPCConnection(machServiceName:)으로 데몬에 연결하고,
/// GuardTypes.swift의 MactteryGuardHelperProtocol 6개 메서드를 async/await로 감싼다.
/// XPC 오류는 그대로 던진다 — 호출자(AppState)가 데몬 미등록·미실행을 구분할 수 있게 한다.
/// JSON 인코딩은 Foundation 기본값(날짜는 deferredToDate)을 쓰며, 데몬도 같은 기본값을 써야 한다.
///
/// 타임아웃: 데몬 미등록 시 Mach 서비스가 없어 reply가 오지 않는데, 연결이
/// 무효화되면서 reply 클로저가 버려지면 continuation이 새어
/// "SWIFT TASK CONTINUATION MISUSE"가 발생한다 (2026-11-16 런타임 확인).
/// 모든 호출은 withXPCResult를 거쳐 5초 타임아웃으로 반드시 완료된다.
@MainActor
final class DaemonClient {
    private var connection: NSXPCConnection?

    /// 현재 연결의 프록시. 연결이 없거나 무효화됐으면 새로 만든다.
    private func proxy() throws -> MactteryGuardHelperProtocol {
        if let connection {
            guard let proxy = connection.remoteObjectProxy as? MactteryGuardHelperProtocol else {
                throw GuardXPCError.error(
                    code: GuardXPCError.internalError, description: "XPC 프록시를 만들 수 없습니다."
                )
            }
            return proxy
        }
        let newConnection = NSXPCConnection(machServiceName: GuardConstants.machServiceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: MactteryGuardHelperProtocol.self)
        // 무효화되면 캐시를 비워 다음 호출에서 재생성한다.
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connection = nil
            }
        }
        newConnection.resume()
        connection = newConnection
        guard let proxy = newConnection.remoteObjectProxy as? MactteryGuardHelperProtocol else {
            throw GuardXPCError.error(
                code: GuardXPCError.internalError, description: "XPC 프록시를 만들 수 없습니다."
            )
        }
        return proxy
    }

    /// XPC 호출을 타임아웃과 함께 수행한다. reply와 타임아웃 중 먼저 온 것만 적용된다.
    private func withXPCResult<T: Sendable>(
        timeoutSeconds: UInt64 = 5,
        _ invoke: @escaping (@escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeBox(continuation)
            invoke { result in box.resume(with: result) }
            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                box.resume(with: .failure(GuardXPCError.error(
                    code: GuardXPCError.internalError,
                    description: "응답 시간 초과 (\(timeoutSeconds)초)"
                )))
            }
        }
    }

    /// 현재 데몬 상태 스냅샷. 데몬 미등록·미실행 시 XPC 오류를 던진다.
    func getState() async throws -> DaemonState {
        let remote = try proxy()
        let data: Data = try await withXPCResult { resume in
            // reply 클로저는 ResumeBox(Sendable)만 캡처한다. self를 캡처하지 않는다.
            remote.getState { data, error in
                if let error {
                    resume(.failure(error))
                } else if let data {
                    resume(.success(data))
                } else {
                    resume(.failure(GuardXPCError.error(
                        code: GuardXPCError.internalError, description: "빈 응답을 받았습니다."
                    )))
                }
            }
        }
        return try JSONDecoder().decode(DaemonState.self, from: data)
    }

    /// 설정 적용. 전송 전에 validated()로 범위를 교정한다 (데몬도 다시 검증한다).
    func applySettings(_ settings: GuardSettings) async throws {
        let remote = try proxy()
        let data = try JSONEncoder().encode(settings.validated())
        let _: Void = try await withXPCResult { resume in
            remote.applySettings(data) { error in
                if let error {
                    resume(.failure(error))
                } else {
                    resume(.success(()))
                }
            }
        }
    }

    /// 1회 100% 완충 시작.
    func chargeToFullOnce() async throws {
        let remote = try proxy()
        let _: Void = try await withXPCResult { resume in
            remote.chargeToFullOnce { error in
                if let error {
                    resume(.failure(error))
                } else {
                    resume(.success(()))
                }
            }
        }
    }

    /// 진행 중인 Top Up 취소 (원래 상한으로 즉시 복귀).
    func cancelTopUp() async throws {
        let remote = try proxy()
        let _: Void = try await withXPCResult { resume in
            remote.cancelTopUp { error in
                if let error {
                    resume(.failure(error))
                } else {
                    resume(.success(()))
                }
            }
        }
    }

    /// 제어 일시정지/재개. 일시정지 시 데몬이 충전 허용 상태로 복원한다.
    func setPaused(_ paused: Bool) async throws {
        let remote = try proxy()
        let _: Void = try await withXPCResult { resume in
            remote.setPaused(paused) { error in
                if let error {
                    resume(.failure(error))
                } else {
                    resume(.success(()))
                }
            }
        }
    }

    /// 제거 준비: 데몬이 충전 허용 복원을 마친 뒤 성공을 반환한다.
    /// 앱은 이어서 DaemonRegistration.unregister()를 수행한다.
    func uninstall() async throws {
        let remote = try proxy()
        let _: Void = try await withXPCResult { resume in
            remote.uninstall { error in
                if let error {
                    resume(.failure(error))
                } else {
                    resume(.success(()))
                }
            }
        }
    }
}

/// CheckedContinuation을 한 번만 재개하는 상자. reply와 타임아웃이
/// 경합하므로 락으로 보호한다 (reply는 임의 큐에서 온다).
/// T: Sendable이 필요하다 — resume(returning:)의 파라미터가 sending이라
/// Sendable이 아닌 값을 넘기면 Swift 6에서 데이터 레이스 에러가 난다.
private final class ResumeBox<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
