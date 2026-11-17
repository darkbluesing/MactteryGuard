// SMCClient.swift — AppleSMC 드라이버 최소 클라이언트 (KeyInfo 읽기 / 값 읽기 / 값 쓰기).
//
// 용도:
//  - 데몬: 어댑터 키(CHIE) 토글 — 보정 후 되돌리기·Adapter 백엔드.
//  - 앱·데몬: 배터리 온도 폴백 읽기 (SMC TB0T).
// 읽기에는 root가 필요 없으나 쓰기에는 root가 필요하다. 앱은 읽기만 한다.
//
// 드라이버 규격 (Apple PowerManagement smc.h 원본 — cmjb.tech/Chromium/macstats 확인):
//  - IOConnectCallStructMethod, selector 2, 80바이트 파라미터 블록 (SMCParamStruct).
//  - key @ 0 (UInt32), dataSize @ 28 (UInt32), dataType @ 32 (UInt32),
//    result @ 40 (UInt8, 0=성공, 0x84=키 없음),
//    data8(명령) @ 42 (UInt8: 5 읽기, 6 쓰기, 9 키 정보), 값 바이트 @ 48 (최대 32바이트).
//  - dataSize의 IOByteCount는 커널에서만 64비트이고 유저스페이스에서는 UInt32다
//    (IOTypes.h: `#if defined(__LP64__) && defined(KERNEL)` — 아니면 32비트).
//    그래서 구조체는 80바이트이지 88바이트가 아니다. 88바이트로 고쳤던 시도는
//    틀렸고 되돌렸다 (2026-11-16).
//  - IOServiceOpen 타입 0/1, 핸드셰이크 유무는 전송에 영향이 없다
//    (smc-test 매트릭스 실측 2026-11-16: 4조합 전부 kr=0). 타입 1 + 호출마다
//    open/close는 Chromium 패턴이라 그대로 유지한다.
//  - C 구조체 대신 바이트 버퍼 + 고정 오프셋으로 접근한다 (Swift 구조체 패딩 회피).
//
// 바이트 순서 — 여기가 함정이다 (2026-11-16 smc-test로 확정):
//  - key/dataSize/dataType은 전부 UInt32 필드라 호스트 순서(little-endian)로
//    저장된다. OSType 상수의 값은 big-endian('CHIE' = 0x43484945)이지만,
//    와이어 바이트는 그걸 little-endian으로 쓴 것(45 49 48 43)이다.
//    big-endian으로 쓰면 드라이버가 'EIHC'로 읽어 0x84(키 없음)를 돌려준다 —
//    #KEY까지 전부 실패했던 원인이 이것이었다. 키는 반드시 LE로 쓴다.
//  - dataType도 마찬가지라 응답 바이트를 뒤집어야 "flt " 같은 문자열이 된다.
//    단, read/write 요청에 돌려쓰는 rawTypeBytes는 받은 그대로 둔다.
//  - 값 바이트는 타입마다 다르다. `flt`는 little-endian Float32 (사용자 기기 ismc 덤프에서
//    TB0T bytes 64 66 06 42 = 33.6°C로 확인), `sp78`은 big-endian 16비트 고정소수점(/256).
//    CHIE 같은 1바이트 값은 순서와 무관하다.
// 쓰기는 항상 read-back으로 검증한다 (chargnr 안전 규칙).

import Foundation
import IOKit

public final class SMCClient {
    // MARK: - Types

    public struct KeyInfo {
        /// 데이터 크기 (바이트). 0이면 placeholder — 읽고 쓸 수 없는 키 (batt 프로브 규칙).
        public var dataSize: UInt32
        /// 4문자 타입 코드 ("flt", "ui8", "hex_" 등). 문자 순서로 디코딩된 값.
        public var dataType: String
        public var dataAttributes: UInt8
        /// KeyInfo 응답의 dataSize/dataType 원시 바이트 (읽기·쓰기 요청에 그대로 돌려쓴다).
        fileprivate var rawSizeBytes: [UInt8]
        fileprivate var rawTypeBytes: [UInt8]

        /// batt의 가용성 프로브 규칙: KeyInfo 성공 AND DataSize > 0.
        public var isUsable: Bool { dataSize > 0 && dataSize <= 32 }
    }

