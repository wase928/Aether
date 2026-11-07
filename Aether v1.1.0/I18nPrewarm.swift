//
//  I18nPrewarm.swift
//  maccraft
//
//  给「I18nUpdateMod（汉化更新 mod）」预热资源包缓存。
//
//  ## 为什么启动器要管这件事
//
//  该 mod 在**游戏主线程**、ModLauncher 扫描阶段同步下载汉化包，日志只有一行：
//  ```
//  [INFO]: Using fastest url: http://downloader1.meitangdehulu.com:22943/
//  [INFO]: Downloading: http://downloader1.meitangdehulu.com:22943/Minecraft-Mod-Language-Modpack-1-20.zip
//  ```
//  然后窗口不出现、日志不再动。实测这个源 HEAD 秒回、GET 只有 **2 KB/s**
//  （2.1MB 要 18 分钟），用户看到的就是「点开始游戏卡死」。
//
//  ## 它自己的缓存判定（反编译 ResourcePack.isUpToDate 得到的）
//
//  ```java
//  if (!Files.exists(tmpFilePath)) return false;                 // 没缓存 → 下载
//  if (mtime > now - UPDATE_TIME_GAP) return true;               // 1 天内更新过 → 跳过
//  return md5(local).equals(remoteMd5);                          // 否则比对远端 md5
//  ```
//  缓存路径 = `<home>/Library/Application Support/.i18nupdatemod/<targetVersion>/<filename>`。
//
//  所以要让它「永远不联网」，只要保证这些文件**存在且 mtime 是新的**（< 20 小时）。
//  下载走 GitHub release（实测 380 KB/s，比原源快 190 倍），失败就静默跳过 ——
//  mod 自己还会再试一次，不会因为我们失败而变差。
//

import Foundation

