//
//  VulkanSupport.swift
//  maccraft
//
//  Vulkan 加速支持（macOS）。
//
//  ## 背景：为什么 macOS 需要这一层
//
//  macOS **没有原生 Vulkan**。Vulkan 的官方 macOS 实现是 **MoltenVK**
//  （KhronosGroup 维护，Apache-2.0）—— 它把 Vulkan 调用实时转译成 Metal。
//
//  所以 macOS 上跑 Vulkan 游戏的链路是：
//
//      游戏（Vulkan API）
//        → Vulkan Loader（libvulkan.dylib）
//          → ICD（MoltenVK_icd.json）
//            → libMoltenVK.dylib
//              → Metal → Apple GPU
//
//  ## 为什么不用「自己写一个转译层」
//
//  MoltenVK 已经是 Khronos 官方维护的高性能实现（Apple 自己也用它）。
//  重写一遍不可能比它快，而且 Vulkan→Metal 的真正难点在
//  **深度/模板格式映射、MSAA resolve、descriptor set 缓存、同步语义** ——
//  这些坑 MoltenVK 踩了很多年。
//
//  本模块做的事因此是：**把整条链路自动配好**，而不是造一个新的转译器。
//
//  ## 三个常见坑（都在下面处理了）
//
//  ① **ICD 软链失效**：Homebrew 的 `molten-vk` 把 ICD 装在
//     `etc/vulkan/icd.d/`，而 Vulkan loader 默认只找
//     `/usr/local/share/vulkan/icd.d` 与 `~/.local/share/vulkan/icd.d`，
//     Homebrew 路径（`/opt/homebrew`）**不在 loader 的搜索路径里** → 必须手动指。
//
//  ② **ICD 里的相对路径**：Homebrew 生成的 JSON 用
//     `"library_path": "../../../lib/libMoltenVK.dylib"`（相对 ICD 文件），
//     但实际 dylib 在 `opt/molten-vk/lib/` —— 相对路径解析会失败，
//     必须改成绝对路径。
//
//  ③ **游戏需要 VulkanMod**：Minecraft 官方到 1.21.x 为止
//     默认仍是 OpenGL 渲染器（官方 Vulkan 在 2026-02 宣布，
//     要等 Vibrant Visuals 的正式版）。要现在就用 Vulkan，
//     得装社区的 **VulkanMod**（Fabric / Quilt）。
//

import Foundation
import AppKit

// MARK: - 探测结果

/// Vulkan 环境探测结果。
nonisolated struct VulkanStatus: Equatable {
    /// MoltenVK 的 dylib 是否存在。
    var moltenVKInstalled: Bool = false
    /// Vulkan loader 是否存在（libvulkan.dylib）。
    var loaderInstalled: Bool = false
    /// ICD 清单是否就绪（loader 能找到驱动）。
    var icdReady: Bool = false
    /// 探测到的 GPU 名（走 Vulkan 拿到的，跟系统显示的一致）。
    var gpuName: String? = nil
    /// Vulkan API 版本，如 "1.3.304"。
    var apiVersion: String? = nil
    /// ICD 文件路径。
    var icdPath: String? = nil

    /// 能不能真的跑 Vulkan。
    var usable: Bool { icdReady && loaderInstalled }

    /// 给界面显示的一句话状态。
    var summary: String {
        if !loaderInstalled && !moltenVKInstalled {
            return "未安装 —— 需要先装 MoltenVK"
        }
        if !moltenVKInstalled {
            return "有 Vulkan loader，但缺 MoltenVK 转译层"
        }
        if !icdReady {
            return "MoltenVK 已装，但 ICD 没配好（点「自动修复」）"
        }
        if let gpu = gpuName {
            return "就绪 · \(gpu) · Vulkan \(apiVersion ?? "?")"
        }
        return "就绪"
    }
}

// MARK: - 探测与修复

