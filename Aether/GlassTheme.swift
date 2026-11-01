//
//  GlassTheme.swift
//  maccraft
//
//  macOS 26 液态玻璃（Liquid Glass）主题层。
//
//  ## 分工（重要，别搞混）
//
//  | 区域        | 做法                                             |
//  |-------------|--------------------------------------------------|
//  | 背景        | **普通壁纸**（自定义图 / 渐变），不做任何玻璃处理   |
//  | 侧边栏      | 液态玻璃 `.glassChrome`（通透，能透出壁纸）        |
//  | 内容卡片    | 液态玻璃 `.glassPanel`                            |
//  | 按钮        | 液态玻璃 `.glass` / `.glassProminent`             |
//
//  背景**刻意不做**液态玻璃：玻璃是「折射背景」的效果，
//  背景自己再糊一层、压一层遮罩、加两团柔光，
//  结果就是「毛玻璃上的毛玻璃」——既看不出壁纸本身，
//  又白白多出几次全屏合成（卡顿）。
//
//  macOS 26 的正确做法是：壁纸保持清晰，
//  让**玻璃自己去折射它**——模糊和折射是玻璃的活，不是背景的活。
//
//  ## API 对应关系
//
//  | 想要的效果        | 用的 API                                    |
//  |-------------------|---------------------------------------------|
//  | 一块玻璃          | `.glassEffect(.regular, in: .rect(cornerRadius:))` |
//  | 通透的玻璃        | `.glassEffect(.clear, in: ...)`              |
//  | 带色调的玻璃      | `.glassEffect(.regular.tint(.blue), in: ...)` |
//  | 可按压变亮的玻璃  | `.glassEffect(.regular.interactive(), in: ...)` |
//  | 玻璃按钮          | `.buttonStyle(.glass)` / `.glassProminent`   |
//  | 相邻玻璃融合      | `GlassEffectContainer(spacing:)`             |
//
//  这些 API 需要 macOS 26 —— 本工程 `MACOSX_DEPLOYMENT_TARGET = 26.0`，
//  所以不需要 availability 标注。
//

import SwiftUI
import AppKit
import Combine

// MARK: - 背景壁纸

/// 壁纸加载器。
///
/// 单独抽出来是因为 `@State` 在 `.task` 的 async 闭包里赋值会报
/// `cannot assign to property: 'self' is immutable`（View 是值类型，
/// 跨 await 后 self 不可变）。放进 class 里就没这问题。
@MainActor
final class WallpaperLoader: ObservableObject {
    /// 已经解码好的壁纸。
    @Published private(set) var image: NSImage?

    /// 当前已加载的路径（用来避免重复解码同一张图）。
    private var loadedPath: String = ""

    /// 加载壁纸（后台线程解码，主线程只做赋值）。
    func load(_ url: URL) async {
        if url.path == loadedPath, image != nil { return }
        let decoded = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
        guard !Task.isCancelled else { return }
        loadedPath = url.path
        image = decoded
    }

    func clear() {
        image = nil
        loadedPath = ""
    }
}

/// 窗口背景：**一张普通壁纸**（自定义图或默认渐变）。
///
/// ## 为什么必须用 GeometryReader
///
/// SwiftUI 的 `ZStack` 里，图片拿到的尺寸提议是**不确定的**
/// （ZStack 的尺寸由子视图决定 → 子视图反过来问 ZStack 要尺寸 → 循环），
/// 结果就是图只画中间一小块，看起来「没铺满」。
///
/// 这里把背景挂在 `.background { }` 上 —— `.background` 会把宿主视图的
/// 尺寸**原样**作为提议传进来，配合 `GeometryReader` 就能拿到确定的宽高。
///
/// `.aspectRatio(contentMode: .fill)` + `.clipped()` 是 SwiftUI 标准的
/// 「铺满裁剪」：图按比例放大到盖住整个 frame，多出来的部分裁掉，
/// 永远铺满、永远不会溢出到窗口外面。
struct AetherBackground: View {
    @Environment(\.colorScheme) private var scheme
    /// 背景图文件名（存在 UserDefaults）。
    @AppStorage(Background.Key.file) private var storedFile: String = ""
    /// 压暗强度（0~0.8）—— 只为文字可读，不是玻璃效果。
    @AppStorage(Background.Key.dim) private var dimAmount: Double = 0.22

    @StateObject private var loader = WallpaperLoader()

    private var wallpaperURL: URL? {
        Background.imageURL(storedFile: storedFile)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let url = wallpaperURL {
                    wallpaper(url, size: geo.size)
                } else {
                    gradientField(size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: storedFile) {
            guard let url = wallpaperURL else {
                loader.clear()
                return
            }
            await loader.load(url)
        }
    }

    // MARK: 自定义壁纸

    @ViewBuilder
    private func wallpaper(_ url: URL, size: CGSize) -> some View {
        if let image = loader.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                // 压一层暗色保证界面文字清晰（不是玻璃，只是遮罩）。
                .overlay(Color.black.opacity(dimAmount))
        } else {
            // 图还没解码出来：先垫渐变，避免闪一下白底。
            gradientField(size: size)
        }
    }

