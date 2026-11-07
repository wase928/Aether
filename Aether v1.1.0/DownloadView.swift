//
//  DownloadView.swift
//  maccraft
//
//  组件下载中心：左侧分类（原版 / 加载器 / Mod / 光影 / 资源包），右侧安装面板。
//  布局参考 PCL2 的 PageDownloadLeft + PageDownloadInstall；
//  资源类不再要求先搜索——进页面就是"下载量热门榜"，点一下即装。
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - 分类

nonisolated enum DownloadCategory: String, CaseIterable, Identifiable, Sendable {
    case vanilla, forge, fabric, neoforge, quilt, mod, shader, resourcepack, modpack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vanilla:      return "原版游戏"
        case .forge:        return "Forge"
        case .fabric:       return "Fabric"
        case .neoforge:     return "NeoForge"
        case .quilt:        return "Quilt"
        case .mod:          return "Mod"
        case .shader:       return "光影包"
        case .resourcepack: return "资源包"
        case .modpack:      return "整合包"
        }
    }

    var icon: String {
        switch self {
        case .vanilla:      return "cube.fill"
        case .forge:        return "hammer.fill"
        case .fabric:       return "square.stack.3d.up.fill"
        case .neoforge:     return "flame.fill"
        case .quilt:        return "square.grid.3x3.fill"
        case .mod:          return "puzzlepiece.extension.fill"
        case .shader:       return "sun.max.fill"
        case .resourcepack: return "paintpalette.fill"
        case .modpack:      return "shippingbox.fill"
        }
    }

    var loader: LoaderKind? {
        switch self {
        case .forge:    return .forge
        case .fabric:   return .fabric
        case .neoforge: return .neoforge
        case .quilt:    return .quilt
        default:        return nil
        }
    }

    var resourceType: ResourceType? {
        switch self {
        case .mod:          return .mod
        case .shader:       return .shader
        case .resourcepack: return .resourcepack
        default:            return nil
        }
    }

    var isLoader: Bool { loader != nil }
    var isResource: Bool { resourceType != nil }
}

// MARK: - 下载中心状态

@MainActor
final class DownloadCenter: ObservableObject {
    @Published var category: DownloadCategory = .vanilla
    @Published var query = ""
    @Published var mcVersion = ""
    @Published var loaderVersions: [String] = []
    @Published var selectedLoader: String?
    @Published var projects: [ModrinthProject] = []
    @Published var totalHits = 0
    @Published var busy = false
    @Published var loadingMore = false
    @Published var status = ""
    @Published var installing = false
    @Published var installingProject: String?
    @Published var lastInstalled: String?
    /// 整合包导入日志（面板里实时显示）
    @Published var importLog: [String] = []
    /// 是否正在导入
    @Published var importingPack = false
    /// 正在读取包内清单（准备弹确认面板）
    @Published var preparingPack = false
    /// 待确认的整合包导入。非 nil 时弹出设置面板：
    /// 让用户确认/修改「目标 MC 版本」，在线整合包还能选具体版本。
    @Published var pendingPack: PendingPack?

    /// 导入前的确认信息。
    struct PendingPack: Identifiable {
        let id = UUID()
        var title: String
        var kindLabel: String
        /// 包内声明的 MC 版本（通用包为空）
        var declaredMC: String
        /// 包内声明的加载器，如 "Forge 47.4.20"
        var loader: String
        /// 本地导入的文件/文件夹
        var localURL: URL?
        /// 在线导入的项目
        var project: ModrinthProject?
        /// 在线导入可选的具体整合包版本
        var versions: [ModrinthVersion] = []
        var versionID: String?
        /// 用户选定的目标 MC 版本
        var targetMC: String = ""
    }

    /// 资源安装目标：mod 装到该版本的 mods/，光影与资源包是全局目录。
    @Published var targetVersionID: String?
    /// 当前正在跑的加载器安装任务（幂等互斥用）。
    ///
    /// 为什么要这个：`installing` 标志挡不住重入 ——
    /// 第一次安装抛错时 catch 会把 `installing` 置回 false，
    /// 而 SwiftUI 的 `.task` 在 view 重建时会重跑，于是第二次又进来。
    /// 结果**两个安装流程并发**，各自推自己的进度 →
    /// 进度条在「预置依赖 8/9」和「0/9」之间交替（抽风）。
    private var installTask: Task<Void, Never>?
    /// 当前正在跑的整合包导入任务（幂等互斥用，同 installTask）。
    private var modpackTask: Task<Void, Never>?
    /// 已安装项目 key 集合（按钮显示"已安装"用）。
    @Published var installedKeys: Set<String> = []

    private let pageSize = 24

    func select(_ c: DownloadCategory, store: LauncherStore) async {
        category = c
        projects = []
        totalHits = 0
        query = ""
        status = ""
        loaderVersions = []
        selectedLoader = nil
        if mcVersion.isEmpty { mcVersion = store.manifest?.latest.release ?? "" }
        if targetVersionID == nil { targetVersionID = store.activeVersionID }
        // 资源类：按"目标版本的基础 MC 版本"筛选，而不是清单里的最新版
        if c.isResource, let vid = targetVersionID,
           let base = VersionLibrary.baseMinecraftVersion(of: vid) {
            mcVersion = base
        }

        if c.isLoader { await loadLoaderVersions(store: store) }
        if c == .modpack {
            // 整合包分类进页面就拉热门榜，跟 Mod / 光影一致
            await searchModpacks(store: store)
        }
        if c.isResource {
            refreshInstalled()
            await search(store: store)     // 空查询 = 热门榜，进页面就有内容
        }
    }

    func refreshInstalled() {
        guard let type = category.resourceType, let vid = targetVersionID else {
            installedKeys = []
            return
        }
        installedKeys = InstalledIndex.installedKeys(type: type, versionID: vid)
    }

