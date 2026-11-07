//
//  VersionLibrary.swift
//  maccraft
//
//  「已安装版本」的扫描、继承解析与安装落盘。
//
//  Forge / Fabric / Quilt / NeoForge 的版本 JSON 都只有一个 inheritsFrom 片段，
//  真正的客户端、资源、参数在原版版本里。启动前必须把父子链合并成一份完整 JSON，
//  这也是 PCL / HMCL 的 CommonVersion 做的事。
//

import Foundation
import CryptoKit

/// 版本来自哪个加载器。
nonisolated enum LoaderKind: String, Sendable, CaseIterable {
    case vanilla
    case fabric
    case forge
    case neoforge
    case quilt

    var title: String {
        switch self {
        case .vanilla:  return "原版"
        case .fabric:   return "Fabric"
        case .forge:    return "Forge"
        case .neoforge: return "NeoForge"
        case .quilt:    return "Quilt"
        }
    }

    /// UI 上的配色。
    var tintHex: UInt32 {
        switch self {
        case .vanilla:  return 0x62B47A
        case .fabric:   return 0xDBAE5A
        case .forge:    return 0x5A7FD6
        case .neoforge: return 0xE08B4A
        case .quilt:    return 0xC46BD8
        }
    }
}

/// 一个已安装到 `versions/` 的版本。
nonisolated struct InstalledVersion: Identifiable, Sendable, Hashable {
    let id: String
    let type: String
    let loader: LoaderKind
    let baseVersion: String?      // inheritsFrom
    let hasClientJar: Bool
    let modifiedAt: Date?
    let dir: URL

    var displayName: String { id }
    /// 形如 "1.21.4 · Fabric"
    var subtitle: String {
        if let baseVersion, loader != .vanilla { return "\(baseVersion) · \(loader.title)" }
        return type == "snapshot" ? "快照版" : "正式版"
    }
}

/// 合并好的完整版本（可交给启动器）。
nonisolated struct ResolvedVersion {
    let details: VersionDetails
    let chain: [String]          // [child, parent, ...]
    let clientJarID: String      // 哪个版本目录里放着 client jar
}

