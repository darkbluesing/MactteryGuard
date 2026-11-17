// GuardLogger.swift — 날짜별 로그 파일 기록 + 30일 자동 보관 후 삭제 (§14.8).
//
// 앱과 데몬이 같은 로거를 쓴다. 경로만 다르다.
//  - 앱:    ~/Library/Logs/MactteryGuard/mactteryguard-YYYY-MM-DD.log
//  - 데몬:  /Library/Logs/MactteryGuard/helper-YYYY-MM-DD.log (root 데몬은 사용자 홈에 쓸 수 없음)
// 날짜별 파일로 나누는 이유: 30일 보관 정책을 "오래된 파일 삭제"로 단순하게 구현하기 위함이다.
// 모든 쓰기는 직렬 큐에서 수행되므로 어느 스레드에서 불러도 안전하다.

import Foundation

public final class GuardLogger: @unchecked Sendable {
    public enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    /// 로그 보관 일수 (§14.8: 30일).
    public static let retentionDays = 30

    private let directory: URL
    private let filePrefix: String
    private let queue = DispatchQueue(label: "com.loveaimg.mactteryguard.logger")
    /// 마지막 정리 시각. queue 안에서만 접근한다.
    private var lastPrune: Date = .distantPast

    /// - Parameters:
    ///   - directory: 로그 디렉터리 (없으면 생성한다).
    ///   - filePrefix: 파일명 접두사 ("mactteryguard" 또는 "helper").
    public init(directory: URL, filePrefix: String) {
        self.directory = directory
        self.filePrefix = filePrefix
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 데몬 로그 디렉터리는 사용자가 Finder에서 열어볼 수 있게 읽기 권한을 열어둔다.
        // (root 소유 755: 소유자 쓰기, 그 외 읽기·실행.)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path
        )
        pruneIfNeeded()
    }

    /// 앱 로그 디렉터리: ~/Library/Logs/MactteryGuard/
    public static func appDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MactteryGuard", isDirectory: true)
    }

    /// 데몬 로그 디렉터리: /Library/Logs/MactteryGuard/
    public static func daemonDirectory() -> URL {
        URL(fileURLWithPath: "/Library/Logs/MactteryGuard", isDirectory: true)
    }

    public func debug(_ message: String) { log(message, level: .debug) }
    public func info(_ message: String) { log(message, level: .info) }
    public func warn(_ message: String) { log(message, level: .warn) }
    public func error(_ message: String) { log(message, level: .error) }

    /// 충전 제어 쓰기 전용 기록 (설계 §9.2: 타임스탬프 + 대상 + 이전 값 + 새 값 + 트리거).
    public func logWrite(_ message: String) {
        log("WRITE \(message)", level: .info)
    }

    public func log(_ message: String, level: Level = .info) {
        let line = "\(timestampString()) [\(level.rawValue)] \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
            let fileURL = self.fileURL(for: Date())
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: fileURL) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: fileURL, options: .atomic)
                    // 새로 만든 로그 파일도 사용자가 읽을 수 있게 한다.
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o644], ofItemAtPath: fileURL.path
                    )
                }
            }
            self.pruneIfNeededLocked()
        }
    }

    /// 30일이 지난 로그 파일을 삭제한다. 하루에 한 번만 수행한다.
    public func pruneIfNeeded() {
        queue.async { [weak self] in self?.pruneIfNeededLocked() }
    }

    private func pruneIfNeededLocked() {
        let now = Date()
        guard now.timeIntervalSince(lastPrune) > 24 * 60 * 60 else { return }
        lastPrune = now
        let cutoff = now.addingTimeInterval(TimeInterval(-Self.retentionDays * 24 * 60 * 60))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(filePrefix) {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("\(filePrefix)-\(dayString(for: date)).log")
    }

    private func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
