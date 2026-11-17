import Foundation
import IOKit
import IOKit.ps

/// Step 2 — 읽기 전용 배터리 상태 모니터.
/// IOKit 전원 API로만 읽고, 충전 제어나 SMC 쓰기는 일절 하지 않는다.
/// 기본값(잔량·충전 여부·AC·남은 시간)은 기존 IOPS 직접 읽기를 유지하고,
/// 상세 값(사이클·상태·온도)은 BatteryReader에 위임한다 (§14.7).
@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var percent: Int = 0
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isOnAC: Bool = false
    /// 충전 중이면 완충까지, 방전 중이면 방전까지 남은 시간(분). 알 수 없으면 nil.
    @Published private(set) var timeRemainingMinutes: Int?
    /// 사이클 수. 읽기 자체가 실패하면 이전 값을 유지하고, 읽기는 성공했으나
    /// 해당 항목이 없으면 nil이 된다.
    @Published private(set) var cycleCount: Int?
    /// 배터리 상태 (정상/보통/교체 권장). 실패 시 동작은 cycleCount와 동일.
    @Published private(set) var condition: BatteryCondition?
    /// 최대 용량 (%). 실패 시 동작은 cycleCount와 동일.
    @Published private(set) var maxCapacityPercent: Int?
    /// 배터리 온도 (°C). 실패 시 동작은 cycleCount와 동일.
    @Published private(set) var temperatureCelsius: Double?

    private var timer: Timer?
    /// 상세 읽기용 리더. 내부 SMC 연결을 재사용하므로 매 틱 새로 만들지 않는다.
    private lazy var batteryReader = BatteryReader()

    init() {
        refresh()
        // 이 모니터는 앱 수명 동안 유지되므로 타이머 해제 코드가 필요 없다.
        // Timer 블록은 @Sendable이라 MainActor 홉을 거쳐 refresh()를 부른다.
        // [weak self] 캡처로 타이머-모니터 간 순환 참조를 피한다.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        // IOPSCopyPowerSourcesInfo()는 Swift에서 Unmanaged<CFTypeRef>를 반환한다.
        // takeRetainedValue()로 소유권을 ARC에 넘겨야 후속 호출에 전달할 수 있다.
        // List도 Copy 함수라 takeRetainedValue(), Description은 Get 함수라
        // takeUnretainedValue()다 (소유권이 blob에 있다). 빼면 캐스트가 항상 실패한다.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first else { return }
        guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { return }

        let current = info[kIOPSCurrentCapacityKey as String] as? Int
        let maximum = info[kIOPSMaxCapacityKey as String] as? Int
        if let current, let maximum, maximum > 0 {
            percent = max(0, min(100, current * 100 / maximum))
        }

        if let state = info[kIOPSPowerSourceStateKey as String] as? String {
            isOnAC = (state == (kIOPSACPowerValue as String))
        }
        if let charging = info[kIOPSIsChargingKey as String] as? Bool {
            isCharging = charging
        }

        let timeToEmpty = validMinutes(info[kIOPSTimeToEmptyKey as String] as? Int)
        let timeToFull = validMinutes(info[kIOPSTimeToFullChargeKey as String] as? Int)
        timeRemainingMinutes = isCharging ? timeToFull : timeToEmpty

        // 상세 값(사이클·상태·온도)은 BatteryReader에 위임한다.
        // 기본값은 위 IOPS 읽기 결과를 그대로 쓴다 (두 경로가 다르면 IOPS를 우선한다).
        if let detailed = batteryReader.read(includeDetails: true) {
            cycleCount = detailed.cycleCount
            condition = detailed.condition
            maxCapacityPercent = detailed.maxCapacityPercent
            temperatureCelsius = detailed.temperatureCelsius
        }
    }

    /// IOKit 시간 값은 -1이면 "알 수 없음"을 뜻한다.
    private func validMinutes(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}