nonisolated enum VulkanSupport {

    // MARK: 常量

    /// Vulkan loader 会搜索的 ICD 目录（按优先级）。
    /// loader 实际搜索：系统级 `/usr/local/share`、用户级 `~/.local/share`，
    /// 以及 `VK_ICD_FILENAMES` / `VK_DRIVER_FILES` 指定的路径。
    private static let icdSearchDirs = [
        "~/Library/Application Support/maccraft/vulkan/icd.d",  // Aether 自己管的一份
        "~/Library/Application Support/vulkan/icd.d",
        "/usr/local/share/vulkan/icd.d",
        "/opt/homebrew/share/vulkan/icd.d",
    ]

    /// Homebrew 的 MoltenVK 安装位置（arm64）。
    private static let brewMoltenVK = "/opt/homebrew/opt/molten-vk"
    /// Homebrew 的 MoltenVK 安装位置（Intel）。
    private static let brewMoltenVKIntel = "/usr/local/opt/molten-vk"

    // MARK: 探测

    /// 探测当前 Vulkan 环境。
    static func detect() -> VulkanStatus {
        var st = VulkanStatus()

        // loader
        st.loaderInstalled = loaderPaths().contains { FileManager.default.fileExists(atPath: $0) }

        // MoltenVK dylib
        let dylib = moltenVKDylibPath()
        st.moltenVKInstalled = dylib != nil

        // ICD：先看自己管的目录，再看系统里已存在的
        var icdCandidates: [URL] = []
        for dir in icdSearchDirs {
            let d = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            let f = d.appendingPathComponent("MoltenVK_icd.json")
            if FileManager.default.fileExists(atPath: f.path) { icdCandidates.append(f) }
        }
        // 也看看环境变量指定的
        if let env = ProcessInfo.processInfo.environment["VK_ICD_FILENAMES"] {
            for p in env.split(separator: ":") {
                let f = URL(fileURLWithPath: String(p))
                if FileManager.default.fileExists(atPath: f.path) { icdCandidates.append(f) }
            }
        }

        st.icdPath = icdCandidates.first?.path
        st.icdReady = !(icdCandidates.isEmpty) && st.moltenVKInstalled && st.loaderInstalled

        return st
    }

    /// Vulkan loader 的可能位置。
    private static func loaderPaths() -> [String] {
        [
            "/opt/homebrew/lib/libvulkan.dylib",
            "/opt/homebrew/lib/libvulkan.1.dylib",
            "/usr/local/lib/libvulkan.dylib",
            "/usr/local/lib/libvulkan.1.dylib",
        ]
    }

    /// 找 MoltenVK 的 dylib（Homebrew 装的，或用户手动放的）。
    static func moltenVKDylibPath() -> String? {
        var candidates = [
            "\(brewMoltenVK)/lib/libMoltenVK.dylib",
            "\(brewMoltenVKIntel)/lib/libMoltenVK.dylib",
        ]
        // Aether 自己目录下的一份（如果用户手动放过）
        let own = Paths.appSupport.appendingPathComponent("vulkan/libMoltenVK.dylib")
        candidates.insert(own.path, at: 0)
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: 修复 ICD

    /// 修好 ICD 配置，让 Vulkan loader 能找到 MoltenVK。
    ///
    /// 做两件事：
    /// ① 在 Aether 自己的目录写一份 ICD（`library_path` 用**绝对路径**，
    ///    绕开 Homebrew 那个相对路径解析失败的问题）；
    /// ② 返回需要注入的环境变量（`VK_ICD_FILENAMES`），
    ///    启动游戏时由 LaunchService 设进子进程环境。
    @discardableResult
    static func repairICD() -> (ok: Bool, message: String) {
        guard let dylib = moltenVKDylibPath() else {
            return (false, "没找到 libMoltenVK.dylib —— 请先安装 MoltenVK")
        }
        let dir = Paths.appSupport.appendingPathComponent("vulkan/icd.d", isDirectory: true)
        do {
            try Paths.ensure(dir)
            let json = """
            {
                "file_format_version" : "1.0.0",
                "ICD": {
                    "library_path": "\(dylib)",
                    "api_version" : "1.4.0",
                    "is_portability_driver" : true
                }
            }
            """
            let f = dir.appendingPathComponent("MoltenVK_icd.json")
            try json.write(to: f, atomically: true, encoding: .utf8)
            return (true, "ICD 已写入 \(f.path)")
        } catch {
            return (false, "写入 ICD 失败：\(error.localizedDescription)")
        }
    }

    /// 启动游戏时该设的环境变量。
    ///
    /// 设 `VK_ICD_FILENAMES` 指向 Aether 自己那份 ICD，
    /// 这样不依赖系统 loader 的搜索路径（Homebrew 路径本来就不在搜索范围里）。
    static func environmentOverrides() -> [String: String] {
        var env: [String: String] = [:]
        let ownICD = Paths.appSupport
            .appendingPathComponent("vulkan/icd.d/MoltenVK_icd.json")
        if FileManager.default.fileExists(atPath: ownICD.path) {
            env["VK_ICD_FILENAMES"] = ownICD.path
            // 新版 loader 用这个变量名，老的用上面那个，两个都设最稳
            env["VK_DRIVER_FILES"] = ownICD.path
        }
        // MoltenVK 特有的调优：portability driver 默认会做一些保守的兼容处理，
        // 关掉能省一点开销（Apple Silicon 上不需要）
        env["MVK_CONFIG_DEFAULT_VENDOR_ID"] = env["MVK_CONFIG_DEFAULT_VENDOR_ID"] ?? "0x106b"
        return env
    }

    // MARK: VulkanMod

    /// VulkanMod 的 Modrinth 项目 slug。
    static let vulkanModSlug = "vulkanmod"

    /// VulkanMod 的 Modrinth 项目 ID（`/project/vulkanmod` 查出来的）。
    ///
    /// 固定用 ID 而不是全文搜索 —— 搜 "vulkanmod" 会匹配到
    /// 「Smooth Motion Blur」这种名字里带 v-u-l-k-a-n 的无关 mod。
    static let vulkanModProjectID = "JYQhtZtO"

    /// 当前版本有没有装 VulkanMod。
    static func hasVulkanMod(versionID: String) -> Bool {
        let dir = Paths.modsDir(versionID)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.contains { $0.lowercased().contains("vulkanmod") && $0.hasSuffix(".jar") }
    }

    /// 这个版本能不能装 VulkanMod（需要 Fabric 或 Quilt 加载器）。
    ///
    /// 判据用已安装列表里的 `loader` 字段 —— 它由版本 id 与原始 JSON 推断而来
    /// （`VersionLibrary.detectLoader`），比只看 mainClass 可靠。
    static func supportsVulkanMod(versionID: String) -> Bool {
        guard let inst = VersionLibrary.scan().first(where: { $0.id == versionID }) else { return false }
        return inst.loader == .fabric || inst.loader == .quilt
    }

    /// 一键安装 VulkanMod 到指定实例。
    ///
    /// 流程：搜 Modrinth → 挑兼容当前 MC 版本与加载器的最新版 → 装到 mods 目录。
    ///
    /// - Returns: (成功, 提示信息)
    static func installVulkanMod(versionID: String) async -> (ok: Bool, message: String) {
        // ① 前置检查
        guard supportsVulkanMod(versionID: versionID) else {
            return (false, "VulkanMod 只能装在 Fabric / Quilt 实例上（当前实例不支持）")
        }
        if hasVulkanMod(versionID: versionID) {
            return (true, "VulkanMod 已安装")
        }
        // ② 找实例的真实 MC 版本号与加载器
        //
        // ⚠️ 不能用实例 id（整合包实例叫 "pack-xxx"），
        //    也不能用 `baseVersion`（那是 inheritsFrom，对 Fabric 常为 nil）。
        //    正确做法是沿继承链取最底层 —— `VersionLibrary.baseMinecraftVersion`。
        guard let inst = VersionLibrary.scan().first(where: { $0.id == versionID }) else {
            return (false, "找不到实例 \(versionID)")
        }
        let loader = inst.loader
        let mcVersion = VersionLibrary.baseMinecraftVersion(of: versionID) ?? versionID
        guard mcVersion != versionID || loader != .vanilla else {
            return (false, "读不出实例的 MC 版本号")
        }

        do {
            // ③ 查适配当前 MC 版本的 VulkanMod
            //
            // ⚠️ 不用 `Modrinth.versions(mcVersion:)` ——
            //    它有「查不到就退回不限制版本」的兜底，会把**不兼容**的版本也带回来。
            //    这里要求严格命中 game_versions。
            let versions = try await Modrinth.versions(projectID: vulkanModProjectID,
                                                        mcVersion: mcVersion,
                                                        loader: loader)
            guard let pick = pickBestVulkanMod(versions, mcVersion: mcVersion) else {
                return (false, "VulkanMod 没有适配 MC \(mcVersion) 的版本"
                        + "（Modrinth 上最新只到 26.1.2；MC 26.3 要等 VulkanMod 更新）")
            }
            // ④ 装
            let url = try await Modrinth.install(pick, type: .mod, versionID: versionID)
            return (true, "VulkanMod 已安装：\(url.lastPathComponent)")
        } catch {
            return (false, "安装 VulkanMod 失败：\(error.localizedDescription)")
        }
    }

    /// 从候选版本里挑一个最合适的。
    ///
    /// 优先顺序：正式版 > 实验版；版本号大的优先。
    ///
    /// ## 版本匹配必须严格
    ///
    /// 早期用 `hasPrefix` 宽松匹配（"26.1".hasPrefix("26") 成立），
    /// 结果会把**不兼容的 MC 版本**当成兼容 —— 比如 MC 26.3 装上只支持 26.1 的
    /// VulkanMod，运行时才炸。
    ///
    /// 所以：**必须精确命中 game_versions 列表**。
    /// 实测（2026-11）：VulkanMod 最新只到 26.1.2，**没有** 26.3 的版本 ——
    /// 这时候应该老实说「没有适配版本」，而不是硬塞一个。
    private static func pickBestVulkanMod(_ versions: [ModrinthVersion], mcVersion: String) -> ModrinthVersion? {
        // 精确匹配 game_versions
        let compatible = versions.filter { $0.game_versions.contains(mcVersion) }
        let pool = compatible.isEmpty ? [] : compatible
        guard !pool.isEmpty else { return nil }
        // 非实验版优先（版本号里带 "experimental" 的往后排）
        return pool.min { a, b in
            let aExp = a.version_number.lowercased().contains("experimental") ? 1 : 0
            let bExp = b.version_number.lowercased().contains("experimental") ? 1 : 0
            if aExp != bExp { return aExp < bExp }
            // 同为正式版：发布日期新的优先（比字符串比较靠谱）
            return a.date_published > b.date_published
        }
    }
}

// MARK: - MoltenVK 安装

/// 从 Homebrew 装 MoltenVK。
///
/// 用 `brew install` 而不是直接下 tar —— 因为 Homebrew 已经把
/// 路径、签名、依赖都处理好了，而且 brew 装的东西升级方便。
///
/// 注意：`brew install` 在受限环境里可能因为沙箱失败，
/// 那时给用户明确的手动指令，不在这里硬刚。
enum MoltenVKInstaller {

    /// MoltenVK 是否已安装（brew 或手动）。
    static func isInstalled() -> Bool {
        VulkanSupport.moltenVKDylibPath() != nil
    }

    /// 执行安装。返回 (成功, 提示信息)。
    @MainActor
    static func install() async -> (ok: Bool, message: String) {
        if isInstalled() {
            return (true, "MoltenVK 已安装")
        }
        // brew 在 /opt/homebrew/bin 或 /usr/local/bin
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let brew else {
            return (false, "找不到 Homebrew。请到 https://brew.sh 安装后重试，或手动装 MoltenVK。")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brew)
        proc.arguments = ["install", "molten-vk"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (false, "启动 brew 失败：\(error.localizedDescription)")
        }
        // 读输出（避免管道缓冲满导致卡死）
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let out = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus == 0, isInstalled() {
            let fix = VulkanSupport.repairICD()
            return (true, "MoltenVK 安装完成。\(fix.message)")
        }
        // 失败时把关键行摘出来给用户看
        let key = out.split(separator: "\n")
            .filter { $0.contains("Error") || $0.contains("error") || $0.contains("✘") }
            .prefix(3).joined(separator: "\n")
        return (false, "brew install 失败（退出码 \(proc.terminationStatus)）。\(key)")
    }
}