    func setTarget(_ id: String) {
        targetVersionID = id
        if let base = VersionLibrary.baseMinecraftVersion(of: id) { mcVersion = base }
        refreshInstalled()
    }

    func isInstalled(_ project: ModrinthProject) -> Bool {
        guard let type = category.resourceType, let vid = targetVersionID else { return false }
        if installedKeys.contains(InstalledIndex.key(type: type, versionID: vid, projectID: project.project_id)) {
            return true
        }
        // 索引缺失时按文件名兜底（例如功能上线前装的）
        return InstalledIndex.matchedFile(type: type, versionID: vid,
                                          slug: project.slug, title: project.title) != nil
    }

    // MARK: 加载器

    /// 调试用：不经界面直接装某个加载器版本。
    /// 格式 `--install-loader=<kind>:<mc>:<version>`，例如
    /// `--install-loader=forge:1.20.1:47.4.28`。
    ///
    /// 为什么需要：CGEvent 模拟点击在本机无效（缺辅助功能权限），
    /// 而加载器安装的进度条是这次要验证的核心，没法手点就没法截图取证。
    func debugInstallLoader(kind: String, mc: String, version: String, store: LauncherStore) async {
        guard let cat = DownloadCategory(rawValue: kind) else { return }
        category = cat
        mcVersion = mc
        selectedLoader = version
        await installLoader(store: store)
    }

    // MARK: 整合包（在线获取）

    /// 搜索可下载的整合包（Modrinth project_type=modpack）。
    ///
    /// 整合包跟 Mod / 光影不一样：它不是「装进某个版本」的资源，
    /// 而是整套实例 —— 所以这里不做 loader / 版本过滤，
    /// 直接按下载量排序（相当于热门榜），再由用户挑。
    func searchModpacks(store: LauncherStore, append: Bool = false) async {
        // append（加载更多）时只亮 loadingMore，不亮 busy，
        // 否则会和初始加载的 `busy` 互斥、按钮点了没反应。
        if append { loadingMore = true } else { busy = true }
        if !append { status = "搜索整合包…" }
        let off = append ? projects.count : 0
        do {
            let result = try await Modrinth.search(.modpack, query: query,
                                                   mcVersion: nil, loader: nil,
                                                   offset: off, limit: pageSize)
            if append {
                // 去重：Modrinth 分页偶尔会回带上一页尾部的项目，避免卡片重复。
                let existing = Set(projects.map(\.project_id))
                projects += result.hits.filter { !existing.contains($0.project_id) }
            } else {
                projects = result.hits
            }
            totalHits = result.total
            status = result.hits.isEmpty
                ? "没有找到整合包"
                : "共 \(result.total) 个 · 已显示 \(projects.count)"
        } catch {
            status = "✖ 搜索失败：\(error.localizedDescription)"
        }
        busy = false
        loadingMore = false
    }

    // MARK: 整合包导入前确认（选 MC 版本 / 选整合包版本）

    /// 本地包：先读包内清单（只取一个条带，不解压整包），再弹确认面板。
    func prepareLocalImport(_ url: URL, store: LauncherStore) async {
        guard pendingPack == nil, !preparingPack else { return }
        preparingPack = true
        let p = await ModpackImporter.preview(of: url)
        // 通用包（HMCL / PCL / Prism 导出）没有清单，读不到 MC 版本 ——
        // 默认给当前激活实例的版本，让用户自己确认。
        let fallbackMC = store.activeMCVersion ?? store.manifest?.latest.release ?? ""
        pendingPack = PendingPack(title: p.name,
                                  kindLabel: Self.kindLabel(p.kind),
                                  declaredMC: p.declaredMC,
                                  loader: p.loader,
                                  localURL: url,
                                  targetMC: p.declaredMC.isEmpty ? fallbackMC : p.declaredMC)
        preparingPack = false
    }

    /// 在线整合包：拉出全部版本，弹确认面板 —— 版本和 MC 版本都能选。
    func prepareOnlineImport(_ project: ModrinthProject) async {
        guard pendingPack == nil, !preparingPack else { return }
        preparingPack = true
        status = "读取「\(project.title)」的版本…"
        do {
            let versions = try await Modrinth.versions(projectID: project.project_id,
                                                       mcVersion: nil, loader: nil, type: .modpack)
            guard let first = versions.first else {
                status = "✖ 这个整合包没有可用版本"
                preparingPack = false
                return
            }
            pendingPack = PendingPack(title: project.title,
                                      kindLabel: "Modrinth 整合包 (.mrpack)",
                                      declaredMC: first.game_versions.first ?? "",
                                      loader: first.loaders.joined(separator: " / "),
                                      project: project,
                                      versions: versions,
                                      versionID: first.id,
                                      targetMC: first.game_versions.first ?? "")
            status = "共 \(versions.count) 个版本可选"
        } catch {
            status = "✖ 读取版本失败：\(error.localizedDescription)"
        }
        preparingPack = false
    }

    /// 面板里切换「整合包版本」时，同步默认 MC 版本与加载器标签。
    func selectPendingVersion(_ id: String) {
        guard var p = pendingPack, let v = p.versions.first(where: { $0.id == id }) else { return }
        p.versionID = id
        p.declaredMC = v.game_versions.first ?? ""
        p.loader = v.loaders.joined(separator: " / ")
        // 原来的目标版本不在新版本的适配列表里 → 跟回新版本的默认 MC
        if p.targetMC.isEmpty || !v.game_versions.contains(p.targetMC) {
            p.targetMC = p.declaredMC
        }
        pendingPack = p
    }

