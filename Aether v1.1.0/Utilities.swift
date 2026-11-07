//
//  Utilities.swift
//  maccraft
//
//  通用工具：路径、版本比较、离线 UUID、设置项。
//

import Foundation
import AppKit
import CryptoKit

/// 默认窗口尺寸：跟随屏幕，而不是写死一个数字。
///
/// ## 为什么不能写死 1280×720
///
/// Minecraft 的 `--width/--height` 收的单位是**点**，和 `NSScreen.frame` 一致
/// （2560×1600 的 Retina 屏报 1280×800 点）。写死 1280×720 时：
/// · 外接大屏上会开成一个小方块；
/// · 小屏（1280×800）上又几乎顶满，标题栏还被菜单栏挤下去。
/// · 更糟的是之前「自定义分辨率」默认关，等于不传 `--width/--height`，
///   游戏走原版兜底的 854×480 —— 再配上整合包的 `guiScale:3`，界面巨大又糊。
///
/// 所以默认值改成按屏幕算：16:9 尽量贴满，超出可视高度就按高度反推。
nonisolated enum DisplayDefaults {
    /// 屏幕逻辑尺寸（点）。
    ///
    /// 用 CoreGraphics 而不是 NSScreen：NSScreen 要在主线程拿，而 CLI 自检
    /// 是「主线程卡在 semaphore 上等结果」的结构 —— 一旦 await MainActor.run
    /// 就死锁（实测直接 SIGTERM）。CGDisplayBounds 没有这个限制，
    /// 报的单位也是点（1440×900 的屏就报 1440×900，不是 2560×1600）。
    static func screenPoints() -> (w: Int, h: Int)? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success, count > 0 else { return nil }
        let main = ids.first { $0 == CGMainDisplayID() } ?? ids[0]
        let b = CGDisplayBounds(main)
        guard b.width > 0, b.height > 0 else { return nil }
        return (Int(b.width.rounded()), Int(b.height.rounded()))
    }

    /// 默认窗口：16:9，占屏幕宽度 80%。
    ///
    /// 不留满屏是有意的：满宽时窗口贴着菜单栏、Dock 和屏幕边缘，
    /// 看着像「卡住了没全屏」，拖动也难受。80% 正好是一眼能看出是窗口、
    /// 又足够大的比例（1440×900 的屏 → 1152×648）。
    static func windowSize() -> (w: Int, h: Int) {
        guard let (sw, sh) = screenPoints() else { return (1280, 720) }
        var w = Int(Double(sw) * 0.8)
        var h = Int((Double(w) * 9.0 / 16.0).rounded())
        // 高度别顶到菜单栏/标题栏外面
        let maxH = max(480, Int(Double(sh) * 0.85))
        if h > maxH {
            h = maxH
            w = Int((Double(h) * 16.0 / 9.0).rounded())
        }
        // 对齐偶数，避免 Retina 2x 下的半像素
        w = max(640, (w / 2) * 2)
        h = max(480, (h / 2) * 2)
        return (w, h)
    }

    /// 一行摘要，给设置界面和日志用。
    static func summary() -> String {
        let (w, h) = windowSize()
        return "\(w)×\(h)"
    }
}

