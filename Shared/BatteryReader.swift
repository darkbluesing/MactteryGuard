// BatteryReader.swift — 배터리 상태 동기 읽기 (앱 표시용 + 데몬 제어 판단용 공용).
//
// 읽기 경로:
//  - 잔량·충전 여부·AC 전원·남은 시간: IOKit 전원 API (IOPSCopyPowerSourcesInfo 계열).
//    Step 1 BatteryMonitor와 같은 경로다.
//  - 사이클 수·상태·온도 (상세): 아래 폴백 체인 순서로 읽는다.
//    1) IORegistry AppleSmartBattery 속성 (CycleCount, Temperature)
//    2) IOPS 전원 설명 딕셔너리 (BatteryHealth, Temperature)
//    3) SMC TB0T (온도만, chargnr 확인: macOS 27에서 IORegistry에 Temperature가 없음)
//
// 단위 주의 (특히 온도):
//  - IORegistry "Temperature"와 IOPS "Temperature"는 1/100 °C 단위의 정수다.
//    예: 3355 → 33.55°C. (AppleSmartBattery의 오래된 규격.)
//  - SMC TB0T는 `flt`(little-endian Float32) 또는 `sp78`(고정소수점 /256)이다.
//    단위 변환을 틀리면 33.6°C가 3355°C로 표시되므로, plausibility 범위(-20...80°C)로 검증한다.

import Foundation
import IOKit
import IOKit.ps

public final class BatteryReader {
    private lazy var smc: SMCClient? = SMCClient()

    public init() {}

    /// 동기 스냅샷. 실패(전원 정보 없음)하면 nil.
    /// - Parameter includeDetails: true면 사이클·상태·온도까지 읽는다 (IORegistry/SMC 접근).
    ///   데몬 제어 루프는 매 틱 상세까지 읽을 필요가 없으면 false로 부를 수 있다.
    public func read(includeDetails: Bool = true) -> BatteryReading? {
        // IOPSCopyPowerSourcesInfo()는 Swift에서 Unmanaged<CFTypeRef>를 반환한다.
        // takeRetainedValue()로 소유권을 ARC에 넘겨야 후속 호출에 전달할 수 있다.
        // List도 Copy 함수라 takeRetainedValue(), Description은 Get 함수라
        // takeUnretainedValue()다 (소유권이 blob에 있다). 빼면 캐스트가 항상 실패한다.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
        else { return nil }

        var percent = 0
        if let current = info[kIOPSCurrentCapacityKey as String] as? Int,
           let maximum = info[kIOPSMaxCapacityKey as String] as? Int, maximum > 0 {
            percent = max(0, min(100, current * 100 / maximum))
        }
        let isOnAC: Bool
        if let state = info[kIOPSPowerSourceStateKey as String] as? String {
            isOnAC = (state == (kIOPSACPowerValue as String))
        } else {
            isOnAC = false
        }
        let isCharging = (info[kIOPSIsChargingKey as String] as? Bool) ?? false
        let timeToEmpty = validMinutes(info[kIOPSTimeToEmptyKey as String] as? Int)
        let timeToFull = validMinutes(info[kIOPSTimeToFullChargeKey as String] as? Int)

        var reading = BatteryReading(
            percent: percent,
            isCharging: isCharging,
            isOnAC: isOnAC,
            timeRemainingMinutes: isCharging ? timeToFull : timeToEmpty
        )

        if includeDetails {
            let registry = appleSmartBatteryProperties()
            reading.cycleCount = cycleCount(registry: registry, iops: info)
            reading.condition = condition(registry: registry, iops: info)
            reading.maxCapacityPercent = capacityHealth(registry: registry)?.percent
            let (temperature, source) = temperature(registry: registry, iops: info)
            reading.temperatureCelsius = temperature
            reading.temperatureSource = source
        }
        return reading
    }

    /// 클램셸(뚜껑 닫힘) 상태. IOPMrootDomain의 AppleClamshellState 속성.
    /// 읽기에 실패하면 false(열림)로 취급한다 — 절단 일시정지는 보수적으로만 적용된다.
    public func isClamshellClosed() -> Bool {
        guard let properties = ioRegistryProperties(serviceName: "IOPMrootDomain") else { return false }
        return (properties["AppleClamshellState"] as? Bool) ?? false
    }

    // MARK: - Detail readers

