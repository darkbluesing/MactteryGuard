// CalibrationDetector.swift — macOS 보정(완충 강제) 감지.
//
// 보정 중에는 macOS가 모든 충전 제한을 무시하므로 (AlDente 공식 인정),
// 감지가 되면 엔진은 쓰기를 중단하고 보정이 끝나기를 기다린다.
// 감지 경로 3개 (BATT_NATIVE_RESEARCH.md §6, §9.4):
//  1) notify 상태 (1차): com.apple.system.powersources.chargingtofulloverride.
//     권한 없이 읽을 수 있고 로그 문구에 의존하지 않는다.
//     단, 부팅 후 powerd가 처음 post하기 전에는 0으로 읽히므로,
//     초기 0을 "보정 아님"으로 단정하지 않고 로그·관찰과 교차 확인한다.
//  2) OSLogStore (2차): PowerUIAgent 로그에서 ChargingUpForGauging /
//     "mitigations are in place" 검출. GaugingMitigationActions는 정상 항목이라 무시한다.
//     데몬은 root이므로 전체 로그를 읽을 수 있다 (샌드박스 없음).
//  3) 관찰 기반 (3차, 엔진에서 수행): 충전 차단 상태에서 잔량이 60초 간격으로
//     2회 연속 상승하면 보정으로 간주한다. 이 파일은 로그·notify만 담당한다.
//
// 보정 종료 판정: notify 0 + 최근 10분 로그 신호 없음 + (100% 도달 또는 잔량 정체).
// 종료 판정의 최종 결정은 엔진이 상태와 함께 내린다.

import Darwin
import Foundation
import OSLog

public final class CalibrationDetector {
    private let logger: GuardLogger

    /// 마지막 로그 폴링 시각 (너무 잦은 폴링 방지용).
    private var lastLogPoll: Date = .distantPast
    /// 마지막 로그 폴링 결과 (신호 있음/없음).
    private var lastLogSignal: Bool = false

    public init(logger: GuardLogger) {
        self.logger = logger
    }

    // MARK: - Notify (1차)

    /// 오버라이드 notify 상태. true=보정 완충 오버라이드 활성.
    /// 읽기 실패 시 nil (미확인 — 다른 경로로 판단한다).
    public func notifyOverrideActive() -> Bool? {
        guard let registerCheck = NotifyAPI.registerCheck,
              let getState = NotifyAPI.getState,
              let cancel = NotifyAPI.cancel else { return nil }
        var token: Int32 = 0
        let name = GuardConstants.calibrationOverrideNotify
        let registerStatus = name.withCString { registerCheck($0, &token) }
        guard registerStatus == 0 else { return nil }
        defer { _ = cancel(token) }
        var state: UInt64 = 0
        let getStatus = getState(token, &state)
        guard getStatus == 0 else { return nil }
        return state != 0
    }

    // MARK: - OSLogStore (2차)

    /// 최근 `minutes`분 PowerUIAgent 로그에 보정 신호가 있는지 확인한다.
    /// OSLogStore 폴링은 비용이 있으므로 60초에 한 번만 실제로 조회하고,
    /// 그 사이에는 마지막 결과를 반환한다.
    public func logSignalPresent(minutes: Int = 10) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastLogPoll) >= 60 else {
            return lastLogSignal
        }
        lastLogPoll = now
        lastLogSignal = pollLog(minutes: minutes)
        return lastLogSignal
    }

    private func pollLog(minutes: Int) -> Bool {
        let started = Date()
        defer {
            logger.debug("OSLogStore 폴링 소요 \(String(format: "%.2f", Date().timeIntervalSince(started)))초")
        }
        do {
            let store = try OSLogStore(scope: .system)
            let startDate = Date().addingTimeInterval(TimeInterval(-minutes * 60))
            let position = store.position(date: startDate)
            // subsystem으로 스토어 측에서 필터링한다 (2026-11-17 수정).
            // 이전에는 10분치 전체 로그를 가져와 Swift에서 걸렀는데, 조회가
            // 수 초 걸려 MainActor를 막고 XPC getState가 5초 타임아웃됐다
            // (앱 로그에 60초 간격 연결 끊김 반복). predicate를 쓰면
            // 해당 subsystem 항목만 반환돼 조회가 수십 ms 수준으로 준다.
            let predicate = NSPredicate(format: "subsystem == %@", "com.apple.powerui.smartcharging")
            let entries = try store.getEntries(at: position, matching: predicate)
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                let message = logEntry.composedMessage
                // GaugingMitigationActions는 시간당 한 번 나타나는 정상 항목이라 제외한다.
                if message.contains("GaugingMitigationActions") { continue }
                if message.contains("ChargingUpForGauging")
                    || message.contains("mitigations are in place") {
                    logger.info("보정 로그 신호 검출: \(message.prefix(120))")
                    return true
                }
            }
            return false
        } catch {
            logger.warn("OSLogStore 폴링 실패: \(error.localizedDescription)")
            return false
        }
    }
}
