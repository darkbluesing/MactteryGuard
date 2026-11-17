import SwiftUI
import AppKit

/// Step 2 팝오버 (한국어·영어 UI, 너비 320).
/// 구성: (a) 보정 배너 + 아이폰 스타일 배터리 아이콘 (%를 아이콘 안에 표시,
/// 잔량에 따라 채움 너비·색 변화), (b) 어댑터·남은 시간, (c) 배터리 상세,
/// (d) 충전 제어, (e) 알림(연결 끊김·오류 등 주의가 필요할 때만),
/// (f) 설정, (g) 종료.
/// 데몬의 내부 상태(백엔드·버전 등)는 일반 화면에 표시하지 않는다
/// (2026-11-16 사용자 요청). 모든 상태·액션은 AppState를 통한다.
struct PopoverView: View {
    @ObservedObject var appState: AppState

    @State private var showForceDischargeAlert = false
    @State private var showUninstallAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.daemonState?.calibrationActive == true {
                calibrationBanner
            }

            header

            Divider()

            statusRow(label: "어댑터", value: appState.monitor.isOnAC ? String(localized: "연결됨") : String(localized: "연결 안 됨"))
            statusRow(label: "남은 시간", value: timeRemainingText)

            Divider()

            statusRow(label: "사이클 수", value: cycleCountText)
            statusRow(label: "배터리 상태", value: appState.monitor.condition?.displayName ?? String(localized: "알 수 없음"))
            statusRow(
                label: "최대 용량",
                value: appState.monitor.maxCapacityPercent.map { "\($0)%" } ?? String(localized: "알 수 없음")
            )
            statusRow(label: "온도", value: temperatureText)

            Divider()

            controlSection

            if showDaemonNotice {
                Divider()

                daemonNotice
            }

            Divider()

            settingsSection

