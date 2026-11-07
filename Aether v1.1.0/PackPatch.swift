//
//  PackPatch.swift
//  maccraft
//
//  整合包「缺失文件清单」补全。
//
//  ## 为什么会有这个东西
//
//  BMC 系列这类整合包会把一部分补丁 mod **从 manifest.json 里摘出去**，
//  改成在 `overrides/config/missing_mods_checker.json` 里列一份「启动时自己下」的清单
//  （作者用来绕开 CurseForge 的再分发限制）。
//
//  游戏侧由 mod `MissingModsChecker` 消费这份清单，它的执行时机极早 ——
//  `ITransformationService` 构造阶段，也就是 ModLauncher 刚起、还没开始扫 mod 的时候：
//
//  ```
//  NeoBootstrap.<init> → MissingModsChecker.launch → MissingModsWindow.open
//      → Object.wait()      // 主线程在这里无限等待
//  ```
//
//  于是：
//  · 日志停在 `EARLYDISPLAY: GL info: ...` 之后再无输出，看起来就是「卡死」
//  · CLI / 无窗口环境没人能点，主线程永远不返回
//  · 用户点关闭窗口时它走 `Runtime.halt(1)`，**直接退出游戏**，不是继续加载
//
//  对启动器来说唯一正确的做法是：在起 JVM 之前把清单补齐，让 mod 走
//  「All mods found!」分支 —— 那个窗口根本不会出现。
//
//  ## 怎么补
//
//  清单里每项都带 `url`（`.../minecraft/mc-mods/<slug>/download/<fileID>`），
//  ForgeCDN 的直链规则是 `files/<fileID/1000>/<fileID%1000>/<fileName>`，
//  文件名就是清单里的 `pattern`。所以不需要任何 API key，直接拼直链并发下载。
//

import Foundation

nonisolated enum PackPatch {

    /// 清单里的一项。
    struct Entry: Sendable {
        let name: String
        /// 目标文件名（清单里的 `pattern`，和 CDN 上的文件名一致）
        let fileName: String
        /// CurseForge 页面地址，用来取 fileID
        let url: String
        /// mods / resourcepacks / datapacks
        let folder: String

        /// `.../download/5010620` → 5010620
        var fileID: Int? {
            guard let r = url.range(of: "/download/", options: .backwards) else { return nil }
            let digits = url[r.upperBound...].prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
    }

    struct Outcome: Sendable {
        var checked = 0
        var missing: [Entry] = []
        var downloaded: [String] = []
        var failed: [String] = []
    }

    static let manifestRelativePath = "config/missing_mods_checker.json"

    static func manifestURL(profileDir: URL) -> URL {
        profileDir.appendingPathComponent(manifestRelativePath)
    }

    /// 解析清单。文件不存在 / 格式不对都返回空数组（不是所有整合包都有这份清单）。
    static func entries(profileDir: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: manifestURL(profileDir: profileDir)),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { d in
            guard let file = d["pattern"] as? String,
                  !file.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Entry(name: (d["displayName"] as? String) ?? file,
                         fileName: file,
                         url: (d["url"] as? String) ?? "",
                         folder: (d["destination"] as? String) ?? "mods")
        }
    }

    /// 只读检查：清单里哪些文件在实例里不存在。
    static func pending(profileDir: URL) -> Outcome {
        let all = entries(profileDir: profileDir)
        var outcome = Outcome(checked: all.count)
        let fm = FileManager.default
        for e in all {
            let dest = profileDir.appendingPathComponent(e.folder, isDirectory: true)
                .appendingPathComponent(e.fileName)
            if fm.fileExists(atPath: dest.path) { continue }
            outcome.missing.append(e)
        }
        return outcome
    }

    /// 补齐清单里缺的文件。
    ///
    /// - Note: 下载失败不抛错 —— 补不齐顶多回到「游戏弹窗要你手点」，
    ///   比让整个启动流程失败要好。
    static func repair(profileDir: URL,
                       log: @escaping @Sendable (String) -> Void,
                       progress: @escaping @Sendable (Int, Int) -> Void) async -> Outcome {
        var outcome = pending(profileDir: profileDir)
        guard !outcome.missing.isEmpty else { return outcome }

        log("⚠ 整合包缺少 \(outcome.missing.count) 个文件（作者放在 \(manifestRelativePath) 清单里）")
        log("  游戏内的 MissingModsChecker 会在启动最早期弹窗等它，缺一个就进不去。")
        log("  正在自动补齐（只需一次，之后启动不再等）…")
        progress(0, outcome.checked)

        var items: [DownloadItem] = []
        for e in outcome.missing {
            guard let fid = e.fileID else {
                outcome.failed.append(e.fileName)
                log("  ⚠ \(e.name)：清单里没有可解析的 fileID，跳过")
                continue
            }
            // 文件名里有 `+`、空格、`'`：必须百分号编码，且 `+` 要显式编成 %2B
            // （path 里的 `+` 是字面量，CDN 上会 404）。
            var cs = CharacterSet.urlPathAllowed
            cs.remove(charactersIn: "+")
            let encoded = e.fileName.addingPercentEncoding(withAllowedCharacters: cs) ?? e.fileName
            let tail = "files/\(fid / 1000)/\(fid % 1000)/\(encoded)"
            var cands: [MirrorCandidate] = []
            if let u = URL(string: "https://edge.forgecdn.net/" + tail) {
                cands.append(MirrorCandidate(source: "forgecdn", url: u))
            }
            if let u = URL(string: "https://mediafilez.forgecdn.net/" + tail) {
                cands.append(MirrorCandidate(source: "mediafilez", url: u))
            }
            guard !cands.isEmpty else {
                outcome.failed.append(e.fileName)
                continue
            }
            let dir = profileDir.appendingPathComponent(e.folder, isDirectory: true)
            try? Paths.ensure(dir)
            items.append(DownloadItem(urls: cands,
                                      destination: dir.appendingPathComponent(e.fileName),
                                      sha1: nil, size: nil, kind: .other))
        }

        guard !items.isEmpty else { return outcome }

        let total = outcome.checked
        let counter = ProgressCounter(total: items.count)
        let tally = Tally()
        do {
            try await DownloadManager.downloadMany(items, counter: counter,
                                                  maxConcurrent: 8,
                                                  tolerateFailures: true,
                                                  onFallback: { m in log("    " + m) },
                                                  onFile: { file, ok in
                _ = file
                _ = ok
                Task {
                    let done = await tally.bump()
                    progress(done, total)
                }
            })
        } catch {
            log("  ⚠ 补齐过程出错：\(error.localizedDescription)")
        }

        // 用磁盘现状判定结果，比信任下载回调可靠（并发 + 重试路径下回调可能少几次）。
        let after = pending(profileDir: profileDir)
        outcome.downloaded = outcome.missing
            .filter { e in !after.missing.contains { $0.fileName == e.fileName } }
            .map(\.fileName)
        outcome.failed = after.missing.map(\.fileName)

        if outcome.failed.isEmpty {
            log("  ✔ 已补齐 \(outcome.downloaded.count) 个文件")
        } else {
            log("  ⚠ 仍有 \(outcome.failed.count) 个未补齐：\(outcome.failed.prefix(3).joined(separator: "、"))"
                + (outcome.failed.count > 3 ? " 等" : ""))
            log("    启动后游戏内可能弹窗要求手动下载。")
        }
        return outcome
    }

    /// 下载回调里做原子计数（回调散在多个并发任务上）。
    private actor Tally {
        private var done = 0
        func bump() -> Int {
            done += 1
            return done
        }
    }
}
