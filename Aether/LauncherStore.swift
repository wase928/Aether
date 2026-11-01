//
//  LauncherStore.swift
//  maccraft
//
//  启动器的核心状态机：版本清单、下载编排、进度、日志与进程管理。
//

import Foundation
import Combine
import AppKit

/// 主界面分页（PCL / HMCL 风格的左侧竖排导航）。
enum Tab: Hashable {
    case home
    case download
    case versions
    case mods
    case settings
}

@MainActor
final class LauncherStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loadingManifest
        case preparing
        case downloading
        case launching
        case running
        case error
    }

    // ---- 版本清单 ----
    @Published var manifest: VersionManifest?
    @Published var searchText: String = ""
    @Published var selectedVersionID: String?

    // ---- 界面分页 ----
    @Published var selectedTab: Tab = .home

    // ---- 运行状态 ----
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var statusText: String = "就绪"
    @Published var logText: String = ""
    @Published var activeProcess: Process?

    /// 设置页展示用：本机检测到的 JDK（首次打开设置页时刷新）。
    @Published var detectedJVMs: [URL] = []

    /// 统一的任务进度 + 实时日志（解压 / 下载 / 安装共用，界面底部任务条绑定它）。
    let feed = TaskFeed()

    // ---- 已安装版本 ----
    @Published var installed: [InstalledVersion] = []
    /// 当前选中的已安装版本（首页大卡片 + Mod 管理都用它）。
    @Published var activeVersionID: String? {
        didSet { UserDefaults.standard.set(activeVersionID, forKey: "aether.activeVersion") }
    }
    /// Mod 管理列表。
    @Published var modEntries: [ModEntry] = []

    var activeVersion: InstalledVersion? {
        installed.first { $0.id == activeVersionID }
    }
    /// 当前版本对应的基础版本号（给 Modrinth 过滤用）。
    var activeMCVersion: String? {
        guard let v = activeVersion else { return nil }
        return v.baseVersion ?? (v.loader == .vanilla ? v.id : nil)
    }
    var activeLoader: LoaderKind { activeVersion?.loader ?? .vanilla }

    var isBusy: Bool {
        phase == .loadingManifest || phase == .preparing ||
        phase == .downloading || phase == .launching
    }

    var searchResults: [VersionManifest.VersionRef] {
        guard let manifest else { return [] }
        if searchText.isEmpty { return manifest.versions }
        return manifest.versions.filter { $0.id.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - 生命周期

    /// 当前清单刷新任务句柄（手动刷新时可取消上一次，防挂死）。
    private var manifestTask: Task<Void, Never>?

    /// 由 App 层注入：启动前取一个可用的正版账号（null 表示离线模式）。
    var accountProvider: (() async -> MinecraftAccount?)?

    init() {
        activeVersionID = UserDefaults.standard.string(forKey: "aether.activeVersion")
        installed = VersionLibrary.scan()
        if ProcessInfo.processInfo.environment["AETHER_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[store] init active=\(activeVersionID ?? "nil") installed=\(installed.map(\.id))\n".utf8))
        }
    }

    /// 重新扫描已安装版本（安装 / 删除后调用）。
    func refreshInstalled() {
        installed = VersionLibrary.scan()
        if ProcessInfo.processInfo.environment["AETHER_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[store] refresh active=\(activeVersionID ?? "nil") installed=\(installed.map(\.id))\n".utf8))
        }
        if activeVersionID == nil || !installed.contains(where: { $0.id == activeVersionID }) {
            activeVersionID = installed.first?.id
        }
        refreshMods()
    }

    /// 当前版本的 mod 列表。
    func refreshMods() {
        guard let id = activeVersionID else { modEntries = []; return }
        modEntries = ModEntry.scan(in: Paths.modsDir(id))
    }

    func toggleMod(_ entry: ModEntry) {
        let fm = FileManager.default
        if entry.enabled {
            let dst = entry.url.appendingPathExtension("disabled")
            try? fm.moveItem(at: entry.url, to: dst)
        } else {
            var name = entry.url.lastPathComponent
            if name.hasSuffix(".disabled") { name = String(name.dropLast(".disabled".count)) }
            try? fm.moveItem(at: entry.url, to: entry.url.deletingLastPathComponent().appendingPathComponent(name))
        }
        refreshMods()
    }

    func deleteMod(_ entry: ModEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        refreshMods()
    }

    func revealModsFolder() {
        guard let id = activeVersionID else { return }
        let dir = Paths.modsDir(id)
        try? Paths.ensure(dir)
        NSWorkspace.shared.open(dir)
    }

    /// 安装原版版本（下载版本 JSON + client.jar）。
    func installVanilla(_ ref: VersionManifest.VersionRef) async -> Bool {
        guard phase != .downloading else { return false }
        phase = .downloading
        progress = 0
        statusText = "正在安装 \(ref.id)…"
        append("▶ 安装原版 \(ref.id)")
        do {
            let id = try await VersionLibrary.installVanilla(ref) { [weak self] received, expected in
                Task { @MainActor in
                    self?.progress = expected > 0 ? Double(received) / Double(expected) : 0
                    self?.statusText = "下载 \(ref.id) 客户端 \(DownloadManager.mb(received))/\(DownloadManager.mb(max(expected, 0))) MB"
                }
            }
            append("✔ 已安装 \(id)")
            refreshInstalled()
            activeVersionID = id
            phase = .idle
            statusText = "就绪"
            progress = 0
            return true
        } catch {
            append("✖ 安装失败：\(error.localizedDescription)")
            phase = .error
            statusText = "安装失败"
            return false
        }
    }

    /// 删除已安装版本。
    func deleteVersion(_ id: String) {
        try? VersionLibrary.delete(id)
        refreshInstalled()
        append("🗑 已删除版本 \(id)")
    }

    // MARK: - 启动（按已安装版本）

    func launch(versionID: String) async {
        guard phase != .running, phase != .preparing, phase != .downloading else { return }
        do {
            phase = .preparing
            progress = 0
            logText = ""
            pendingLog.removeAll()
            openLogFile()
            // 任务条必须开一个新的任务：否则会把上一次的（已完成的）进度留在界面上，
            // 看着像还在下载。
            feed.begin("启动 \(versionID)")
            append("▶ 准备启动 \(versionID)")

            let resolved = try VersionLibrary.resolve(versionID)
            let details = resolved.details
            append("  继承链：\(resolved.chain.joined(separator: " → "))")
            append("  主类：\(details.mainClass)")

            let baseHint = resolved.chain.count > 1 ? resolved.chain.last : details.id
            let major = JavaManager.requiredJavaMajor(for: details, hint: baseHint)
            append("  所需 Java 大版本：\(major)")
            statusText = "准备 Java 运行时…"
            let java = try await JavaManager.javaExecutable(major: major) { [weak self] received, expected in
                Task { @MainActor in
                    self?.progress = expected > 0 ? Double(received) / Double(expected) : 0
                    self?.statusText = "下载 Java \(major) 运行时 \(DownloadManager.mb(received)) / \(DownloadManager.mb(max(expected, 0))) MB"
                }
            }
            append("  Java 就绪：\(java.path)")

            phase = .downloading
            try await downloadClient(details, jarID: resolved.clientJarID)
            try await downloadLibraries(details)
            try await downloadNatives(details)

            let (assetFile, indexName) = try await MojangAPI.fetchAssetIndex(details: details)
            append("  资源索引：\(indexName) · 对象数 \(assetFile.objects.count) · 已写入 \(Paths.assetIndexFile(indexName).path)")
            try await downloadAssets(assetFile)

            let jarPath = Paths.clientJar(resolved.clientJarID)
            // SecureJarHandler 版本（Forge/NeoForge 1.17+）的 gameDir 根目录不能有
            // 「多出来的」原版客户端 jar：它会被推导出模块名 `client`，与加载器的
            // srg jar（模块 `minecraft`）撞包 → `ResolutionException` → 启动失败。
            // 整合包作者经常把 client.jar 一起打包，这里在启动前清掉。
            // 注意：原版实例主类是 net.minecraft.client.main.Main，不走模块化，
            // 绝不能动它自己的 client.jar（就在 versions/<id>/ 里）。
            quarantineConflictingClientJars(gameDir: Paths.versionDir(versionID),
                                            primaryJar: jarPath,
                                            mainClass: details.mainClass)
            let cp = LaunchService.classpath(details: details,
                                             librariesDir: Paths.librariesDir,
                                             clientJar: jarPath)
            append("  classpath 已就绪（\(cp.split(separator: ":").count) 项）")
            // classpath 最后一项才是客户端 jar（HMCL 的顺序：libraries → primary jar）
            append("  客户端 jar：\(jarPath.lastPathComponent)")

            phase = .launching
            statusText = "启动中…"
            let account = await accountProvider?()
            if let account {
                append("  账号：\(account.name)（\(account.kind.title)）")
            } else {
                append("  账号：\(SettingsKeys.usernameValue)（离线）")
            }
            // 外置登录需要 authlib-injector 一起进 JVM
            var injectorJar: URL?
            if let account, account.kind == .yggdrasil {
                statusText = "准备外置登录组件…"
                do {
                    injectorJar = try await AuthlibInjector.ensureJar()
                    append("  authlib-injector：\(injectorJar!.path)")
                } catch {
                    append("  ⚠ authlib-injector 下载失败：\(error.localizedDescription)")
                }
            }
            let plan = LaunchService.plan(
                details: details,
                javaExecutable: java,
                username: SettingsKeys.usernameValue,
                memoryMB: SettingsKeys.memoryMBValue,
                resolution: SettingsKeys.resolutionEnabledValue
                    ? (SettingsKeys.widthValue, SettingsKeys.heightValue) : nil,
                gameDir: Paths.versionDir(versionID),
                clientJar: jarPath,
                librariesDir: Paths.librariesDir,
                nativesDir: Paths.nativesDir(versionID),
                classpath: cp,
                assetsRoot: Paths.assetsDir,
                assetsIndexName: indexName,
                account: account,
                authlibInjectorJar: injectorJar
            )
            append("  启动 Minecraft \(versionID) …")
            launchProcess(plan)
            phase = .running
            statusText = "运行中"
            feed.finish(ok: true, "已启动 \(versionID)")
        } catch {
            append("✖ 错误：\(error.localizedDescription)")
            feed.finish(ok: false, error.localizedDescription)
            phase = .error
            statusText = "出错"
        }
    }

    /// 导入整合包（.mrpack / 通用 zip / 实例文件夹）。
    /// 解压、写入、查询、下载四个阶段都会实时上报进度和日志。
    @discardableResult
    func importModpack(_ url: URL, onLog: (@Sendable (String) -> Void)? = nil) async -> Bool {
        guard phase != .downloading, phase != .preparing, phase != .running else { return false }
        phase = .downloading
        progress = 0
        logText = ""
        pendingLog.removeAll()
        openLogFile()
        statusText = "导入整合包…"
        feed.begin("导入整合包 · \(url.lastPathComponent)")
        append("▶ 导入整合包：\(url.lastPathComponent)")

        // 阶段权重：按真实耗时分配。
        // 解压很快（ditto，1 秒级），加载器安装最慢（跑安装器 + 预置依赖），
        // 下载文件数最多但可以并发，所以下载给大头。
        let relay = ProgressRelay(order: [
            (.scan, 0.02), (.extract, 0.08), (.install, 0.05),
            (.loader, 0.30), (.merge, 0.05), (.resolve, 0.10),
            (.download, 0.38), (.finish, 0.02)
        ]) { [weak self] p in
            Task { @MainActor in self?.absorb(p) }
        }

        do {
            let result = try await ModpackImporter.import(url, baseVersionID: activeVersionID, relay: relay) { msg in
                Task { @MainActor in
                    self.append("  " + msg)
                    self.feed.log(msg)
                    onLog?(msg)
                }
            }
            refreshInstalled()
            activeVersionID = result.versionID
            let summary = "实例 \(result.versionID) · \(result.fileCount) 个文件 · 用时 \(String(format: "%.1f", result.elapsed))s"
            append("✔ 导入完成：\(summary)")
            feed.finish(ok: true, summary)
            statusText = "整合包已导入"
            phase = .idle
            progress = 1
            return true
        } catch {
            let msg = "✖ 导入失败：\(error.localizedDescription)"
            append(msg)
            feed.finish(ok: false, msg)
            onLog?(msg)          // 面板里也要看到，不能只说「详见上方日志」
            statusText = "导入失败"
            phase = .error
            return false
        }
    }

    /// 把一条进度同时喂给任务条和顶部进度条。
    private func absorb(_ p: TaskProgress) {
        feed.apply(p)
        // overall 可能是 -1（表示「按阶段权重换算」，但这条没走 relay）。
        // 直接写进 progress 会让 ProgressView 拿到负值显示成空条。
        if p.overall >= 0 { progress = p.overall }
        var parts: [String] = ["\(p.stage.rawValue)"]
        if p.total > 0 { parts.append("\(p.current)/\(p.total)") }
        if p.totalBytes > 0 {
            parts.append("\(DownloadManager.mb(p.bytes))/\(DownloadManager.mb(p.totalBytes)) MB")
        }
        if p.speed > 0 { parts.append(String(format: "%.1f MB/s", p.speed / 1_048_576)) }
        if !p.detail.isEmpty { parts.append(p.detail) }
        statusText = parts.joined(separator: " · ")
    }

    /// 启动器安装的加载器后，直接刷新列表。
    func noteInstalled(_ id: String) {
        refreshInstalled()
        activeVersionID = id
    }

    func loadManifest() async {
        // 防抖：已在刷新中就不重复发起（HMCL 也是同一份清单只允许一个刷新任务）。
        guard phase != .loadingManifest else { return }
        // 先装本地缓存：窗口秒开、离线也能用。
        if let cached = MojangAPI.cachedManifest() {
            manifest = cached
            if selectedVersionID == nil { selectedVersionID = cached.latest.release }
            statusText = "就绪（本地缓存）"
        }
        phase = .loadingManifest
        statusText = "刷新版本列表…"
        do {
            let m = try await MojangAPI.fetchManifest()
            manifest = m
            if selectedVersionID == nil { selectedVersionID = m.latest.release }
            phase = .idle
            statusText = "就绪"
            append("已加载 \(m.versions.count) 个版本 · 最新正式版 \(m.latest.release)")
        } catch is CancellationError {
            append("■ 已取消刷新")
            phase = manifest == nil ? .error : .idle
            statusText = manifest == nil ? "出错" : "就绪（本地缓存）"
        } catch {
            append("✖ 刷新版本列表失败：\(error.localizedDescription)")
            // 有缓存就继续可用，否则报错。
            if manifest == nil {
                phase = .error
                statusText = "出错"
            } else {
                phase = .idle
            }
        }
    }

    /// 手动刷新：取消上一次任务再重新发起（网络挂起时用户不必干等）。
    func refreshManifest() {
        manifestTask?.cancel()
        phase = .idle
        manifestTask = Task { await loadManifest() }
    }

    func prepareAndLaunch(_ ref: VersionManifest.VersionRef) async {
        guard phase != .running else { return }
        do {
            phase = .preparing
            progress = 0
            logText = ""
            pendingLog.removeAll()
            openLogFile()
            feed.begin("准备启动 \(ref.id)")
            append("▶ 准备启动 \(ref.id)（\(ref.type)）")
            let details = try await MojangAPI.fetchVersionDetails(ref)
            append("  主类：\(details.mainClass)")

            let major = JavaManager.requiredJavaMajor(for: details)
            append("  所需 Java 大版本：\(major)")
            statusText = "准备 Java 运行时…"
            let java = try await JavaManager.javaExecutable(major: major) { [weak self] received, expected in
                Task { @MainActor in
                    self?.progress = expected > 0 ? Double(received) / Double(expected) : 0
                    self?.statusText = "下载 Java \(major) 运行时 \(DownloadManager.mb(received)) / \(DownloadManager.mb(max(expected, 0))) MB"
                }
            }
            append("  Java 就绪：\(java.path)")

            phase = .downloading
            try await downloadClient(details)
            try await downloadLibraries(details)
            try await downloadNatives(details)

            let (assetFile, indexName) = try await MojangAPI.fetchAssetIndex(details: details)
            append("  资源索引：\(indexName) · 对象数 \(assetFile.objects.count) · 已写入 \(Paths.assetIndexFile(indexName).path)")
            try await downloadAssets(assetFile)
            if indexName.hasPrefix("legacy") || indexName.hasPrefix("pre-1.6") {
                try MojangAPI.materializeVirtualAssets(indexName: indexName, file: assetFile)
                append("  已铺开旧版资源目录 virtual/\(indexName)")
            }

            // 同 launch()：SecureJarHandler 版本的 gameDir 根目录不能留「多出来的」
            // 原版客户端 jar（JPMS 模块冲突）。原版实例（主类 Main）不受影响。
            quarantineConflictingClientJars(gameDir: Paths.versionDir(ref.id),
                                            primaryJar: Paths.clientJar(details.id),
                                            mainClass: details.mainClass)
            let cp = LaunchService.classpath(
                details: details,
                librariesDir: Paths.librariesDir,
                clientJar: Paths.clientJar(details.id)
            )
            append("  classpath 已就绪（\(cp.split(separator: ":").count) 项）")
            append("  客户端 jar：\(Paths.clientJar(details.id).lastPathComponent)")

            phase = .launching
            statusText = "启动中…"
            let account = await accountProvider?()
            if let account {
                append("  账号：\(account.name)（\(account.kind.title)）")
            } else {
                append("  账号：\(SettingsKeys.usernameValue)（离线）")
            }
            // 外置登录需要 authlib-injector 一起进 JVM
            var injectorJar: URL?
            if let account, account.kind == .yggdrasil {
                statusText = "准备外置登录组件…"
                do {
                    injectorJar = try await AuthlibInjector.ensureJar()
                    append("  authlib-injector：\(injectorJar!.path)")
                } catch {
                    append("  ⚠ authlib-injector 下载失败：\(error.localizedDescription)")
                }
            }
            let plan = LaunchService.plan(
                details: details,
                javaExecutable: java,
                username: SettingsKeys.usernameValue,
                memoryMB: SettingsKeys.memoryMBValue,
                resolution: SettingsKeys.resolutionEnabledValue
                    ? (SettingsKeys.widthValue, SettingsKeys.heightValue) : nil,
                gameDir: Paths.appSupport,
                clientJar: Paths.clientJar(details.id),
                librariesDir: Paths.librariesDir,
                nativesDir: Paths.nativesDir(details.id),
                classpath: cp,
                assetsRoot: Paths.assetsDir,
                assetsIndexName: indexName,
                account: account,
                authlibInjectorJar: injectorJar
            )
            append("  启动 Minecraft \(details.id) …")
            launchProcess(plan)
            phase = .running
            statusText = "运行中"
        } catch {
            append("✖ 错误：\(error.localizedDescription)")
            phase = .error
            statusText = "出错"
        }
    }

    func stop() {
        activeProcess?.terminate()
        append("■ 已发送停止信号")
    }

    // MARK: - 下载步骤

    private func downloadClient(_ details: VersionDetails, jarID: String? = nil) async throws {
        guard let client = details.downloads?.client else { throw LauncherError.missingClient }
        let dest = Paths.clientJar(jarID ?? details.id)
        if FileManager.default.fileExists(atPath: dest.path) {
            append("  客户端已存在，跳过"); return
        }
        append("  下载客户端（约 \((client.size ?? 0) / 1_000_000) MB）…")
        let official = URL(string: Mirror.toOfficial(client.url)) ?? URL(string: client.url)!
        let cands = Mirror.candidates(for: official, kind: .clientJar)
        append("  源顺序：" + cands.map { Mirror.label($0.source) }.joined(separator: " → "))
        try await DownloadManager.downloadCandidates(
            cands, kind: .clientJar, to: dest, sha1: client.sha1,
            progress: { [weak self] received, expected in
                let p = expected > 0 ? Double(received) / Double(expected) : 0
                Task { @MainActor in
                    self?.progress = p
                    self?.statusText = "下载客户端 \(DownloadManager.mb(received)) / \(DownloadManager.mb(max(expected, 0))) MB"
                }
            },
            onSwitch: fallbackLogger)
    }

    /// 把加载器实例 gameDir 根目录里的「多出来的原版客户端 jar」挪走。
    ///
    /// 背景（真实崩溃）：
    /// ```
    /// java.lang.module.ResolutionException: Modules minecraft and client
    ///   export package net.minecraft.world.level.storage.loot to module xxx
    /// ```
    /// `minecraft` 模块来自加载器的已重映射 srg jar，`client` 模块来自 gameDir 里
    /// 整合包自带的原版 client.jar —— SecureJarHandler 按混淆包名 `fgi$a` 反推出模块名 `client`。
    /// 两者都导出 `net.minecraft.server` 等包 → JPMS 判定冲突 → 游戏直接退出。
    ///
    /// ## 两个必须做对的判据（踩过坑）
    ///
    /// **1. 只对 SecureJarHandler 版本做**（看主类，不看本机状态）。
    /// 原版的主类是 `net.minecraft.client.main.Main`，不扫描 mods 目录、不做模块化，
    /// 多一份客户端 jar 不会致命。更要命的是：原版实例的 **client.jar 就在
    /// `versions/<id>/` 里**，而它同时也是 gameDir —— 早先这里用「本机有没有 srg jar」
    /// 当判据（本机装过 NeoForge → 恒为真），结果把原版实例自己的 client.jar 挪走了，
    /// classpath 指向空文件 → `Could not find or load main class net.minecraft.client.main.Main`。
    ///
    /// **2. 绝不碰 primary jar**（classpath 最后一项那个）。
    /// 它由 `ignoreList` 里的 `${primary_jar_name}` 排除出模块层，
    /// 留着它是对的；只有「多出来的」那一份才是冲突源。
    private func quarantineConflictingClientJars(gameDir: URL,
                                                 primaryJar: URL,
                                                 mainClass: String) {
        guard LaunchService.usesSecureJarHandler(mainClass: mainClass) else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: gameDir, includingPropertiesForKeys: nil) else { return }
        let quarantine = gameDir.appendingPathComponent(".aether-conflicts", isDirectory: true)
        for item in items where item.lastPathComponent.hasSuffix(".jar") {
            // primary jar（classpath 里那个）不碰
            if item.standardizedFileURL.path == primaryJar.standardizedFileURL.path { continue }
            guard ZipTool.isMinecraftClientJar(item) else { continue }
            try? Paths.ensure(quarantine)
            let dest = quarantine.appendingPathComponent(item.lastPathComponent)
            try? fm.removeItem(at: dest)
            do {
                try fm.moveItem(at: item, to: dest)
                append("  ⚠ 已移走冲突的客户端 jar：\(item.lastPathComponent)")
                append("    （与加载器的 srg jar 冲突，已放到 .aether-conflicts/）")
            } catch {
                append("  ⚠ 无法移走 \(item.lastPathComponent)：\(error.localizedDescription)")
            }
        }
    }

    /// 对某一类资源做一次「样本测速」，返回按实测速度排好的源顺序（已带 5 分钟缓存）。
    private func measuredSourceOrder(probe: URL, kind: ResourceKind, cacheKey: String) async -> [String]? {
        let cands = Mirror.candidates(for: probe, kind: kind)
        guard cands.count > 1, SettingsKeys.downloadSourceValue == .auto else { return nil }
        let ranked = await SourceBenchmark.rank(cands, kind: kind, cacheKey: cacheKey)
        let speeds = ranked.compactMap { c -> String? in
            guard let s = SourceHealth.shared.speed(of: c.source, kind: kind), s > 0 else { return nil }
            return "\(Mirror.label(c.source)) \(String(format: "%.1f", s / 1_048_576)) MB/s"
        }
        if !speeds.isEmpty { append("  实测源速：" + speeds.joined(separator: " · ")) }
        return ranked.map(\.source)
    }

    /// 按源顺序重建候选链（保证每个文件都从最快的源开始）。
    private func applyOrder(_ order: [String]?, to official: URL, kind: ResourceKind) -> [MirrorCandidate] {
        let cands = Mirror.candidates(for: official, kind: kind)
        guard let order else { return cands }
        return cands.sorted {
            (order.firstIndex(of: $0.source) ?? 99) < (order.firstIndex(of: $1.source) ?? 99)
        }
    }

    private func downloadLibraries(_ details: VersionDetails) async throws {
        // 1) 先收集待下载项（跳过已存在的）
        var pending: [(official: URL, local: URL, sha1: String?, size: Int64?)] = []
        for lib in details.libraries where rulesAllow(lib.rules, features: [:]) {
            // 加载器的库可能只有 maven 坐标（fabric / quilt / 部分 forge），统一走 artifact()
            guard let artifact = lib.artifact() else { continue }
            let local = Paths.librariesDir.appendingPathComponent(artifact.path)
            if FileManager.default.fileExists(atPath: local.path) { continue }
            let official = URL(string: Mirror.toOfficial(artifact.url)) ?? URL(string: artifact.url)!
            pending.append((official, local, artifact.sha1, artifact.size))
        }
        append("  待下载依赖库 \(pending.count) 个")
        guard !pending.isEmpty else { return }

        // 2) 用体积最大的那个类库做测速样本（结果 5 分钟内复用，不会每个文件都测）
        let probe = (pending.max { ($0.size ?? 0) < ($1.size ?? 0) })?.official
        let order = probe == nil ? nil : await measuredSourceOrder(
            probe: probe!, kind: .library, cacheKey: "library")

        let items = pending.map {
            DownloadItem(urls: applyOrder(order, to: $0.official, kind: .library),
                         destination: $0.local, sha1: $0.sha1, size: $0.size, kind: .library)
        }
        let totalBytes = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let counter = ProgressCounter(total: items.count, totalBytes: totalBytes)
        let mon = monitor(counter, label: "下载依赖库")
        defer { mon.cancel() }
        try await DownloadManager.downloadMany(items, counter: counter, onFallback: fallbackLogger)
    }

    private func downloadNatives(_ details: VersionDetails) async throws {
        let nativesDir = Paths.nativesDir(details.id)
        var count = 0
        for lib in details.libraries where rulesAllow(lib.rules, features: [:]) {
            guard let natives = lib.natives,
                  let key = natives["osx"] ?? natives["macos"],
                  let artifact = lib.downloads?.classifiers?[key] else { continue }
            let jarDest = nativesDir.appendingPathComponent("\(lib.name.replacingOccurrences(of: ":", with: "_")).jar")
            let official = URL(string: Mirror.toOfficial(artifact.url)) ?? URL(string: artifact.url)!
            try await DownloadManager.downloadCandidates(
                Mirror.candidates(for: official, kind: .library),
                kind: .library, to: jarDest, sha1: artifact.sha1,
                onSwitch: fallbackLogger)
            LaunchService.unzip(jarDest, to: nativesDir, exclude: lib.extract?.exclude ?? [])
            count += 1
        }
        if count > 0 { append("  解包原生库 \(count) 个") }
    }

    private func downloadAssets(_ file: AssetIndexFile) async throws {
        // 1) 收集缺失资源
        var pending: [(hash: String, size: Int64)] = []
        for (_, obj) in file.objects {
            let dest = Paths.assetsDir
                .appendingPathComponent("objects", isDirectory: true)
                .appendingPathComponent(String(obj.hash.prefix(2)), isDirectory: true)
                .appendingPathComponent(obj.hash)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            pending.append((obj.hash, Int64(obj.size)))
        }
        append("  待下载资源 \(pending.count) 个")
        guard !pending.isEmpty else { return }

        // 2) 用最大的那个资源做测速样本
        let order: [String]?
        if let probe = pending.max(by: { $0.size < $1.size }) {
            let prefix = String(probe.hash.prefix(2))
            let official = URL(string: "https://resources.download.minecraft.net/\(prefix)/\(probe.hash)")!
            order = await measuredSourceOrder(probe: official, kind: .assetObject, cacheKey: "asset")
        } else {
            order = nil
        }

        let objectsDir = Paths.assetsDir.appendingPathComponent("objects", isDirectory: true)
        let items = pending.map { p -> DownloadItem in
            let dest = objectsDir
                .appendingPathComponent(String(p.hash.prefix(2)), isDirectory: true)
                .appendingPathComponent(p.hash)
            let official = URL(string: "https://resources.download.minecraft.net/\(p.hash.prefix(2))/\(p.hash)")!
            return DownloadItem(urls: applyOrder(order, to: official, kind: .assetObject),
                                destination: dest, sha1: p.hash, size: p.size, kind: .assetObject)
        }
        let totalBytes = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let counter = ProgressCounter(total: items.count, totalBytes: totalBytes)
        let mon = monitor(counter, label: "下载资源")
        defer { mon.cancel() }
        try await DownloadManager.downloadMany(items, counter: counter, maxConcurrent: 16,
                                               onFallback: fallbackLogger)
    }

    // MARK: - 进程

    private func launchProcess(_ plan: LaunchService.Plan) {
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        process.environment = ProcessInfo.processInfo.environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            append("✖ 启动失败：\(error.localizedDescription)")
            phase = .error
            return
        }
        activeProcess = process

        attachOutput(out.fileHandleForReading)
        attachOutput(err.fileHandleForReading)
        Task {
            while process.isRunning {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let reason = process.terminationReason == .uncaughtSignal ? "被信号终止" : "退出码 \(process.terminationStatus)"
            append("■ Minecraft 已退出（\(reason)）")
            phase = .idle
            statusText = "已停止"
            activeProcess = nil
        }
    }

    // MARK: - 辅助

    /// 换源回退提示写进运行日志（跨线程安全： hop 回主线程）。
    private var fallbackLogger: @Sendable (String) -> Void {
        { msg in Task { @MainActor in self.append(msg) } }
    }

    private func monitor(_ counter: ProgressCounter, label: String) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let d = await counter.done
                let t = await counter.total
                let name = await counter.currentFile
                let b = await counter.currentBytes
                let bt = await counter.currentTotal
                let doneBytes = await counter.doneBytes
                let totalBytes = await counter.totalBytes
                let speed = await counter.sampleSpeed()

                let frac = t > 0 ? Double(d) / Double(t) : 0
                progress = frac
                // 资源文件名是 40 位 hash，截短显示
                let shown = name.count > 20 ? "\(name.prefix(8))…" : name
                var parts: [String] = ["\(label) \(d)/\(t)"]
                if !name.isEmpty {
                    if bt > 0 {
                        parts.append("\(shown) \(DownloadManager.mb(b))/\(DownloadManager.mb(bt)) MB")
                    } else {
                        parts.append(shown)
                    }
                }
                if totalBytes > 0 {
                    parts.append("总 \(DownloadManager.mb(doneBytes + b))/\(DownloadManager.mb(totalBytes)) MB")
                }
                if speed > 0 {
                    parts.append(String(format: "%.1f MB/s", speed / 1_048_576))
                }
                statusText = parts.joined(separator: " · ")

                // 注意：overall 必须一起给。
                // TaskProgress.overall 默认 -1，表示「让 ProgressRelay 按阶段权重换算」，
                // 但这里没走 relay，TaskFeed 会原样保留旧值 —— 早期版本因为漏传，
                // 任务条的百分比一直停在 0%，只有计数在跳，看着像卡死。
                feed.apply(TaskProgress(stage: .download, current: d, total: t,
                                        bytes: doneBytes + b, totalBytes: totalBytes,
                                        detail: "\(label) · \(shown)", speed: speed,
                                        ratio: frac, overall: frac))

                if d >= t { break }
                // 关键：用 `try await` 而不是 `try?` —— 取消时 sleep 会抛 CancellationError，
                // 必须让循环退出。以前用 try? 把错误吞了，取消后循环继续跑，
                // 于是上一次启动的 monitor 一直往界面写旧数据，
                // 表现为「3828/5147 · 0.0 MB/s」卡在屏幕上不放。
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                } catch {
                    break
                }
            }
        }
    }

    /// 日志：先在内存里排队，每 150ms 批量刷新一次界面，避免逐行写 @Published 把主线程拖死。
    @MainActor private var pendingLog: [String] = []
    @MainActor private var flushScheduled = false
    @MainActor private var logFileHandle: FileHandle?

    /// 界面日志上限（字符数），超出后只保留尾部，防止 Text 渲染卡顿。完整日志在 logs/latest.log。
    private let logDisplayLimit = 400_000

    func append(_ text: String) {
        appendLines([text])
    }

    func appendLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        if let fh = logFileHandle {
            try? fh.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        pendingLog.append(contentsOf: lines)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.flushLogToView()
        }
    }

    private func flushLogToView() {
        flushScheduled = false
        guard !pendingLog.isEmpty else { return }
        let batch = pendingLog
        pendingLog.removeAll(keepingCapacity: true)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        var parts: [String] = [logText]
        parts.reserveCapacity(batch.count + 1)
        for line in batch { parts.append("[\(stamp)] \(line)\n") }
        var text = parts.joined()
        if text.count > logDisplayLimit {
            text = String(text.suffix(logDisplayLimit))
            if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            text = "…（界面只保留最近日志，完整内容见 logs/latest.log）\n" + text
        }
        logText = text
    }

    private func openLogFile() {
        try? Paths.ensure(Paths.logsDir)
        let url = Paths.logsDir.appendingPathComponent("latest.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFileHandle = try? FileHandle(forWritingTo: url)
    }

    /// 分块读取进程输出（readabilityHandler），按行切分后批量进日志。
    /// 之前用 `bytes.lines` 逐字节异步迭代，游戏一刷几千行 warning 就把主线程拖垮（实测日志延迟 70 秒）。
    private func attachOutput(_ handle: FileHandle) {
        let pump = LinePump { [weak self] lines in
            Task { @MainActor in self?.appendLines(lines) }
        }
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                pump.flushRemainder()
                return
            }
            pump.feed(data)
        }
    }

    /// 在 Finder 中打开游戏数据目录。
    func revealDataFolder() {
        NSWorkspace.shared.open(Paths.appSupport)
    }

    /// 探测本机已安装的 JDK（仅在打开设置页时触发一次；仅做目录枚举 + 一次 java_home 查询，很快）。
    func refreshLocalJVMs() {
        detectedJVMs = JavaManager.listLocalJVMs()
    }
}

/// 把进程输出的字节流按行切开，批量交给上层（避免逐字节 / 逐行处理）。
nonisolated final class LinePump: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLines: @Sendable ([String]) -> Void

    init(onLines: @escaping @Sendable ([String]) -> Void) {
        self.onLines = onLines
    }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        var start = buffer.startIndex
        while let idx = buffer[start...].firstIndex(of: 0x0A) {
            let slice = buffer[start..<idx]
            if let s = String(data: slice, encoding: .utf8) { lines.append(s) }
            start = buffer.index(after: idx)
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        if buffer.count > 2_000_000 { buffer.removeAll(keepingCapacity: true) }  // 超长无换行保护
        lock.unlock()
        if !lines.isEmpty { onLines(lines) }
    }

    func flushRemainder() {
        lock.lock()
        let rest = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) { onLines([s]) }
    }
}
