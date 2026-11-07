//
//  maccraftApp.swift
//  maccraft
//
//  应用入口。
//

import SwiftUI
import AppKit

@main
struct maccraftApp: App {
    @StateObject private var store = LauncherStore()
    @StateObject private var account = AccountStore()

    init() {
        // 命令行自检：maccraft --selftest（跑完即退出，不打开窗口）
        if SelfTest.runIfRequested() { exit(0) }

        // 清理旧版本留下的背景模糊缓存（现在背景是普通壁纸，不再需要预模糊）
        Background.purgeLegacyBlurCaches()

        // 关闭 App 时把常驻的登录心跳进程一并收掉，别留 JVM 在后台
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            HMCLLogin.stopHeartbeat()
            HMCLLogin.terminateCurrent()
        }
    }

    /// 窗口默认尺寸。
    ///
    /// 调试用：`--window-size=1400x1600` 可以把窗口拉高，
    /// 方便一次性看全设置页（内容比默认窗口长）。
    private static func parsedWindowSize() -> (width: CGFloat, height: CGFloat) {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--window-size=") }) {
            let spec = arg.replacingOccurrences(of: "--window-size=", with: "")
            let parts = spec.split(separator: "x").map(String.init)
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
                return (w, h)
            }
        }
        return (1040, 720)
    }

    var body: some Scene {
        let size = Self.parsedWindowSize()
        WindowGroup {
            MainView()
                .environmentObject(store)
                .environmentObject(account)
                .frame(minWidth: 960, minHeight: 680)
        }
        .defaultSize(width: size.width, height: size.height)
        // 窗口默认居中：不然在多显示器 / 之前挪过窗口的情况下，
        // 新开的实例会飘到屏幕外侧，用户以为「没启动」。
        .defaultPosition(.center)
        .windowResizability(.automatic)
        .commands {
            // 自定义「关于」：系统面板 + 几行简介（见 AboutPanel.swift）
            CommandGroup(replacing: .appInfo) {
                Button("关于 Aether") {
                    AboutPanel.show()
                }
            }
            // 用普通命令替换系统 Settings 场景，避免触发 AppIntents / linkd 注册噪声。
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    store.selectedTab = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
