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
        guard let entries = try? fm.contentsOfDirectory(at: Paths.versionsDir,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var out: [InstalledVersion] = []
        for dir in entries where dir.hasDirectoryPath {
            let id = dir.lastPathComponent
            let json = Paths.versionJSON(id)
            guard fm.fileExists(atPath: json.path) else { continue }
            let raws = (try? String(contentsOf: json, encoding: .utf8)) ?? ""
            let header = try? JSONDecoder().decode(VersionHeader.self, from: Data(raws.utf8))
            // 整合包实例的 JSON 只有 {id, inheritsFrom}，本身既不含加载器关键字也不带 client jar。
            // 必须沿继承链往上找：整条链上第一个非 vanilla 的加载器 + 最底层的 MC 版本。
            var loader = detectLoader(id: id, raw: raws)
            var resolvedBase: String? = header?.inheritsFrom
            var cursor: String? = header?.inheritsFrom
            var depth = 0
            while let c = cursor, depth < 12 {
                let cJSON = Paths.versionJSON(c)
                let cRaw = (try? String(contentsOf: cJSON, encoding: .utf8)) ?? ""
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
            let base = resolvedBase ?? header?.inheritsFrom
            let jar = clientJarExists(inChain: id)
            let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            out.append(InstalledVersion(id: header?.id.isEmpty == false ? header!.id : id,
                                        type: header?.type ?? "release",
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

    static func resolve(_ id: String, depth: Int = 0) throws -> ResolvedVersion {
        guard depth < 6 else { throw LauncherError.cannotWrite("版本继承链过深：\(id)") }
        let json = Paths.versionJSON(id)
        guard let data = try? Data(contentsOf: json) else {
            throw LauncherError.cannotWrite("版本未安装：\(id)")
        }
        let child = try JSONDecoder().decode(VersionDetails.self, from: data)
        let jarHere = FileManager.default.fileExists(atPath: Paths.clientJar(id).path)

        guard let parentID = child.inheritsFrom, !parentID.isEmpty else {
            return ResolvedVersion(details: child,
                                   chain: [id],
                                   clientJarID: jarHere ? id : id)
        }
        let parent = try resolve(parentID, depth: depth + 1)
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

    /// 沿继承链找 client jar（整合包实例自己不带 jar，jar 在最底层的原版目录里）。
    private static func clientJarExists(inChain id: String) -> Bool {
        let fm = FileManager.default
        var cursor: String? = id
        var depth = 0
        while let c = cursor, depth < 12 {
            if fm.fileExists(atPath: Paths.clientJar(c).path) { return true }
            let json = Paths.versionJSON(c)
            let raw = (try? String(contentsOf: json, encoding: .utf8)) ?? ""
            let h = try? JSONDecoder().decode(VersionHeader.self, from: Data(raw.utf8))
            cursor = h?.inheritsFrom
            depth += 1
        }
        return false
    }

    // MARK: - 安装 / 删除

    /// 写入版本 JSON（原样保存，供以后解析）。
    static func save(json data: Data, id: String) throws {
        let dir = Paths.versionDir(id)
        try Paths.ensure(dir)
        try data.write(to: Paths.versionJSON(id), options: .atomic)
    }

    /// 安装一个原版：写版本 JSON + 下载 client.jar。返回版本 id。
    static func installVanilla(_ ref: VersionManifest.VersionRef,
                               progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> String {
        let official = URL(string: Mirror.toOfficial(ref.url)) ?? URL(string: ref.url)!
        let data = try await MojangAPI.fetchData(kind: .versionJSON, official: official)
        try save(json: data, id: ref.id)

        let details = try JSONDecoder().decode(VersionDetails.self, from: data)
        if let client = details.downloads?.client {
            let dest = Paths.clientJar(ref.id)
            if !FileManager.default.fileExists(atPath: dest.path) {
                let url = URL(string: Mirror.toOfficial(client.url)) ?? URL(string: client.url)!
                try await DownloadManager.downloadCandidates(
                    Mirror.candidates(for: url, kind: .clientJar), kind: .clientJar,
                    to: dest, sha1: client.sha1, progress: progress)
            }
        }
        return ref.id
    }

    static func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: Paths.versionDir(id))
        // 实例没了，索引里的映射也作废 —— 否则下次导入同一份包会以为
        // 「已经导过了」而复用一个不存在的目录。
        PackIndex.forget(versionID: id)
    }
}