nonisolated enum VersionLibrary {
    // MARK: - 扫描

    static func scan() -> [InstalledVersion] {
        let fm = FileManager.default
        // 只扫 `profiles/` —— 版本核心在 `meta/versions/`，永远不露面。
        guard let entries = try? fm.contentsOfDirectory(at: Paths.profilesDir,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var out: [InstalledVersion] = []
        for dir in entries where dir.hasDirectoryPath {
            let dirID = dir.lastPathComponent
            guard let jsonURL = versionJSONIn(dir, prefer: dirID),
                  let data = try? Data(contentsOf: jsonURL),
                  let header = try? JSONDecoder().decode(VersionHeader.self, from: data) else { continue }
            let raws = String(decoding: data, as: UTF8.self)
            // 整合包实例的 JSON 只有 {id, inheritsFrom}，本身既不含加载器关键字也不带 client jar。
            // 必须沿继承链往上找：整条链上第一个非 vanilla 的加载器 + 最底层的 MC 版本。
            var loader = detectLoader(id: dirID, raw: raws)
            var resolvedBase: String? = header.inheritsFrom
            var cursor: String? = header.inheritsFrom
            var depth = 0
            while let c = cursor, depth < 12 {
                let cRaw = (try? String(contentsOf: Paths.parentVersionJSON(c), encoding: .utf8)) ?? ""
                let cHeader = try? JSONDecoder().decode(VersionHeader.self, from: Data(cRaw.utf8))
                if loader == .vanilla {
                    loader = detectLoader(id: c, raw: cRaw)
                }
                if let next = cHeader?.inheritsFrom {
                    cursor = next
                } else {
                    resolvedBase = c          // 链底 = 真正的 MC 版本
                    cursor = nil
                }
                depth += 1
            }
            let base = resolvedBase ?? header.inheritsFrom
            let jar = clientJarExists(inChain: dirID)
            let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            out.append(InstalledVersion(id: dirID,
                                        type: header.type ?? "release",
                                        loader: loader,
                                        baseVersion: base,
                                        hasClientJar: jar,
                                        modifiedAt: mtime,
                                        dir: dir))
        }
        return out.sorted { a, b in
            if a.loader == .vanilla && b.loader != .vanilla { return true }
            if a.loader != .vanilla && b.loader == .vanilla { return false }
            return (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast)
        }
    }

    /// 目录里的版本 JSON：优先 `<dir>/<id>.json`，找不到就取目录里第一个 .json。
    static func versionJSONIn(_ dir: URL, prefer id: String) -> URL? {
        let fm = FileManager.default
        let exact = dir.appendingPathComponent("\(id).json")
        if fm.fileExists(atPath: exact.path) { return exact }
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return nil }
        return items.first { $0.pathExtension == "json" }
    }

    nonisolated struct VersionHeader: Decodable {
        let id: String
        let type: String?
        let inheritsFrom: String?
    }

    static func detectLoader(id: String, raw: String) -> LoaderKind {
        let lower = id.lowercased()
        if lower.hasPrefix("fabric-loader") || raw.contains("net.fabricmc.loader") { return .fabric }
        if lower.hasPrefix("quilt-loader") || raw.contains("org.quiltmc") { return .quilt }
        if lower.hasPrefix("neoforge") || raw.contains("net.neoforged") { return .neoforge }
        if lower.hasPrefix("forge") || raw.contains("net.minecraftforge") { return .forge }
        return .vanilla
    }

    // MARK: - 解析（父子链合并）

    /// - Parameter asCore: 为 true 时按「核心」查目录（`meta/versions` 优先）。
    ///   解析继承父版本必须走核心优先 —— 否则原版实例（`profiles/1.20.1`）和它继承的
    ///   原版核心（`meta/versions/1.20.1`）同名，父级会解析回自己，死循环。
    static func resolve(_ id: String, depth: Int = 0, asCore: Bool = false) throws -> ResolvedVersion {
        guard depth < 6 else { throw LauncherError.cannotWrite("版本继承链过深：\(id)") }
        let dir = asCore ? Paths.parentVersionDir(id) : Paths.versionDir(id)
        guard let json = versionJSONIn(dir, prefer: id), let data = try? Data(contentsOf: json) else {
            throw LauncherError.cannotWrite("版本未安装：\(id)")
        }
        let child = try JSONDecoder().decode(VersionDetails.self, from: data)
        let jarHere = FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).jar").path)

        guard let parentID = child.inheritsFrom, !parentID.isEmpty else {
            return ResolvedVersion(details: child,
                                   chain: [id],
                                   clientJarID: jarHere ? id : id)
        }
        let parent = try resolve(parentID, depth: depth + 1, asCore: true)
        let merged = VersionDetails.merge(child: child, parent: parent.details)
        return ResolvedVersion(details: merged,
                               chain: [id] + parent.chain,
                               clientJarID: jarHere ? id : parent.clientJarID)
    }

    /// 某个已安装版本对应的 Minecraft 版本号（沿继承链取最底层）。
    static func baseMinecraftVersion(of id: String) -> String? {
        guard let r = try? resolve(id) else { return nil }
        return r.chain.last
    }

    /// 沿继承链找 client jar（整合包实例自己不带 jar，jar 在最底层的原版核心目录里）。
    private static func clientJarExists(inChain id: String) -> Bool {
        let fm = FileManager.default
        var cursor: String? = id
        var asCore = false
        var depth = 0
        while let c = cursor, depth < 12 {
            let dir = asCore ? Paths.parentVersionDir(c) : Paths.versionDir(c)
            if fm.fileExists(atPath: dir.appendingPathComponent("\(c).jar").path) { return true }
            let raw = (try? String(contentsOf: dir.appendingPathComponent("\(c).json"), encoding: .utf8)) ?? ""
            let h = try? JSONDecoder().decode(VersionHeader.self, from: Data(raw.utf8))
            cursor = h?.inheritsFrom
            asCore = true
            depth += 1
        }
        return false
    }

    // MARK: - 安装 / 删除

    /// 写入版本 JSON（原样保存，供以后解析）。
    /// 写入核心版本 JSON（加载器 install_profile / fabric profile 这种）。
    /// 核心一律落 `meta/versions/<id>`，不进实例目录 —— 否则会以「版本」身份出现在列表里。
    static func save(json data: Data, id: String) throws {
        let dir = Paths.coreDir(id)
        try Paths.ensure(dir)
        try data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
    }

    /// 安装一个原版核心（版本 JSON + client.jar）到指定目录。
    /// 只写核心，不建实例 —— 实例由调用方决定（`installVanilla` / 整合包）。
    @discardableResult
    static func installCore(_ ref: VersionManifest.VersionRef,
                            into dir: URL,
                            progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> String {
        let jsonPath = dir.appendingPathComponent("\(ref.id).json")
        let clientPath = dir.appendingPathComponent("\(ref.id).jar")
        let official = URL(string: Mirror.toOfficial(ref.url)) ?? URL(string: ref.url)!
        let data = try await MojangAPI.fetchData(kind: .versionJSON, official: official)
        try Paths.ensure(dir)
        try data.write(to: jsonPath, options: .atomic)

        let details = try JSONDecoder().decode(VersionDetails.self, from: data)
        if let client = details.downloads?.client {
            if !FileManager.default.fileExists(atPath: clientPath.path) {
                let url = URL(string: Mirror.toOfficial(client.url)) ?? URL(string: client.url)!
                try await DownloadManager.downloadCandidates(
                    Mirror.candidates(for: url, kind: .clientJar), kind: .clientJar,
                    to: clientPath, sha1: client.sha1, progress: progress)
            }
        }
        return ref.id
    }

    /// 安装一个可玩的原版实例：核心进 `meta/versions/`（只此一份），
    /// 再在 `profiles/` 下建一个继承它的实例 —— 这样版本管理里看到的是「实例」，
    /// 核心不会重复占空间，也不会因为装了多个整合包而堆一堆同名 jar。
    static func installVanilla(_ ref: VersionManifest.VersionRef,
                               progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> String {
        try await installCore(ref, into: Paths.coreDir(ref.id), progress: progress)
        try ensureProfile(id: ref.id, inheritsFrom: ref.id, type: ref.type)
        return ref.id
    }

    /// 建一个实例目录 + 继承壳 JSON（`{id, inheritsFrom}`）。
    /// 已存在则只补写 JSON，不动里面的 mods / 存档。
    static func ensureProfile(id: String, inheritsFrom: String, type: String = "release") throws {
        let dir = Paths.profileDir(id)
        try Paths.ensure(dir)
        let json = dir.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: json.path) { return }
        let obj: [String: Any] = ["id": id, "inheritsFrom": inheritsFrom, "type": type]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: json, options: .atomic)
    }

    static func delete(_ id: String) throws {
        let fm = FileManager.default
        // 只删实例（profiles/）。核心在 meta/versions 里，可能被别的实例共用，
        // 这里不擅自清理 —— 免得用户删掉一个整合包，连带把共用的原版 / 加载器核心也弄没了。
        let profile = Paths.profileDir(id)
        if Paths.isDirectory(profile) {
            try fm.removeItem(at: profile)
        } else {
            try fm.removeItem(at: Paths.coreDir(id))
        }
        // 实例没了，索引里的映射也作废 —— 否则下次导入同一份包会以为
        // 「已经导过了」而复用一个不存在的目录。
        PackIndex.forget(versionID: id)
    }

    /// 核心回收：只删「刚才那个实例依赖过、且现在没有任何实例再依赖」的核心。
    /// 共享核心（多个整合包同版本）不会被误删。
    static func garbageCollectCores(candidates: [String]) {
        guard !candidates.isEmpty else { return }
        let referenced = referencedCores()
        let fm = FileManager.default
        for id in candidates where !referenced.contains(id) {
            let dir = Paths.coreDir(id)
            guard fm.fileExists(atPath: dir.path) else { continue }
            try? fm.removeItem(at: dir)
        }
    }

    /// 当前所有实例（含多级继承）引用到的核心 id 集合。
    static func referencedCores() -> Set<String> {
        let fm = FileManager.default
        var out = Set<String>()
        guard let entries = try? fm.contentsOfDirectory(at: Paths.profilesDir,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return out }
        for dir in entries where dir.hasDirectoryPath {
            let dirID = dir.lastPathComponent
            guard let json = versionJSONIn(dir, prefer: dirID),
                  let data = try? Data(contentsOf: json),
                  let h = try? JSONDecoder().decode(VersionHeader.self, from: data) else { continue }
            var cursor = h.inheritsFrom
            var depth = 0
            while let c = cursor, depth < 12 {
                out.insert(c)
                let raw = (try? String(contentsOf: Paths.parentVersionJSON(c), encoding: .utf8)) ?? ""
                cursor = (try? JSONDecoder().decode(VersionHeader.self, from: Data(raw.utf8)))?.inheritsFrom
                depth += 1
            }
        }
        return out
    }

    // MARK: - 存储布局（profiles / meta 分离）

    /// 建立新布局：`meta/versions` + `profiles`，并把 `versions` 变成指向 `meta/versions` 的软链。
    ///
    /// 为什么要留这个软链：Forge / NeoForge 安装器只会往 `--installClient <dir>` 下的
    /// `versions/` 写文件（我们传的是 appSupport），软链让它实际写进 `meta/versions`，
    /// 这样核心目录就统一了，不用装完再搬家。
    static func ensureLayout() {
        let fm = FileManager.default
        try? Paths.ensure(Paths.metaVersionsDir)
        try? Paths.ensure(Paths.profilesDir)
        let legacy = Paths.legacyVersionsDir
        if Paths.isSymlink(legacy) { return }
        if fm.fileExists(atPath: legacy.path) {
            // 旧布局的真目录还在 → 不动它，等用户点「一键迁移」。
            return
        }
        try? fm.createSymbolicLink(at: legacy, withDestinationURL: Paths.metaVersionsDir)
    }

    /// 是否是旧布局（需要迁移）。
    static var hasLegacyLayout: Bool {
        let fm = FileManager.default
        let legacy = Paths.legacyVersionsDir
        if fm.fileExists(atPath: Paths.packCoresDir.path) { return true }
        guard fm.fileExists(atPath: legacy.path), !Paths.isSymlink(legacy) else { return false }
        let items = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        return !items.isEmpty
    }

    struct MigrationReport: Sendable {
        var cores = 0
        var profiles = 0
        var skipped = 0
    }

    enum MigrationAction: String, Sendable {
        case profile        // 实例 → profiles/
        case core           // 加载器 / 被继承的核心 → meta/versions/
        case vanillaSplit   // 手动装的原版：核心进 meta + 留一个实例壳
        case packCore       // 旧的 .packcores/<mc> → meta/versions/<mc>
        case dropSymlink    // 旧的 versions/<mc> → .packcores 软链，直接删
    }

    struct MigrationStep: Sendable {
        let id: String
        let action: MigrationAction
        let source: URL
    }

    /// **只读**：算一遍迁移计划，不做任何落盘动作。
    /// UI 预览 / 命令行 `--layout-check` 用它确认分类对不对。
    static func planMigration() -> [MigrationStep] {
        let fm = FileManager.default
        var steps: [MigrationStep] = []
        let legacy = Paths.legacyVersionsDir
        if fm.fileExists(atPath: legacy.path), !Paths.isSymlink(legacy) {
            let entries = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []
            // 先算引用关系：被别的版本 inheritsFrom 的 = 核心
            var referenced = Set<String>()
            for dir in entries where dir.hasDirectoryPath {
                let id = dir.lastPathComponent
                guard let json = versionJSONIn(dir, prefer: id),
                      let data = try? Data(contentsOf: json),
                      let h = try? JSONDecoder().decode(VersionHeader.self, from: data),
                      let inh = h.inheritsFrom else { continue }
                referenced.insert(inh)
            }
            for entry in entries {
                let id = entry.lastPathComponent
                if Paths.isSymlink(entry) {
                    steps.append(MigrationStep(id: id, action: .dropSymlink, source: entry)); continue
                }
                guard entry.hasDirectoryPath else { continue }
                let json = versionJSONIn(entry, prefer: id)
                let raw = json.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                let header = try? JSONDecoder().decode(VersionHeader.self, from: Data(raw.utf8))
                let loader = detectLoader(id: id, raw: raw)
                if id.hasPrefix("pack-") {
                    steps.append(MigrationStep(id: id, action: .profile, source: entry))
                } else if referenced.contains(id) || loader != .vanilla || header?.inheritsFrom != nil {
                    steps.append(MigrationStep(id: id, action: .core, source: entry))
                } else {
                    steps.append(MigrationStep(id: id, action: .vanillaSplit, source: entry))
                }
            }
        }
        if fm.fileExists(atPath: Paths.packCoresDir.path) {
            let cores = (try? fm.contentsOfDirectory(at: Paths.packCoresDir,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            for core in cores where core.hasDirectoryPath {
                steps.append(MigrationStep(id: core.lastPathComponent, action: .packCore, source: core))
            }
        }
        return steps
    }

    /// 一键迁移旧数据（`versions/` + `.packcores/`）到新布局。
    ///
    /// 分类规则：
    ///   · `pack-*`              → 实例
    ///   · 被别的版本 inheritsFrom → 核心
    ///   · 加载器版本（forge/fabric/neoforge/quilt）→ 核心
    ///   · 其余（手动装的原版）    → 核心 + 同名实例壳
    ///
    /// 同一卷内是 rename，秒级完成；**绝不覆盖**已存在的目标，撞车就跳过并保留原位。
    @discardableResult
    static func migrateLegacyLayout(log: (@Sendable (String) -> Void)? = nil) throws -> MigrationReport {
        let fm = FileManager.default
        // ⚠️ 绝对防线：`versions` 已经是软链 → 早就迁过了，一律不动。
        //
        // 为什么这条必须放在最前面：`contentsOfDirectory` 会**跟随软链**列出目标目录
        // （meta/versions）里的条目，随后再按「旧目录的条目」把它们搬去 coreDir(id) ——
        // 而 src 与 dst 恰好是同一个路径。任何「先删目标再移动」的实现都会在那一刻
        // 把源（也就是唯一的一份数据）删掉，move 随之失败，数据凭空消失。
        // 2026-11-07 真实数据就是这样被清空的（2.6G → 0），加这条闸门永不复现。
        if Paths.isSymlink(Paths.legacyVersionsDir) {
            log?("versions 已是软链（新布局已生效），跳过迁移")
            return MigrationReport()
        }
        try Paths.ensure(Paths.metaVersionsDir)
        try Paths.ensure(Paths.profilesDir)
        var report = MigrationReport()

        for step in planMigration() {
            switch step.action {
            case .dropSymlink:
                try? fm.removeItem(at: step.source)
            case .profile:
                if move(step.source, to: Paths.profileDir(step.id), fm: fm) {
                    report.profiles += 1
                    log?("实例 → profiles/\(step.id)")
                } else {
                    report.skipped += 1
                    log?("⚠ 跳过 \(step.id)：目标已存在")
                }
            case .core:
                if move(step.source, to: Paths.coreDir(step.id), fm: fm) {
                    report.cores += 1
                    log?("核心 → meta/versions/\(step.id)")
                } else {
                    report.skipped += 1
                    log?("⚠ 跳过 \(step.id)：目标已存在")
                }
            case .packCore:
                if move(step.source, to: Paths.coreDir(step.id), fm: fm) {
                    report.cores += 1
                    log?("核心 → meta/versions/\(step.id)")
                } else {
                    report.skipped += 1
                    log?("⚠ 跳过 .packcores/\(step.id)：目标已存在")
                }
            case .vanillaSplit:
                let json = versionJSONIn(step.source, prefer: step.id)
                let raw = json.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                let type = (try? JSONDecoder().decode(VersionHeader.self, from: Data(raw.utf8)))?.type ?? "release"
                try splitVanilla(step.source, id: step.id, type: type, report: &report, log: log)
            }
        }

        // `.packcores` 空了就删
        if let rest = try? fm.contentsOfDirectory(at: Paths.packCoresDir, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]), rest.isEmpty {
            try? fm.removeItem(at: Paths.packCoresDir)
        }

        // 旧目录清空后换成软链（安装器还能照常往里写，文件落进 meta/versions）
        let legacy = Paths.legacyVersionsDir
        if !Paths.isSymlink(legacy) {
            if fm.fileExists(atPath: legacy.path) {
                let rest = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
                if rest.isEmpty { try? fm.removeItem(at: legacy) }
            }
            if !fm.fileExists(atPath: legacy.path) {
                try? fm.createSymbolicLink(at: legacy, withDestinationURL: Paths.metaVersionsDir)
            }
        }
        return report
    }

    /// 原版：核心（json+jar+natives）进 meta，实例内容（mods/存档/设置）留一份壳在 profiles。
    private static func splitVanilla(_ dir: URL, id: String, type: String,
                                     report: inout MigrationReport,
                                     log: (@Sendable (String) -> Void)?) throws {
        let fm = FileManager.default
        let core = Paths.coreDir(id)
        var container = dir
        if !Paths.isDirectory(core) {
            if move(dir, to: core, fm: fm) {
                report.cores += 1
                container = core
            } else {
                // 核心目标已被占用：实例内容照样搬，原目录留着不动（不覆盖任何东西）。
                report.skipped += 1
                log?("⚠ 原版 \(id)：meta 里已有同名核心，只补实例壳")
            }
        }
        let profile = Paths.profileDir(id)
        try ensureProfile(id: id, inheritsFrom: id, type: type)
        // 这些是「实例内容」，启动器把它们当游戏目录根
        let instanceItems = ["mods", "config", "resourcepacks", "shaderpacks", "saves",
                             "screenshots", "logs", "options.txt", "optionsof.txt", "servers.dat",
                             "usercache.json", ".aether-conflicts"]
        var moved = 0
        for name in instanceItems {
            let src = container.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = profile.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            if move(src, to: dst, fm: fm) { moved += 1 }
        }
        // 原目录里只剩核心文件且已搬空 → 删掉；否则留着让用户确认
        if container == dir {
            let rest = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])) ?? []
            if rest.isEmpty { try? fm.removeItem(at: dir) }
        }
        report.profiles += 1
        log?("原版 → 核心 meta/versions/\(id) + 实例 profiles/\(id)（搬了 \(moved) 个实例目录）")
    }

    /// 同卷改名。目标已存在则**不覆盖**，返回 false（宁可跳过也不丢数据）。
    @discardableResult
    private static func move(_ src: URL, to dst: URL, fm: FileManager) -> Bool {
        // 绝对防线：src 和 dst 是同一路径（或互相包含）时直接拒绝。
        // 任何「先删目标、再移动」的实现在这种自指移动上都会销毁源数据。
        let s = src.standardizedFileURL.path
        let d = dst.standardizedFileURL.path
        if s == d || s.hasPrefix(d + "/") || d.hasPrefix(s + "/") { return false }
        try? Paths.ensure(dst.deletingLastPathComponent())
        if fm.fileExists(atPath: dst.path) { return false }
        do {
            try fm.moveItem(at: src, to: dst)
            return true
        } catch {
            return false
        }
    }
}