    public enum SMCError: Error, CustomStringConvertible {
        case connectionFailed
        case keyNotFound(String)
        case invalidKey(String)
        case callFailed(kern_return_t)
        case resultError(UInt8)
        case readbackMismatch

        public var description: String {
            switch self {
            case .connectionFailed: return "AppleSMC 연결 실패"
            case .keyNotFound(let key): return "SMC 키 없음: \(key)"
            case .invalidKey(let key): return "잘못된 SMC 키: \(key)"
            case .callFailed(let kr): return "SMC 호출 실패: 0x\(String(kr, radix: 16))"
            case .resultError(let code): return "SMC 결과 오류: 0x\(String(code, radix: 16))"
            case .readbackMismatch: return "SMC 쓰기 후 read-back 불일치"
            }
        }
    }

    // MARK: - Connection

    private var connection: io_connect_t = 0

    /// AppleSMC 서비스를 열고 연결한다. 실패하면 nil.
    /// 타입 1 (Chromium 패턴). 타입 0도 전송은 되지만 1을 쓴다.
    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 1, &conn)
        guard kr == kIOReturnSuccess, conn != 0 else { return nil }
        connection = conn
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    // MARK: - KeyInfo probe

    /// 키의 메타데이터를 읽는다. 키가 없거나 권한이 없으면 nil.
    /// 게이팅된 키는 여기서 실패하거나 DataSize 0 placeholder로 나타난다.
    public func keyInfo(for key: String) -> KeyInfo? {
        guard let keyCode = ostype(key) else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        writeUInt32LE(&input, offset: 0, keyCode)
        input[42] = 9 // SMC_CMD_READ_KEYINFO (data8)
        guard let output = call(input), output[40] == 0 else { return nil }

        let rawSize = Array(output[28..<32])
        let rawType = Array(output[32..<36])
        // dataSize 바이트 순서: little-endian 해석이 유효 범위면 쓰고, 아니면 big-endian으로 재해석한다.
        let sizeLE = readUInt32LE(output, offset: 28)
        let sizeBE = readUInt32BE(output, offset: 28)
        let dataSize: UInt32
        if sizeLE <= 32 {
            dataSize = sizeLE
        } else if sizeBE <= 32 {
            dataSize = sizeBE
        } else {
            return nil
        }
        // dataType은 UInt32 필드라 호스트 순서로 오므로 뒤집어야 문자 순서가 된다.
        let dataType = String(bytes: rawType.reversed(), encoding: .ascii) ?? ""
        return KeyInfo(
            dataSize: dataSize,
            dataType: dataType,
            dataAttributes: output[36],
            rawSizeBytes: rawSize,
            rawTypeBytes: rawType
        )
    }

    /// batt 방식의 가용성 프로브: KeyInfo 성공 AND DataSize > 0.
    public func isUsable(key: String) -> Bool {
        keyInfo(for: key)?.isUsable ?? false
    }

    // MARK: - Read / Write

    /// 키 값을 읽는다. (값 바이트, 타입 코드)를 반환한다.
    public func read(key: String) -> (data: Data, type: String)? {
        guard let info = keyInfo(for: key), info.isUsable else { return nil }
        guard let keyCode = ostype(key) else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        writeUInt32LE(&input, offset: 0, keyCode)
        // KeyInfo에서 받은 dataSize/dataType 바이트를 그대로 돌려쓴다 (바이트 순서 회피).
        input.replaceSubrange(28..<32, with: info.rawSizeBytes)
        input.replaceSubrange(32..<36, with: info.rawTypeBytes)
        input[42] = 5 // SMC_CMD_READ_VALUE (data8)
        guard let output = call(input), output[40] == 0 else { return nil }
        let count = Int(info.dataSize)
        return (Data(output[48..<(48 + count)]), info.dataType)
    }

    /// 키 값을 쓴다 (root 필요). 성공 시 read-back으로 검증한다. 실패하면 false.
    /// 재시도는 호출자(백엔드)가 담당한다.
    public func write(key: String, data: Data) -> Bool {
        guard let info = keyInfo(for: key), info.isUsable,
              Int(info.dataSize) == data.count,
              let keyCode = ostype(key)
        else { return false }
        var input = [UInt8](repeating: 0, count: 80)
        writeUInt32LE(&input, offset: 0, keyCode)
        input.replaceSubrange(28..<32, with: info.rawSizeBytes)
        input.replaceSubrange(32..<36, with: info.rawTypeBytes)
        input.replaceSubrange(48..<(48 + data.count), with: data)
        input[42] = 6 // SMC_CMD_WRITE_VALUE (data8)
        guard let output = call(input), output[40] == 0 else { return false }
        // Read-back 검증: 쓴 값이 실제로 반영됐는지 다시 읽어 확인한다.
        guard let back = read(key: key), back.data == data else { return false }
        return true
    }

    /// 1바이트 키 쓰기 (CHIE 등). 최대 `attempts`회 재시도한다.
    public func writeByte(key: String, value: UInt8, attempts: Int = 3) -> Bool {
        for _ in 0..<max(1, attempts) {
            if write(key: key, data: Data([value])) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// 1바이트 키 읽기. 실패하면 nil.
    public func readByte(key: String) -> UInt8? {
        guard let result = read(key: key), result.data.count == 1 else { return nil }
        return result.data[0]
    }

    // MARK: - Low-level call

    private func call(_ input: [UInt8]) -> [UInt8]? {
        // 호출마다 open → struct → close (Chromium 패턴). open 실패면 호출 불가.
        // close 실패는 무시한다 — struct 호출의 성공 여부가 기준이다.
        let openKr = IOConnectCallMethod(connection, 0, nil, 0, nil, 0, nil, nil, nil, nil)
        guard openKr == kIOReturnSuccess else { return nil }
        defer { _ = IOConnectCallMethod(connection, 1, nil, 0, nil, 0, nil, nil, nil, nil) }
        var output = [UInt8](repeating: 0, count: 80)
        // IOConnectCallStructMethod의 size_t 파라미터는 Swift에서 Int다.
        // mach_msg_type_number_t(UInt32)를 쓰면 타입 변환 에러가 난다.
        var outputSize = 80
        let kr = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(
                    connection, 2,
                    inPtr.baseAddress, input.count,
                    outPtr.baseAddress, &outputSize
                )
            }
        }
        guard kr == kIOReturnSuccess else { return nil }
        return output
    }

    // MARK: - Byte helpers

    /// "CHIE" 같은 4문자 키를 big-endian OSType으로 바꾼다.
    private func ostype(_ key: String) -> UInt32? {
        guard key.count == 4, let data = key.data(using: .ascii), data.count == 4 else { return nil }
        return (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16)
            | (UInt32(data[2]) << 8) | UInt32(data[3])
    }

    private func writeUInt32BE(_ buffer: inout [UInt8], offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8((value >> 24) & 0xFF)
        buffer[offset + 1] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 3] = UInt8(value & 0xFF)
    }

    /// UInt32를 호스트 순서(little-endian)로 쓴다. 키 필드용.
    private func writeUInt32LE(_ buffer: inout [UInt8], offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func readUInt32LE(_ buffer: [UInt8], offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16)
            | (UInt32(buffer[offset + 3]) << 24)
    }

    private func readUInt32BE(_ buffer: [UInt8], offset: Int) -> UInt32 {
        (UInt32(buffer[offset]) << 24)
            | (UInt32(buffer[offset + 1]) << 16)
            | (UInt32(buffer[offset + 2]) << 8)
            | UInt32(buffer[offset + 3])
    }
}

// MARK: - Temperature decoding

/// SMC 온도 값 디코딩.
///  - `flt`: 4바이트 little-endian Float32 (사용자 기기 TB0T에서 확인).
///  - `sp78`: 2바이트 big-endian 고정소수점 (상위 8비트 정수 + 하위 8비트 소수, /256).
/// 그 외 타입은 nil.
public enum SMCTemperature {
    public static func decode(data: Data, type: String) -> Double? {
        // 타입 코드는 4바이트 고정이라 "flt"가 "flt\0"처럼 패딩될 수 있다.
        // 공백과 NUL을 함께 제거하지 않으면 매치가 실패해 온도를 놓친다.
        let clean = type.trimmingCharacters(in: CharacterSet(charactersIn: " \0\t\n\r"))
        switch clean {
        case "flt":
            guard data.count == 4 else { return nil }
            let bits = UInt32(data[0])
                | (UInt32(data[1]) << 8)
                | (UInt32(data[2]) << 16)
                | (UInt32(data[3]) << 24)
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "sp78":
            guard data.count == 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(data[0]) << 8) | UInt16(data[1]))
            return Double(raw) / 256.0
        default:
            return nil
        }
    }
}
