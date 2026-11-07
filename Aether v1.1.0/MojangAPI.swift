//
//  MojangAPI.swift
//  maccraft
//
//  与 Mojang 启动元数据服务交互。
//
//  取 JSON 的策略是「对冲竞速」（hedged request）：
//   候选源按 400ms 间隔依次起跑，谁先返回合法数据就用谁，其余立刻取消。
//  这比 HMCL 的「失败才换源」更快——BMCLAPI 的 302 常常要 8 秒才吐首字节，
//  而官方 0.5 秒就回来了，竞速能直接拿到最快的那个，又不会因为镜像抽风而卡死。
//

import Foundation
import CryptoKit

nonisolated enum MojangAPI {
    /// 版本清单的官方地址（镜像候选由 Mirror 生成）。
    static let manifestURL = URL(string: "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json")!

    /// 元数据用短超时 session：请求 12s、整体 30s。
    /// 之前用 URLSession.shared 默认配置（资源超时 7 天），遇到涓流节点会永久挂起。
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - 数据获取（候选竞速）

    /// 取原始字节：多源竞速，先成功者胜；`validate` 返回 false 视为该源失败。
    static func fetchData(kind: ResourceKind,
                          official: URL,
                          validate: (@Sendable (Data) -> Bool)? = nil) async throws -> Data {
        let candidates = Mirror.candidates(for: official, kind: kind)

        if candidates.count == 1, let only = candidates.first {
            let data = try await getData(only.url)
            if let validate, !validate(data) { throw LauncherError.stalled("内容校验失败") }
            return data
        }

        var errors: [Error] = []
        let data: Data? = try await withThrowingTaskGroup(of: Result<Data, Error>.self) { group -> Data? in
            for (i, cand) in candidates.enumerated() {
                group.addTask {
                    if i > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(i) * 400_000_000)
                    }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    do {
                        let d = try await getData(cand.url)
                        if let validate, !validate(d) {
                            SourceHealth.shared.recordMiss(cand.source, kind: kind)
                            return .failure(LauncherError.stalled("内容校验失败"))
                        }
                        SourceHealth.shared.recordSuccess(cand.source, kind: kind)
                        return .success(d)
                    } catch {
                        if case LauncherError.http(404) = error {
                            SourceHealth.shared.recordMiss(cand.source, kind: kind)
                        } else {
                            SourceHealth.shared.recordFailure(cand.source, kind: kind)
                        }
                        return .failure(error)
                    }
                }
            }
            while let r = try await group.next() {
                switch r {
                case .success(let d):
                    group.cancelAll()
                    return d
                case .failure(let e):
                    if !(e is CancellationError) { errors.append(e) }
                }
            }
            return nil
        }

        if let data { return data }
        throw errors.last ?? LauncherError.stalled("全部下载源均失败")
    }

    static func fetchJSON<T: Decodable>(kind: ResourceKind, official: URL) async throws -> T {
        let data = try await fetchData(kind: kind, official: official)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func getData(_ url: URL) async throws -> Data {
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw LauncherError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw LauncherError.stalled("空响应") }
        return data
    }

    // MARK: - 清单

    static func fetchManifest() async throws -> VersionManifest {
        var manifest: VersionManifest = try await fetchJSON(kind: .manifest, official: manifestURL)
        // 规范成官方 host 后再缓存，使缓存与所选源无关（切换源无需重新下载清单）。
        manifest = manifest.normalizingURLs()
        try? JSONEncoder().encode(manifest).write(to: Paths.manifestCache)
        return manifest
    }

    /// 读取本地缓存的版本清单（无网络、瞬间完成）。读出时再次规范化，确保是官方 host。
    static func cachedManifest() -> VersionManifest? {
        guard let data = try? Data(contentsOf: Paths.manifestCache) else { return nil }
        guard let m = try? JSONDecoder().decode(VersionManifest.self, from: data) else { return nil }
        return m.normalizingURLs()
    }

    static func fetchVersionDetails(_ ref: VersionManifest.VersionRef) async throws -> VersionDetails {
        let official = URL(string: Mirror.toOfficial(ref.url)) ?? URL(string: ref.url)!
        return try await fetchJSON(kind: .versionJSON, official: official)
    }

    /// 获取资源索引。新版用 assetIndex.url；旧版（无 assetIndex）按 assets 字段回退。
    /// **必须把索引 JSON 落盘到 `assets/indexes/<id>.json`** —— 游戏读的就是这个文件，
    /// 只下载 objects 而不写索引，会卡在启动画面（实测日志：Can't open the resource index file）。
    static func fetchAssetIndex(details: VersionDetails) async throws -> (file: AssetIndexFile, indexName: String) {
        if let index = details.assetIndex {
            let official = URL(string: Mirror.toOfficial(index.url)) ?? URL(string: index.url)!
            // 注意必须是原始字节；并且用 SHA-1 校验，防止镜像返回错误页。
            let data = try await fetchData(kind: .assetIndex, official: official) { data in
                Insecure.SHA1.hash(data: data).map { String(format: "%02hhx", $0) }.joined() == index.sha1
            }
            let file = try JSONDecoder().decode(AssetIndexFile.self, from: data)
            try writeIndexFile(data, id: index.id)
            return (file, index.id)
        }
        // 旧版：https://launchermeta.mojang.com/mc/assets/<assets>.json
        guard let assets = details.assets else { throw LauncherError.missingClient }
        let official = URL(string: "https://launchermeta.mojang.com/mc/assets/\(assets).json")!
        let data = try await fetchData(kind: .assetIndex, official: official)
        let file = try JSONDecoder().decode(AssetIndexFile.self, from: data)
        try writeIndexFile(data, id: assets)
        return (file, assets)
    }

    /// 把资源索引写入 `assets/indexes/<id>.json`（游戏按 `--assetIndex <id>` 读取）。
    static func writeIndexFile(_ data: Data, id: String) throws {
        try Paths.ensure(Paths.assetsIndexesDir)
        let dest = Paths.assetIndexFile(id)
        let existing = try? Data(contentsOf: dest)
        if existing == data { return }
        try data.write(to: dest, options: .atomic)
    }

    /// 旧版（legacy / pre-1.6）资源需要铺成 `assets/virtual/<id>/<名字>`，现代版本不需要。
    static func materializeVirtualAssets(indexName: String, file: AssetIndexFile) throws {
        guard indexName.hasPrefix("legacy") || indexName.hasPrefix("pre-1.6") else { return }
        let virtualDir = Paths.assetsDir
            .appendingPathComponent("virtual", isDirectory: true)
            .appendingPathComponent(indexName, isDirectory: true)
        try Paths.ensure(virtualDir)
        for (name, obj) in file.objects {
            let prefix = String(obj.hash.prefix(2))
            let src = Paths.assetsObjectsDir
                .appendingPathComponent(prefix, isDirectory: true)
                .appendingPathComponent(obj.hash)
            let dst = virtualDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path),
                  !FileManager.default.fileExists(atPath: dst.path) else { continue }
            try? Paths.ensure(dst.deletingLastPathComponent())
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }

    /// 资源对象的候选地址（按当前偏好排序）。
    static func assetCandidates(hash: String) -> [MirrorCandidate] {
        let prefix = String(hash.prefix(2))
        let official = URL(string: "https://resources.download.minecraft.net/\(prefix)/\(hash)")!
        return Mirror.candidates(for: official, kind: .assetObject)
    }
}