nonisolated enum I18nPrewarm {
    /// mod 的缓存根目录（注意是 `~/Library/Application Support`，**不是**启动器的数据目录）。
    static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/.i18nupdatemod", isDirectory: true)
    }

    /// 新鲜度阈值：mod 自身是 1 天，这里留 4 小时余量，避免「刚好过线」时又去慢源。
    private static let freshness: TimeInterval = 20 * 3600

    private static let releaseBase =
        "https://github.com/CFPAOrg/Minecraft-Mod-Language-Package/releases/download/autobuild/"

    // MARK: - 元数据

    private struct Meta: Decodable {
        struct Game: Decodable {
            let gameVersions: String
            let convertFrom: [String]?
        }
        struct Asset: Decodable {
            let targetVersion: String
            let loader: String
            let filename: String
        }
        let games: [Game]?
        let assets: [Asset]?
    }

    /// 一次预热的结果（只用于日志，不参与控制流）。
    struct Outcome: Sendable {
        var downloaded: [String] = []
        var skipped = 0
        var failed: [String] = []
        var note: String?
        var didSomething: Bool { !downloaded.isEmpty || !failed.isEmpty }
    }

    // MARK: - 入口

    /// 启动前调用。找不到 mod / 不需要更新时几乎零开销（一次目录列举 + 一次 stat）。
    @discardableResult
    static func prepareIfNeeded(versionID: String,
                                log: @Sendable (String) -> Void) async -> Outcome {
        var outcome = Outcome()

        let modsDir = Paths.modsDir(versionID)
        guard let mods = try? FileManager.default.contentsOfDirectory(atPath: modsDir.path) else {
            return outcome
        }
        // 只有装了 I18nUpdateMod 才需要管；版本号前缀匹配就够了。
        guard let modFile = mods.first(where: {
            $0.lowercased().hasPrefix("i18nupdatemod") && $0.hasSuffix(".jar")
        }) else { return outcome }

        let jar = modsDir.appendingPathComponent(modFile)
        guard let raw = ZipTool.readEntry(jar, "i18nMetaData.json"),
              let meta = try? JSONDecoder().decode(Meta.self, from: raw),
              let assets = meta.assets, !assets.isEmpty else {
            return outcome
        }

        // 当前实例到底对应哪个 MC 版本：沿继承链取最底层。
        guard let mc = VersionLibrary.baseMinecraftVersion(of: versionID) else { return outcome }
        // mod 的 assets 只分 Forge / Fabric 两类（NeoForge 吃 Forge 那份）。
        let chainIDs = (try? VersionLibrary.resolve(versionID))?.chain ?? []
        let loaderName = chainIDs.contains { $0.lowercased().contains("fabric") } ? "fabric" : "forge"

        // 需要哪些包：当前大版本 + 该版本声明的 convertFrom（mod 会下载它们再合并转换）。
        var wanted = Set<String>()
        let major = String(mc.split(separator: ".").prefix(2).joined(separator: "."))  // 1.20.1 → 1.20
        if assets.contains(where: { $0.targetVersion == major }) { wanted.insert(major) }
        for g in meta.games ?? [] where versionRange(g.gameVersions, contains: mc) {
            for c in g.convertFrom ?? [] { wanted.insert(c) }
        }
        guard !wanted.isEmpty else { return outcome }

        let targets = assets.filter {
            wanted.contains($0.targetVersion) && $0.loader.lowercased() == loaderName
        }
        guard !targets.isEmpty else { return outcome }

        for a in targets {
            let dir = cacheRoot.appendingPathComponent(a.targetVersion, isDirectory: true)
            let dest = dir.appendingPathComponent(a.filename)
            if isFresh(dest) { outcome.skipped += 1; continue }

            // 本地已有（只是过期）就先当种子：拉不到新的时至少还能用它 touch 一下。
            let hadLocal = FileIntegrity.isCompleteArchive(dest)
            do {
                try Paths.ensure(dir)
                try await DownloadManager.downloadCandidates(candidates(for: a.filename),
                                                             kind: .library,
                                                             to: dest,
                                                             sha1: nil,
                                                             timeout: 45)
                guard FileIntegrity.isCompleteArchive(dest) else {
                    throw LauncherError.cannotWrite("\(a.filename) 下载不完整")
                }
                touch(dest)
                outcome.downloaded.append(a.filename)
                log("  汉化包已预置：\(a.filename)")
            } catch {
                if hadLocal {
                    // 下不到新的，但本地那份是完整的：把 mtime 刷新，mod 就不会去慢源重下。
                    touch(dest)
                    outcome.skipped += 1
                    log("  汉化包沿用本地缓存：\(a.filename)（更新失败：\(error.localizedDescription)）")
                } else {
                    outcome.failed.append(a.filename)
                    log("  ⚠ 汉化包预置失败（\(a.filename)）：\(error.localizedDescription)")
                    log("    mod 会自己重试；若启动卡住，多半就是耗在这一步。")
                }
            }
        }

        if outcome.didSomething, outcome.note == nil {
            outcome.note = "汉化包 \(outcome.downloaded.count) 个已更新"
        }
        return outcome
    }

    // MARK: - 辅助

    private static func isFresh(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let mtime = v.contentModificationDate else { return false }
        // 截断的残片不能被当成「新鲜缓存」，否则 mod 拿到坏包会卡在转换阶段。
        guard FileIntegrity.isCompleteArchive(url) else { return false }
        return Date().timeIntervalSince(mtime) < freshness
    }

    /// 候选源：GitHub 原址 + 两个加速镜像（国内直连 GitHub release 经常 502）。
    static func candidates(for filename: String) -> [MirrorCandidate] {
        let direct = releaseBase + filename
        var list: [MirrorCandidate] = []
        if let u = URL(string: direct) { list.append(MirrorCandidate(source: "github", url: u)) }
        for prefix in ["https://ghproxy.net/", "https://gh-proxy.com/", "https://ghfast.top/"] {
            if let u = URL(string: prefix + direct) {
                list.append(MirrorCandidate(source: URL(string: prefix)?.host ?? "proxy", url: u))
            }
        }
        return list
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// 解析 i18nMetaData 里的 `"[1.20,1.20.1]"` 并判断 mc 是否落在区间内。
    static func versionRange(_ expr: String, contains mc: String) -> Bool {
        let body = expr.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
        let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let lo = parts.first, !lo.isEmpty else { return false }
        let hi = parts.count > 1 ? parts[1] : lo
        return VersionCompare.isNewerOrEqual(mc, lo) && VersionCompare.isNewerOrEqual(hi, mc)
    }
}
