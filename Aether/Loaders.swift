//
//  Loaders.swift
//  maccraft
//
//  加载器（Fabric / Quilt / Forge / NeoForge）的版本清单与自动安装。
//
//  实现方式与 PCL / HMCL 一致：
//   · Fabric / Quilt：从 meta 取 `profile/json`，直接落成 `versions/<id>/<id>.json`（继承原版）；
//   · Forge / NeoForge：下载官方 installer jar，执行 `--installClient`，由安装器写版本 JSON 和库。
//  元数据统一走 BMCLAPI 镜像（本机实测官方 maven / neoforged 直连超时）。
//

import Foundation

nonisolated enum Loaders {
    /// 加载器安装的子进度回调。
    /// 用命名结构体而不是元组 —— Swift 不允许元组参数带默认值。
    ///
    /// 语义：`done` 是「当前进行到第几步」（1-based），`fraction` 是「这一步内部完成到哪」（0...1）。
    /// 三个子步（下载安装器 / 预置依赖 / 跑安装器）拼起来，整体进度才是单调递增的，
    /// 不会出现「1/1 就绪 → 0/7 预置依赖」这种回跳。
    struct Progress: Sendable {
        let message: String
        let done: Int
        let total: Int
        var fraction: Double = 0

        /// 加载器安装**内部**的比例（0~1），用于阶段内插值（relay 用）。
        var ratio: Double { Loaders.stageRatio(done: done, total: total, fraction: fraction) }
    }

    /// 加载器安装内部的三子步 → 比例（0~1）。
    ///
    /// 三个子步：1=下载安装器 2=预置依赖 3=跑安装器。
    static func stageRatio(done: Int, total: Int, fraction: Double) -> Double {
        guard total > 0 else { return 0 }
        let step = Double(max(1, min(done, total))) - 1.0   // 当前步之前已完成了几步
        let inner = max(0, min(fraction, 1))
        return (step + inner) / Double(total)
    }

    /// 加载器安装的子步 → **任务整体**百分比（0~1）。
    ///
    /// 前两段不在这里：原版客户端（0%~12%）与 Java 运行时（12%~18%）由调用方负责，
    /// 加载器安装本身占 18%~100%。
    ///
    /// ## 为什么必须有这个函数（进度条抽风的根因）
    ///
    /// 加载器安装有**两个**进度来源：
    ///   · `progress` 回调 —— 按子步推进（来自 `Progress`）
    ///   · `onFile` 回调   —— 按文件推进（来自 `FileProgress`）
    ///
    /// 两者如果各算各的，百分比就会在两个不同的值之间**来回跳**，
    /// 表现就是进度条「抽风」（一会儿 62% 一会儿 76%）。
    /// 必须用同一个函数、同一套分段，算出来的值才会一致。
    static func taskOverall(done: Int, fraction: Double) -> Double {
        let f = max(0, min(fraction, 1))
        switch done {
        case 1:  return 0.18 + 0.10 * f          // 下载安装器  18% ~ 28%
        case 2:  return 0.28 + 0.50 * f          // 预置依赖    28% ~ 78%
        default: return 0.78 + 0.22 * f          // 跑安装器    78% ~ 100%
        }
    }

    // MARK: - 端点

    private static let fabricMeta  = ["https://meta.fabricmc.net",
                                      "https://bmclapi2.bangbang93.com/fabric-meta"]
    private static let quiltMeta   = ["https://meta.quiltmc.org"]
    private static let forgeList   = "https://bmclapi2.bangbang93.com/forge/minecraft/"
    private static let forgePromos = "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json"
    private static let neoList     = "https://bmclapi2.bangbang93.com/neoforge/meta/api/maven/details/releases/net/neoforged/neoforge"
    private static let neoLegacyList = "https://bmclapi2.bangbang93.com/neoforge/meta/api/maven/details/releases/net/neoforged/forge"

    // MARK: - 通用请求

    private static func getJSON(_ url: String, timeout: TimeInterval = 20) async throws -> Any {
        guard let u = URL(string: url) else { throw LauncherError.http(0) }
        let (data, resp) = try await URLSession.shared.data(from: u)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw LauncherError.http(http.statusCode)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Fabric

    static func fabricLoaderVersions(mc: String) async -> [String] {
        for root in fabricMeta {
            if let arr = try? await getJSON("\(root)/v2/versions/loader/\(mc)") as? [[String: Any]] {
                let versions = arr.compactMap { ($0["loader"] as? [String: Any])?["version"] as? String }
                if !versions.isEmpty { return Array(versions.prefix(30)) }
            }
        }
        return []
    }

    static func installFabric(mc: String, loader: String) async throws -> String {
        var lastError: Error?
        for root in fabricMeta {
            do {
                guard let u = URL(string: "\(root)/v2/versions/loader/\(mc)/\(loader)/profile/json") else { continue }
                let (data, resp) = try await URLSession.shared.data(from: u)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw LauncherError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
                }
                // profile 自带 id，如 fabric-loader-0.16.9-1.21.4
                let header = try JSONDecoder().decode(VersionLibrary.VersionHeader.self, from: data)
                let vid = header.id.isEmpty ? "fabric-loader-\(loader)-\(mc)" : header.id
                try VersionLibrary.save(json: data, id: vid)
                return vid
            } catch { lastError = error }
        }
        throw lastError ?? LauncherError.http(0)
    }

    // MARK: - Quilt

    static func quiltLoaderVersions(mc: String) async -> [String] {
        if let arr = try? await getJSON("https://meta.quiltmc.org/v3/versions/loader/\(mc)") as? [[String: Any]] {
            let versions = arr.compactMap { ($0["loader"] as? [String: Any])?["version"] as? String }
            if !versions.isEmpty { return Array(versions.prefix(30)) }
        }
        return []
    }

    static func installQuilt(mc: String, loader: String) async throws -> String {
        guard let u = URL(string: "https://meta.quiltmc.org/v3/versions/loader/\(mc)/\(loader)/profile/json") else {
            throw LauncherError.http(0)
        }
        let (data, resp) = try await URLSession.shared.data(from: u)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw LauncherError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let header = try JSONDecoder().decode(VersionLibrary.VersionHeader.self, from: data)
        let vid = header.id.isEmpty ? "quilt-loader-\(loader)-\(mc)" : header.id
        try VersionLibrary.save(json: data, id: vid)
        return vid
    }

    // MARK: - Forge

    static func forgeVersions(mc: String) async -> [String] {
        if let arr = try? await getJSON(forgeList + mc) as? [[String: Any]] {
            let versions = arr.compactMap { $0["version"] as? String }
            if !versions.isEmpty { return sortDesc(versions) }
        }
        // 兜底：promotions（只有 latest / recommended）
        if let obj = try? await getJSON(forgePromos) as? [String: Any],
           let promos = obj["promos"] as? [String: String] {
            var out: [String] = []
            for key in ["\(mc)-latest", "\(mc)-recommended"] {
                if let v = promos[key], !out.contains(v) { out.append(v) }
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    /// 加载器版本是否已经在本地装好了；返回**实际的版本 id**（可能与传入的不同）。
    /// 重复导入同一个整合包时不必重跑安装器（那要 30~40 秒）。
    ///
    /// 版本目录名有两种形态：
    ///   · `neoforge-21.1.248`  —— NeoForge 常见形态
    ///   · `1.20.1-forge-47.4.28` —— Forge 的 install_profile 写法
    /// 所以除了精确匹配，再扫一遍本地目录找「包含版本号且是 forge/neoforge」的。
    /// 返回 nil 表示需要重新安装。
    static func installedLoaderID(_ versionID: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.versionJSON(versionID).path) { return versionID }

        // 精确匹配不到时，按「目录名里含版本号」再找一次。
        let bare = versionID.lowercased()
            .replacingOccurrences(of: "neoforge-", with: "")
            .replacingOccurrences(of: "forge-", with: "")
        guard let entries = try? fm.contentsOfDirectory(atPath: Paths.versionsDir.path) else { return nil }
        // 优先选最贴近的（名字完全以版本号结尾的）
        var fallback: String?
        for e in entries where !e.hasPrefix("pack-") {
            let low = e.lowercased()
            guard low.contains("forge") else { continue }
            if low.hasSuffix(bare) { return e }          // 精确后缀匹配最可信
            if low.contains(bare), fallback == nil { fallback = e }
        }
        return fallback
    }

    /// 安装 Forge：先确保原版在本地，再跑 installer。
    /// - Parameter progress: (阶段文案, 已完成, 总数) —— 供任务条显示。
    static func installForge(mc: String, version: String, java: URL,
                             log: (@Sendable (String) -> Void)? = nil,
                             progress: (@Sendable (Progress) -> Void)? = nil,
                             onFile: (@Sendable (FileProgress) -> Void)? = nil) async throws -> String {
        let triple = "\(mc)-\(version)"
        let file = "forge-\(triple)-installer.jar"
        let rel = "net/minecraftforge/forge/\(triple)/\(file)"
        let candidates = [
            "https://bmclapi2.bangbang93.com/maven/\(rel)",
            "https://maven.minecraftforge.net/\(rel)",
            "https://files.minecraftforge.net/maven/\(rel)"
        ]
        // 已经装好的同版本直接复用：装一次要 30~40 秒，重复导入时没必要再跑。
        if let existing = installedLoaderID("forge-\(triple)") {
            log?("Forge \(version) 已安装（\(existing)），跳过")
            progress?(Progress(message: "Forge \(version) 已就绪", done: 3, total: 3, fraction: 1))
            return existing
        }
        let jar = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        var lastError: Error?
        progress?(Progress(message: "下载 Forge 安装器", done: 1, total: 3))
        for c in candidates {
            do {
                guard let u = URL(string: c) else { continue }
                let mc = MirrorCandidate(source: "forge", url: u)
                try await DownloadManager.downloadCandidates([mc], kind: .library, to: jar, sha1: nil,
                                                             timeout: 30)
                lastError = nil
                break
            } catch { lastError = error }
        }
        if let lastError { throw lastError }
        progress?(Progress(message: "Forge 安装器就绪", done: 1, total: 3, fraction: 1))

        // 安装器真正写入的版本 id 来自 install_profile.json 的 version 字段
        // （1.20.1 的 Forge 47.x 是 "1.20.1-forge-47.4.28"，不是 "forge-1.20.1-47.4.28"）
        let targetID = profileVersionID(jar) ?? "forge-\(triple)"
        try? FileManager.default.removeItem(at: Paths.versionDir(targetID))
        try prepareLauncherProfiles()
        // 安装器会去 maven.minecraftforge.net 拉依赖（国内直连超时），先用镜像预置好，让它直接跳过下载。
        try await preseedLibraries(installerJar: jar, log: log, progress: progress, onFile: onFile)
        log?("运行 Forge 安装器（\(version)）…")
        progress?(Progress(message: "运行 Forge 安装器", done: 3, total: 3))
        let (code, output) = try await runInstaller(java: java, jar: jar, log: log)
        try? FileManager.default.removeItem(at: jar)
        guard code == 0 else {
            throw LauncherError.cannotWrite("Forge 安装器退出码 \(code)\n\(output.suffix(600))")
        }
        guard FileManager.default.fileExists(atPath: Paths.versionJSON(targetID).path) else {
            throw LauncherError.cannotWrite("安装器没有产出 \(targetID).json\n\(output.suffix(400))")
        }
        progress?(Progress(message: "Forge \(version) 安装完成", done: 3, total: 3, fraction: 1))
        return targetID
    }

    /// install_profile.json 里的 version 字段 = 安装器最终写入的版本目录名。
    static func profileVersionID(_ jar: URL) -> String? {
        guard let data = try? unzipEntry(jar, "install_profile.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    /// 预置依赖时的单文件进度回调（文件名 + 已完成数 + 总数）。
    ///
    /// 为什么要单独一个回调：`preseedLibraries` 一次要下几十个库，
    /// 只报「第几步」的话中间几十秒界面上一动不动 —— 用户看到的���「卡死」。
    /// 这个回调让每个文件完成都能推进一次进度条。
    struct FileProgress: Sendable {
        let name: String
        let done: Int
        let total: Int
        /// 这一步内部的比例（0...1）。
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    // MARK: - NeoForge

    static func neoForgeVersions(mc: String) async -> [String] {
        // NeoForge 版本号 = <mc 次版本>.<mc 修订号>.<build>，例如 1.21.4 -> 21.4.x
        let parts = mc.split(separator: ".").compactMap { Int($0) }
        let prefix: String?
        if parts.count >= 3 { prefix = "\(parts[1]).\(parts[2])." }
        else if parts.count == 2 { prefix = "\(parts[1]).0." }
        else { prefix = nil }

        let endpoint = (mc == "1.20.1") ? neoLegacyList : neoList
        guard let obj = try? await getJSON(endpoint) as? [String: Any],
              let files = obj["files"] as? [[String: Any]] else { return [] }
        let names = files.compactMap { $0["name"] as? String }
        let filtered = prefix.map { p in names.filter { $0.hasPrefix(p) } } ?? names
        return sortDesc(filtered).prefix(40).map { $0 }
    }

    static func installNeoForge(mc: String, version: String, java: URL,
                                log: (@Sendable (String) -> Void)? = nil,
                                progress: (@Sendable (Progress) -> Void)? = nil,
                                onFile: (@Sendable (FileProgress) -> Void)? = nil) async throws -> String {
        let file = "neoforge-\(version)-installer.jar"
        let rel = "net/neoforged/neoforge/\(version)/\(file)"
        let candidates = [
            "https://bmclapi2.bangbang93.com/maven/\(rel)",
            "https://maven.neoforged.net/releases/\(rel)"
        ]
        // 已经装好的同版本直接复用：装一次要 30~40 秒，重复导入时没必要再跑。
        if let existing = installedLoaderID("neoforge-\(version)") {
            log?("NeoForge \(version) 已安装（\(existing)），跳过")
            progress?(Progress(message: "NeoForge \(version) 已就绪", done: 3, total: 3, fraction: 1))
            return existing
        }
        let jar = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        var lastError: Error?
        progress?(Progress(message: "下载 NeoForge 安装器", done: 1, total: 3))
        for c in candidates {
            do {
                guard let u = URL(string: c) else { continue }
                try await DownloadManager.downloadCandidates(
                    [MirrorCandidate(source: "neoforge", url: u)], kind: .library,
                    to: jar, sha1: nil, timeout: 30)
                lastError = nil
                break
            } catch { lastError = error }
        }
        if let lastError { throw lastError }
        progress?(Progress(message: "NeoForge 安装器就绪", done: 1, total: 3, fraction: 1))

        let targetID = profileVersionID(jar) ?? "neoforge-\(version)"
        try? FileManager.default.removeItem(at: Paths.versionDir(targetID))
        try prepareLauncherProfiles()
        try await preseedLibraries(installerJar: jar, log: log, progress: progress, onFile: onFile)
        log?("运行 NeoForge 安装器（\(version)）…")
        progress?(Progress(message: "运行 NeoForge 安装器", done: 3, total: 3))
        let (code, output) = try await runInstaller(java: java, jar: jar, log: log)
        try? FileManager.default.removeItem(at: jar)
        guard code == 0 else {
            // 安装器失败时它会打印 "These libraries failed to download"，
            // 把相关行挑出来，比整段堆栈有用。
            let failed = output.split(separator: "\n")
                .filter { $0.contains("Could not") || $0.contains("failed to download")
                          || $0.contains("DownloadUtils") || $0.contains("NeoForge")
                          || $0.contains("library") || $0.contains("http") }
                .suffix(12)
                .joined(separator: "\n")
            throw LauncherError.cannotWrite("NeoForge 安装器退出码 \(code)\n\(failed)")
        }
        guard FileManager.default.fileExists(atPath: Paths.versionJSON(targetID).path) else {
            throw LauncherError.cannotWrite("安装器没有产出 \(targetID).json\n\(output.suffix(400))")
        }
        progress?(Progress(message: "NeoForge \(version) 安装完成", done: 3, total: 3, fraction: 1))
        return targetID
    }

    // MARK: - 安装器辅助

    /// Forge / NeoForge 安装器要求目录里有 launcher_profiles.json，否则直接拒绝安装。
    static func prepareLauncherProfiles() throws {
        try Paths.ensure(Paths.appSupport)
        try Paths.ensure(Paths.versionsDir)
        let url = Paths.appSupport.appendingPathComponent("launcher_profiles.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let json: [String: Any] = [
            "profiles": [:] as [String: Any],
            "selectedProfile": "",
            "clientToken": "",
            "authenticationDatabase": [:] as [String: Any],
            "launcherVersion": ["name": "Aether", "format": 21],
            "settings": [:] as [String: Any],
            "version": 3
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private static func runInstaller(java: URL, jar: URL, log: (@Sendable (String) -> Void)?) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = java
        process.currentDirectoryURL = Paths.appSupport
        process.arguments = ["-jar", jar.path, "--installClient", Paths.appSupport.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let box = LockedText()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            if let s = String(data: d, encoding: .utf8) { box.append(s) }
        }
        try process.run()

        // 最多等 3 分钟（安装器要下载几百 MB 依赖）
        let deadline = Date().addingTimeInterval(300)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        return (process.terminationStatus, box.value)
    }

    // MARK: - 预置安装器依赖

    private struct InstallProfile: Decodable {
        struct Lib: Decodable {
            let name: String
            let downloads: Downloads?
        }
        struct Downloads: Decodable {
            struct Artifact: Decodable {
                let url: String?
                let path: String?
            }
            let artifact: Artifact?
        }
        let libraries: [Lib]?
        let data: [String: [String: String]]?
    }

    /// 把 install_profile.json 里声明的库 / data 文件全部预置到 libraries/。
    /// 安装器发现文件已在本地就会跳过下载（否则会卡死在 maven.minecraftforge.net）。
    static func preseedLibraries(installerJar: URL,
                                 log: (@Sendable (String) -> Void)? = nil,
                                 progress: (@Sendable (Progress) -> Void)? = nil,
                                 onFile: (@Sendable (FileProgress) -> Void)? = nil) async throws {
        let data = try unzipEntry(installerJar, "install_profile.json")
        let profile = try JSONDecoder().decode(InstallProfile.self, from: data)

        var coords: [(coord: String, url: String?, path: String?)] = []
        for lib in profile.libraries ?? [] {
            coords.append((lib.name, lib.downloads?.artifact?.url, lib.downloads?.artifact?.path))
        }
        for (_, mapping) in profile.data ?? [:] {
            for (_, value) in mapping where value.hasPrefix("[") && value.hasSuffix("]") {
                let coord = String(value.dropFirst().dropLast())
                if coord.contains(":") { coords.append((coord, nil, nil)) }
            }
        }

        var items: [DownloadItem] = []
        var seen = Set<String>()
        for c in coords {
            guard let path = c.path ?? Maven.path(forCoordinate: c.coord) else { continue }
            let local = Paths.librariesDir.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: local.path) { continue }
            if !seen.insert(local.path).inserted { continue }

            var candidates: [MirrorCandidate] = []
            if let raw = c.url, let u = URL(string: raw) {
                candidates.append(contentsOf: Mirror.candidates(for: u, kind: .library))
            }
            // 没有显式地址，或镜像都没覆盖时，按 maven 根逐个试。
            // 顺序很重要：maven.neoforged.net 在部分网络下直接超时，
            // 所以把实测可用的 bmclapi 与 neoforged.forgecdn.net 放在前面。
            for root in ["https://bmclapi2.bangbang93.com/maven/",
                         "https://neoforged.forgecdn.net/releases/",
                         "https://maven.neoforged.net/releases/",
                         "https://maven.minecraftforge.net/",
                         "https://maven.fabricmc.net/"] {
                if let u = URL(string: root + path),
                   !candidates.contains(where: { $0.url == u }) {
                    candidates.append(MirrorCandidate(source: Mirror.host(for: root), url: u))
                }
            }
            items.append(DownloadItem(urls: candidates, destination: local, sha1: nil, kind: .library))
        }

        guard !items.isEmpty else { return }
        let total = items.count
        log?("预置安装器依赖 \(total) 个（走镜像，避免安装器自己下载卡住）…")
        progress?(Progress(message: "预置安装器依赖 \(total) 个", done: 2, total: 3))
        let counter = ProgressCounter(total: total)
        // onFile 是同步回调，拿不到 actor 的 done —— 用一个带锁的计数器自己数。
        // 关键：**两条进度来源必须共用这一个计数器**。
        // 之前 monitor 读 counter.done、onFile 读自己的 DoneBox，
        // 并发下两者的瞬时值会差几个百分点 → 进度条来回跳（抽风）。
        final class DoneBox: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
            var current: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let doneBox = DoneBox()
        // 把每个依赖的完成情况也推到任务条上：这一步通常有几十个文件，
        // 没有进度的话用户会以为卡住了。
        let mon: Task<Void, Never>? = progress.map { cb in
            Task { @Sendable in
                while !Task.isCancelled {
                    let d = doneBox.current
                    if d > 0 {
                        cb(Progress(message: "预置安装器依赖 \(d)/\(total)",
                                    done: 2, total: 3,
                                    fraction: Double(d) / Double(total)))
                    }
                    if d >= total { break }
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { break }
                }
            }
        }
        defer { mon?.cancel() }
        try await DownloadManager.downloadMany(items,
                                               counter: counter,
                                               maxConcurrent: 12,
                                               tolerateFailures: true,
                                               onFile: { name, ok in
                                                   let n = doneBox.next()
                                                   onFile?(FileProgress(name: name, done: n, total: total))
                                               })
        mon?.cancel()
        progress?(Progress(message: "安装器依赖就绪", done: 2, total: 3, fraction: 1))
    }

    private static func unzipEntry(_ jar: URL, _ name: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", jar.path, name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw LauncherError.cannotWrite("无法读取安装器内的 \(name)")
        }
        return data
    }

    private static func sortDesc(_ versions: [String]) -> [String] {
        versions.sorted { a, b in
            let pa = a.split(separator: ".").map { Int($0) ?? 0 }
            let pb = b.split(separator: ".").map { Int($0) ?? 0 }
            for i in 0..<max(pa.count, pb.count) {
                let x = i < pa.count ? pa[i] : 0
                let y = i < pb.count ? pb[i] : 0
                if x != y { return x > y }
            }
            return a > b
        }
    }
}

/// 线程安全的字符串累积器（安装器输出）。
nonisolated final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        if text.count < 200_000 { text += s }
    }
    var value: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}
