// AdapterBackend.swift — 어댑터 백엔드 (벽전원 SMC 키 토글).
//
// 역할 두 가지:
//  1) 네이티브 백엔드가 가용하지 않을 때의 폴백 제어 (히스테리시스 루프).
//  2) 보정 후 되돌리기(강제 방전) — 네이티브 모드에서도 CHIE 절단으로 상한까지 내린다.
//     (사용자 옵트인 시에만, §14.6)
//
// 키 (BATT_NATIVE_RESEARCH.md §4 검증됨): CH0I(1순위)/CH0J(2순위)/CHIE(3순위) 중
// 가용한 것을 쓴다. 20457.1+ 펌웨어에서는 사실상 CHIE만 동작한다.
//  - CH0I/CH0J: 00=허용, 01=차단.
//  - CHIE: 00=허용, 08=차단.
//
// 안전 규칙:
//  - 잔량 10% 이하면 어떤 설정으로도 어댑터를 차단하지 않는다 (chargnr 규칙).
//  - 클램셸(뚜껑 닫힘) 중에는 절단을 일시정지한다 (chargnr 방식 — batt식 수면 방지 아님).
//  - 수면 직전에는 어댑터를 다시 켠다 (수면 중 절단 상태로 방전 방지).
//  - 모든 쓰기는 read-back 검증 + 3회 재시도 (SMCClient.writeByte 내장).
//  - 어댑터 모드는 깨어 있을 때만 동작한다 (수면 중 강제 불가 — 설계 §3.7).

import Foundation

public final class AdapterBackend: ChargeBackend {
    public let kind: BackendKind = .adapter

    private let store: DaemonStore
    private let logger: GuardLogger
    private let reader: BatteryReader
    private var smc: SMCClient?

    /// 선택된 어댑터 키 (프로브 결과). nil이면 프로브 전 또는 불가.
    private var adapterKey: String?
    /// 선택된 키의 차단 값 (CH0I/CH0J=01, CHIE=08).
    private var blockValue: UInt8 = 0x08

    /// 키 후보 (우선순위 순) + 차단 값.
    private static let candidates: [(key: String, block: UInt8)] = [
        ("CH0I", 0x01),
        ("CH0J", 0x01),
        ("CHIE", 0x08),
    ]

    public init(store: DaemonStore, logger: GuardLogger, reader: BatteryReader) {
        self.store = store
        self.logger = logger
        self.reader = reader
    }

    // MARK: - Probe

    public func probe() -> Bool {
        guard let client = smcClient() else {
            logger.warn("어댑터 프로브 실패: SMC 연결 불가")
            return false
        }
        for candidate in Self.candidates {
            if client.isUsable(key: candidate.key) {
                adapterKey = candidate.key
                blockValue = candidate.block
                logger.info("어댑터 프로브: \(candidate.key) 가용 (차단 값 0x\(String(candidate.block, radix: 16)))")
                return true
            }
        }
        logger.warn("어댑터 프로브 실패: CH0I/CH0J/CHIE 모두 불가")
        return false
    }

    // MARK: - ChargeBackend

    /// Adapter 백엔드에서 setLimit은 "상한까지는 충전 허용, 상한에서는 차단"이라는
    /// 히스테리시스 정책의 선언이다. 실제 토글은 엔진이 매 틱 판단해
    /// setAdapterEnabled로 수행한다. 여기서는 현재 잔량 기준으로 한 번 적용한다.
    /// (엔진은 setLimit 호출 후에도 매 틱 상태를 보고 토글한다.)
    /// isCalibrating은 무시한다 — 어댑터 백엔드는 원래 값을 저장하지 않는다.
    public func setLimit(_ limit: Int, isCalibrating: Bool) -> BackendResult {
        guard adapterKey != nil else { return .failed("어댑터 키 미선택 (프로브 필요)") }
        guard let reading = reader.read(includeDetails: false) else {
            return .failed("배터리 읽기 실패")
        }
        // 상한 이상이면 차단, 미만이면 허용 — 이후 틱에서 히스테리시스가 이어받는다.
        let shouldBlock = reading.percent >= limit
        return setAdapterEnabled(!shouldBlock, percent: reading.percent) ? .applied : .failed("어댑터 토글 실패")
    }

