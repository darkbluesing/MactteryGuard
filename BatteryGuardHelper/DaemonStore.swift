// DaemonStore.swift — 데몬 영속 상태 저장소.
//
// 데몬은 앱이 꺼져 있어도 동작해야 하므로, 설정을 앱 UserDefaults가 아닌
// 자기 위치에 저장한다: /Library/Application Support/MactteryGuard/
//  - settings.json: 마지막 유효 설정 (앱 종료·재부팅 후에도 제어 유지).
//  - originals.json: 네이티브 상한을 처음 건드리기 전 사용자의 원래 값
//    (MCLFeatureState/mclLimitValue). 제거·해제 시 복원용 (ampere Originals 패턴).
//  - shadow.json: 마지막으로 적용한 상태 (재시작 후 재동기화용).
// root 데몬이 쓰므로 디렉터리는 root 소유가 된다. 파일은 644로 만들어
// 사용자가 읽을 수 있게 한다.

import Foundation

/// 네이티브 상한 오버라이드 전 사용자의 원래 설정값.
/// 두 값 모두 nil이면 "원래 설정 없음"(기능을 쓴 적 없음)을 뜻한다.
public struct MCLOriginals: Codable, Equatable, Sendable {
    public var featureState: Int?
    public var limitValue: Int?

    public init(featureState: Int? = nil, limitValue: Int? = nil) {
        self.featureState = featureState
        self.limitValue = limitValue
    }

    /// 원래 설정이 존재했는지 (둘 중 하나라도 값이 있으면 존재).
    public var existed: Bool { featureState != nil || limitValue != nil }
}

/// 데몬이 마지막으로 적용한 상태 (재시작 후 재동기화·복원 판단용).
public struct ShadowState: Codable, Equatable, Sendable {
    /// 마지막으로 설정한 네이티브 상한. nil이면 설정한 적 없음.
    public var nativeLimit: Int?
    /// 마지막 어댑터 상태. nil이면 건드린 적 없음.
    public var adapterEnabled: Bool?
    /// 마지막 상태 전이 시각.
    public var updatedAt: Date

    public init(nativeLimit: Int? = nil, adapterEnabled: Bool? = nil, updatedAt: Date = Date()) {
        self.nativeLimit = nativeLimit
        self.adapterEnabled = adapterEnabled
        self.updatedAt = updatedAt
    }
}

// 데몬 영속 상태 저장소. @MainActor 제어 엔진(과 엔진이 호출하는 백엔드)에서만
// 접근하므로 사실상 단일 스레드에서 쓰인다. 저장 프로퍼티가 모두 불변(let)이고
// 메서드가 동기 파일 I/O만 하므로 @unchecked Sendable로 표시한다 — main.swift의
// 전역 let 바인딩(Swift 6 전역 상태 규칙)에 필요하다.
public final class DaemonStore: @unchecked Sendable {
    public static let directory = URL(fileURLWithPath: "/Library/Application Support/MactteryGuard", isDirectory: true)

    private let settingsURL: URL
    private let originalsURL: URL
    private let shadowURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL = DaemonStore.directory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path
        )
        self.settingsURL = directory.appendingPathComponent("settings.json")
        self.originalsURL = directory.appendingPathComponent("originals.json")
        self.shadowURL = directory.appendingPathComponent("shadow.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    // MARK: - Settings

    public func loadSettings() -> GuardSettings? {
        load(SettingsFile.self, from: settingsURL)?.settings
    }

    public func saveSettings(_ settings: GuardSettings) {
        save(SettingsFile(settings: settings), to: settingsURL)
    }

    // MARK: - Originals

    /// 원래 값을 저장한다. 이미 저장된 값이 있으면 덮어쓰지 않는다
    /// (처음 오버라이드 전의 값만이 "원래 값"이다).
    public func saveOriginalsIfAbsent(_ originals: MCLOriginals) {
        guard loadOriginals() == nil else { return }
        save(originals, to: originalsURL)
    }

    public func loadOriginals() -> MCLOriginals? {
        load(MCLOriginals.self, from: originalsURL)
    }

    public func clearOriginals() {
        try? FileManager.default.removeItem(at: originalsURL)
    }

    // MARK: - Shadow

    public func loadShadow() -> ShadowState? {
        load(ShadowState.self, from: shadowURL)
    }

    public func saveShadow(_ shadow: ShadowState) {
        save(shadow, to: shadowURL)
    }

    public func clearShadow() {
        try? FileManager.default.removeItem(at: shadowURL)
    }

    // MARK: - Helpers

    private struct SettingsFile: Codable {
        var settings: GuardSettings
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path
        )
    }
}