    // MARK: 默认渐变

    private func gradientField(size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(hex: 0x0B1020), Color(hex: 0x121A33), Color(hex: 0x0C1A26)]
                    : [Color(hex: 0xEAF1FF), Color(hex: 0xF6F2FF), Color(hex: 0xE6F6F8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            glowField(size: size)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// 两团柔光，给玻璃一点可折射的高光变化。
    ///
    /// 这里**故意不加 `.blur()`**：
    /// 径向渐变本身就是「中心实、边缘虚」的柔和过渡，再叠一层 blur 效果几乎没变，
    /// 但代价是每帧两次大尺寸的高斯卷积 —— 实测这是整个界面卡顿的主因。
    private func glowField(size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [accentGlow.opacity(scheme == .dark ? 0.30 : 0.22), .clear],
                    center: .center, startRadius: 0, endRadius: 320))
                .frame(width: 640, height: 640)
                .offset(x: -size.width * 0.22, y: -size.height * 0.30)

            Circle()
                .fill(RadialGradient(
                    colors: [secondaryGlow.opacity(scheme == .dark ? 0.24 : 0.18), .clear],
                    center: .center, startRadius: 0, endRadius: 300))
                .frame(width: 560, height: 560)
                .offset(x: size.width * 0.24, y: size.height * 0.28)
        }
    }

    private var accentGlow: Color {
        scheme == .dark ? Color(hex: 0x2E6BFF) : Color(hex: 0x4C8DFF)
    }

    private var secondaryGlow: Color {
        scheme == .dark ? Color(hex: 0x00C2D1) : Color(hex: 0x35D6E0)
    }
}

// MARK: - 玻璃样式

/// 统一的玻璃卡片外观。
///
/// 之所以抽成常量而不是到处写 `.glassEffect(.regular, in: .rect(cornerRadius: 12))`：
/// 圆角半径和玻璃种类必须全 app 一致，否则玻璃块拼接处会出现错位。
enum GlassTheme {
    /// 大面板圆角（下载页 / 设置页的分组卡片）。
    static let panelRadius: CGFloat = 12
    /// 小卡片圆角（资源卡片、列表项）。
    static let cardRadius: CGFloat = 12
    /// 胶囊圆角（搜索框、chip）。
    static let capsuleRadius: CGFloat = 10

    /// 常规玻璃（大多数面板用这个）。
    static var panel: Glass { .regular }

    /// 通透玻璃（侧边栏、底部任务条这类大浮层用这个，能透出更多背景）。
    static var chrome: Glass { .clear.tint(.primary.opacity(0.04)) }

    /// 可按压的玻璃（按钮、选中的导航项）。
    static var interactive: Glass { .regular.interactive() }
}

// MARK: - 便捷修饰符

extension View {
    /// 把视图变成一块常规玻璃面板。
    ///
    /// ## 为什么要显式分层
    ///
    /// `glassEffect` 会给视图加一层材质，SwiftUI 把它排在**内容之上**。
    /// 这层材质会吃掉落在它上面的点击 —— 表现是「卡片里的按钮点不动」，
    /// 而且半透明的材质罩在按钮上还会把文字冲淡成灰色，看着像 disabled。
    ///
    /// 所以这里不用 `.glassEffect(...)` 直接修饰，而是显式搭一个 ZStack：
    /// **玻璃层 zIndex 低，内容层 zIndex 高** → 内容永远在最上面，
    /// 怎么点都能点到。全 app 的玻璃卡片统一走这里，就不用逐个按钮加 zIndex。
    func glassPanel(radius: CGFloat = GlassTheme.panelRadius) -> some View {
        glassLayer(GlassTheme.panel, radius: radius)
    }

    /// 把视图变成通透玻璃（侧边栏 / 任务条这类大面积浮层）。
    func glassChrome(radius: CGFloat = 0) -> some View {
        glassLayer(GlassTheme.chrome, radius: radius)
    }

    /// 把视图变成可按压的玻璃（选中态的导航项）。
    func glassInteractive(radius: CGFloat = 10) -> some View {
        glassEffect(GlassTheme.interactive, in: .rect(cornerRadius: radius))
    }

