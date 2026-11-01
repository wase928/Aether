//
//  JavaManager.swift
//  maccraft
//
//  Java 运行时策略：
//   1) 优先使用用户在设置里手动指定的 JDK；
//   2) 其次探测本机已安装的 JDK（系统目录 / 用户目录 / /usr/libexec/java_home）；
//   3) 都没有才从 Adoptium 下载并解包（带超时与进度，避免卡死）。
//

import Foundation

nonisolated enum JavaManager {
    /// 根据版本要求选择 JDK 大版本：
    /// 优先使用版本 JSON 中的 javaVersion.majorVersion；缺失时按经验回退。
    /// - Parameter hint: 加载器版本的 id 里没有原版号（如 forge-1.12.2-14.23.5.2860），
    ///   需要传基础版本号来做判断。
    static func requiredJavaMajor(for details: VersionDetails, hint: String? = nil) -> Int {
        if let jv = details.javaVersion {
            return jv.majorVersion
        }
        let id = hint ?? details.id
        // 从 "forge-1.20.1-47.2.0" / "fabric-loader-0.16.9-1.21.4" 里抠出 1.x.y
        let mc = extractMCVersion(from: id) ?? id
        if mc.hasPrefix("1.7") || mc.hasPrefix("1.8") || mc.hasPrefix("1.12") {
            return 8
        }
        if VersionCompare.isNewerOrEqual(mc, "1.20.5") {
            return 21
        }
        if VersionCompare.isNewerOrEqual(mc, "1.18") {
            return 17
        }
        return 16
    }

    /// 从任意版本 id 里提取形如 1.20.1 的 Minecraft 版本号。
    static func extractMCVersion(from id: String) -> String? {
        let pattern = #"1\.\d{1,2}(\.\d{1,2})?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(id.startIndex..., in: id)
        guard let m = re.firstMatch(in: id, range: range),
              let r = Range(m.range, in: id) else { return nil }
        return String(id[r])
    }

    // MARK: 探测

    /// 列出本机已安装的全部 JDK 的 bin/java 路径（去重）。
    static func listLocalJVMs() -> [URL] {
        var result: [URL] = []
        let roots: [URL] = [
            URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Java/JavaVirtualMachines")
        ]
        for root in roots {
            guard let subs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for sub in subs where sub.pathExtension == "jdk" || sub.pathExtension == "jre" {
                let java = sub.appendingPathComponent("Contents/Home/bin/java")
                if FileManager.default.fileExists(atPath: java.path) { result.append(java) }
            }
        }
        if let out = Shell.run("/usr/libexec/java_home", ["-V"]) {
            for line in out.split(whereSeparator: \.isNewline) {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.hasSuffix("/Contents/Home") {
                    let java = URL(fileURLWithPath: s).appendingPathComponent("bin/java")
                    if FileManager.default.fileExists(atPath: java.path), !result.contains(java) {
                        result.append(java)
                    }
                }
            }
        }
        return result
    }

    /// 解析某个 java 可执行文件的 major 版本（运行 `java -version`）。
    static func majorVersion(of java: URL) -> Int? {
        guard let out = Shell.run(java.path, ["-version"]) else { return nil }
        guard let range = out.range(of: "version \"") else { return nil }
        let token = out[range.upperBound...].prefix(while: { $0 != "\"" })
        let parts = token.split(separator: ".")
        guard let first = Int(parts[0]) else { return nil }
        if first == 1, parts.count > 1, let second = Int(parts[1]) {
            return second == 0 ? 8 : second
        }
        return first
    }

    /// 探测本地匹配 major 的 JDK；找不到返回 nil。
    static func detectLocalJava(major: Int) -> URL? {
        // 1) 手动指定优先（兼容三种常见布局：java 二进制 / JDK Home / *.jdk 根目录）
        let manual = SettingsKeys.javaHomeValue
        if !manual.isEmpty {
            let base = URL(fileURLWithPath: manual)
            let candidates: [URL] = [
                base,
                base.appendingPathComponent("bin/java"),
                base.appendingPathComponent("Contents/Home/bin/java")
            ]
            for c in candidates {
                var cand = c
                if cand.lastPathComponent != "java" {
                    cand = cand.appendingPathComponent("bin/java")
                }
                if FileManager.default.fileExists(atPath: cand.path),
                   let v = majorVersion(of: cand), v == major {
                    return cand
                }
            }
        }
        // 2) 扫描本机 JVM
        for java in listLocalJVMs() {
            if let v = majorVersion(of: java), v == major { return java }
        }
        return nil
    }

    // MARK: 获取可用 Java

    /// 返回可用的 java 可执行文件 URL。
    /// 本地优先；缺失时下载 Adoptium Temurin。
    ///
    /// 下载源顺序：**清华 TUNA 镜像 → 官方 api.adoptium.net**。
    /// 官方接口会 307 跳转到 GitHub CDN，国内直连常见 100~500 KB/s 甚至直接超时；
    /// TUNA 实测 15.5 MB/s（200MB 约 13 秒），快两个数量级。
    static func javaExecutable(major: Int,
                               progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        if let local = detectLocalJava(major: major) {
            return local
        }

        let dir = Paths.runtimesDir.appendingPathComponent("temurin-\(major)", isDirectory: true)
        let existing = findJava(in: dir)
        if FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        try Paths.ensure(dir)

        let archive = dir.appendingPathComponent("jdk.tar.gz")
        try? FileManager.default.removeItem(at: archive)

        var candidates: [MirrorCandidate] = []
        if let tuna = await tunaArchiveURL(major: major) {
            candidates.append(MirrorCandidate(source: "tuna", url: tuna))
        }
        let api = URL(string: "https://api.adoptium.net/v3/binary/latest/\(major)/ga/mac/aarch64/jdk/hotspot/normal/eclipse")!
        candidates.append(MirrorCandidate(source: "adoptium", url: api))

        try await DownloadManager.downloadCandidates(candidates, kind: .other, to: archive,
                                                     sha1: nil, timeout: 30, progress: progress)

        try await untar(archive, into: dir)
        let found = findJava(in: dir)
        guard FileManager.default.fileExists(atPath: found.path) else { throw LauncherError.javaUnavailable }
        // 清掉隔离属性，避免首次运行时被 Gatekeeper 拦
        _ = Shell.run("/usr/bin/xattr", ["-cr", dir.path])
        try? FileManager.default.removeItem(at: archive)
        return found
    }

    /// 在清华 TUNA 的 Adoptium 镜像里找某 major 最新的 macOS arm64 包。
    /// 目录形如 /Adoptium/21/jdk/aarch64/mac/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz
    static func tunaArchiveURL(major: Int) async -> URL? {
        let base = "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/\(major)/jdk/aarch64/mac/"
        guard let index = URL(string: base) else { return nil }
        var req = URLRequest(url: index)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("maccraft/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            FileHandle.standardError.write(Data("[tuna] 请求失败：\(error)\n".utf8))
            return nil
        }
        guard let html = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("[tuna] 解码失败，\(data.count) 字节\n".utf8))
            return nil
        }

        let pattern = "OpenJDK\(major)U-jdk_aarch64_mac_hotspot_[0-9._]+\\.tar\\.gz"
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            FileHandle.standardError.write(Data("[tuna] 正则构造失败：\(pattern)\n".utf8))
            return nil
        }
        let names = re.matches(in: html, range: NSRange(html.startIndex..., in: html))
            .compactMap { Range($0.range, in: html).map { String(html[$0]) } }
        guard let newest = names.max(by: { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }) else {
            FileHandle.standardError.write(Data("[tuna] 页面 \(data.count) 字节，但没匹配到包名\n".utf8))
            return nil
        }
        return URL(string: base + newest)
    }

    /// 从文件名里抠出数字序列做排序键（21.0.13_9 → [21,0,13,9]）。
    private static func versionKey(_ name: String) -> [Int] {
        let digits = name.compactMap { $0.isNumber ? $0 : " " }
        return String(digits).split(separator: " ").compactMap { Int($0) }
    }

    /// 非阻塞解包（terminationHandler 回调，不阻塞主线程）。
    private static func untar(_ archive: URL, into dir: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", dir.path]
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: LauncherError.javaUnavailable)
                }
            }
            do { try process.run() }
            catch { cont.resume(throwing: error) }
        }
    }

    /// 在解包目录中查找 bin/java（Adoptium macOS JDK 布局为 jdk-*/Contents/Home/bin/java）。
    private static func findJava(in dir: URL) -> URL {
        if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "java" &&
                   fileURL.pathComponents.contains("bin") {
                    return fileURL
                }
            }
        }
        return dir.appendingPathComponent("Contents/Home/bin/java")
    }
}
