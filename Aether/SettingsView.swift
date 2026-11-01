//
//  SettingsView.swift
//  maccraft
//
//  “设置”分页：玩家名、Java、下载源、内存、分辨率、外观（液态玻璃）、数据目录。
//  现在作为主界面左侧导航的一个分页，而非独立 Settings 场景。
//
//  外观上：每个分组是一块玻璃卡片（`.glassPanel`），
//  Form 自己的行背景被清成透明 —— 否则系统那层灰底会把窗口底下的渐变
//  / 自定义背景全挡住，玻璃就没得折射了。
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var store: LauncherStore
    // 背景设置用 @AppStorage（View 的 property wrapper）——
    // 放进 ObservableObject 里不会自动更新也不会自动写回。
    @AppStorage(Background.Key.file) private var bgFile: String = ""
    @AppStorage(Background.Key.dim) private var bgDim: Double = 0.22

    @AppStorage(SettingsKeys.username) private var username = "Player"
    @AppStorage(SettingsKeys.memoryMB) private var memoryMB = 4096
    @AppStorage(SettingsKeys.resolutionEnabled) private var resolutionEnabled = false
    @AppStorage(SettingsKeys.width) private var width = 1280
    @AppStorage(SettingsKeys.height) private var height = 720
    @AppStorage(SettingsKeys.javaHome) private var javaHome = ""
    @AppStorage(SettingsKeys.downloadSource) private var downloadSource = "auto"

    /// 当前背景图的本地副本。
    private var bgURL: URL? { Background.imageURL(storedFile: bgFile) }
    /// 背景图预览。
    private var bgPreview: NSImage? {
        guard let bgURL else { return nil }
        return NSImage(contentsOf: bgURL)
    }

    var body: some View {
        ScrollView {
            // 用 ScrollView + VStack 而不是 Form：
            // Form 会把每个控件拆成独立的 list row，
            // 玻璃背景就得加在每个 row 上 —— 结果是一堆碎玻璃卡片，不是整块。
            VStack(alignment: .leading, spacing: 14) {
                playerSection
                javaSection
                sourceSection
                memorySection
                resolutionSection
                appearanceSection
                dataSection
                aboutSection
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { store.refreshLocalJVMs() }
    }

    // MARK: - 分组

    private var playerSection: some View {
        glassSection("玩家") {
            TextField("离线用户名", text: $username)
                .textFieldStyle(.roundedBorder)
            Text("当前为离线模式（无需登录），适合单人 / 局域网游戏。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var javaSection: some View {
        glassSection("Java 运行时") {
            Text("默认自动探测本机已安装的 JDK（/Library/Java/JavaVirtualMachines、Homebrew、Azul 等）；若没有才会从网络下载 Adoptium Temurin（国内访问 GitHub 可能很慢，建议手动指定）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("手动指定 JDK 路径（可选）", text: $javaHome)
                    .textFieldStyle(.roundedBorder)
                Button("浏览…") { pickJDK() }
                    .controlSize(.small)
            }
            if !store.detectedJVMs.isEmpty {
                Text("本机已检测到 \(store.detectedJVMs.count) 个 JDK：")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.detectedJVMs, id: \.self) { url in
                    Text(url.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
        }
    }

    private var sourceSection: some View {
        glassSection("下载源") {
            Picker("下载源", selection: $downloadSource) {
                ForEach(DownloadSource.allCases) { src in
                    Text(src.label).tag(src.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text(currentSourceDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("候选链：类库 阿里云 → 腾讯云 → BMCLAPI(/libraries→/maven) → 官方；清单/客户端/资源 BMCLAPI → 官方。任一源超时、断流或速度低于阈值（<120 KB/s）都会立刻切换到下一个。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var memorySection: some View {
        glassSection("内存") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("最大内存")
                    Spacer(minLength: 0)
                    Text(String(format: "%.1f GB", Double(memoryMB) / 1024))
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(memoryMB) },
                    set: { memoryMB = Int($0) }
                ), in: 1024...16384, step: 512)
            }
        }
    }

    private var resolutionSection: some View {
        glassSection("分辨率") {
            Toggle("自定义窗口分辨率", isOn: $resolutionEnabled)
            if resolutionEnabled {
                HStack {
                    Stepper("宽 \(width)", value: $width, in: 640...3840, step: 64)
                    Stepper("高 \(height)", value: $height, in: 480...2160, step: 64)
                }
            }
        }
    }

    private var appearanceSection: some View {
        glassSection("外观 · 液态玻璃") {
            Text("背景是一张普通壁纸，液态玻璃只用在侧边栏、卡片和按钮上 —— 玻璃自己去折射壁纸，这样才干净、也不卡。")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 背景预览
            HStack(spacing: 12) {
                Group {
                    if let img = bgPreview {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(
                            colors: [.blue.opacity(0.5), .cyan.opacity(0.4), .purple.opacity(0.45)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(width: 96, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(bgFile.isEmpty ? "默认渐变背景" : "自定义壁纸")
                        .font(.callout.weight(.medium))
                    Text(bgFile.isEmpty ? "没有选择图片" : bgFile)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    if let name = Background.pickAndStore() { bgFile = name }
                } label: {
                    Label("选择壁纸…", systemImage: "photo.on.rectangle.angled")
                }
                .controlSize(.small)

                Button("恢复默认") {
                    Background.clearFiles()
                    bgFile = ""
                }
                .controlSize(.small)
                .disabled(bgFile.isEmpty)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("背景压暗")
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f%%", bgDim * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $bgDim, in: 0...0.8, step: 0.05)
                Text("在壁纸上压一层暗色，保证界面文字清晰。图片很亮时调高一点。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dataSection: some View {
        glassSection("数据目录") {
            HStack {
                Text(Paths.appSupport.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("在 Finder 中显示") { store.revealDataFolder() }
                    .controlSize(.small)
            }
        }
    }

    private var aboutSection: some View {
        glassSection("关于") {
            LabeledContent("名称", value: "Aether")
            LabeledContent("平台", value: "macOS 26+ · Apple Silicon")
            LabeledContent("运行环境", value: "纯 Swift · arm64")
        }
    }

    /// 一个玻璃分组卡片（标题 + 内容，整块一块玻璃）。
    private func glassSection<C: View>(_ title: String,
                                       @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 14)
        // 强制置顶：分组里的按钮（浏览 JDK、在 Finder 中显示）不能被玻璃层挡住。
        .onTop()
    }

    /// 当前下载源选项的说明文字。
    private var currentSourceDetail: String {
        (DownloadSource(rawValue: downloadSource) ?? .auto).detail
    }

    /// 打开文件选择面板，挑选 JDK 主目录（含 Contents/Home 的目录）。
    private func pickJDK() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "选择 JDK 主目录（应含有 Contents/Home/bin/java）"
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            javaHome = url.path
            store.refreshLocalJVMs()
        }
    }
}
