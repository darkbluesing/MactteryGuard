// PmsetParser.swift — `pmset -g battlimit` 실행·파싱 (네이티브 상한 등록 확인용).
//
// 네이티브 백엔드가 상한을 설정한 뒤, 실제로 powerd에 등록됐는지는
// pmset으로만 확인할 수 있다 (BATT_NATIVE_RESEARCH.md §2.4).
// IOPSCopyBatteryLevelLimits()는 동일하게 게이팅되므로 쓰지 않는다.
//
// 파싱 규칙 (batt registration.go의 아이디어 — 코드는 새로 작성):
//  - "No battery level limits set" → 등록 없음.
//  - chargeSocLimitReason이 "manualChargeLimit"이고 Terminated가 0인 항목의
//    chargeSocLimitSoc 값을 읽는다.
//  - 출력 형식이 예상과 다르면 .unknown으로 처리한다 (조용히 성공으로 간주하지 않음).
//
// 주의: pmset 출력 형식을 이 VM에서 확인할 수 없으므로, 파서는 관대하게 작성하고
// 원시 출력을 로그에 남긴다. 실기에서 형식이 다르면 이 파일만 고치면 된다.

import Foundation

/// pmset -g battlimit 파싱 결과.
public enum PmsetRegistration: Equatable {
    /// 등록된 상한 없음.
    case none
    /// 수동 상한 등록됨 (상한 %).
    case registered(limit: Int)
    /// 출력 형식을 해석할 수 없음 — 원시 출력 포함 (확인 불가 = 미확인).
    case unknown(raw: String)
}

public enum PmsetParser {
    /// /usr/bin/pmset -g battlimit를 실행하고 등록 상태를 반환한다.
    /// 실행 실패(타임아웃·없음) 시 .unknown을 반환한다.
    public static func registration(timeoutSeconds: TimeInterval = 5) -> PmsetRegistration {
        guard let output = runPmset(timeoutSeconds: timeoutSeconds) else {
            return .unknown(raw: "")
        }
        return parse(output)
    }

    /// 원시 출력을 파싱한다 (테스트·디버깅용으로 분리).
    public static func parse(_ output: String) -> PmsetRegistration {
        if output.contains("No battery level limits set") {
            return .none
        }
        // 키: 값 형태의 행들을 수집한다. pmset 출력은 들여쓰기와 공백이 일정하지 않으므로
        // 공백을 정규화해 찾는다.
        var soc: Int?
        var reason: String?
        var terminated: String?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "chargeSocLimitSoc":
                soc = Int(parts[1])
            case "chargeSocLimitReason":
                reason = parts[1]
            case "Terminated":
                terminated = parts[1]
            default:
                break
            }
        }
        if reason == "manualChargeLimit", terminated == "0", let soc {
            return .registered(limit: soc)
        }
        // manualChargeLimit 행이 아니면 등록 없음으로 단정하지 않는다 —
        // 형식이 다를 수 있으므로 미확인으로 처리한다.
        if soc == nil && reason == nil && terminated == nil {
            return .unknown(raw: output)
        }
        // Terminated=1이면 등록이 종료된 상태 = 사실상 등록 없음.
        if reason == "manualChargeLimit", terminated == "1" {
            return .none
        }
        return .unknown(raw: output)
    }

    private static func runPmset(timeoutSeconds: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "battlimit"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // 타임아웃 대기: Process.waitUntilExit()은 블로킹이므로 별도 스레드에서 기다린다.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        guard group.wait(timeout: .now() + timeoutSeconds) == .success else {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
