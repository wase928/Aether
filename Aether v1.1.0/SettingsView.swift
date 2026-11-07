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
                performanceSection
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
        .task { store.refreshVulkan() }
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

    /// 性能调优分区。
    ///
    /// 这一整块是「点了启动游戏就自动生效」的 —— 用户不用手动敲 JVM 参数，
    /// 也不用知道 ZGC 是什么。
    private var performanceSection: some View {
        glassSection("性能调优") {
            // ---- JVM 调优 ----
            Toggle("JVM 调优（推荐）", isOn: $jvmTuningEnabled)
            if jvmTuningEnabled {
                Picker("垃圾回收器", selection: $jvmGC) {
                    ForEach(JVMOptimize.GCKind.allCases) { kind in
                        Text(kind.rawValue).tag(Optional(kind))
                    }
                }
                .pickerStyle(.menu)

                Toggle("激进模式（预热更充分，启动略慢）", isOn: $jvmTuningAggressive)

                Text("""
                MC 的帧率瓶颈大多不在 GPU，而在 GC 停顿：每 tick 产生大量短命对象，\
                默认 GC 的回收停顿会把帧时间打成锯齿。启动器会按 Java 版本自动选 \
                低停顿 GC（Java 17+ 用 ZGC），并在启动前实测本机 JVM 是否支持，\
                不支持就自动降级 —— 不会出现「参数不被接受、游戏起不来」。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let eff = effectiveGC {
                    Text("当前实际使用：\(eff.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.4)

            // ---- Vulkan 加速 ----
            HStack {
                Toggle("Vulkan 加速", isOn: $vulkanEnabled)
                Spacer(minLength: 0)
                if store.vulkanInstalling {
                    ProgressView().controlSize(.small)
                }
            }
            Text("""
            macOS 没有原生 Vulkan，靠 MoltenVK（Khronos 官方）实时转译成 Metal。\
            开启后启动器会自动配好 ICD 路径。**注意**：Minecraft 官方到 1.21.x \
            默认仍是 OpenGL 渲染器，要真正走 Vulkan 还需要装 VulkanMod \
            （仅 Fabric / Quilt 实例可用）。
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(vkStatus)
                    .font(.caption)
                    .foregroundStyle(vkStatusColor)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if !store.vulkanStatus.moltenVKInstalled {
                    Button("安装 MoltenVK") { store.installMoltenVK() }
                        .controlSize(.small)
                } else if !store.vulkanStatus.icdReady {
                    Button("修复 ICD 配置") { store.repairVulkanICD() }
                        .controlSize(.small)
                }
                Button("重新检测") { store.refreshVulkan() }
                    .controlSize(.small)
            }

            // ---- VulkanMod ----
            //
            // 光有 MoltenVK 不够 —— MC 官方到 1.21.x 默认还是 OpenGL 渲染器，
            // 要真正走 Vulkan 必须装 VulkanMod（只有 Fabric / Quilt 有）。
            Divider().opacity(0.4)
            if let activeID = store.activeVersionID {
                HStack {
                    Text("VulkanMod")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    Text(VulkanSupport.hasVulkanMod(versionID: activeID) ? "已安装" : "未安装")
                        .font(.caption)
                        .foregroundStyle(VulkanSupport.hasVulkanMod(versionID: activeID) ? .green : .secondary)
                }
                if !VulkanSupport.supportsVulkanMod(versionID: activeID) {
                    Text("当前实例不是 Fabric / Quilt，装不了 VulkanMod。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !VulkanSupport.hasVulkanMod(versionID: activeID) {
                    Button("为当前实例安装 VulkanMod") {
                        store.installVulkanMod(versionID: activeID)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 性能相关的状态与动作

    @AppStorage(SettingsKeys.jvmTuningEnabled) private var jvmTuningEnabled = true
    @AppStorage(SettingsKeys.jvmGC) private var jvmGC: String = ""
    @AppStorage(SettingsKeys.jvmTuningAggressive) private var jvmTuningAggressive = false
    @AppStorage(SettingsKeys.vulkanEnabled) private var vulkanEnabled = false

    private var vkStatus: String { store.vulkanStatus.summary }
    private var vkStatusColor: Color {
        let s = store.vulkanStatus
        return s.usable ? .green : (s.moltenVKInstalled ? .orange : .secondary)
    }

    /// 实际会用哪个 GC（考虑自动降级）。
    private var effectiveGC: JVMOptimize.GCKind? {
        let preferred = jvmGC.isEmpty ? nil : JVMOptimize.GCKind(rawValue: jvmGC)
        return JVMOptimize.resolveGC(preferred: preferred, javaMajor: 21, javaExecutable: nil)
    }

    private var resolutionSection: some View {
        glassSection("分辨率") {
            Toggle("自定义窗口分辨率", isOn: $resolutionEnabled)
            if resolutionEnabled {
                HStack {
                    Stepper("宽 \(width)", value: $width, in: 640...3840, step: 64)
                    Stepper("高 \(height)", value: $height, in: 480...2160, step: 64)
                }
            } else {
                // 关掉自定义不等于「不给尺寸」：以前那样等于让 MC 走原版兜底的
                // 854×480，再碰上整合包的 guiScale 就会界面巨大、字还糊。
                Text("默认跟随屏幕：\(DisplayDefaults.summary())（16:9，按屏幕算出，不写死）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Divider().opacity(0.4)

            // 存放结构：实例与核心分离（照 SwiftCraft 的分法）
            VStack(alignment: .leading, spacing: 4) {
                Text("存放结构")
                    .font(.caption.weight(.semibold))
                Label {
                    Text("profiles/ —— 可游玩的实例（整合包 / 原版档），版本列表只扫这里")
                        .font(.caption).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "square.stack.3d.up.fill").font(.caption2)
                }
                Label {
                    Text("meta/versions/ —— 版本核心（原版 + Forge / Fabric 加载器），永远不进列表")
                        .font(.caption).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "shippingbox.fill").font(.caption2)
                }
            }

            if store.needsStorageMigration {
                Divider().opacity(0.4)
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("检测到旧版存放结构").font(.caption.weight(.semibold))
                        Text("把现有 versions/ 与 .packcores/ 原地迁移到 profiles/ + meta/versions/。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        store.migrateStorage()
                    } label: {
                        if store.migratingStorage {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("迁移中…")
                            }
                        } else {
                            Text("一键迁移")
                        }
                    }
                    .controlSize(.small)
                    .disabled(store.migratingStorage)
                }
                if !store.storageMigrationNote.isEmpty {
                    Text(store.storageMigrationNote)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Divider().opacity(0.4)
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("已在新布局上（核心与实例分离，版本列表不会显示核心）")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("重新扫描") {
                        store.needsStorageMigration = VersionLibrary.hasLegacyLayout
                        store.refreshInstalled()
                    }
                    .controlSize(.mini)
                }
                if !store.storageMigrationNote.isEmpty {
                    Text(store.storageMigrationNote)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var aboutSection: some View {
        glassSection("关于") {
            LabeledContent("名称", value: "Aether")
            LabeledContent("平台", value: "macOS 26+ · Apple Silicon")
            LabeledContent("运行环境", value: "Swift / SwiftUI · arm64")
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
