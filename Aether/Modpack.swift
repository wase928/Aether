//
//  Modpack.swift
//  maccraft
//
//  整合包导入。
//
//  支持：
//   · .mrpack（Modrinth）：解析 modrinth.index.json，按 dependencies 自动装原版 + 加载器，
//     再逐个下载 files（带 sha1 校验），最后铺 overrides / client-overrides。
//   · 通用压缩包 / 文件夹（HMCL、PCL、MultiMC/Prism 导出的实例、手搓的 .minecraft）：
//     识别根目录（或 .minecraft/ 下）的 mods、config、resourcepacks、shaderpacks 等，
//     建一个继承目标版本的新实例并整目录复制。
//   · CurseForge 整合包：manifest.json 里只有 projectID/fileID，需要先把文件名查出来
//     （参见 CurseForge.swift —— 走免 key 的 mcimirror 反向代理，不需要 API Key）。
//
//  性能（实测 339MB / 375MB 解压后 / 1325 文件）：
//   · 以前：unzip -q 到临时目录（3.1s）→ 递归 copyItem 到版本目录（2.4s）≈ 5.5s
//   · 现在：ditto -x -k 到临时目录（1.1s）→ ditto clone 合并（0.25s）≈ 1.4s
//   每个阶段都会往 TaskFeed 上报进度（文件数 + 字节 + 当前文件），不再只有转圈。
//

import Foundation

/// 导入过程的上下文：进度管道 + 日志。
nonisolated struct ImportContext: Sendable {
    let relay: ProgressRelay?
    let log: @Sendable (String) -> Void
    /// 导入开始的时刻，用于给每行日志打上耗时标记（定位哪一步慢）。
    let startedAt: Date

    init(relay: ProgressRelay?, log: @escaping @Sendable (String) -> Void) {
        self.relay = relay
        self.log = log
        self.startedAt = Date()
    }

    /// 相对导入开始的耗时（秒，1 位小数），用于日志里定位慢步骤。
    nonisolated static func stamp(_ ctx: ImportContext) -> String {
        String(format: "%.1f", Date().timeIntervalSince(ctx.startedAt))
    }

    func report(_ stage: TaskProgress.Stage,
                current: Int = 0,
                total: Int = 0,
                detail: String = "",
                bytes: Int64 = 0,
                totalBytes: Int64 = 0,
                speed: Double = 0,
                ratio: Double = -1,
                force: Bool = false) {
        guard let relay else { return }
        relay.send(TaskProgress(stage: stage, current: current, total: total,
                                bytes: bytes, totalBytes: totalBytes,
                                detail: detail, speed: speed, ratio: ratio),
                   force: force)
    }}