    /// 确认开始导入。
    func confirmPending(store: LauncherStore) async {
        guard let p = pendingPack else { return }
        pendingPack = nil
        // 只有用户真改了才当「覆盖」传下去，否则会平白多一条「已覆盖」警告日志。
        let override: String? = {
            guard !p.targetMC.isEmpty else { return nil }
            if p.declaredMC.isEmpty { return p.targetMC }
            return p.targetMC == p.declaredMC ? nil : p.targetMC
        }()
        if let url = p.localURL {
            importingPack = true
            let ok = await store.importModpack(url, overrideMC: override)
            importingPack = false
            status = ok ? "✔ 导入完成" : "✖ 导入失败，展开底部日志查看原因"
        } else if let project = p.project,
                  let vid = p.versionID,
                  let v = p.versions.first(where: { $0.id == vid }) {
            await installModpack(project, version: v, overrideMC: override, store: store)
        }
    }

    private static func kindLabel(_ k: ModpackImporter.Kind) -> String {
        switch k {
        case .modrinth:   return "Modrinth 整合包 (.mrpack)"
        case .curseforge: return "CurseForge 整合包"
        case .generic:    return "通用实例包"
        case .unknown:    return "未知格式"
        }
    }

    /// 下载并导入一个整合包（Modrinth 上的 .mrpack）。
    /// - Parameters:
    ///   - version: 指定用哪个整合包版本；nil = 自动取最新。
    ///   - overrideMC: 用户手动选定的目标 MC 版本；nil = 跟随包内声明。
    func installModpack(_ project: ModrinthProject,
                        version: ModrinthVersion? = nil,
                        overrideMC: String? = nil,
                        store: LauncherStore) async {
        // 同 installLoader：幂等互斥，防止两个导入流程并发。
        guard modpackTask == nil else { return }
        let t = Task { @MainActor in
            await performInstallModpack(project, version: version, overrideMC: overrideMC, store: store)
        }
        modpackTask = t
        await t.value
        modpackTask = nil
    }

    private func performInstallModpack(_ project: ModrinthProject,
                                       version: ModrinthVersion?,
                                       overrideMC: String?,
                                       store: LauncherStore) async {
        guard !installing else { return }
        installing = true
        installingProject = project.project_id
        let feed = store.feed
        feed.begin("导入整合包 \(project.title)")
        status = "准备下载 \(project.title)…"
        // 统一进度管道：让「下载本体 + 导入各阶段」共用一条 relay，进度连续推进，
        // 不会在 mrpack 本体下完后焊死在「下载整合包」（之前漏传 relay 导致 import 内部
        // 所有阶段上报全是 no-op，且卡在哪完全看不见 → 看起来像卡死又不导入）。
        let relay = ProgressRelay(order: [
            (.scan, 0.02), (.extract, 0.08), (.install, 0.05),
            (.loader, 0.30), (.merge, 0.05), (.resolve, 0.10),
            (.download, 0.38), (.finish, 0.02)
        ]) { [weak feed] p in
            Task { @MainActor in feed?.apply(p) }
        }
        defer {
            installing = false
            installingProject = nil
        }
        do {
            // 用户没指定版本时取最新（不按 MC 版本过滤 —— 整合包自带版本信息）
            let picked: ModrinthVersion
            if let version {
                picked = version
            } else {
                let versions = try await Modrinth.versions(projectID: project.project_id,
                                                            mcVersion: nil, loader: nil,
                                                            type: .modpack)
                guard let v = versions.first else {
                    throw LauncherError.cannotWrite("这个整合包没有可用版本")
                }
                picked = v
            }
            feed.log("整合包版本：\(picked.name)（\(picked.version_number)）· MC \(picked.game_versions.joined(separator: "/"))")
            if let overrideMC, !overrideMC.isEmpty,
               overrideMC != picked.game_versions.first {
                feed.log("⚠ 目标 MC 版本按你的选择用 \(overrideMC)（该整合包版本声明 \(picked.game_versions.joined(separator: "/"))）")
            }
            let id = try await Modrinth.installModpack(picked, baseVersionID: store.activeVersionID,
                                                      overrideMC: overrideMC,
                                                      relay: relay,
                                                      log: { msg in
                                                          Task { @MainActor in feed.log(msg) }
                                                      })
            store.refreshInstalled()
            store.activeVersionID = id
            status = "✔ 已导入 \(project.title)，实例 \(id)"
            feed.finish(ok: true, "整合包 \(project.title) 已导入")
        } catch {
            status = "✖ 导入失败：\(error.localizedDescription)"
            feed.log("✖ 导入失败：\(error.localizedDescription)")
            feed.finish(ok: false, error.localizedDescription)
        }
    }

    /// 调试用：直接导入某个整合包项目（不用手点按钮）。
    /// 格式 `--import-modpack=<project_id>`。
    func debugImportModpack(projectID: String, store: LauncherStore) async {
        do {
            // 从搜索结果里取真实的项目信息（标题、图标等）
            let result = try await Modrinth.search(.modpack, query: "", mcVersion: nil,
                                                   loader: nil, offset: 0, limit: 1)
            if let project = result.hits.first(where: { $0.project_id == projectID }) {
                await installModpack(project, store: store)
            } else {
                // 热门榜里没有就直接构造一个最小项目
                let versions = try await Modrinth.versions(projectID: projectID, mcVersion: nil,
                                                            loader: nil, type: .modpack)
                guard let v = versions.first else {
                    status = "✖ 没有可用版本"
                    return
                }
                await installModpack(
                    ModrinthProject(project_id: projectID, slug: projectID, title: v.name,
                                    description: "", icon_url: nil, downloads: 0,
                                    categories: [], project_type: "modpack"),
                    store: store)
            }
        } catch {
            status = "✖ \(error.localizedDescription)"
        }
    }

    func loadLoaderVersions(store: LauncherStore) async {
        guard let loader = category.loader, !mcVersion.isEmpty else { return }
        busy = true
        status = "获取 \(loader.title) 版本列表…"
        let list: [String]
        switch loader {
        case .fabric:   list = await Loaders.fabricLoaderVersions(mc: mcVersion)
        case .quilt:    list = await Loaders.quiltLoaderVersions(mc: mcVersion)
        case .forge:    list = await Loaders.forgeVersions(mc: mcVersion)
        case .neoforge: list = await Loaders.neoForgeVersions(mc: mcVersion)
        case .vanilla:  list = []
        }
        loaderVersions = list
        selectedLoader = list.first
        status = list.isEmpty ? "没有找到适用于 \(mcVersion) 的版本" : "\(list.count) 个可用版本"
        busy = false
    }

