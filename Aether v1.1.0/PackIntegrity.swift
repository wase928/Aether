//
//  PackIntegrity.swift
//  maccraft
//
//  整合包实例的「文件清单契约」。
//
//  ## 为什么需要
//
//  导入 mrpack 时，`modrinth.index.json` 里列了 340 个文件，但下载是并发的：
//  某个大文件（mowziesmobs 35MB、aether-redux 29MB）偶发断流 / 超时 / 校验不过时，
//  `tolerateFailures` 会把它**静默跳过**，导入照样报成功。
//
//  后果非常隐蔽：
//    · 实例看起来「导入完成」，实际少 7 个 mod
//    · 启动后 Forge 报 `5 errors have occurred during loading`，
//      或者更糟 —— MissingModsChecker 在更早期就弹窗阻塞
//    · 玩家只会觉得「这个启动器下的包有问题」
//
//  所以导入时把 index.files 落一份到实例里（`.aether-files.json`），
//  之后每次启动前拿它核对一遍：缺谁补谁。文件被误删、磁盘抽风、上次没下完，
//  都能自愈，行为是幂等的（齐全时只是一次 stat，几十毫秒）。
//

import Foundation

nonisolated enum PackIntegrity {

    struct Item: Codable, Sendable {
        /// 相对实例根目录的路径，如 `mods/xxx.jar`
        let path: String
        let url: String
        let sha1: String?
        let size: Int64?
    }

    static let manifestName = ".aether-files.json"

    static func manifestURL(profileDir: URL) -> URL {
        profileDir.appendingPathComponent(manifestName)
    }

    static func save(_ items: [Item], profileDir: URL) {
        guard !items.isEmpty else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(items) else { return }
        try? Paths.ensure(profileDir)
        try? data.write(to: manifestURL(profileDir: profileDir), options: .atomic)
    }

    static func load(profileDir: URL) -> [Item] {
        guard let data = try? Data(contentsOf: manifestURL(profileDir: profileDir)),
              let items = try? JSONDecoder().decode([Item].self, from: data)
        else { return [] }
        return items
    }

    /// 只读核对：清单里哪些文件不在盘上（或大小明显不对）。
    static func missing(profileDir: URL) -> [Item] {
        let fm = FileManager.default
        return load(profileDir: profileDir).filter { it in
            let dest = profileDir.appendingPathComponent(it.path)
            guard let attrs = try? fm.attributesOfItem(atPath: dest.path),
                  let n = attrs[.size] as? Int64 else { return true }
            // 大小对不上就当归零重下：半截文件比缺文件更坑（zip 能开、内容缺）。
            if let want = it.size, want > 0, n != want { return true }
            return false
        }
    }

    /// 补齐缺失项。
    /// - Returns: (补上的数量, 仍然缺的)
    @discardableResult
    static func repair(profileDir: URL,
                       log: @escaping @Sendable (String) -> Void,
                       progress: @escaping @Sendable (Int, Int) -> Void) async -> (fixed: Int, remaining: [String]) {
        let gap = missing(profileDir: profileDir)
        guard !gap.isEmpty else { return (0, []) }

        log("⚠ 整合包清单里有 \(gap.count) 个文件缺失或不完整")
        for it in gap.prefix(6) { log("   · \(it.path)") }
        if gap.count > 6 { log("   · …另有 \(gap.count - 6) 个") }

        var items: [DownloadItem] = []
        for it in gap {
            guard let primary = URL(string: it.url) else { continue }
            var cands = [MirrorCandidate(source: "modrinth", url: primary)]
            // 官方 CDN 优先（实测 4MB/s 级），mcimirror 只在官方失败时兜底。
            if let m = URL(string: it.url.replacingOccurrences(of: "https://cdn.modrinth.com",
                                                              with: "https://mod.mcimirror.top")) {
                cands.append(MirrorCandidate(source: "mcimirror", url: m))
            }
            let dest = profileDir.appendingPathComponent(it.path)
            try? Paths.ensure(dest.deletingLastPathComponent())
            items.append(DownloadItem(urls: cands, destination: dest,
                                      sha1: it.sha1, size: it.size, kind: .other))
        }
        guard !items.isEmpty else { return (0, gap.map(\.path)) }

        let total = items.count
        let counter = ProgressCounter(total: total)
        do {
            try await DownloadManager.downloadMany(items, counter: counter,
                                                  maxConcurrent: 6,
                                                  tolerateFailures: true,
                                                  onFallback: { m in log("    " + m) },
                                                  onFile: { file, ok in
                _ = file
                _ = ok
                Task {
                    let d = await counter.done
                    progress(d, total)
                }
            })
        } catch {
            log("  ⚠ 补齐过程出错：\(error.localizedDescription)")
        }

        // 用磁盘现状复核，不信任下载回调。
        let after = missing(profileDir: profileDir)
        let remaining = after.map(\.path)
        let fixed = gap.count - remaining.count
        if remaining.isEmpty {
            log("  ✔ 已补齐 \(fixed) 个文件")
        } else {
            log("  ⚠ 仍缺 \(remaining.count) 个：\(remaining.prefix(3).joined(separator: "、"))"
                + (remaining.count > 3 ? " 等" : ""))
        }
        return (fixed, remaining)
    }
}
