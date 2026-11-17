// main.swift — MactteryGuardHelper 데몬 진입점 (LaunchDaemon, root).
//
// launchd가 부팅 시(또는 Mach 서비스 첫 연결 시) 실행한다.
//  1. 로거·저장소·제어 엔진·XPC 서비스를 만든다.
//  2. 제어 엔진을 시작한다 (백엔드 선택 + 제어 루프).
//  3. XPC 리스너를 시작한다.
//  4. SIGTERM/SIGINT 시 충전 허용으로 복원한 뒤 종료한다 (FAIL-OPEN).
//  5. 메인 런루프를 돌린다.
//
// 종료 시 복원이 핵심이다: 어떤 이유로 데몬이 멈추든 배터리가 차단 상태로
// 고착되어서는 안 된다. 시그널 핸들러는 MainActor 태스크로 복원을 수행하고,
// 2초 안에 끝나지 않으면 강제 종료한다 (복원보다 무한 대기가 나쁘다).
// 크래시 시에는 launchd(KeepAlive)가 데몬을 재시작하고, 시작 시 섀도 상태를
// 보고 재동기화한다.

import Darwin
import Foundation

let logger = GuardLogger(directory: GuardLogger.daemonDirectory(), filePrefix: "helper")
logger.info("MactteryGuardHelper 시작 (pid \(ProcessInfo.processInfo.processIdentifier), euid \(geteuid()))")

if geteuid() != 0 {
    logger.warn("데몬이 root가 아닌 사용자로 실행 중입니다 — 설정 경로·SMC 쓰기가 동작하지 않을 수 있습니다")
}

let store = DaemonStore()
let engine = ControlEngine(store: store, logger: logger)
let xpcService = XPCService(engine: engine, logger: logger)

// MARK: - Signal handling (FAIL-OPEN on termination)

/// 시그널 소스 보관소. DispatchSourceSignal은 Sendable이 아니므로
/// 전역 상태로 두려면 락으로 보호하는 래퍼가 필요하다 (Swift 6 전역 상태 규칙).
/// 소스는 데몬 수명 동안 유지되어야 한다 (해제되면 시그널을 받지 못한다).
final class SignalSourceStore: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()

    func append(_ source: DispatchSourceSignal) {
        lock.lock()
        defer { lock.unlock() }
        sources.append(source)
    }
}

let signalSources = SignalSourceStore()

func installSignalHandler(for sig: Int32) {
    // 기본 동작을 무시하고 DispatchSource로 받는다.
    // (파라미터 이름이 signal이면 Darwin의 signal() 함수를 가려서
    // "Cannot call value of non-function type 'Int32'" 에러가 난다.)
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        logger.info("시그널 수신 (\(sig)) — 충전 허용 복원 후 종료")
        Task { @MainActor in
            _ = engine.shutdownRestore()
            engine.stop()
            exit(0)
        }
        // 복원이 2초 안에 끝나지 않으면 강제 종료한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            logger.warn("종료 복원 타임아웃 — 강제 종료")
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

installSignalHandler(for: SIGTERM)
installSignalHandler(for: SIGINT)
installSignalHandler(for: SIGHUP)

// MARK: - Start

// 엔진 시작은 MainActor에서 수행한다 (ControlEngine이 @MainActor).
Task { @MainActor in
    engine.start()
    xpcService.resume()
}

// 메인 런루프를 돌린다. Timer·XPC·수면 알림이 이 루프에서 동작한다.
RunLoop.main.run()
