import SwiftUI
import AppKit

/// MactteryGuard — Step 2: 충전 제어 메뉴바 앱.
/// 배터리 표시는 AppState가 소유하는 BatteryMonitor가, 충전 제어는 XPC로 연결된
/// 헬퍼 데몬이 담당한다. 앱은 데몬과 XPC로만 통신한다 (SMC 직접 접근 없음).
@main
struct MactteryGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(appState: appState)
        } label: {
            MenuBarLabelView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 메뉴바 라벨: 단색 적응형 배터리 아이콘 (숫자·번개 안쪽 표시).
/// 보정 중이면 "보정 중"을 함께 표시 (§14.7).
/// colorScheme을 읽어 단색 아이콘의 잉크색을 정한다
/// (어두운 메뉴바에서는 흰색, 밝은 메뉴바에서는 검은색).
private struct MenuBarLabelView: View {
    @ObservedObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            menuBarIcon
            if appState.daemonState?.calibrationActive == true {
                Text("보정 중")
            }
        }
    }

    /// 메뉴바 아이콘 이미지.
    /// MenuBarExtra 라벨은 커스텀 SwiftUI 뷰를 그대로 그리지 않고
    /// 이미지+텍스트만 추려내 도형이 사라진다 (2026-11-17 실측:
    /// 배터리 외곽선·채움이 안 보이고 번개+숫자만 시스템 크기로 표시됨).
    /// 그래서 BatteryLevelIcon을 ImageRenderer로 래스터 이미지로 바꿔 쓴다.
    /// 렌더 실패 시에는 숫자 텍스트로 폴백한다.
    @ViewBuilder
    private var menuBarIcon: some View {
        if let nsImage = renderedMenuBarIcon {
            Image(nsImage: nsImage)
        } else {
            Text("\(appState.monitor.percent)%")
        }
    }

    private var renderedMenuBarIcon: NSImage? {
        let icon = BatteryLevelIcon(
            percent: appState.monitor.percent,
            isCharging: appState.monitor.isCharging,
            geometry: .menuBar,
            whiteBolt: false,
            monochrome: true,
            colorScheme: colorScheme,
            showPercentSign: false
        )
        .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }
}

/// 앱 종료 처리.
/// releaseOnQuit 설정이 켜져 있을 때만 데몬에 setPaused(true)를 보내 충전 복원을 시도한다.
/// 종료 중이므로 NSXPCConnection을 직접 만들고 세마포어 + 2초 타임아웃으로 짧게 대기한 뒤
/// 포기한다 (무한 대기 금지). AppState와 무관하게 동작하므로 종료 시점의 상태에 영향받지 않는다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        guard AppSettings.storedReleaseOnQuit else { return }
        let connection = NSXPCConnection(machServiceName: GuardConstants.machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: MactteryGuardHelperProtocol.self)
        let semaphore = DispatchSemaphore(value: 0)
        // 연결이 무효화돼도 대기에서 빠져나온다 (reply와 중복 신호가 나도 무해하다).
        connection.invalidationHandler = { semaphore.signal() }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxy as? MactteryGuardHelperProtocol else { return }
        proxy.setPaused(true) { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}
