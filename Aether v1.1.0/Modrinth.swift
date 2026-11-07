//
//  Modrinth.swift
//  maccraft
//
//  Mod / 光影 / 资源包 的搜索与自动安装（Modrinth v2 API）。
//  下载走「CDN 原站 + mod.mcimirror.top 镜像」候选链，和 Mojang 资源一套逻辑。
//

import Foundation

/// 可下载的资源类型。
nonisolated enum ResourceType: String, CaseIterable, Identifiable, Sendable {
    case mod
    case shader
    case resourcepack
    case modpack

    var id: String { rawValue }

    /// Modrinth 的 project_type 取值。
    var projectType: String {
        switch self {
        case .mod:          return "mod"
        case .shader:       return "shader"
        case .resourcepack: return "resourcepack"
        case .modpack:      return "modpack"
        }
    }

    var title: String {
        switch self {
        case .mod:          return "Mod"
        case .shader:       return "光影包"
        case .resourcepack: return "资源包"
        case .modpack:      return "整合包"
        }
    }

    var icon: String {
        switch self {
        case .mod:          return "puzzlepiece.extension.fill"
        case .shader:       return "sun.max.fill"
        case .resourcepack: return "paintpalette.fill"
        case .modpack:      return "shippingbox.fill"
        }
    }

    /// 安装目录（相对版本目录或游戏根目录）。
    func destination(versionID: String) -> URL {
        switch self {
        case .mod:          return Paths.modsDir(versionID)
        case .shader:       return Paths.shaderPacksDir
        case .resourcepack: return Paths.resourcePacksDir
        case .modpack:      return Paths.appSupport   // 整合包不走「装进某个版本」
        }
    }
}

nonisolated struct ModrinthProject: Identifiable, Decodable, Sendable {
    let project_id: String
    let slug: String
    let title: String
    let description: String
    let icon_url: String?
    let downloads: Int
    let categories: [String]
    let project_type: String

    var id: String { project_id }

    /// 手动构造（调试入口用：拿不到搜索结果时兜底）。
    init(project_id: String, slug: String, title: String, description: String,
         icon_url: String?, downloads: Int, categories: [String], project_type: String) {
        self.project_id = project_id
        self.slug = slug
        self.title = title
        self.description = description
        self.icon_url = icon_url
        self.downloads = downloads
        self.categories = categories
        self.project_type = project_type
    }
}

nonisolated struct ModrinthVersion: Identifiable, Decodable, Sendable {
    struct File: Decodable, Sendable {
        let url: String
        let filename: String
        let primary: Bool?
        let size: Int
    }

    let id: String
    let name: String
    let version_number: String
    let game_versions: [String]
    let loaders: [String]
    let files: [File]
    let date_published: String

    var primaryFile: File? { files.first(where: { $0.primary == true }) ?? files.first }
}