    func installLoader(store: LauncherStore) async {
        // 幂等：无论 .task 重跑几次，同一时刻只能有一个安装流程。
        guard installTask == nil else { return }
        let t = Task { @MainActor in
            await performInstallLoader(store: store)
        }
        installTask = t
        await t.value
        installTask = nil
    }

    private func performInstallLoader(store: LauncherStore) async {
        guard let loader = category.loader, let version = selectedLoader, !installing else { return }
        installing = true
        let feed = store.feed
        feed.begin("安装 \(loader.title) \(version)（MC \(mcVersion)）")
        feed.log("准备安装 \(loader.title) \(version)")
        status = "准备安装 \(loader.title) \(version)…"

        // 把「加载器安装」的三子步映射成整体百分比。
        //
        // 关键：`TaskProgress.overall` 默认 -1，含义是「交给 ProgressRelay 按阶段权重换算」。
        // 但这里走的是 `feed.apply`（不经过 relay），TaskFeed 会原样保留旧值 ——
        // 旧值初始为 0，于是百分比永远停在 0%，只剩计数在跳，看着像卡死。
        // 所以**必须显式给 overall**。
        //
        do {
            if let ref = store.manifest?.versions.first(where: { $0.id == mcVersion }) {
                if !FileManager.default.fileExists(atPath: Paths.versionJSON(ref.id).path) {
                    status = "先安装原版 \(mcVersion)…"
                    feed.log("先安装原版 \(mcVersion)")
                    _ = try await VersionLibrary.installVanilla(ref) { got, total in
                        let frac = total > 0 ? Double(got) / Double(total) : 0
                        Task { @MainActor in
                            // 原版客户端占前 15%
                            feed.apply(TaskProgress(stage: .download, bytes: got,
                                                    totalBytes: max(total, 0),
                                                    detail: "原版客户端 \(self.mcVersion).jar",
                                                    overall: 0.15 * frac))
                        }
                    }
                    feed.log("原版 \(mcVersion) 就绪")
                }
            }
            let java = try await JavaManager.javaExecutable(major: javaMajor(mc: mcVersion)) { got, total in
                let frac = total > 0 ? Double(got) / Double(total) : 0
                Task { @MainActor in
                    // Java 运行时占 15%~20%
                    feed.apply(TaskProgress(stage: .download, bytes: got,
                                            totalBytes: max(total, 0), detail: "Java 运行时",
                                            overall: 0.15 + 0.05 * frac))
                }
            }
            feed.log("Java 就绪：\(java.path)")
            status = "正在安装 \(loader.title) \(version)（安装器需要一点时间）…"
            let id: String
            switch loader {
            case .fabric:
                id = try await Loaders.installFabric(mc: mcVersion, loader: version)
                feed.apply(TaskProgress(stage: .loader, detail: "Fabric 就绪", overall: 1))
            case .quilt:
                id = try await Loaders.installQuilt(mc: mcVersion, loader: version)
                feed.apply(TaskProgress(stage: .loader, detail: "Quilt 就绪", overall: 1))
            case .forge:
                // 注意：**必须用具名参数传闭包**。
                // 写成尾随闭包 `installForge(...) { s in ... }` 会被 Swift 反向匹配到
                // 最后一个参数 `progress`（编译器会警告 "backward matching of the
                // unlabeled trailing closure is deprecated"），
                // 于是 `log` 收不到闭包、`progress` 拿到类型不对的闭包 ——
                // 表现就是日志正常但进度条永远是 0%。
                id = try await Loaders.installForge(
                    mc: mcVersion, version: version, java: java,
                    log: { s in
                        Task { @MainActor in
                            feed.log(s)
                            self.status = s
                        }
                    },
                    progress: { p in
                        Task { @MainActor in
                            feed.log(p.message)
                            // 统一用 Loaders.taskOverall —— 和 onFile 那条路径同一套换算，
                            // 否则两个来源算出的值不同，进度条会来回跳。
                            let ov = Loaders.taskOverall(done: p.done, fraction: p.fraction)
                            feed.apply(TaskProgress(stage: .loader, detail: p.message,
                                                    ratio: p.ratio, overall: ov))
                            self.status = p.message
                        }
                    },
                    onFile: { f in
                        Task { @MainActor in
                            feed.log("  ↓ \(f.name)")
                            // 每个文件完成推进一次：预置依赖有几十个，
                            // 不逐个推的话中间几十秒界面一动不动。
                            let ov = Loaders.taskOverall(done: 2, fraction: f.fraction)
                            feed.apply(TaskProgress(stage: .loader,
                                                    detail: "预置依赖 \(f.done)/\(f.total) · \(f.name)",
                                                    ratio: Loaders.stageRatio(done: 2, total: 3,
                                                                            fraction: f.fraction),
                                                    overall: ov))
                        }
                    })
            case .neoforge:
                id = try await Loaders.installNeoForge(
                    mc: mcVersion, version: version, java: java,
                    log: { s in
                        Task { @MainActor in
                            feed.log(s)
                            self.status = s
                        }
                    },
                    progress: { p in
                        Task { @MainActor in
                            feed.log(p.message)
                            // 统一用 Loaders.taskOverall —— 和 onFile 那条路径同一套换算，
                            // 否则两个来源算出的值不同，进度条会来回跳。
                            let ov = Loaders.taskOverall(done: p.done, fraction: p.fraction)
                            feed.apply(TaskProgress(stage: .loader, detail: p.message,
                                                    ratio: p.ratio, overall: ov))
                            self.status = p.message
                        }
                    },
                    onFile: { f in
                        Task { @MainActor in
                            feed.log("  ↓ \(f.name)")
                            let ov = Loaders.taskOverall(done: 2, fraction: f.fraction)
                            feed.apply(TaskProgress(stage: .loader,
                                                    detail: "预置依赖 \(f.done)/\(f.total) · \(f.name)",
                                                    ratio: Loaders.stageRatio(done: 2, total: 3,
                                                                            fraction: f.fraction),
                                                    overall: ov))
                        }
                    })
            case .vanilla:
                id = mcVersion
            }
            store.noteInstalled(id)
            lastInstalled = id
            status = "✔ 已安装 \(id)，回主页即可启动"
            feed.log("✔ 已安装 \(id)")
            feed.finish(ok: true, "已安装 \(id)")
        } catch {
            status = "✖ 安装失败：\(error.localizedDescription)"
            feed.log("✖ 安装失败：\(error.localizedDescription)")
            feed.finish(ok: false, error.localizedDescription)
        }
        installing = false
    }

