//
//  Utilities.swift
//  maccraft
//
//  通用工具：路径、版本比较、离线 UUID、设置项。
//

import Foundation
import CryptoKit

nonisolated enum Paths {
    nonisolated(unsafe) static let fileManager = FileManager.default

    /// 所有游戏数据统一存放在 ~/Library/Application Support/maccraft 下，
    /// 与官方 .minecraft 隔离，避免互相干扰。
    static var appSupport: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("maccraft", isDirectory: true)
    }
    static var versionsDir: URL { appSupport.appendingPathComponent("versions", isDirectory: true) }
    static var librariesDir: URL { appSupport.appendingPathComponent("libraries", isDirectory: true) }
    static var assetsDir: URL { appSupport.appendingPathComponent("assets", isDirectory: true) }
    /// 资源索引目录：Minecraft 通过 `--assetIndex <id>` 读取 `<assets>/indexes/<id>.json`，
    /// 缺这个文件会卡在启动画面并刷 "Missing sound for event"。
    static var assetsIndexesDir: URL { assetsDir.appendingPathComponent("indexes", isDirectory: true) }
    static var assetsObjectsDir: URL { assetsDir.appendingPathComponent("objects", isDirectory: true) }
    static var logsDir: URL { appSupport.appendingPathComponent("logs", isDirectory: true) }

    static func assetIndexFile(_ id: String) -> URL {
        assetsIndexesDir.appendingPathComponent("\(id).json")
    }
    static var runtimesDir: URL { appSupport.appendingPathComponent("runtimes", isDirectory: true) }
    /// 版本清单本地缓存，启动时可秒开、离线可用。
    static var manifestCache: URL { appSupport.appendingPathComponent("manifest.cache.json") }

    static func versionDir(_ id: String) -> URL { versionsDir.appendingPathComponent(id, isDirectory: true) }
    static func versionJSON(_ id: String) -> URL { versionDir(id).appendingPathComponent("\(id).json") }
    static func modsDir(_ id: String) -> URL { versionDir(id).appendingPathComponent("mods", isDirectory: true) }
    static var shaderPacksDir: URL { appSupport.appendingPathComponent("shaderpacks", isDirectory: true) }
    static var resourcePacksDir: URL { appSupport.appendingPathComponent("resourcepacks", isDirectory: true) }
    static func clientJar(_ id: String) -> URL { versionDir(id).appendingPathComponent("\(id).jar") }
    static func nativesDir(_ id: String) -> URL { versionDir(id).appendingPathComponent("natives", isDirectory: true) }

    static func ensure(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// 把 Maven 坐标 (group:artifact:version[:classifier]) 转换成仓库相对路径。
nonisolated enum Maven {
    /// 支持 `group:artifact:version:classifier@ext` 这种写法（Forge 的 install_profile 里常见）。
    static func path(forCoordinate coord: String) -> String? {
        var body = coord
        var ext = "jar"
        if let at = body.lastIndex(of: "@") {
            ext = String(body[body.index(after: at)...])
            body = String(body[..<at])
        }
        let parts = body.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        let group = parts[0].replacingOccurrences(of: ".", with: "/")
        let artifact = parts[1]
        let version = parts[2]
        let classifier = parts.count > 3 ? parts[3] : nil
        let file = classifier.map { "\(artifact)-\(version)-\($0).\(ext)" } ?? "\(artifact)-\(version).\(ext)"
        return "\(group)/\(artifact)/\(version)/\(file)"
    }

    static func path(for name: String) -> String {
        let parts = name.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return name }
        let group = parts[0].replacingOccurrences(of: ".", with: "/")
        let artifact = parts[1]
        let version = parts[2]
        let fileName: String
        if parts.count > 3 {
            fileName = "\(artifact)-\(version)-\(parts[3]).jar"
        } else {
            fileName = "\(artifact)-\(version).jar"
        }
        return "\(group)/\(artifact)/\(version)/\(fileName)"
    }
}

/// Minecraft 版本号数值比较（"1.20.5" > "1.20.4"，"1.10" > "1.9"）。
nonisolated enum VersionCompare {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.components(separatedBy: ".").compactMap { Int($0) }
        let pb = b.components(separatedBy: ".").compactMap { Int($0) }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let xa = pa.count > i ? pa[i] : 0
            let xb = pb.count > i ? pb[i] : 0
            if xa != xb { return xa < xb ? .orderedAscending : .orderedDescending }
        }
        return a.compare(b)
    }
    static func isNewerOrEqual(_ a: String, _ b: String) -> Bool {
        compare(a, b) != .orderedAscending
    }
}