    public func currentLimit() -> Int? {
        // 어댑터 백엔드는 상한 "값"을 저장하지 않는다 (토글만 한다).
        // 엔진이 설정에서 상한을 알고 있으므로 여기서는 nil을 반환한다.
        nil
    }

    public func restore() -> Bool {
        // FAIL-OPEN: 어댑터 허용으로 복원한다.
        guard adapterKey != nil else { return true } // 건드린 적 없으면 복원할 것도 없음
        let ok = writeAdapter(enabled: true)
        if ok {
            logger.logWrite("어댑터 복원 (허용)")
            updateShadow(enabled: true)
        } else {
            logger.error("어댑터 복원 실패")
        }
        return ok
    }

    public func verify(expectedLimit: Int) -> Bool {
        // 어댑터 상태가 섀도와 일치하는지 확인한다.
        guard let shadow = store.loadShadow(), let expected = shadow.adapterEnabled else {
            return true // 섀도가 없으면 확인할 상태가 없음
        }
        guard let actual = isAdapterEnabled() else { return false }
        return actual == expected
    }

    // MARK: - Adapter control (엔진이 매 틱 호출)

    /// 어댑터 허용/차단. 안전 가드를 모두 통과해야 차단한다.
    /// - Returns: 요청한 상태가 됐으면 true (이미 그 상태면 쓰지 않고 true).
    public func setAdapterEnabled(_ enabled: Bool, percent: Int) -> Bool {
        if !enabled {
            // 차단 가드.
            if percent <= GuardConstants.adapterCutFloorPercent {
                logger.warn("어댑터 차단 거부: 잔량 \(percent)%가 하한(\(GuardConstants.adapterCutFloorPercent)%) 이하")
                return false
            }
            if reader.isClamshellClosed() {
                logger.info("어댑터 차단 일시정지: 클램셸 닫힘")
                return false
            }
        }
        // 섀도 상태: 이미 원하는 상태면 쓰지 않는다.
        if let current = isAdapterEnabled(), current == enabled {
            return true
        }
        let ok = writeAdapter(enabled: enabled)
        if ok {
            logger.logWrite("어댑터 \(enabled ? "허용" : "차단") (잔량 \(percent)%)")
            updateShadow(enabled: enabled)
        } else {
            logger.error("어댑터 \(enabled ? "허용" : "차단") 실패")
        }
        return ok
    }

    /// 현재 어댑터 상태. true=허용, false=차단, nil=읽기 실패.
    public func isAdapterEnabled() -> Bool? {
        guard let key = adapterKey, let client = smcClient() else { return nil }
        guard let value = client.readByte(key: key) else { return nil }
        return value == 0x00
    }

    /// 수면 직전 호출: 어댑터를 다시 켠다.
    public func prepareForSleep() {
        guard adapterKey != nil else { return }
        if isAdapterEnabled() == false {
            _ = writeAdapter(enabled: true)
            logger.logWrite("수면 직전 어댑터 허용 복원")
            updateShadow(enabled: true)
        }
    }

    // MARK: - Private

    private func writeAdapter(enabled: Bool) -> Bool {
        guard let key = adapterKey, let client = smcClient() else { return false }
        let value: UInt8 = enabled ? 0x00 : blockValue
        return client.writeByte(key: key, value: value, attempts: 3)
    }

    private func smcClient() -> SMCClient? {
        if smc == nil { smc = SMCClient() }
        return smc
    }

    private func updateShadow(enabled: Bool) {
        var shadow = store.loadShadow() ?? ShadowState()
        shadow.adapterEnabled = enabled
        shadow.updatedAt = Date()
        store.saveShadow(shadow)
    }
}