    private func javaMajor(mc: String) -> Int {
        if mc.hasPrefix("1.7") || mc.hasPrefix("1.8") || mc.hasPrefix("1.12") { return 8 }
        if VersionCompare.isNewerOrEqual(mc, "1.20.5") { return 21 }
        if VersionCompare.isNewerOrEqual(mc, "1.18") { return 17 }
        return 16
    }

    // MARK: 资源

    func search(store: LauncherStore, append: Bool = false) async {
        guard let type = category.resourceType else { return }
        if append { loadingMore = true } else { busy = true }
        if !append { status = query.isEmpty ? "加载热门排行…" : "搜索中…" }

        do {
            let result = try await Modrinth.search(type,
                                                  query: query.trimmingCharacters(in: .whitespaces),
                                                  mcVersion: mcVersion.isEmpty ? nil : mcVersion,
                                                  loader: store.activeLoader,
                                                  offset: append ? projects.count : 0,
                                                  limit: pageSize)
            if append {
                let existing = Set(projects.map(\.project_id))
                projects += result.hits.filter { !existing.contains($0.project_id) }
            } else {
                projects = result.hits
            }
            totalHits = result.total
            status = projects.isEmpty ? "没有结果" : "共 \(totalHits) 个 · 已显示 \(projects.count)"
        } catch {
            status = "✖ 加载失败：\(error.localizedDescription)"
        }
        busy = false
        loadingMore = false
    }

    var hasMore: Bool { projects.count < totalHits }

    func install(_ project: ModrinthProject, store: LauncherStore) async {
        guard let type = category.resourceType, !installing else { return }
        guard let vid = targetVersionID else {
            status = "先在主页选一个版本"
            return
        }
        installing = true
        installingProject = project.project_id
        let feed = store.feed
        feed.begin("安装 \(project.title)")
        feed.log("获取 \(project.title) 的文件…")
        status = "获取 \(project.title) 的文件…"
        defer {
            installing = false
            installingProject = nil
        }
        do {
            let versions = try await Modrinth.versions(projectID: project.project_id,
                                                       mcVersion: mcVersion.isEmpty ? nil : mcVersion,
                                                       loader: store.activeLoader,
                                                       type: type)
            guard let v = versions.first, let file = v.primaryFile else {
                throw LauncherError.cannotWrite("没有兼容 \(mcVersion) 的文件")
            }
            status = "下载 \(file.filename)（\(file.size / 1024) KB）…"
            feed.log("下载 \(file.filename)（\(file.size / 1024) KB）")
            let dest = try await Modrinth.install(v, type: type, versionID: vid) { got, total in
                Task { @MainActor in
                    feed.apply(TaskProgress(stage: .download, bytes: got,
                                            totalBytes: max(total, 0), detail: file.filename))
                }
            }
            InstalledIndex.record(projectID: project.project_id, title: project.title,
                                  type: type, versionID: vid, file: dest)
            refreshInstalled()
            if type == .mod { store.refreshMods() }
            status = "✔ 已安装 \(file.filename)"
            feed.finish(ok: true, "已安装 \(file.filename)")
        } catch {
            status = "✖ 安装失败：\(error.localizedDescription)"
            feed.finish(ok: false, error.localizedDescription)
        }
    }

    /// 卸载（删文件 + 清索引）。
    func uninstall(_ project: ModrinthProject, store: LauncherStore) {
        guard let type = category.resourceType, let vid = targetVersionID else { return }
        let scope = type == .mod ? vid : "-"
        let records = InstalledIndex.all().filter {
            $0.projectID == project.project_id && $0.type == type.rawValue && $0.versionID == scope
        }
        for r in records {
            try? FileManager.default.removeItem(at: type.destination(versionID: vid).appendingPathComponent(r.filename))
        }
        if records.isEmpty, let matched = InstalledIndex.matchedFile(type: type, versionID: vid,
                                                                     slug: project.slug, title: project.title) {
            try? FileManager.default.removeItem(at: matched)
        }
        InstalledIndex.remove(projectID: project.project_id, type: type, versionID: vid)
        refreshInstalled()
        if type == .mod { store.refreshMods() }
        status = "已卸载 \(project.title)"
    }
}

// MARK: - 界面

