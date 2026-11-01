//
//  ContentView.swift
//  maccraft
//
//  主界面外壳：左侧竖排导航（PCL / HMCL 风格）+ 右侧内容切换。
//  不使用 NavigationSplitView / List(selection:)，以避免“view updates 内发布”警告。
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: LauncherStore
    @EnvironmentObject private var account: AccountStore
    /// 窗口度量（标题栏高度）—— 用来给内容让出交通灯那一行。
    @StateObject private var metrics = WindowMetrics()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // 内容区顶部让出标题栏（fullSizeContentView 之后内容从窗口最顶开始，
                    // 不让开的话页面标题会被裁掉一半）。
                    .padding(.top, metrics.topInset)
            }
            // 全局任务条：无论在哪一页，下载 / 解压 / 安装都有实时进度和日志。
            // 浮在窗口底部横跨整宽，是 macOS 26 那种悬浮玻璃条的位置。
            TaskBar(feed: store.feed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 壁纸挂在**背景层**并忽略安全区 → 一直铺到窗口最顶上（含标题栏那条）。
        // 内容本身仍在安全区内，红绿灯不会压到侧栏品牌名上。
        .background {
            AetherBackground()
                .ignoresSafeArea()
        }
        // 让内容视图铺到标题栏底下，标题栏自身透明 —— 壁纸一直铺到屏幕最顶上。
        .background(FullSizeWindowConfigurator(metrics: metrics).frame(width: 0, height: 0))
        .sheet(isPresented: $account.showLoginSheet) {
            LoginSheet().environmentObject(account)
        }
        .task {
            // 启动时把"取可用正版账号"的能力注入给启动器
            store.accountProvider = { await account.validAccount() }
            // 调试用：--tab=home|download|versions|mods|settings
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--tab=") }) {
                switch arg.replacingOccurrences(of: "--tab=", with: "") {
                case "download": store.selectedTab = .download
                case "versions": store.selectedTab = .versions
                case "mods":     store.selectedTab = .mods
                case "settings": store.selectedTab = .settings
                default:         store.selectedTab = .home
                }
            }
            // 调试用：--about 直接打开关于面板
            if CommandLine.arguments.contains("--about") {
                try? await Task.sleep(nanoseconds: 600_000_000)
                AboutPanel.show()
            }

            // 调试用：--login 直接打开登录面板
            if CommandLine.arguments.contains("--login") { account.showLoginSheet = true }
            // 调试用：--import-account 启动即执行导入
            if CommandLine.arguments.contains("--import-account") { account.importFromLauncher() }

            // 调试用：--version=<已安装版本 id>
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--version=") }) {
                let id = arg.replacingOccurrences(of: "--version=", with: "")
                if store.installed.contains(where: { $0.id == id }) {
                    store.activeVersionID = id
                    store.refreshMods()
                }
            }
            // 调试用：--set-background=<图片路径> 启动即设为窗口背景
            // （走 app 自己的 UserDefaults 路径 —— macOS 26 上 container 会让
            //  `defaults write` 写到另一个文件，验证不了真实行为）
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--set-background=") }) {
                let path = arg.replacingOccurrences(of: "--set-background=", with: "")
                if let name = Background.store(URL(fileURLWithPath: path)) {
                    UserDefaults.standard.set(name, forKey: Background.Key.file)
                }
            }
            // 调试用：--launch-now=<版本 id> 启动即拉起游戏（不用手点按钮）
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--launch-now=") }) {
                let id = arg.replacingOccurrences(of: "--launch-now=", with: "")
                try? await Task.sleep(nanoseconds: 800_000_000)
                await store.launch(versionID: id)
            }
            // 有缓存也照样发起刷新：缓存先上屏保证秒开，后台再换新数据。
            await store.loadManifest()
        }
    }

    // MARK: 左侧导航
    private var sidebar: some View {
        VStack(spacing: 8) {
            brand
            // 导航项之间留一点缝，好让相邻玻璃融成一块
            GlassEffectContainer(spacing: 4) {
                VStack(spacing: 4) {
                    tabButton(.home, "主页", "house.fill")
                    tabButton(.download, "下载", "arrow.down.circle.fill")
                    tabButton(.versions, "版本", "square.stack.3d.up.fill")
                    tabButton(.mods, "Mod", "puzzlepiece.extension.fill")
                    tabButton(.settings, "设置", "gear")
                }
            }
            Spacer(minLength: 0)
            AccountChip()
        }
        // 顶部让开标题栏那一条（红绿灯就浮在这行上面）——
        // 注意这个 padding 在**玻璃之内**，所以玻璃本身仍然一路铺到窗口顶边，
        // 只有内容下移，不会露出墙纸把交通灯衬空。
        .padding(.top, metrics.topInset + 6)
        .frame(width: 188)
        // 侧边栏用通透玻璃：能透出后面的壁纸，是液态玻璃最明显的地方
        .glassChrome()
        .overlay(alignment: .trailing) {
            // 右边一条极淡的描边代替原来的 Divider
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 1)
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 26))
                .foregroundStyle(.linearGradient(
                    colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 1) {
                Text("Aether").font(.headline)
                Text("Minecraft 启动器").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func tabButton(_ tab: Tab, _ title: String, _ icon: String) -> some View {
        let selected = store.selectedTab == tab
        return Button {
            store.selectedTab = tab
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(width: 22, alignment: .center)
                Text(title).font(.body.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .modifier(GlassNavItem(selected: selected))
        // 强制置顶：导航项的玻璃层叠在上面会吃掉点击。
        .onTop()
    }

    // MARK: 内容区
    @ViewBuilder
    private var content: some View {
        switch store.selectedTab {
        case .home:      HomeView()
        case .download:  DownloadView()
        case .versions:  VersionsTabView()
        case .mods:      ModsView()
        case .settings:  SettingsView()
        }
    }
}

/// 侧栏导航项的玻璃态。
///
/// - 选中：可按压玻璃 + 强调色 tint（按下去会有高光变化）
/// - 未选中：不加玻璃（透明），保持侧栏通透
private struct GlassNavItem: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if selected {
            content
                .glassEffect(Glass.regular.tint(Color.accentColor.opacity(0.22)).interactive(),
                             in: .rect(cornerRadius: 10))
        } else {
            content
        }
    }
}