    /// 玻璃卡片的标准结构：玻璃在下、内容在上。
    ///
    /// 玻璃层用 `.background` 承载（背景层在内容之下，本身就不拦点击），
    /// 内容层 zIndex 拉高 → 内容永远在最上面，怎么点都能点到。
    ///
    /// 注意**不要**用 ZStack + 形状来承载玻璃：
    /// 形状只能撑在自己的固有尺寸里，玻璃材质就铺不满整张卡片了。
    private func glassLayer(_ glass: Glass, radius: CGFloat) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(glass, in: .rect(cornerRadius: radius))
                    .allowsHitTesting(false)
            }
            .zIndex(1)
    }

    /// 在玻璃块下面垫一层极淡的底色。
    ///
    /// 玻璃本身是半透的，如果底下全是背景渐变，文字对比度可能不够。
    /// 这一层不透明度极低（0.04~0.06），只用来微调对比度，看不出是一层。
    func glassBackdrop(_ opacity: Double = 0.05) -> some View {
        background(Color.primary.opacity(opacity))
    }

    /// **强制置顶**到所在容器的最上层。
    ///
    /// ## 为什么需要
    ///
    /// SwiftUI 的 `.overlay { }` 叠在内容**之上**，其中的形状会吃掉
    /// 落在它上面的点击 —— 表现是「按钮点不动」。
    /// 而且半透明的 overlay 颜色罩在按钮上，会把按钮文字冲淡成灰色，
    /// 看着像 disabled，特别容易误判成状态机卡住。
    ///
    /// 用户的原话：「强制置顶所有给用户在应用里面交互的按钮」。
    /// 所以：**所有可交互的按钮一律加这个修饰符**，
    /// zIndex 拉高后按钮永远在最上层，任何 overlay 都压不住它。
    ///
    /// 用 `.zIndex` 而不是「装饰层不允许命中」的理由：
    /// 前者是**主动把按钮提到最上面**，不依赖对方是否设置了命中规则；
    /// 后者要靠每一处装饰层都记得加，漏一处就又点不动了。
    func onTop(_ z: Double = 1000) -> some View {
        zIndex(z)
    }
}

// MARK: - 玻璃容器

/// 把一组相邻的玻璃块包起来，让它们融合成一整块。
///
/// 没有这个容器时，两个相邻的玻璃块之间会有一条明显的分界；
/// 有了它，SwiftUI 会把它们之间的部分合并，形成 Apple 那种「一整块玻璃」的观感。
struct GlassSection<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

// MARK: - 窗口配置

/// 窗口的实时度量（顶部需要让开的高度）。
///
/// 开了 `fullSizeContentView` 之后，SwiftUI 内容视图铺满整个窗口，
/// 也就**顶到了标题栏底下** —— 页面标题会被裁掉一半、
/// 侧栏品牌名会被红绿灯压住。
///
/// 所以要量出「顶部该让开多少」，给内容留出这段空间。
///
/// ## 怎么量
///
/// 最准的是**直接量交通灯按钮**：`.standardWindowButton(.closeButton)`
/// 的底边就是红绿灯那一行的下沿。
/// （`contentLayoutRect` 在没有工具栏时等于整个内容区，量不出东西。）
@MainActor
final class WindowMetrics: ObservableObject {
    /// 顶部需要让开的高度（交通灯那一行 + 一点余量）。
    @Published private(set) var topInset: CGFloat = 0

    func update(from window: NSWindow) {
        var inset: CGFloat = 0

        // ① 交通灯按钮的底边（最准）
        // 注意两点：
        // · `convert(_:to: nil)` 得到的是**窗口坐标**，而 AppKit 的 y 轴朝上
        //   → maxY 是「距底边多高」，要换算成「距顶边多高」得用高度减掉它；
        // · fullSizeContentView 之后 contentView 覆盖整个窗口，
        //   所以窗口高度就是参考系。
        if let close = window.standardWindowButton(.closeButton),
           let host = close.superview {
            let rectInWindow = host.convert(close.frame, to: nil)
            inset = max(0, window.frame.height - rectInWindow.maxY)
        }

        // ② 兜底：标题栏高度（万一拿不到按钮）
        if inset == 0, let contentView = window.contentView {
            let chrome = contentView.bounds.height - window.contentLayoutRect.height
            inset = max(0, chrome)
        }

        if abs(inset - topInset) > 0.5 {
            topInset = inset
        }
    }
}

/// 让窗口内容**顶到标题栏底下**（fullSizeContentView），并把标题栏本身变透明。
///
/// ## 为什么需要
///
/// 默认情况下 SwiftUI 的内容从标题栏**下方**开始，
/// 于是标题栏那一块是系统自己的深色条 —— 和下面的壁纸之间
/// 会有一道明显的分界（就是之前说的「标题栏深色矩形」）。
///
/// 开了 `fullSizeContentView` 之后：
/// · 内容视图铺满整个窗口（含标题栏区域）
/// · 标题栏本身透明 → 壁纸一直铺到屏幕最顶上
/// · 红绿灯浮在侧栏玻璃上 —— 这正是 macOS 26 应用该有的样子
///
/// 用 `NSViewRepresentable` 拿窗口是因为 SwiftUI 没有对应修饰符。
/// 之所以覆写 `viewDidMoveToWindow` 而不是用 `DispatchQueue.main.async`：
/// 后者时机不定（视图可能还没挂进窗口），`viewDidMoveToWindow` 是确定信号。
struct FullSizeWindowConfigurator: NSViewRepresentable {
    let metrics: WindowMetrics

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.metrics = metrics
        return view
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.metrics = metrics
        nsView.configureIfNeeded()
    }

    /// 挂在窗口里就能自动配置的哑视图。
    final class ConfiguratorView: NSView {
        var metrics: WindowMetrics?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureIfNeeded()
        }

        func configureIfNeeded() {
            guard let window else { return }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            metrics?.update(from: window)
        }
    }
}