struct DownloadView: View {
    @EnvironmentObject private var store: LauncherStore
    @StateObject private var center = DownloadCenter()

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 12)]

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: Binding(get: { center.pendingPack != nil },
                                    set: { if !$0 { center.pendingPack = nil } })) {
            PackImportSheet(center: center, store: store)
        }
        .task {
            if center.mcVersion.isEmpty {
                center.mcVersion = store.manifest?.latest.release ?? store.activeMCVersion ?? "1.21.4"
            }
            var initial = DownloadCategory.vanilla
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--download=") }),
               let c = DownloadCategory(rawValue: arg.replacingOccurrences(of: "--download=", with: "")) {
                initial = c
            }
            await center.select(initial, store: store)
            // 调试用：--import-pack=<path> 启动即导入该整合包
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--import-pack=") }) {
                let path = arg.replacingOccurrences(of: "--import-pack=", with: "")
                runImport(URL(fileURLWithPath: path))
            }
            // 调试 / 深链：--version=<id> 指定 Mod 安装目标
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--version=") }) {
                let id = arg.replacingOccurrences(of: "--version=", with: "")
                if store.installed.contains(where: { $0.id == id }) { center.setTarget(id) }
            }
            // 调试用：--install-loader=<kind>:<mc>:<version> 启动即安装加载器
            // （CGEvent 点不动按钮，而加载器安装的进度条需要截图取证）
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--install-loader=") }) {
                let spec = arg.replacingOccurrences(of: "--install-loader=", with: "")
                let parts = spec.split(separator: ":").map(String.init)
                if parts.count == 3 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await center.debugInstallLoader(kind: parts[0], mc: parts[1],
                                                    version: parts[2], store: store)
                }
            }
            // 调试用：--import-modpack=<project_id> 启动即导入该整合包
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--import-modpack=") }) {
                let pid = arg.replacingOccurrences(of: "--import-modpack=", with: "")
                try? await Task.sleep(nanoseconds: 500_000_000)
                await center.debugImportModpack(projectID: pid, store: store)
            }
        }
    }

    // MARK: 左栏

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("游戏")
                ForEach([DownloadCategory.vanilla, .forge, .fabric, .neoforge, .quilt]) { c in
                    railItem(c)
                }
                sectionLabel("资源").padding(.top, 12)
                ForEach([DownloadCategory.mod, .shader, .resourcepack]) { c in
                    railItem(c)
                }
                sectionLabel("其它").padding(.top, 12)
                railItem(.modpack)
            }
            .padding(12)
        }
        .frame(width: 178)
        .glassChrome(radius: 12)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
    }

    private func railItem(_ c: DownloadCategory) -> some View {
        Button {
            Task { await center.select(c, store: store) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: c.icon)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(c.title).font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(center.category == c ? Color.accentColor.opacity(0.16) : .clear)
            )
            .foregroundStyle(center.category == c ? Color.accentColor : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 右栏

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if center.category == .vanilla {
                    vanillaPanel
                } else if center.category.isLoader {
                    loaderPanel
                } else if center.category == .modpack {
                    modpackPanel
                } else {
                    resourcePanel
                }
            }
            .padding(22)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: center.category.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(center.category.title).font(.system(size: 24, weight: .bold))
                Spacer(minLength: 0)
                if center.busy || center.installing {
                    ProgressView().controlSize(.small)
                }
            }
            if !center.status.isEmpty {
                Text(center.status)
                    .font(.caption)
                    .foregroundStyle(center.status.hasPrefix("✖") ? .red : .secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: 原版

    private var vanillaPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField("搜索版本号…", text: $center.query) {}

            let list = filteredVersions
            if list.isEmpty {
                emptyHint(store.manifest == nil ? "正在加载版本列表…" : "没有匹配的版本")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(list) { ref in
                        versionRow(ref)
                        Divider().opacity(0.4)
                    }
                }
                .glassPanel(radius: 12)
            }
        }
    }

    private var filteredVersions: [VersionManifest.VersionRef] {
        let all = store.manifest?.versions ?? []
        let q = center.query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? all : all.filter { $0.id.localizedCaseInsensitiveContains(q) }
        return Array(filtered.prefix(300))
    }

    private func versionRow(_ ref: VersionManifest.VersionRef) -> some View {
        let installed = FileManager.default.fileExists(atPath: Paths.versionJSON(ref.id).path)
        return HStack(spacing: 12) {
            Image(systemName: ref.type == "release" ? "star.fill" : (ref.type == "snapshot" ? "flask.fill" : "clock"))
                .foregroundStyle(ref.type == "release" ? .yellow : .secondary)
                .frame(width: 18)
            Text(ref.id).font(.system(.body, design: .monospaced)).fontWeight(.medium)
            Text(ref.type == "release" ? "正式版" : (ref.type == "snapshot" ? "快照" : "历史"))
                .font(.caption2)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(String(ref.releaseTime.prefix(10)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            if installed {
                Label("已安装", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("安装") {
                    Task {
                        if await store.installVanilla(ref) {
                            center.status = "✔ 已安装 \(ref.id)"
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(store.phase == .downloading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: 加载器

    private var loaderPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Minecraft 版本").font(.callout)
                Menu(center.mcVersion.isEmpty ? "选择版本" : center.mcVersion) {
                    ForEach((store.manifest?.versions ?? []).filter { $0.type == "release" }.prefix(60)) { v in
                        Button(v.id) {
                            center.mcVersion = v.id
                            Task { await center.loadLoaderVersions(store: store) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 140)
                Button {
                    Task { await center.loadLoaderVersions(store: store) }
                } label: {
                    Label("获取版本", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(center.busy)
                Spacer(minLength: 0)
            }
            .padding(14)
            .glassPanel(radius: 12)

            Text("\(center.category.title) 会装到 versions/ 下并继承 \(center.mcVersion) 的客户端与资源；Forge / NeoForge 由官方安装器执行（依赖已走镜像预置）。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if center.loaderVersions.isEmpty {
                emptyHint(center.busy ? "获取中…" : "选择版本后点「获取版本」")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(center.loaderVersions, id: \.self) { v in
                        HStack(spacing: 12) {
                            Image(systemName: center.selectedLoader == v ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(center.selectedLoader == v ? Color.accentColor : .secondary)
                            Text(v).font(.system(.body, design: .monospaced))
                            Spacer(minLength: 0)
                            if center.selectedLoader == v, center.installing {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .onTapGesture { center.selectedLoader = v }
                    }
                }
                .glassPanel(radius: 12)

                Button {
                    Task { await center.installLoader(store: store) }
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(center.installing ? "安装中…" : "安装 \(center.category.title) \(center.selectedLoader ?? "")")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(center.installing || center.selectedLoader == nil)
            }
        }
    }

    // MARK: 整合包

    private var modpackPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            // ---- 在线获取：搜索 Modrinth 的整合包 ----
            VStack(alignment: .leading, spacing: 10) {
                Label("在线获取整合包", systemImage: "square.grid.2x2.fill")
                    .font(.headline)

                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                        TextField("搜索整合包（留空显示热门排行）", text: $center.query)
                            .textFieldStyle(.plain)
                            .onSubmit { Task { await center.searchModpacks(store: store) } }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .glassPanel(radius: 10)

                    Button {
                        Task { await center.searchModpacks(store: store) }
                    } label: {
                        Text("搜索").frame(width: 44)
                    }
                    .controlSize(.large)
                    .disabled(center.busy)
                }

                if center.projects.isEmpty {
                    emptyHint(center.busy ? "加载中…" : "搜点什么，或从下面导入本地整合包")
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(center.projects) { p in
                            modpackCard(p)
                        }
                    }

                    if center.hasMore {
                        Button {
                            Task { await center.searchModpacks(store: store, append: true) }
                        } label: {
                            HStack(spacing: 6) {
                                if center.loadingMore { ProgressView().controlSize(.small) }
                                Text(center.loadingMore ? "加载中…" : "加载更多（\(center.projects.count)/\(center.totalHits)）")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .disabled(center.loadingMore)
                    }

                    Text("共 \(center.totalHits) 个整合包")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(radius: 12)

            // ---- 本地导入 ----
            VStack(alignment: .leading, spacing: 10) {
                Label("从本地导入", systemImage: "shippingbox.fill")
                    .font(.headline)
                Text("支持 CurseForge 的 manifest 整合包、Modrinth 的 .mrpack、带 mods/config 的通用压缩包，以及 HMCL / PCL / Prism 导出的实例文件夹。导入会新建一个独立实例，不会污染现有版本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        pickModpack()
                    } label: {
                        Label("选择整合包文件…", systemImage: "folder.badge.plus")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.phase == .downloading)

                    Button {
                        pickModpackFolder()
                    } label: {
                        Label("选择实例文件夹…", systemImage: "folder")
                    }
                    .controlSize(.large)
                    .disabled(store.phase == .downloading)

                    if store.phase == .downloading {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }

                Label("三种格式都能自动装：Modrinth 的 .mrpack、CurseForge 的 manifest 包（自动查文件名并下载）、以及带 mods/config 的通用压缩包。",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(radius: 12)

            if store.phase == .downloading {
                ProgressView(value: store.progress) {
                    Text(store.statusText).font(.caption).lineLimit(1)
                }
                .progressViewStyle(.linear)
            }

            if center.importingPack || store.feed.isActive {
                importLogPanel
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("已导入的实例").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(store.installed.filter { $0.id.hasPrefix("pack-") }) { v in
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.orange).font(.caption)
                        Text(v.id).font(.system(.caption, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("启动") {
                            store.activeVersionID = v.id
                            Task { await store.launch(versionID: v.id) }
                        }
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassPanel(radius: 8)
                }
            }
        }
    }

    /// 整合包卡片：与 Mod 卡片不同 —— 装的是整套实例，所以按钮是「导入」。
    private func modpackCard(_ p: ModrinthProject) -> some View {
        let busy = center.installingProject == p.project_id
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: p.icon_url.flatMap(URL.init)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                        .overlay(Image(systemName: "shippingbox.fill")
                            .font(.caption).foregroundStyle(.tertiary))
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(formatCount(p.downloads)) 次下载")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            Text(p.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text(p.project_type)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    Task { await center.prepareOnlineImport(p) }
                } label: {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("导入").frame(width: 44)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(center.installing || store.phase == .downloading)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 12)
    }

    /// 整合包导入日志：与底部任务条同源（store.feed），这里给一块更大的阅读区域。
    private var importLogPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("实时进度")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !store.feed.snap.done {
                    ProgressView().controlSize(.mini)
                }
                Text(store.feed.snap.stage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !store.feed.snap.counter.isEmpty {
                    Text(store.feed.snap.counter)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text(store.feed.snap.detail.isEmpty ? "" : store.feed.snap.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("清空") { store.feed.clearLog() }
                    .controlSize(.mini)
                    .disabled(!store.feed.snap.done)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.feed.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(colorFor(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 160)
                .background(Color.black.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: store.feed.lines.count) { _, newValue in
                    guard newValue > 0 else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newValue - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func colorFor(_ line: String) -> Color {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("✖") { return .red }
        if t.hasPrefix("⚠") { return .orange }
        if t.hasPrefix("✔") { return .green }
        if t.hasPrefix("↻") { return .yellow }
        if t.hasPrefix("▶") { return .primary }
        return .secondary
    }

    private func pickModpack() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .archive]
        panel.message = "选择整合包（.mrpack / .zip）"
        if panel.runModal() == .OK, let url = panel.url {
            runImport(url)
        }
    }

    private func pickModpackFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择整合包实例文件夹（含 mods / config）"
        if panel.runModal() == .OK, let url = panel.url {
            runImport(url)
        }
    }

    /// 跑导入，并把每一步日志实时回显到底部任务条 + 本页日志面板。
    /// 先弹设置面板（选 MC 版本 / 整合包版本），确认后才真正开始。
    private func runImport(_ url: URL) {
        Task { await center.prepareLocalImport(url, store: store) }
    }

    // MARK: 资源（Mod / 光影 / 资源包）

    private var resourcePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if center.category == .mod {
                    Text("装到").font(.caption).foregroundStyle(.secondary)
                    Menu(center.targetVersionID ?? "选择版本") {
                        ForEach(store.installed) { v in
                            Button("\(v.id) · \(v.loader.title)") { center.setTarget(v.id) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 240)
                } else {
                    Label(center.category == .shader ? "装到 shaderpacks/" : "装到 resourcepacks/",
                          systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text("MC \(center.mcVersion.isEmpty ? "-" : center.mcVersion)")
                    .font(.caption).foregroundStyle(.tertiary)
                if center.category == .mod {
                    Text("· \(store.activeLoader.title)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text("已安装 \(center.installedKeys.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(center.installedKeys.isEmpty ? Color.secondary : Color.green)
            }

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("搜索 \(center.category.title)（留空显示热门排行）", text: $center.query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await center.search(store: store) } }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassPanel(radius: 10)

                Button {
                    Task { await center.search(store: store) }
                } label: {
                    Text("搜索").frame(width: 44)
                }
                .controlSize(.large)
                .disabled(center.busy)
            }

            if center.projects.isEmpty {
                emptyHint(center.busy ? "加载中…" : "没有结果")
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(center.projects) { p in
                        projectCard(p)
                    }
                }

                if center.hasMore {
                    Button {
                        Task { await center.search(store: store, append: true) }
                    } label: {
                        HStack(spacing: 6) {
                            if center.loadingMore { ProgressView().controlSize(.small) }
                            Text(center.loadingMore ? "加载中…" : "加载更多（\(center.projects.count)/\(center.totalHits)）")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .disabled(center.loadingMore)
                }
            }
        }
    }

    private func projectCard(_ p: ModrinthProject) -> some View {
        let installed = center.isInstalled(p)
        let downloading = center.installingProject == p.project_id

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: p.icon_url.flatMap(URL.init)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                        .overlay(Image(systemName: center.category.icon)
                            .font(.caption).foregroundStyle(.tertiary))
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(formatCount(p.downloads)) 次下载")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if installed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("已安装")
                }
            }

            Text(p.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                ForEach(p.categories.prefix(2), id: \.self) { c in
                    Text(c)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.13)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                if installed {
                    Button {
                        center.uninstall(p, store: store)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("卸载")
                }

                Button {
                    Task { await center.install(p, store: store) }
                } label: {
                    HStack(spacing: 5) {
                        if downloading {
                            ProgressView().controlSize(.mini)
                            Text("下载中")
                        } else if installed {
                            Image(systemName: "arrow.clockwise")
                            Text("重装")
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("下载")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(installed ? Color.green : Color.accentColor)
                .disabled(center.installing)
            }
        }
        // 强制置顶：卡片外层 overlay 叠在上面会吃掉按钮点击。
        .onTop()
        .padding(12)
        .frame(minHeight: 128)
        .glassPanel(radius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(installed ? Color.green.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: 小工具

    private func searchField(_ placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassPanel(radius: 10)
    }

    private func emptyHint(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 36)
        .glassPanel(radius: 12)
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - 整合包导入设置面板

/// 导入前让用户确认「目标 MC 版本」，在线整合包还能选具体版本。
///
/// 为什么需要：整合包清单里声明的 MC 版本不一定是你想装的那个
/// （比如想把只有 1.20.1 版的包挂到 1.20.4 上），而加载器核心是按 MC 版本装的，
/// 所以必须在导入前把版本定下来。
struct PackImportSheet: View {
    @ObservedObject var center: DownloadCenter
    var store: LauncherStore

    var body: some View {
        Group {
            if let p = center.pendingPack {
                content(p)
            } else {
                ProgressView().frame(width: 520, height: 200)
            }
        }
    }

    private func content(_ p: DownloadCenter.PendingPack) -> some View {
        let releases = (store.manifest?.versions ?? [])
            .filter { $0.type == "release" }
            .map(\.id)
        let choices = releases.filter { $0 != p.declaredMC && $0 != p.targetMC }
        let changed = !p.declaredMC.isEmpty && p.targetMC != p.declaredMC

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("导入整合包").font(.system(size: 17, weight: .semibold))
                    Text(p.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                chip(p.kindLabel)
                if !p.loader.isEmpty { chip(p.loader) }
                if !p.declaredMC.isEmpty { chip("包内声明 MC \(p.declaredMC)") }
                Spacer(minLength: 0)
            }

            Divider().opacity(0.5)

            if !p.versions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("整合包版本")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { p.versionID ?? "" },
                        set: { center.selectPendingVersion($0) })) {
                        ForEach(p.versions, id: \.id) { v in
                            Text("\(v.version_number) · MC \(v.game_versions.joined(separator: "/"))"
                                 + (v.loaders.isEmpty ? "" : " · \(v.loaders.joined(separator: "/"))"))
                                .tag(v.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("选旧版本可以避开新版包里的兼容问题。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("目标 MC 版本")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { p.targetMC },
                    set: { newValue in
                        guard var cur = center.pendingPack else { return }
                        cur.targetMC = newValue
                        center.pendingPack = cur
                    })) {
                    if !p.declaredMC.isEmpty {
                        Text("跟随包内声明（\(p.declaredMC)）").tag(p.declaredMC)
                    }
                    ForEach(choices, id: \.self) { v in
                        Text(v).tag(v)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(hintText(p, changed: changed))
                    .font(.caption2)
                    .foregroundStyle(changed ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Text("原版核心与加载器会装到 meta/versions，实例放 profiles/。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("取消") { center.pendingPack = nil }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await center.confirmPending(store: store) }
                } label: {
                    Text("开始导入").frame(width: 76)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(p.targetMC.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func hintText(_ p: DownloadCenter.PendingPack, changed: Bool) -> String {
        if p.declaredMC.isEmpty {
            return "这个包没声明 MC 版本，请指定一个目标版本（决定装哪个原版核心与加载器）。"
        }
        if changed {
            return "⚠ 已覆盖为 \(p.targetMC)：核心与加载器按 \(p.targetMC) 安装，包里的 mod 仍按原样落盘 —— 版本不匹配时游戏可能起不来。"
        }
        return "核心、加载器都按包内声明的 \(p.targetMC) 安装。"
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
            .foregroundStyle(.secondary)
    }
}