nonisolated enum Paths {
    nonisolated(unsafe) static let fileManager = FileManager.default
    /// 所有游戏数据统一存放在 ~/Library/Application Support/maccraft 下，
    /// 与官方 .minecraft 隔离，避免互相干扰。
    /// 调试 / 自检可以用 `AETHER_DATA_DIR=/tmp/xxx` 指到临时目录，不碰真实数据。
    static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["AETHER_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("maccraft", isDirectory: true)
    }
    // MARK: - 存储布局（实例 / 核心分离）

    /// 版本核心（原版 + Forge/Fabric/NeoForge/Quilt 加载器）真正的落盘位置：
    /// `meta/versions/<id>/`。**永远不进版本管理列表** —— 它是依赖，不是可游玩的实例。
    static var metaDir: URL { appSupport.appendingPathComponent("meta", isDirectory: true) }
    static var metaVersionsDir: URL { metaDir.appendingPathComponent("versions", isDirectory: true) }

    /// 可游玩的实例（整合包 / 手动装的原版档）：`profiles/<id>/`。
    /// 版本管理列表**只扫这个目录** —— 一个整合包就只多一个入口，不会再冒出多余的 forge 客户端。
    static var profilesDir: URL { appSupport.appendingPathComponent("profiles", isDirectory: true) }

    /// 旧版布局的 `versions/`。迁移后它是一条指向 `meta/versions` 的软链，
    /// 这样 Forge / NeoForge 安装器（会把 `--installClient` 目录下的 `versions/` 当安装目标）
    /// 仍然能正常工作，而文件实际落在 `meta/versions`。
    static var legacyVersionsDir: URL { appSupport.appendingPathComponent("versions", isDirectory: true) }

    /// 核心目录（只放核心，不查实例）。
    static func coreDir(_ id: String) -> URL { metaVersionsDir.appendingPathComponent(id, isDirectory: true) }
    /// 实例目录（只放实例，不查核心）。
    static func profileDir(_ id: String) -> URL { profilesDir.appendingPathComponent(id, isDirectory: true) }

    /// 统一的版本目录解析：实例优先 → 核心 → 默认实例目录（新建实例的落点）。
    ///
    /// 为什么「实例优先」：同一个 id 可能既是原版核心（`meta/versions/1.20.1`）
    /// 又是它的可玩实例（`profiles/1.20.1`）。这里是「以版本 id 找目录」的通用入口，
    /// 游戏目录 / mods / natives 都该指向实例；而解析继承父版本时走 `parentVersionDir`（核心优先）。
    static func versionDir(_ id: String) -> URL {
        let p = profileDir(id)
        if fileManager.fileExists(atPath: p.path) { return p }
        let c = coreDir(id)
        if fileManager.fileExists(atPath: c.path) { return c }
        return p
    }
    /// 继承父版本（核心）的目录：核心优先，兜底实例（兼容迁移前的旧数据）。
    static func parentVersionDir(_ id: String) -> URL {
        let c = coreDir(id)
        if fileManager.fileExists(atPath: c.path) { return c }
        return profileDir(id)
    }

    static var versionsDir: URL { metaVersionsDir }
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

    static func versionJSON(_ id: String) -> URL { versionDir(id).appendingPathComponent("\(id).json") }
    /// 继承父版本（核心）的 JSON：核心优先。
    static func parentVersionJSON(_ id: String) -> URL { parentVersionDir(id).appendingPathComponent("\(id).json") }
    static func modsDir(_ id: String) -> URL { versionDir(id).appendingPathComponent("mods", isDirectory: true) }
    static var shaderPacksDir: URL { appSupport.appendingPathComponent("shaderpacks", isDirectory: true) }
    static var resourcePacksDir: URL { appSupport.appendingPathComponent("resourcepacks", isDirectory: true) }
    /// client jar 永远在「核心」里（实例只放 mods / 存档，壳 JSON 继承核心）。
    /// 所以这里核心优先 —— 原版实例 `profiles/1.20.1` 和核心 `meta/versions/1.20.1` 同名，
    /// 用实例优先会指向一个不存在的 jar。
    static func clientJar(_ id: String) -> URL { parentVersionDir(id).appendingPathComponent("\(id).jar") }
    static func nativesDir(_ id: String) -> URL { versionDir(id).appendingPathComponent("natives", isDirectory: true) }

    /// 整合包「拉取的原版核心」以前放这里（隐藏目录 + `versions/<mc>` 软链）。
    /// 新布局把核心统一放进 `meta/versions/`，这个目录只在迁移旧数据时还用得到。
    static var packCoresDir: URL { appSupport.appendingPathComponent(".packcores", isDirectory: true) }
    static func packCoreDir(_ id: String) -> URL { packCoresDir.appendingPathComponent(id, isDirectory: true) }

    /// 一个路径是不是目录（软链按目标算）。
    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }
    /// 一个路径本身是不是软链（不跟随）。
    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

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

    /// 物理内存（MB）。
    static var physicalMemoryMB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    }

    /// **实际生效**的堆上限。
    ///
    /// 堆不是越大越好：给到接近物理内存时，macOS 会开始压缩内存页/换页，
    /// GC 扫描的对象图也更大。实测 16G 的 M1 给 `-Xmx16384M` 启动 BMC4，
    /// 进程的 system 时间从 30 秒级涨到 167 秒（全是缺页/压缩），启动慢一倍。
    ///
    /// 所以这里夹到物理内存的 60%：16G 机器 → 约 9.8G，8G 机器 → 约 4.8G。
    /// 用户设得更大也不会被采纳，但设置界面还会显示他填的值（不悄悄改数据）。
    static var effectiveMemoryMB: Int {
        let cap = max(2048, Int(Double(physicalMemoryMB) * 0.6))
        return min(memoryMBValue, cap)
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

    // MARK: - 性能调优

    /// JVM 调优总开关。
    static let jvmTuningEnabled = "aether.jvmTuningEnabled"
    static var jvmTuningEnabledValue: Bool {
        // 默认开 —— 对绝大多数用户是净收益（GC 停顿是 MC 帧率的主要瓶颈）
        UserDefaults.standard.object(forKey: jvmTuningEnabled) as? Bool ?? true
    }

    /// GC 选择（rawValue，空 = 按 Java 版本自动）。
    static let jvmGC = "aether.jvmGC"
    static var jvmGCValue: JVMOptimize.GCKind? {
        guard let raw = UserDefaults.standard.string(forKey: jvmGC) else { return nil }
        return JVMOptimize.GCKind(rawValue: raw)
    }

    /// 激进调优（大页 + JIT 预热）。
    static let jvmTuningAggressive = "aether.jvmTuningAggressive"
    static var jvmTuningAggressiveValue: Bool {
        UserDefaults.standard.object(forKey: jvmTuningAggressive) as? Bool ?? false
    }

    /// 汇总成一份配置传给 LaunchService。
    static var jvmTuningValue: JVMOptimize.Config {
        JVMOptimize.Config(enabled: jvmTuningEnabledValue,
                           gc: jvmGCValue,
                           aggressive: jvmTuningAggressiveValue)
    }

    /// Vulkan 加速开关（装 MoltenVK + 让游戏走 Vulkan）。
    static let vulkanEnabled = "aether.vulkanEnabled"
    static var vulkanEnabledValue: Bool {
        UserDefaults.standard.object(forKey: vulkanEnabled) as? Bool ?? false
    }
}