nonisolated enum ModpackImporter {
    struct ImportResult: Sendable {
        let versionID: String
        let name: String
        let fileCount: Int
        let failed: Int
        var elapsed: TimeInterval = 0
    }

    enum Kind: String {
        case modrinth   // .mrpack
        case curseforge // manifest.json + files[projectID/fileID]
        case generic    // 带 mods/config 的通用包
        case unknown
    }

    // MARK: - 识别

    static func detect(_ url: URL) -> Kind {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .unknown }
        if isDir.boolValue {
            return hasInstanceDirs(url) ? .generic : .unknown
        }
        guard let entries = ZipTool.entries(of: url) else { return .unknown }
        if entries.contains("modrinth.index.json") { return .modrinth }
        if entries.contains("manifest.json") { return .curseforge }
        if entries.contains(where: { $0.hasPrefix("mods/") || $0.hasPrefix("config/") || $0.hasPrefix(".minecraft/") }) {
            return .generic
        }
        return .unknown
    }

    private static func hasInstanceDirs(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let candidates = ["mods", "config", "resourcepacks", "shaderpacks", ".minecraft", "versions"]
        return candidates.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    // MARK: - 导入入口

    static func `import`(_ url: URL,
                         baseVersionID: String?,
                         relay: ProgressRelay? = nil,
                         log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ImportResult {
        let started = Date()
        let ctx = ImportContext(relay: relay, log: log)

        ctx.report(.scan, current: 0, total: 1, detail: "识别格式…", force: true)
        let kind = detect(url)
        log("识别为 \(kindLabel(kind))：\(url.lastPathComponent)")
        ctx.report(.scan, current: 1, total: 1, detail: kindLabel(kind), force: true)

        var result: ImportResult
        switch kind {
        case .modrinth:   result = try await importMrpack(url, ctx: ctx)
        case .generic:    result = try await importGeneric(url, baseVersionID: baseVersionID, ctx: ctx)
        case .curseforge: result = try await importCurseForge(url, ctx: ctx)
        case .unknown:
            throw LauncherError.cannotWrite("无法识别这个整合包格式（支持 .mrpack、带 mods/config 的压缩包或实例文件夹）")
        }
        result.elapsed = Date().timeIntervalSince(started)
        // 记住源文件 → 实例的映射：下次导入同一个文件会复用同一个实例目录，
        // 不会每次都新建一份 1GB 的重复实例。
        PackIndex.record(source: url, versionID: result.versionID, title: result.name)
        ctx.report(.finish, current: 1, total: 1,
                   detail: "导入完成，用时 \(String(format: "%.1f", result.elapsed))s", force: true)
        return result
    }

    private static func kindLabel(_ k: Kind) -> String {
        switch k {
        case .modrinth:   return "Modrinth 整合包 (.mrpack)"
        case .curseforge: return "CurseForge 整合包"
        case .generic:    return "通用实例包"
        case .unknown:    return "未知格式"
        }
    }

    // MARK: - Modrinth (.mrpack)

    private struct MrpackIndex: Decodable {
        struct File: Decodable {
            let path: String
            let hashes: [String: String]?
            let downloads: [String]
            let env: [String: String]?
        }
        let name: String
        let versionId: String?
        let files: [File]
        let dependencies: [String: String]
    }

    private static func importMrpack(_ url: URL, ctx: ImportContext) async throws -> ImportResult {
        let temp = try await unzip(url, ctx: ctx)

        let indexURL = temp.appendingPathComponent("modrinth.index.json")
        let index = try JSONDecoder().decode(MrpackIndex.self, from: Data(contentsOf: indexURL))
        let mc = index.dependencies["minecraft"] ?? ""
        ctx.log("[+\(ImportContext.stamp(ctx))s] Modrinth 整合包「\(index.name)」· MC \(mc) · \(index.files.count) 个待下载文件")

        // 1) 加载器
        let loaderID: String
        if let fabric = index.dependencies["fabric-loader"] {
            ctx.log("安装 Fabric \(fabric)（MC \(mc)）…")
            try await ensureVanilla(mc, ctx: ctx)
            ctx.report(.loader, current: 1, total: 3, detail: "安装 Fabric \(fabric)", ratio: 0, force: true)
            loaderID = try await Loaders.installFabric(mc: mc, loader: fabric)
            ctx.report(.loader, current: 3, total: 3, detail: "Fabric \(fabric) 就绪", ratio: 1, force: true)
        } else if let quilt = index.dependencies["quilt-loader"] {
            ctx.log("安装 Quilt \(quilt)（MC \(mc)）…")
            try await ensureVanilla(mc, ctx: ctx)
            ctx.report(.loader, current: 1, total: 3, detail: "安装 Quilt \(quilt)", ratio: 0, force: true)
            loaderID = try await Loaders.installQuilt(mc: mc, loader: quilt)
            ctx.report(.loader, current: 3, total: 3, detail: "Quilt \(quilt) 就绪", ratio: 1, force: true)
        } else if let forge = index.dependencies["forge"] {
            ctx.log("安装 Forge \(forge)（MC \(mc)）…")
            try await ensureVanilla(mc, ctx: ctx)
            ctx.report(.loader, current: 1, total: 3, detail: "安装 Forge \(forge)", ratio: 0, force: true)
            let java = try await JavaManager.javaExecutable(major: javaMajor(mc: mc)) { got, total in
                ctx.report(.download, detail: "Java 运行时", bytes: got, totalBytes: max(total, 0))
            }
            loaderID = try await Loaders.installForge(
                mc: mc, version: forge, java: java,
                log: ctx.log,
                progress: { p in
                    ctx.report(.loader, current: p.done, total: max(p.total, 1),
                               detail: p.message, ratio: p.ratio, force: true)
                },
                onFile: { f in
                    ctx.log("  ↓ \(f.name)")
                    // 与 progress 那条路径用同一套换算，否则两个来源的值不同 → 进度条抽风
                    ctx.report(.loader, detail: "预置依赖 \(f.done)/\(f.total) · \(f.name)",
                               ratio: Loaders.stageRatio(done: 2, total: 3, fraction: f.fraction),
                               force: true)
                })
            ctx.report(.loader, current: 3, total: 3, detail: "Forge \(forge) 就绪", ratio: 1, force: true)
        } else if let neo = index.dependencies["neoforge"] {
            ctx.log("安装 NeoForge \(neo)（MC \(mc)）…")
            try await ensureVanilla(mc, ctx: ctx)
            ctx.report(.loader, current: 1, total: 3, detail: "安装 NeoForge \(neo)", ratio: 0, force: true)
            let java = try await JavaManager.javaExecutable(major: javaMajor(mc: mc)) { got, total in
                ctx.report(.download, detail: "Java 运行时", bytes: got, totalBytes: max(total, 0))
            }
            loaderID = try await Loaders.installNeoForge(
                mc: mc, version: neo, java: java,
                log: ctx.log,
                progress: { p in
                    ctx.report(.loader, current: p.done, total: max(p.total, 1),
                               detail: p.message, ratio: p.ratio, force: true)
                },
                onFile: { f in
                    ctx.log("  ↓ \(f.name)")
                    // 与 progress 那条路径用同一套换算，否则两个来源的值不同 → 进度条抽风
                    ctx.report(.loader, detail: "预置依赖 \(f.done)/\(f.total) · \(f.name)",
                               ratio: Loaders.stageRatio(done: 2, total: 3, fraction: f.fraction),
                               force: true)
                })
            ctx.report(.loader, current: 3, total: 3, detail: "NeoForge \(neo) 就绪", ratio: 1, force: true)
        } else {
            ctx.log("整合包没声明加载器，按原版处理")
            ctx.report(.install, current: 0, total: 1, detail: "安装原版 \(mc)", force: true)
            try await ensureVanilla(mc, ctx: ctx)
            loaderID = mc
            ctx.report(.install, current: 1, total: 1, detail: "原版 \(mc) 就绪", force: true)
        }

        // 2) 建实例（继承加载器版本，文件放自己的版本目录）
        //    同一个源文件重复导入时复用原实例目录，避免攒出一堆 1GB 的重复实例。
        let reused = reusablePackID(for: url)
        let packID = reused ?? uniquePackID(from: index.name)
        try writeInstance(id: packID, inheritsFrom: loaderID)
        if reused != nil {
            ctx.log("[+\(ImportContext.stamp(ctx))s] 更新已有实例 \(packID)（与上次导入的是同一个文件）")
        } else {
            ctx.log("[+\(ImportContext.stamp(ctx))s] 创建实例 \(packID)")
        }

        // 3) 先铺 overrides（mrpack 规范：files 里的文件优先级更高，会覆盖同名项）
        //    顺序：overrides → client-overrides（后者覆盖前者）
        for dir in ["overrides", "client-overrides"] {
            let src = temp.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let (files, bytes) = ZipTool.measure(src)
            ctx.log("[+\(ImportContext.stamp(ctx))s] 铺开 \(dir)/（\(files) 个文件，\(DownloadManager.mb(bytes)) MB）")
            try await merge(src, into: Paths.versionDir(packID), label: dir,
                          isLoaderInstance: isLoaderInstance(loaderID), ctx: ctx)
        }

        // 4) 下载 files
        var items: [DownloadItem] = []
        for f in index.files {
            if f.env?["client"] == "unsupported" { continue }
            guard let first = f.downloads.first, let primary = URL(string: first) else { continue }
            let dest = Paths.versionDir(packID).appendingPathComponent(f.path)
            var candidates: [MirrorCandidate] = []
            if let mirror = URL(string: first.replacingOccurrences(of: "https://cdn.modrinth.com",
                                                                   with: "https://mod.mcimirror.top")) {
                candidates.append(MirrorCandidate(source: "mcimirror", url: mirror))
            }
            candidates.append(MirrorCandidate(source: "modrinth", url: primary))
            items.append(DownloadItem(urls: candidates, destination: dest,
                                      sha1: f.hashes?["sha1"], kind: .other))
        }
        var failed = 0
        if !items.isEmpty {
            ctx.log("[+\(ImportContext.stamp(ctx))s] 下载 \(items.count) 个文件…")
            ctx.report(.download, current: 0, total: items.count, detail: "准备下载 \(items.count) 个文件", force: true)
            let counter = ProgressCounter(total: items.count)
            let mon = ProgressRelay.report(counter, to: ctx, label: "下载文件")
            try await DownloadManager.downloadMany(items, counter: counter, maxConcurrent: 8,
                                                   tolerateFailures: true,
                                                   onFallback: { m in ctx.log(m) },
                                                   onFile: { name, ok in
                                                       ctx.log(ok ? "  ↓ \(name)" : "  ✖ \(name)")
                                                   })
            mon.cancel()
            // 校验：没落盘的文件算失败（sha1 不符的文件会被删掉）
            let missing = items.filter { !FileManager.default.fileExists(atPath: $0.destination.path) }
            failed = missing.count
            if failed > 0 {
                ctx.log("⚠ \(failed) 个文件下载失败：")
                for m in missing.prefix(5) { ctx.log("   · \(m.destination.lastPathComponent)") }
            }
        }

        ctx.log("✔ 整合包「\(index.name)」导入完成")
        return ImportResult(versionID: packID, name: index.name,
                            fileCount: items.count, failed: failed)
    }

    // MARK: - CurseForge

    private struct CurseManifest: Decodable {
        struct Minecraft: Decodable {
            struct ModLoader: Decodable {
                let id: String
                let primary: Bool?
            }
            let version: String
            let modLoaders: [ModLoader]?
        }
        struct File: Decodable {
            let projectID: Int
            let fileID: Int
            let required: Bool?
        }
        let minecraft: Minecraft
        let name: String
        let version: String?
        let author: String?
        let files: [File]
        let overrides: String?
    }

    private static func importCurseForge(_ url: URL, ctx: ImportContext) async throws -> ImportResult {
        let temp = try await unzip(url, ctx: ctx)

        // manifest.json 可能在根目录，也可能在包一层目录里
        var manifestURL = temp.appendingPathComponent("manifest.json")
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            if let subs = try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.isDirectoryKey]) {
                for sub in subs {
                    let candidate = sub.appendingPathComponent("manifest.json")
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        manifestURL = candidate
                        break
                    }
                }
            }
        }
        let manifest = try JSONDecoder().decode(CurseManifest.self, from: Data(contentsOf: manifestURL))
        let mc = manifest.minecraft.version
        ctx.log("CurseForge 整合包「\(manifest.name)」· MC \(mc) · \(manifest.files.count) 个文件")

        // 1) 加载器：modLoaders 里 primary 的那个，形如 "forge-47.2.0" / "fabric-0.15.0"
        let loaderRaw = manifest.minecraft.modLoaders?.first(where: { $0.primary == true })?.id
            ?? manifest.minecraft.modLoaders?.first?.id
        let loaderID: String
        if let raw = loaderRaw, let dash = raw.firstIndex(of: "-") {
            let kind = String(raw[raw.startIndex..<dash]).lowercased()
            let ver = String(raw[raw.index(after: dash)...])
            ctx.log("加载器：\(kind) \(ver)")
            try await ensureVanilla(mc, ctx: ctx)
            ctx.report(.loader, current: 1, total: 3, detail: "安装 \(kind) \(ver)", ratio: 0, force: true)
            switch kind {
            case "forge":
                let java = try await JavaManager.javaExecutable(major: javaMajor(mc: mc)) { got, total in
                    ctx.report(.download, detail: "Java 运行时", bytes: got, totalBytes: max(total, 0))
                }
                loaderID = try await Loaders.installForge(
                    mc: mc, version: ver, java: java,
                    log: ctx.log,
                    progress: { p in
                        ctx.report(.loader, current: p.done, total: max(p.total, 1),
                                   detail: p.message, ratio: p.ratio, force: true)
                    },
                    onFile: { f in
                        ctx.log("  ↓ \(f.name)")
                        ctx.report(.loader, detail: "预置依赖 \(f.done)/\(f.total) · \(f.name)",
                                   ratio: Loaders.stageRatio(done: 2, total: 3, fraction: f.fraction),
                                   force: true)
                    })
            case "neoforge":
                let java = try await JavaManager.javaExecutable(major: javaMajor(mc: mc)) { got, total in
                    ctx.report(.download, detail: "Java 运行时", bytes: got, totalBytes: max(total, 0))
                }
                loaderID = try await Loaders.installNeoForge(
                    mc: mc, version: ver, java: java,
                    log: ctx.log,
                    progress: { p in
                        ctx.report(.loader, current: p.done, total: max(p.total, 1),
                                   detail: p.message, ratio: p.ratio, force: true)
                    },
                    onFile: { f in
                        ctx.log("  ↓ \(f.name)")
                        ctx.report(.loader, detail: "预置依赖 \(f.done)/\(f.total) · \(f.name)",
                                   ratio: Loaders.stageRatio(done: 2, total: 3, fraction: f.fraction),
                                   force: true)
                    })
            case "fabric":
                loaderID = try await Loaders.installFabric(mc: mc, loader: ver)
            case "quilt":
                loaderID = try await Loaders.installQuilt(mc: mc, loader: ver)
            default:
                ctx.log("⚠ 不认识的加载器 \(kind)，按原版处理")
                loaderID = mc
            }
            ctx.report(.loader, current: 3, total: 3, detail: "\(kind) \(ver) 就绪", ratio: 1, force: true)
        } else {
            ctx.log("整合包没声明加载器，按原版处理")
            ctx.report(.install, current: 0, total: 1, detail: "安装原版 \(mc)", force: true)
            try await ensureVanilla(mc, ctx: ctx)
            loaderID = mc
            ctx.report(.install, current: 1, total: 1, detail: "原版 \(mc) 就绪", force: true)
        }

        // 2) 建实例
        let reused = reusablePackID(for: url)
        let packID = reused ?? uniquePackID(from: manifest.name)
        try writeInstance(id: packID, inheritsFrom: loaderID)
        if reused != nil {
            ctx.log("[+\(ImportContext.stamp(ctx))s] 更新已有实例 \(packID)（与上次导入的是同一个文件）")
        } else {
            ctx.log("[+\(ImportContext.stamp(ctx))s] 创建实例 \(packID)")
        }

        // 3) 查询文件名（manifest 里只有 ID，必须补全）
        let wanted = manifest.files.filter { $0.required != false }
        let pairs = wanted.map { (modID: $0.projectID, fileID: $0.fileID) }
        ctx.log("查询 \(pairs.count) 个文件的下载信息…")
        let infos = await CurseForge.fileInfos(pairs) { done, total in
            ctx.report(.resolve, current: done, total: total,
                       detail: "查询 CurseForge 文件信息", force: done % 10 == 0)
            if done % 10 == 0 || done == total {
                ctx.log("  已查询 \(done)/\(total)")
            }
        }
        ctx.log("  查到 \(infos.count)/\(pairs.count) 个")

        // 3.5) 先铺 overrides（files 里下载的 mod 优先级更高）
        let overridesName0 = manifest.overrides ?? "overrides"
        let overridesSrc = manifestURL.deletingLastPathComponent().appendingPathComponent(overridesName0)
        if FileManager.default.fileExists(atPath: overridesSrc.path) {
            let (files, bytes) = ZipTool.measure(overridesSrc)
            ctx.log("铺开 \(overridesName0)/（\(files) 个文件，\(DownloadManager.mb(bytes)) MB）")
            try await merge(overridesSrc, into: Paths.versionDir(packID), label: overridesName0,
                          isLoaderInstance: isLoaderInstance(loaderID), ctx: ctx)
        }

        // 4) 下载到 mods/
        let modsDir = Paths.versionDir(packID).appendingPathComponent("mods", isDirectory: true)
        try Paths.ensure(modsDir)
        var items: [DownloadItem] = []
        var unresolved: [CurseManifest.File] = []
        for f in wanted {
            guard let info = infos[f.fileID] else {
                unresolved.append(f)
                continue
            }
            let dest = modsDir.appendingPathComponent(info.fileName)
            items.append(DownloadItem(urls: [MirrorCandidate(source: "forgecdn", url: info.downloadURL)],
                                      destination: dest, sha1: info.sha1,
                                      size: info.size, kind: .other))
        }
        if !unresolved.isEmpty {
            ctx.log("⚠ \(unresolved.count) 个文件查不到（可能已被作者删除）")
            for f in unresolved.prefix(5) {
                ctx.log("   · project \(f.projectID) / file \(f.fileID)")
            }
        }

        var failed = 0
        if !items.isEmpty {
            let totalBytes = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            ctx.log("下载 \(items.count) 个 mod（约 \(DownloadManager.mb(totalBytes)) MB）…")
            let counter = ProgressCounter(total: items.count, totalBytes: totalBytes)
            let mon = ProgressRelay.report(counter, to: ctx, label: "下载 Mod")
            try await DownloadManager.downloadMany(items, counter: counter, maxConcurrent: 8,
                                                   tolerateFailures: true,
                                                   onFallback: { m in ctx.log(m) },
                                                   onFile: { name, ok in
                                                       ctx.log(ok ? "  ↓ \(name)" : "  ✖ \(name)")
                                                   })
            mon.cancel()
            let missing = items.filter { !FileManager.default.fileExists(atPath: $0.destination.path) }
            failed = missing.count
            if failed > 0 {
                ctx.log("⚠ \(failed) 个文件下载失败：")
                for m in missing.prefix(5) { ctx.log("   · \(m.destination.lastPathComponent)") }
            }
        }

        ctx.log("✔ 整合包「\(manifest.name)」导入完成")
        return ImportResult(versionID: packID, name: manifest.name,
                            fileCount: items.count, failed: failed + unresolved.count)
    }

    // MARK: - 通用包

    private static let keepDirs: [String] = [
        "mods", "config", "defaultconfigs", "resourcepacks", "shaderpacks",
        "datapacks", "scripts", "saves", "local", "schematics"
    ]
    private static let keepFiles: [String] = ["options.txt", "servers.dat", "optionsshaders.txt"]

    private static func importGeneric(_ url: URL,
                                      baseVersionID: String?,
                                      ctx: ImportContext) async throws -> ImportResult {
        let fm = FileManager.default
        var root = url
        var temp: URL?
        if !url.hasDirectoryPath && url.pathExtension.lowercased() == "zip" {
            // 只解压需要的那几个目录：通用包里常带 versions/ 下的客户端 jar、saves、
            // 甚至内置 JRE，全量解压纯属浪费。这里按条目表判断前缀，只取 mods/config 等。
            let prefix = try detectPrefix(of: url)
            let patterns = (keepDirs + keepFiles).map { prefix + $0 }
            let expected = countMatchingFiles(in: url, prefix: prefix)
            let dir = try await extractSelected(url, to: nil, including: patterns,
                                                expectedFiles: expected, ctx: ctx)
            temp = dir
            root = dir
        }
        defer { if let temp { try? fm.removeItem(at: temp) } }

        // 常见布局：根目录 / .minecraft / 单个包一层目录
        var contentRoot = root
        if fm.fileExists(atPath: root.appendingPathComponent(".minecraft").path) {
            contentRoot = root.appendingPathComponent(".minecraft")
        } else if !hasInstanceDirs(root) {
            if let subs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]),
               let only = subs.first(where: { $0.hasDirectoryPath && hasInstanceDirs($0) }) {
                contentRoot = only
            }
        }
        guard hasInstanceDirs(contentRoot) else {
            throw LauncherError.cannotWrite("压缩包里没找到 mods / config 等实例目录")
        }

        let baseID = baseVersionID ?? "1.21.4"
        let reused = reusablePackID(for: url)
        let packID = reused ?? uniquePackID(from: url.deletingPathExtension().lastPathComponent)
        try writeInstance(id: packID, inheritsFrom: baseID)
        if reused != nil {
            ctx.log("更新已有实例 \(packID)（与上次导入的是同一个来源）")
        } else {
            ctx.log("创建实例 \(packID)（继承 \(baseID)）")
        }

        if fm.fileExists(atPath: contentRoot.appendingPathComponent("versions").path) {
            ctx.log("检测到启动器目录结构，只导入公共资源目录")
        }

        // 合并：目录用 ditto clone（同卷几乎不耗 IO），逐个顶层项上报进度
        let present = (keepDirs + keepFiles).filter {
            fm.fileExists(atPath: contentRoot.appendingPathComponent($0).path)
        }
        for (idx, name) in present.enumerated() {
            let src = contentRoot.appendingPathComponent(name)
            let dst = Paths.versionDir(packID).appendingPathComponent(name)
            try await ZipTool.merge(src, into: dst) { item, _, _ in
                ctx.report(.merge, current: idx, total: present.count,
                           detail: "写入 \(name)/\(item)")
            }
            ctx.report(.merge, current: idx + 1, total: present.count,
                       detail: "写入 \(name)", force: true)
        }
        ctx.log("✔ 导入 \(present.count) 个目录：" + present.joined(separator: "、"))

        return ImportResult(versionID: packID, name: url.deletingPathExtension().lastPathComponent,
                            fileCount: present.count, failed: 0)
    }

    // MARK: - 解压 / 合并

    /// 全量解压到临时目录（ditto，最快），并把解压进度喂给进度条。
    private static func unzip(_ url: URL, ctx: ImportContext) async throws -> URL {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let expected = ZipTool.fileEntries(of: url).count
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let archiveBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        ctx.log("解压中…（压缩包 \(DownloadManager.mb(archiveBytes)) MB，\(expected) 个文件）")
        ctx.report(.extract, current: 0, total: expected, detail: "准备解压", force: true)

        do {
            try await ZipTool.extract(url, to: dir, expectedFiles: expected) { files, bytes in
                ctx.report(.extract, current: files, total: expected,
                           detail: "解压到 \(DownloadManager.mb(bytes)) MB")
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let m = ZipTool.measure(dir)
        ctx.log("解压完成：\(m.files) 个文件 · \(DownloadManager.mb(m.bytes)) MB")
        ctx.report(.extract, current: max(m.files, expected), total: max(expected, 1),
                   detail: "解压完成", force: true)
        return dir
    }

    /// 只解压匹配的条目（unzip include 通配），逐文件上报进度。
    private static func extractSelected(_ url: URL,
                                        to _: URL?,
                                        including patterns: [String],
                                        expectedFiles: Int,
                                        ctx: ImportContext) async throws -> URL {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ctx.log("解压中…（只取 \(patterns.count) 个资源目录，跳过其余内容）")
        ctx.report(.extract, current: 0, total: expectedFiles, detail: "准备解压", force: true)
        do {
            try await ZipTool.extract(url, to: dir, including: patterns,
                                      expectedFiles: expectedFiles) { n, path in
                ctx.report(.extract, current: n, total: expectedFiles, detail: "解压 \(path)")
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let m = ZipTool.measure(dir)
        ctx.report(.extract, current: max(m.files, expectedFiles), total: max(expectedFiles, 1),
                   detail: "解压完成", force: true)
        return dir
    }

    /// 合并 src 到 dst，并把每个顶层项的完成情况写进日志。
    ///
    /// - Parameter isLoaderInstance: 实例是否用 Forge/NeoForge 这类加载器。
    ///   是的话要跳过整合包自带的客户端 jar（根目录那个大 jar）：
    ///   它会被 SecureJarHandler 推导出模块名 `client`，与加载器的 srg jar（模块 `minecraft`）
    ///   撞包 → `ResolutionException: Modules minecraft and client export package ...` → 启动失败。
    private static func merge(_ src: URL, into dst: URL, label: String,
                              isLoaderInstance: Bool, ctx: ImportContext) async throws {
        // skip 回调是并发执行的，用线程安全的盒子收集被跳过的项。
        final class Skipped: @unchecked Sendable {
            private let lock = NSLock()
            private var names: [String] = []
            func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
        }
        let skipped = Skipped()
        do {
            try await ZipTool.merge(src, into: dst,
                                    onItem: { item, idx, total in
                ctx.report(.merge, current: idx, total: total, detail: "写入 \(label)/\(item)",
                           force: idx == total)
            }, skip: { item in
                guard isLoaderInstance,
                      item.lastPathComponent.hasSuffix(".jar"),
                      ZipTool.isMinecraftClientJar(item) else { return false }
                skipped.add(item.lastPathComponent)
                return true
            })
            let names = skipped.all
            if !names.isEmpty {
                ctx.log("  ⚠ 已跳过整合包自带的客户端 jar（与加载器的 srg jar 冲突）："
                        + names.joined(separator: ", "))
            }
        } catch {
            ctx.log("⚠ \(label)/ 合并出错：\(error.localizedDescription)")
            throw error
        }
    }

    /// 推断包里的实例前缀（""、"x/"、".minecraft/"）。
    private static func detectPrefix(of url: URL) throws -> String {
        let entries = ZipTool.entries(of: url) ?? []
        if entries.contains(where: { $0.hasPrefix(".minecraft/mods/") }) { return ".minecraft/" }
        if entries.contains(where: { $0.hasPrefix("mods/") }) { return "" }
        // 包了一层同名目录：<root>/mods/
        for e in entries where e.hasSuffix("/") {
            let comps = e.split(separator: "/")
            if comps.count == 2, comps[1] == "mods" { return String(comps[0]) + "/" }
        }
        return ""
    }

    private static func countMatchingFiles(in url: URL, prefix: String) -> Int {
        let entries = ZipTool.fileEntries(of: url)
        guard !prefix.isEmpty else {
            return entries.filter { e in
                (keepDirs + keepFiles).contains { e.hasPrefix($0 + "/") || e == $0 }
            }.count
        }
        return entries.filter { $0.hasPrefix(prefix) }.count
    }

    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("maccraft-pack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    // MARK: - 辅助

    /// 实例 JSON：只写 id + inheritsFrom，其余（客户端/资源/参数）从父版本继承。
    private static func writeInstance(id: String, inheritsFrom: String) throws {
        let json: [String: Any] = ["id": id, "inheritsFrom": inheritsFrom, "type": "release"]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try Paths.ensure(Paths.versionDir(id))
        try data.write(to: Paths.versionJSON(id), options: .atomic)
    }

    private static func uniquePackID(from name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        base = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        if base.isEmpty { base = "modpack" }
        var candidate = "pack-\(base.prefix(40))"
        var n = 2
        while FileManager.default.fileExists(atPath: Paths.versionDir(candidate).path) {
            candidate = "pack-\(base.prefix(36))-\(n)"
            n += 1
        }
        return candidate
    }

    /// 复用已有实例：同一个源文件之前导入过，就用那个实例 id（覆盖更新），
    /// 而不是每次都新建一份。返回 nil 表示这是第一次导入。
    private static func reusablePackID(for url: URL) -> String? {
        guard let rec = PackIndex.existing(for: url) else { return nil }
        return rec.versionID
    }

    /// 实例是否用 Forge / NeoForge 这类加载器（这类实例不能带原版客户端 jar）。
    ///
    /// 判据只看**这个包自己声明的加载器 id**：
    /// 不能用「本机有没有 srg jar」当判据 —— 本机只要装过任意一个 Forge/NeoForge，
    /// srg jar 就一直躺在 libraries 里，那样会让**原版整合包**也被当成加载器实例，
    /// 把包里自带的客户端 jar 剔掉（原版实例那个 jar 是能正常用的，剔了反而启动不了）。
    ///
    /// 另外 Fabric / Quilt 不走 SecureJarHandler 模块化启动，
    /// 它们的客户端 jar 就是原版 jar，放着无害 —— 只有 Forge / NeoForge 1.17+ 才需要剔。
    private static func isLoaderInstance(_ loaderID: String) -> Bool {
        isLoaderInstanceForCheck(loaderID)
    }

    /// 给自检用的公开入口（判定逻辑见 isLoaderInstance 的注释）。
    static func isLoaderInstanceForCheck(_ loaderID: String) -> Bool {
        let low = loaderID.lowercased()
        return low.contains("forge")
    }

    private static func ensureVanilla(_ mc: String, ctx: ImportContext) async throws {
        guard !mc.isEmpty else { throw LauncherError.cannotWrite("整合包没写 minecraft 版本") }
        if FileManager.default.fileExists(atPath: Paths.versionJSON(mc).path) {
            // 本地已有也要报一次，否则任务条会一直停在上一阶段不动。
            ctx.report(.install, current: 1, total: 1, detail: "原版 \(mc) 已就绪", force: true)
            return
        }
        ctx.log("先安装原版 \(mc)…")
        ctx.report(.install, current: 0, total: 1, detail: "安装原版 \(mc)", force: true)
        let manifest = try await MojangAPI.fetchManifest()
        guard let ref = manifest.versions.first(where: { $0.id == mc }) else {
            throw LauncherError.cannotWrite("版本清单里找不到 \(mc)")
        }
        _ = try await VersionLibrary.installVanilla(ref) { got, total in
            ctx.report(.download, detail: "原版客户端 \(mc).jar",
                       bytes: got, totalBytes: max(total, 0))
        }
        ctx.report(.install, current: 1, total: 1, detail: "原版 \(mc) 就绪", force: true)
    }

    private static func javaMajor(mc: String) -> Int {
        if mc.hasPrefix("1.7") || mc.hasPrefix("1.8") || mc.hasPrefix("1.12") { return 8 }
        if VersionCompare.isNewerOrEqual(mc, "1.20.5") { return 21 }
        if VersionCompare.isNewerOrEqual(mc, "1.18") { return 17 }
        return 16
    }
}

// MARK: - 进度管道适配

extension ProgressRelay {
    /// 把 ProgressCounter 接到导入上下文（下载阶段）。
    nonisolated static func report(_ counter: ProgressCounter, to ctx: ImportContext, label: String) -> Task<Void, Never> {
        guard let relay = ctx.relay else { return Task {} }
        return DownloadManager.report(counter, to: relay, label: label)
    }
}
