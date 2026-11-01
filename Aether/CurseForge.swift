//
//  CurseForge.swift
//  maccraft
//
//  CurseForge 整合包所需的「文件 ID → 文件名 / 下载地址」解析。
//
//  背景：CurseForge 的 manifest.json 里 files 只有 projectID / fileID，
//  没有文件名，而 CDN 直链是 https://edge.forgecdn.net/files/<id/1000>/<id%1000>/<文件名>，
//  所以必须先把文件名查出来。
//
//  官方 API（api.curseforge.com）要 x-api-key，且 CurseForge 不向启动器开发者发放；
//  HMCL 的做法是从 jar 的 manifest 属性 hmcl.curseforge.apikey 取（默认空，等于用不了）。
//
//  这里改用 mod.mcimirror.top —— 一个免 key 的 CurseForge API 反向代理，
//  与官方 v1 接口同构（实测 0.18s 返回单个文件、1.1s 返回整个文件列表）。
//  设置里填了官方 API Key 时优先走官方，可作回退与对照。
//
//  ── 来源说明 ───────────────────────────────────────────────────────────
//  ForgeCDN 直链格式与「缺文件名就查 API 补全」的流程参考 HMCL（GPL-3.0）：
//      HMCLCore/.../modpack/curse/CurseManifestFile.java      (url() 里的 edge.forgecdn.net 拼接)
//      HMCLCore/.../modpack/curse/CurseCompletionTask.java    (executed() 里的补全逻辑)
//      HMCLCore/.../addon/repository/CurseForgeRemoteAddonRepository.java
//      https://github.com/HMCL-dev/HMCL
//  Swift 实现为重新编写，未逐行翻译。
//  ──────────────────────────────────────────────────────────────────────
//

import Foundation

nonisolated enum CurseForge {

    struct FileInfo: Sendable {
        let fileName: String
        let downloadURL: URL
        let sha1: String?
        let size: Int64?
    }

    /// 免 key 的镜像（与官方 v1 同构）。
    private static let mirrorBase = "https://mod.mcimirror.top/curseforge/v1"
    /// 官方 API（需要 key）。
    private static let officialBase = "https://api.curseforge.com/v1"

    // MARK: - 单个文件

    /// 查询某个 mod 的某个文件版本（projectID + fileID）。
    static func fileInfo(modID: Int, fileID: Int) async throws -> FileInfo {
        var lastError: Error?
        for base in candidateBases() {
            do {
                let info = try await query(base: base, modID: modID, fileID: fileID)
                return info
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? LauncherError.cannotWrite("查不到 CurseForge 文件 \(modID)/\(fileID)")
    }

    /// 批量并发查询（整合包一般几十个文件，8 路并发几秒就够）。
    /// 查不到的项目不会抛错，交给调用方按缺失处理。
    static func fileInfos(_ pairs: [(modID: Int, fileID: Int)],
                          maxConcurrent: Int = 8,
                          onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> [Int: FileInfo] {
        guard !pairs.isEmpty else { return [:] }
        let total = pairs.count

        // 用 actor 收结果，避免在 async 上下文里用 NSLock。
        actor Collector {
            private var result: [Int: FileInfo] = [:]
            private var done = 0
            func add(_ fileID: Int, _ info: FileInfo?) -> Int {
                if let info { result[fileID] = info }
                done += 1
                return done
            }
            func snapshot() -> [Int: FileInfo] { result }
        }
        let collector = Collector()

        await withTaskGroup(of: (Int, FileInfo?).self) { group in
            var next = 0
            func spawn() {
                guard next < pairs.count else { return }
                let item = pairs[next]
                next += 1
                group.addTask {
                    let info = try? await fileInfo(modID: item.modID, fileID: item.fileID)
                    return (item.fileID, info)
                }
            }
            for _ in 0..<min(maxConcurrent, pairs.count) { spawn() }
            for await (fileID, info) in group {
                let d = await collector.add(fileID, info)
                onProgress?(d, total)
                spawn()
            }
        }
        return await collector.snapshot()
    }

    // MARK: - 内部

    private static func candidateBases() -> [String] {
        var bases: [String] = [mirrorBase]
        // 用户自己在设置里填了官方 key 的话，官方优先
        if !SettingsKeys.curseForgeAPIKeyValue.isEmpty {
            bases.insert(officialBase, at: 0)
        }
        return bases
    }

    private static func query(base: String, modID: Int, fileID: Int) async throws -> FileInfo {
        guard let url = URL(string: "\(base)/mods/\(modID)/files/\(fileID)") else {
            throw LauncherError.cannotWrite("CurseForge 地址非法")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if base == officialBase {
            req.setValue(SettingsKeys.curseForgeAPIKeyValue, forHTTPHeaderField: "x-api-key")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw LauncherError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let fileName = d["fileName"] as? String, !fileName.isEmpty else {
            throw LauncherError.cannotWrite("CurseForge 返回内容里没有文件名")
        }

        // 优先用接口给的 downloadUrl；没有就按 ForgeCDN 规则拼
        var downloadURL: URL?
        if let raw = d["downloadUrl"] as? String, let u = URL(string: raw) {
            downloadURL = u
        } else if let derived = forgeCDNURL(fileID: fileID, fileName: fileName) {
            downloadURL = derived
        }
        guard let downloadURL else {
            throw LauncherError.cannotWrite("CurseForge 没有可用的下载地址：\(fileName)")
        }

        // sha1：官方 hashes 数组里 algo==1 表示 sha1
        var sha1: String?
        if let hashes = d["hashes"] as? [[String: Any]] {
            for h in hashes {
                if let algo = h["algo"] as? Int, algo == 1, let v = h["value"] as? String {
                    sha1 = v
                    break
                }
            }
        }
        return FileInfo(fileName: fileName,
                        downloadURL: downloadURL,
                        sha1: sha1,
                        size: (d["fileLength"] as? NSNumber)?.int64Value)
    }

    /// ForgeCDN 直链规则：files/<fileID / 1000>/<fileID % 1000>/<fileName>
    /// （HMCL 的 CurseManifestFile.url() 也是这么拼的）
    static func forgeCDNURL(fileID: Int, fileName: String) -> URL? {
        URL(string: "https://edge.forgecdn.net/files/\(fileID / 1000)/\(fileID % 1000)/\(fileName)")
    }
}