/// 离线账号：Minecraft 离线 UUID 为 name 的 UUID v3（MD5）。
nonisolated enum OfflineAccount {
    static func uuid(for name: String) -> String {
        let data = ("OfflinePlayer:" + name).data(using: .utf8)!
        var bytes = Array(Insecure.MD5.hash(data: data))
        bytes[6] = (bytes[6] & 0x0F) | 0x30   // version 3
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let hex = bytes.map { String(format: "%02hhx", $0) }.joined()
        func take(_ from: Int, _ len: Int) -> String {
            let s = hex.index(hex.startIndex, offsetBy: from)
            let e = hex.index(s, offsetBy: len)
            return String(hex[s..<e])
        }
        return "\(take(0, 8))-\(take(8, 4))-\(take(12, 4))-\(take(16, 4))-\(take(20, 12))"
    }
}

/// 本地持久化的设置项（与 Settings 视图共享）。
nonisolated enum SettingsKeys {
    static let username = "aether.username"
    static let memoryMB = "aether.memoryMB"
    static let resolutionEnabled = "aether.resolutionEnabled"
    static let width = "aether.width"
    static let height = "aether.height"
    /// 手动指定的 JDK 路径（JDK Home 或 java 可执行文件），为空则自动探测/下载。
    static let javaHome = "aether.javaHome"
    /// 下载源：official / bmclapi（默认 BMCLAPI，国内更快；可在设置里改回官方）。
    static let downloadSource = "aether.downloadSource"

    static var usernameValue: String {
        UserDefaults.standard.string(forKey: username) ?? "Player"
    }
    static var memoryMBValue: Int {
        let v = UserDefaults.standard.integer(forKey: memoryMB)
        return v == 0 ? 4096 : v
    }
    static var resolutionEnabledValue: Bool {
        UserDefaults.standard.bool(forKey: resolutionEnabled)
    }
    static var widthValue: Int {
        let v = UserDefaults.standard.integer(forKey: width)
        return v == 0 ? 1280 : v
    }
    static var heightValue: Int {
        let v = UserDefaults.standard.integer(forKey: height)
        return v == 0 ? 720 : v
    }
    static var javaHomeValue: String {
        let v = UserDefaults.standard.string(forKey: javaHome) ?? ""
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// CurseForge 官方 API Key（可留空——默认走免 key 的 mcimirror 代理）。
    static let curseForgeAPIKey = "aether.curseforgeAPIKey"
    static var curseForgeAPIKeyValue: String {
        (UserDefaults.standard.string(forKey: curseForgeAPIKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HMCL jar 的路径（借用它的登录模块刷新令牌，留空则自动扫描「下载 / 文档 / 桌面」）。
    static let hmclJarPath = "aether.hmclJarPath"
    static var hmclJarPathValue: String {
        (UserDefaults.standard.string(forKey: hmclJarPath) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 微软登录用的 Azure 客户端 ID（留空则用内置默认值）。
    static let microsoftClientID = "aether.microsoftClientID"
    static var microsoftClientIDValue: String {
        (UserDefaults.standard.string(forKey: microsoftClientID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 下载源偏好：auto（实测最快，默认）/ mirror（镜像优先）/ official（仅官方）。
    static var downloadSourceValue: DownloadSource {
        guard let raw = UserDefaults.standard.string(forKey: downloadSource) else { return .auto }
        // 兼容旧版本存下的 "bmclapi"：直接升到「自动（实测最快）」，
        // 否则老用户会卡在「固定 BMCLAPI 顺序」上继续被慢节点拖死。
        switch raw {
        case "bmclapi":  return .auto
        case "official": return .official
        default:         return DownloadSource(rawValue: raw) ?? .auto
        }
    }
}

/// 同步执行命令行工具并捕获输出（stdout + stderr）。
/// 用于探测本机 Java：`java -version`、`/usr/libexec/java_home -V` 等。
nonisolated enum Shell {
    static func run(_ executable: String, _ args: [String], maxLen: Int = 16_384) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var text = ""
        if let d = try? out.fileHandleForReading.readToEnd(), let s = String(data: d, encoding: .utf8) { text += s }
        if let d = try? err.fileHandleForReading.readToEnd(), let s = String(data: d, encoding: .utf8) { text += s }
        return String(text.prefix(maxLen))
    }
}