/// 已落盘文件「到底下完了没有」的快检。
///
/// ## 为什么必须有这一层
///
/// `FileManager.fileExists` 只能回答「路径上有没有东西」，回答不了「东西是不是好的」。
/// 下载被强退 / 磁盘写满 / 安装器被杀时，目标路径上会留下一个**截断的 jar**，
/// 它照样通过 fileExists，于是被当成「已存在，跳过」，最后塞进 classpath：
/// ```
/// java.lang.module.FindException: Error reading .../securejarhandler-2.1.10.jar
/// Caused by: java.util.zip.ZipException: zip END header not found
/// ```
/// 用户只看到一条库路径 + 一个 JVM 内部异常，完全联想不到「上次没下完」。
///
/// 这里用 zip 的 EOCD（End Of Central Directory，`PK\x05\x06`）做判据：
/// 结构完整的 zip 一定以「EOCD + 注释」结尾，而截断文件一定没有。
/// 只读尾部 64 KiB，一个 300MB 的客户端 jar 也只要一次 pread，开销可以忽略。
nonisolated enum FileIntegrity {
    /// zip 尾部窗口：22 字节 EOCD + 最长 65535 字节注释。
    private static let eocdWindow: UInt64 = 65_557

    static func byteSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// 文件在、非空、且 zip 结构完整（走到 EOCD 且注释长度与文件尾吻合）。
    static func isCompleteArchive(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size >= 22 else { return false }
        let start = size > eocdWindow ? size - eocdWindow : 0
        guard (try? fh.seek(toOffset: start)) != nil,
              let tail = try? fh.readToEnd() else { return false }
        let bytes = [UInt8](tail)
        guard bytes.count >= 22 else { return false }

        // 从尾部往前找 EOCD 签名；找到后还要核对「注释长度 + 22 == 剩余字节数」，
        // 否则压缩包内容里偶然出现的 PK\x05\x06 会被误判成结构完整。
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                let commentLen = Int(bytes[i + 20]) | (Int(bytes[i + 21]) << 8)
                if i + 22 + commentLen == bytes.count { return true }
            }
            i -= 1
        }
        return false
    }

    /// 路径在、大小对得上、且（可选）zip 完整。
    /// - Parameters:
    ///   - expectedSize: Mojang / maven 元数据里声明的字节数，`nil` 或非正数则跳过比对。
    ///   - archive: 该文件是不是 jar / zip（是才做结构检查）。
    static func isUsable(_ url: URL, expectedSize: Int64?, archive: Bool = true) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let actual = byteSize(url)
        guard actual > 0 else { return false }
        if let want = expectedSize, want > 0, actual != want { return false }
        if archive { return isCompleteArchive(url) }
        return true
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