            Divider()

            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(width: 320)
        .task {
            // 팝오버가 열릴 때 즉시 최신 상태를 가져온다.
            await appState.refreshNow()
        }
        .alert("강제 방전", isPresented: $showForceDischargeAlert) {
            Button("켜기") { appState.setForceDischargeEnabled(true) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("강제 방전을 켜면 배터리를 사용해 상한까지 내려가므로 배터리 사이클이 소모됩니다. 켜시겠습니까?")
        }
        .alert("MactteryGuard 제거", isPresented: $showUninstallAlert) {
            Button("제거", role: .destructive) {
                Task { await appState.uninstall() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("충전 제한을 해제하고 등록을 취소합니다. 계속하시겠습니까?")
        }
    }

    // MARK: - (a) 보정 배너 + 배터리 아이콘

    private var calibrationBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("macOS 보정 중 — 충전 제한이 적용되지 않습니다")
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(.orange)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 10) {
            batteryIcon
            Text(statusText)
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// 아이폰 스타일 배터리 아이콘 (2026-11-17, 사용자 목업 기반).
    /// %를 아이콘 안에 표시하고, 잔량에 따라 채움 너비가 바뀐다.
    /// 충전 중이면 번개 표시, 20% 이하면 빨간색.
    /// 실제 그리기는 메뉴바 라벨과 공유하는 BatteryLevelIcon이 담당한다.
    private var batteryIcon: some View {
        BatteryLevelIcon(
            percent: appState.monitor.percent,
            isCharging: appState.monitor.isCharging,
            geometry: .header,
            whiteBolt: false
        )
    }

    private var statusText: String {
        if appState.daemonState?.calibrationActive == true {
            return String(localized: "macOS 보정 중")
        } else if appState.daemonState?.controlState == .dischargeBack {
            return String(localized: "상한으로 되돌리는 중")
        } else if appState.daemonState?.controlState == .failOpen {
            return String(localized: "오류 — 충전 허용됨")
        } else if appState.monitor.isCharging {
            return String(localized: "충전 중")
        } else if appState.monitor.isOnAC {
            return String(localized: "어댑터 전원")
        } else {
            return String(localized: "배터리 사용 중")
        }
    }

    // MARK: - (d) 충전 제어

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("충전 제어")

            Toggle("충전 제어", isOn: Binding(
                get: { appState.settings.controlEnabled },
                set: { appState.setControlEnabled($0) }
            ))
            .disabled(!isDaemonRegistered)

            if !isDaemonRegistered {
                registrationGuidance
            }

            HStack {
                Text("충전 상한")
                Spacer()
                Text("\(appState.settings.upperLimit)%")
                    .fontWeight(.semibold)
            }
            Slider(
                value: Binding(
                    get: { Double(appState.settings.upperLimit) },
                    set: { appState.setUpperLimit(Int($0)) }
                ),
                in: Double(GuardSettings.minUpperLimit)...Double(GuardSettings.maxUpperLimit),
                step: 1
            ) {
                Text("충전 상한")
            } minimumValueLabel: {
                Text("\(GuardSettings.minUpperLimit)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("\(GuardSettings.maxUpperLimit)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(String(format: String(localized: "%d%% 이하에서 재충전"), appState.settings.toGuardSettings().lowerLimit))
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.settings.upperLimit < 80 {
                Text("80% 미만으로 설정하면 macOS 기본 동작과 충돌하거나 드레인이 발생할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            topUpRow

            Toggle("강제 방전", isOn: Binding(
                get: { appState.settings.forceDischargeEnabled },
                set: { newValue in
                    // 켤 때만 확인 얼럿을 띄우고, 확인 시에만 켠다. 끌 때는 바로 끈다.
                    if newValue {
                        showForceDischargeAlert = true
                    } else {
                        appState.setForceDischargeEnabled(false)
                    }
                }
            ))
            Text("보정 후 상한까지 되돌릴 때 배터리를 사용합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 충전 제어를 켤 수 있는 상태인지 (데몬 등록 + 승인 완료).
    private var isDaemonRegistered: Bool {
        appState.registrationStatus == .enabled
    }

    private var registrationGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch appState.registrationStatus {
            // 주의: SMAppService.daemon의 status는 첫 등록 전에는 .notRegistered가
            // 아니라 .notFound를 보고한다 (실측된 동작). 따라서 .notFound도
            // 미등록과 동일하게 취급해 등록 버튼을 보여야 한다.
            case .notRegistered, .notFound:
                Text("충전 제어를 사용하려면 등록이 필요합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("충전 제어 등록") {
                    Task { await appState.registerDaemon() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(appState.isBusy)
            case .requiresApproval:
                Text("시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램에서 MactteryGuard를 승인해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("시스템 설정 열기") {
                    appState.openLoginItemsSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .enabled:
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
    }

    private var topUpRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("1회 완충")
                if let topUp = appState.daemonState?.topUp, topUp != .inactive {
                    Text(topUp.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch appState.daemonState?.topUp {
            case .active:
                Button("1회 완충 중… (취소)") {
                    Task { await appState.cancelTopUp() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isBusy)
            case .reached:
                Button("복귀 대기 중 (취소)") {
                    Task { await appState.cancelTopUp() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isBusy)
            default:
                Button("1회 100% 완충") {
                    Task { await appState.chargeToFullOnce() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!appState.daemonAvailable || !appState.settings.controlEnabled || appState.isBusy)
            }
        }
    }

    // MARK: - (e) 알림 (주의가 필요할 때만)

    /// 데몬의 내부 상태는 표시하지 않고, 사용자의 주의가 필요한 경우에만
    /// 한두 줄의 알림을 보여준다 (연결 끊김·상한 미등록·오류).
    private var showDaemonNotice: Bool {
        // 미등록 상태는 controlSection의 등록 안내가 이미 다루므로 제외한다.
        if appState.registrationStatus == .enabled, !appState.daemonAvailable {
            return true
        }
        if appState.daemonState?.limitRegistered == false {
            return true
        }
        if appState.daemonState?.lastError != nil || appState.lastError != nil {
            return true
        }
        return false
    }

    private var daemonNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.registrationStatus == .enabled, !appState.daemonAvailable {
                Text("충전 제어 서비스에 연결할 수 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("서비스가 시작되는 중일 수 있습니다. 잠시 후 다시 확인해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.daemonState?.limitRegistered == false {
                Text("상한이 macOS에 등록되지 않았습니다.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let daemonError = appState.daemonState?.lastError {
                Text(String(format: String(localized: "오류: %@"), daemonError))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let appError = appState.lastError {
                Text(appError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - (f) 설정

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("설정")

            Toggle("앱 종료 시 충전 제한 해제", isOn: Binding(
                get: { appState.settings.releaseOnQuit },
                set: { appState.setReleaseOnQuit($0) }
            ))

            HStack(spacing: 8) {
                Button("로그 폴더 열기") {
                    appState.openLogsFolder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("MactteryGuard 제거", role: .destructive) {
                    showUninstallAlert = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isBusy)
            }
        }
    }

    // MARK: - 공용

    /// 섹션 제목. LocalizedStringKey를 받아 Text가 카탈로그에서 번역한다
    /// (String 변수를 Text에 넘기면 번역되지 않는다).
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.headline)
    }

    private func statusRow(label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.body)
    }

    private var cycleCountText: String {
        if let count = appState.monitor.cycleCount {
            return String(format: String(localized: "%d회"), count)
        }
        return String(localized: "알 수 없음")
    }

    private var temperatureText: String {
        if let celsius = appState.monitor.temperatureCelsius {
            return String(format: "%.1f°C", celsius)
        }
        return String(localized: "알 수 없음")
    }

    private var timeRemainingText: String {
        guard let minutes = appState.monitor.timeRemainingMinutes else {
            return String(localized: "계산 중…")
        }
        let hours = minutes / 60
        let mins = minutes % 60
        let duration = hours > 0
            ? String(format: String(localized: "%d시간 %d분"), hours, mins)
            : String(format: String(localized: "%d분"), mins)
        return appState.monitor.isCharging
            ? String(format: String(localized: "완충까지 약 %@"), duration)
            : String(format: String(localized: "약 %@ 남음"), duration)
    }
}