    private func cycleCount(registry: [String: Any]?, iops: [String: Any]) -> Int? {
        // 1) IORegistry 최상위
        if let value = registry?["CycleCount"] as? Int { return value }
        // 2) macOS 27: 일부 속성이 BatteryData 딕셔너리 안으로 이동했다.
        if let batteryData = registry?["BatteryData"] as? [String: Any],
           let value = batteryData["CycleCount"] as? Int { return value }
        // 3) IOPS 딕셔너리 (존재하지 않을 수 있음).
        if let value = iops["CycleCount"] as? Int { return value }
        return nil
    }

    private func condition(registry: [String: Any]?, iops: [String: Any]) -> BatteryCondition? {
        // 1) IOPS "BatteryHealth": "Good" / "Fair" / "Poor"
        if let health = iops["BatteryHealth"] as? String {
            switch health {
            case "Good": return .normal
            case "Fair": return .fair
            case "Poor": return .poor
            default: break
            }
        }
        // 2) IORegistry 영구 고장 상태: 0이면 정상.
        if let failure = registry?["PermanentFailureStatus"] as? Int {
            return failure == 0 ? .normal : .poor
        }
        // 3) macOS 27에는 위 키가 둘 다 없다 (ioreg 실측 2026-11-16).
        //    BatteryData의 FullChargeCapacity/DesignCapacity 비율로 유도한다
        //    (시스템 설정의 "최대 용량"과 같은 값; 80% 미만이면 Apple의 교체 권고선).
        return capacityHealth(registry: registry)?.condition
    }

    /// BatteryData 용량으로 최대 용량(%)과 상태를 유도한다.
    /// DesignCapacity=6249, FullChargeCapacity=5954 → 95%, 정상 (2026-11-16 실측).
    private func capacityHealth(registry: [String: Any]?) -> (percent: Int, condition: BatteryCondition)? {
        guard let design = registryValue(registry, key: "DesignCapacity"), design > 0,
              let full = registryValue(registry, key: "FullChargeCapacity"), full > 0
        else { return nil }
        let ratio = Double(full) / Double(design)
        guard ratio > 0, ratio <= 1.1 else { return nil }
        let percent = max(0, min(100, Int((ratio * 100).rounded())))
        let condition: BatteryCondition
        if ratio >= 0.80 {
            condition = .normal
        } else if ratio >= 0.70 {
            condition = .fair
        } else {
            condition = .poor
        }
        return (percent, condition)
    }

    private func temperature(registry: [String: Any]?, iops: [String: Any]) -> (Double?, String?) {
        // 1) IORegistry "Temperature" (1/100 °C). macOS 27에서는 없을 수 있다 (chargnr 확인).
        if let raw = registryValue(registry, key: "Temperature"),
           let celsius = hundredthsToCelsius(raw) {
            return (celsius, "IORegistry")
        }
        // 2) IOPS "Temperature" (1/100 °C).
        if let raw = iops["Temperature"] as? Int,
           let celsius = hundredthsToCelsius(raw) {
            return (celsius, "IOPS")
        }
        // 3) SMC TB0T (flt LE 또는 sp78).
        if let client = smc,
           let result = client.read(key: "TB0T"),
           let celsius = SMCTemperature.decode(data: result.data, type: result.type),
           plausible(celsius) {
            return (celsius, "SMC TB0T")
        }
        return (nil, nil)
    }

    private func registryValue(_ registry: [String: Any]?, key: String) -> Int? {
        if let value = registry?[key] as? Int { return value }
        if let batteryData = registry?["BatteryData"] as? [String: Any],
           let value = batteryData[key] as? Int { return value }
        return nil
    }

    /// 1/100 °C 정수를 °C로 변환. plausibility 범위를 벗어나면 nil (단위 오해석 방지).
    private func hundredthsToCelsius(_ raw: Int) -> Double? {
        let celsius = Double(raw) / 100.0
        return plausible(celsius) ? celsius : nil
    }

    private func plausible(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius > -20 && celsius < 80
    }

    // MARK: - IORegistry

    private func appleSmartBatteryProperties() -> [String: Any]? {
        ioRegistryProperties(serviceName: "AppleSmartBattery")
    }

    private func ioRegistryProperties(serviceName: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceName))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard kr == kIOReturnSuccess, let unmanaged = properties else { return nil }
        let dict = unmanaged.takeRetainedValue() as NSDictionary
        return dict as? [String: Any]
    }

    /// IOKit 시간 값은 -1이면 "알 수 없음"을 뜻한다.
    private func validMinutes(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}