nonisolated enum Modrinth {
    private static let api = "https://api.modrinth.com/v2"

    /// 搜索资源。query 为空时按下载量排序（相当于"热门榜"）。
    static func search(_ type: ResourceType,
                       query: String,
                       mcVersion: String?,
                       loader: LoaderKind?,
                       offset: Int = 0,
                       limit: Int = 24) async throws -> SearchResult {
        var facets: [String] = ["[\"project_type:\(type.projectType)\"]"]
        if let mcVersion, !mcVersion.isEmpty {
            facets.append("[\"versions:\(mcVersion)\"]")
        }
        if type == .mod, let loader, loader != .vanilla {
            let name: String
            switch loader {
            case .fabric:   name = "fabric"
            case .forge:    name = "forge"
            case .neoforge: name = "neoforge"
            case .quilt:    name = "quilt"
            case .vanilla:  name = "fabric"
            }
            facets.append("[\"categories:\(name)\"]")
        }

        var comps = URLComponents(string: "\(api)/search")!
        comps.queryItems = [
            .init(name: "query", value: query),
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset)),
            .init(name: "index", value: query.isEmpty ? "downloads" : "relevance"),
            .init(name: "facets", value: "[\(facets.joined(separator: ","))]")
        ]
        let data = try await get(comps.url!)
        struct Result: Decodable { let hits: [ModrinthProject]; let total_hits: Int? }
        let decoded = try JSONDecoder().decode(Result.self, from: data)
        return SearchResult(hits: decoded.hits, total: decoded.total_hits ?? decoded.hits.count)
    }

    nonisolated struct SearchResult: Sendable {
        let hits: [ModrinthProject]
        let total: Int
    }

    /// 取某资源在指定版本 / 加载器下可用的最新文件。
    /// 注意：loader 过滤只对 Mod 有效——光影/资源包的 loader 是 iris / optifine / canvas，
    /// 用 fabric 去过滤会得到 0 个结果（实测）。
    static func versions(projectID: String,
                         mcVersion: String?,
                         loader: LoaderKind?,
                         type: ResourceType = .mod) async throws -> [ModrinthVersion] {
        func query(mc: String?, withLoader: Bool) -> URL? {
            var comps = URLComponents(string: "\(api)/project/\(projectID)/version")!
            var items: [URLQueryItem] = []
            if let mc, !mc.isEmpty {
                items.append(.init(name: "game_versions", value: "[\(quoted(mc))]"))
            }
            if withLoader, let loader, loader != .vanilla, type == .mod {
                let name = loader == .neoforge ? "neoforge" : loader.rawValue
                items.append(.init(name: "loaders", value: "[\(quoted(name))]"))
            }
            comps.queryItems = items.isEmpty ? nil : items
            return comps.url
        }

        var result: [ModrinthVersion] = []
        if let url = query(mc: mcVersion, withLoader: true) {
            result = try JSONDecoder().decode([ModrinthVersion].self, from: try await get(url))
        }
        // 兜底：去掉版本限制，拿最新的（有些资源没标 game_versions）
        if result.isEmpty, let url = query(mc: nil, withLoader: true) {
            result = try JSONDecoder().decode([ModrinthVersion].self, from: try await get(url))
        }
        return result
    }

    private static func quoted(_ s: String) -> String { "\"\(s)\"" }

    /// 下载并安装到对应目录，返回落地文件 URL。
    static func install(_ version: ModrinthVersion,
                        type: ResourceType,
                        versionID: String,
                        progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        guard let file = version.primaryFile else {
            throw LauncherError.cannotWrite("该版本没有可用文件")
        }
        let dir = type.destination(versionID: versionID)
        try Paths.ensure(dir)
        let dest = dir.appendingPathComponent(file.filename)

        var candidates: [MirrorCandidate] = []
        if let u = URL(string: file.url) {
            // 首选官方 CDN（实测 ~4MB/s，最快）；mcimirror 仅作兜底。
            // 不能把慢镜像放首选——它「能传但极慢」，不会触发首字节超时跳转，
            // 会把大文件钉在几分钟的慢速上。
            candidates.append(MirrorCandidate(source: "modrinth", url: u))
            if let mirror = URL(string: file.url.replacingOccurrences(of: "https://cdn.modrinth.com",
                                                                    with: "https://mod.mcimirror.top")) {
                candidates.append(MirrorCandidate(source: "mcimirror", url: mirror))
            }
        }
        guard !candidates.isEmpty else { throw LauncherError.http(0) }
        try await DownloadManager.downloadCandidates(candidates, kind: .other,
                                                     to: dest, sha1: nil,
                                                     timeout: 30, progress: progress)
        return dest
    }

    private static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        // Modrinth 要求带 User-Agent 标识，否则可能被限流
        req.setValue("maccraft/1.0 (macOS launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw LauncherError.http(http.statusCode)
        }
        return data
    }

    // MARK: - 整合包

    /// 下载整合包文件（.mrpack / manifest.json）并直接导入成实例。
    ///
    /// 整合包不是「装进某个版本」的资源，而是一整套实例 ——
    /// 所以流程是：下载 → 交给 `ModpackImporter` 建实例 → 装加载器 → 下所有 mod。
    ///
    /// - Returns: 新建的实例 id。
    @discardableResult
    static func installModpack(_ version: ModrinthVersion,
                               baseVersionID: String?,
                               overrideMC: String? = nil,
                               relay: ProgressRelay? = nil,
                               progress: (@Sendable (Int64, Int64) -> Void)? = nil,
                               log: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let file = version.primaryFile else {
            throw LauncherError.cannotWrite("该整合包版本没有可用文件")
        }
        // 先下到临时目录：整合包本体很小（几百 KB），真正的内容在导入时按清单逐个拉。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("modpack-\(version.id).\(file.filename.hasSuffix(".mrpack") ? "mrpack" : "zip")")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var candidates: [MirrorCandidate] = []
        if let u = URL(string: file.url) {
            // 首选官方 CDN（实测 ~4MB/s，最快）；mcimirror 仅作兜底。
            // 不能把慢镜像放首选——它「能传但极慢」，不会触发首字节超时跳转，
            // 会把大文件钉在几分钟的慢速上。
            candidates.append(MirrorCandidate(source: "modrinth", url: u))
            if let mirror = URL(string: file.url.replacingOccurrences(of: "https://cdn.modrinth.com",
                                                                    with: "https://mod.mcimirror.top")) {
                candidates.append(MirrorCandidate(source: "mcimirror", url: mirror))
            }
        }
        guard !candidates.isEmpty else { throw LauncherError.http(0) }
        log?("下载整合包 \(file.filename)（\(DownloadManager.mb(Int64(file.size))) MB）…")
        try await DownloadManager.downloadCandidates(candidates, kind: .other,
                                                     to: tmp, sha1: nil,
                                                     timeout: 60) { got, total in
            // 经统一 relay 上报本体下载进度（与后续导入各阶段共用一条任务条，
            // 不会在 mrpack 本体下完后焊死在「下载整合包」）。
            relay?.send(TaskProgress(stage: .download, bytes: got, totalBytes: max(total, 0),
                                     detail: "下载整合包"))
            progress?(got, total)
        }

        log?("开始导入整合包…")
        let result = try await ModpackImporter.import(tmp, baseVersionID: baseVersionID,
                                                     overrideMC: overrideMC, relay: relay) { msg in
            log?(msg)
        }
        log?("✔ 整合包导入完成：实例 \(result.versionID)（\(result.fileCount) 个文件）")
        return result.versionID
    }
}
