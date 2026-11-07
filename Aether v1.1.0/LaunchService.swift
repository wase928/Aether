//
//  LaunchService.swift
//  maccraft
//
//  根据版本元数据构造 Java 启动参数，并提供原生库解包工具。
//

import Foundation

nonisolated struct LaunchService {
    struct Plan {
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL
        /// 额外注入的环境变量（Vulkan ICD 路径等）。
        var environment: [String: String] = [:]
    }

    /// 构造完整的 java 启动参数。
    static func plan(details: VersionDetails,
                     javaExecutable: URL,
                     username: String,
                     memoryMB: Int,
                     resolution: (width: Int, height: Int)?,
                     gameDir: URL,
                     clientJar: URL,
                     librariesDir: URL,
                     nativesDir: URL,
                     classpath: String,
                     assetsRoot: URL,
                     assetsIndexName: String,
                     account: MinecraftAccount? = nil,
                     authlibInjectorJar: URL? = nil,
                     javaMajor: Int = 21,
                     jvmTuning: JVMOptimize.Config = .default) -> Plan {
        // 有正版账号就用 MSA 的 uuid / token，否则走离线模式
        let username = account?.name ?? username
        let uuid = account?.uuid ?? OfflineAccount.uuid(for: username)
        let accessToken = account?.accessToken ?? UUID().uuidString
        let clientId = UUID().uuidString
        // 外置登录（authlib-injector）走 mojang 类型：认证由 injector 在 JVM 内接管
        let isYggdrasil = account?.kind == .yggdrasil
        let userType = (account == nil || isYggdrasil) ? "mojang" : "msa"
        let launcherName = "Aether"
        let launcherVersion = "1.0"

        let features: [String: Bool] = [
            "is_demo_user": false,
            "has_custom_resolution": resolution != nil,
            "has_quick_plays_support": false,
            "is_quick_play_singleplayer": false,
            "is_quick_play_multiplayer": false,
            "is_quick_play_realms": false,
        ]

        func substitute(_ template: String) -> String {
            var s = template
            let map: [String: String] = [
                "${auth_player_name}": username,
                "${auth_uuid}": uuid,
                "${auth_access_token}": accessToken,
                "${auth_session}": accessToken,
                "${auth_xuid}": "0",
                "${clientid}": clientId,
                "${user_type}": userType,
                "${user_properties}": "{}",
                "${version_name}": details.id,
                "${version_type}": details.type,
                "${assets_root}": assetsRoot.path,
                "${game_assets}": assetsRoot.path,
                "${assets_index_name}": assetsIndexName,
                "${game_directory}": gameDir.path,
                "${natives_directory}": nativesDir.path,
                "${library_directory}": librariesDir.path,
                "${classpath}": classpath,
                // NeoForge / Forge 的 module path 参数里会写 ${classpath_separator}，
                // 不替换的话整串 jar 会被拼成一个超长文件名 → File name too long。
                "${classpath_separator}": ":" ,
                "${launcher_name}": launcherName,
                "${launcher_version}": launcherVersion,
                // HMCL `DefaultLauncher.java:637`：
                //   pair("${primary_jar_name}", FileUtils.getName(instance.getInstanceJarFile()))
                // 即 primary jar 的**文件名**（如 `1.21.1.jar`）。
                // BootstrapLauncher 0.1.17+ 用它来把原版 jar 从模块层里排除。
                "${primary_jar_name}": clientJar.lastPathComponent,
                // HMCL `DefaultLauncher.java:627`：primary jar 的绝对路径。
                "${primary_jar}": clientJar.path,
            ]
            for (k, v) in map where s.contains(k) {
                s = s.replacingOccurrences(of: k, with: v)
            }
            if let (w, h) = resolution {
                s = s.replacingOccurrences(of: "${resolution_width}", with: "\(w)")
                s = s.replacingOccurrences(of: "${resolution_height}", with: "\(h)")
            }
            return s
        }

        // ---- JVM 参数 ----
        var jvm: [String] = []
        if let arguments = details.arguments {
            for arg in arguments.jvm where arg.allowed(features: features) {
                jvm.append(contentsOf: arg.values.map(substitute))
            }
        } else {
            jvm = ["-Djava.library.path=\(nativesDir.path)", "-cp", classpath]
        }

        // ---- BootstrapLauncher ignoreList 修复（照抄 HMCL）----
        //
        // HMCL `LaunchManifestNormalizer.repairBootstrapLauncher`：
        //   bootstraplauncher 0.1.17+ 只按「文件名」匹配 ignoreList，
        //   所以只要把 primary jar 的文件名加进 ignoreList，原版混淆 jar
        //   就不会进模块层 —— 否则会和 NeoForge 的 srg jar（模块 `minecraft`）
        //   撞包：
        //   java.lang.module.ResolutionException: Modules _1._21._1 and minecraft
        //     export package net.minecraft.server to module xxx
        //
        // NeoForge 的 jvm 参数原本是 `-DignoreList=client-extra,${version_name}.jar`，
        // 而 ${version_name} 是实例 id（整合包实例是 `pack-xxx`），
        // 跟客户端 jar 的文件名（`1.21.1.jar`）根本不是一个东西。
        if isBootstrapLauncher(details.mainClass) {
            for i in jvm.indices {
                guard jvm[i].hasPrefix("-DignoreList=") else { continue }
                let values = String(jvm[i].dropFirst("-DignoreList=".count))
                if !values.split(separator: ",").contains(where: { $0 == clientJar.lastPathComponent }) {
                    jvm[i] += "," + clientJar.lastPathComponent
                }
            }
        }

        // 堆内存（放在最前，不影响 -cp / 主类位置）
        jvm.insert("-Xmx\(memoryMB)M", at: 0)
        jvm.insert("-Xms\(max(512, memoryMB / 2))M", at: 0)

        // ---- JVM 调优（GC / 大页 / JIT 预热）----
        //
        // MC 的帧率瓶颈大部分不在 GPU，在 GC 停顿 ——
        // 每 tick 产生大量短命对象，默认 G1GC 的年轻代回收会把帧时间打成锯齿。
        // 这里按 Java 版本注入合适的 GC 参数。
        //
        // 注意：版本 JSON 自带的 -XX: 参数优先（用户自己配过就不重复加）。
        //
        // `AETHER_GC=g1|zgc|parallel|shenandoah|off` 供 CLI 基准测试覆盖 GC 选择
        // —— 直接往参数里追加 `-XX:+UseG1GC` 是行不通的：和默认的 `-XX:+UseZGC`
        // 同时存在时 HotSpot 会报 "Multiple garbage collectors selected" 起不来。
        var tuning = jvmTuning
        if let raw = ProcessInfo.processInfo.environment["AETHER_GC"]?.lowercased() {
            switch raw {
            case "off": tuning.enabled = false
            case "g1": tuning.gc = .g1
            case "zgc": tuning.gc = .zgc
            case "shenandoah": tuning.gc = .shenandoah
            case "parallel": tuning.gc = .parallel
            default: break
            }
        }
        if tuning.enabled {
            let versionArgs = details.arguments?.jvm.flatMap { $0.values } ?? []
            if !JVMOptimize.hasCustomGCFlags(versionArguments: versionArgs) {
                // GC 要**实测**这个 JVM 支不支持 —— Shenandoah 是 OpenJDK 特有的，
                // Oracle JDK 不带（用户选了就会起不来）。探测不到就按版本号保守选。
                let gc = JVMOptimize.resolveGC(preferred: tuning.gc,
                                               javaMajor: javaMajor,
                                               javaExecutable: javaExecutable)
                let gcArgs = JVMOptimize.arguments(major: javaMajor,
                                                  memoryMB: memoryMB,
                                                  gc: gc,
                                                  aggressive: tuning.aggressive)
                // 插在 -Xmx/-Xms 之后（索引 2），保持 -Xmx 仍在最前
                jvm.insert(contentsOf: gcArgs, at: min(2, jvm.count))
            }
        }

        // ---- 网络超时（启动期最大的一块「假卡死」）----
        //
        // Java 的 HttpURLConnection 默认**没有**连接/读取超时，等于无限等。
        // 整合包里的模组往往在启动阶段同步发请求，目标又常是国内不可达的
        // `raw.githubusercontent.com`（BMC4 的 modpack-update-checker 就固定请求
        // 该域名的 bmc4forge 分支，日志里那行 `Fetching available hotfixes...`
        // 之后长时间没输出就是它）。实测能挂 40 秒到 3 分钟，表现完全像卡死。
        //
        // 3 秒连接超时对正常网络绰绰有余，又能让不可达的请求**快速失败**继续往下走。
        // 不会影响正版登录 / 联机：登录走启动器自己的 URLSession，游戏联机走 netty
        // 的 socket，都不经过这两个 HttpURLConnection 默认值。
        jvm.append(contentsOf: [
            "-Dsun.net.client.defaultConnectTimeout=3000",
            "-Dsun.net.client.defaultReadTimeout=8000",
        ])

        // ---- 调试用：外部注入 JVM 参数 ----
        //
        // `AETHER_EXTRA_JVM="-Xmx8G -XX:+UseG1GC -Xlog:gc"` 只在 CLI 基准测试里用，
        // GUI 正常启动没有这个环境变量，走不到这里。
        // 必须 append 到**末尾**：HotSpot 对重复的 -Xmx / -XX 是「后者覆盖前者」，
        // 放前面会被上面的默认值盖掉，就测不出差异了。
        if let extra = ProcessInfo.processInfo.environment["AETHER_EXTRA_JVM"],
           !extra.trimmingCharacters(in: .whitespaces).isEmpty {
            jvm.append(contentsOf: extra.split(separator: " ").map(String.init))
        }

        // 外置登录：注入 authlib-injector，让游戏把认证请求指向皮肤站。
        // 格式：-javaagent:<jar>=<服务器地址>（authlib-injector 官方规范）
        if isYggdrasil, let jar = authlibInjectorJar, let server = account?.yggdrasilServer,
           let agent = AuthlibInjector.javaAgentArgument(jar: jar, server: server) {
            jvm.insert(agent, at: 0)
        }

        // ---- 游戏参数 ----
        var game: [String] = []
        if let arguments = details.arguments {
            for arg in arguments.game where arg.allowed(features: features) {
                game.append(contentsOf: arg.values.map(substitute))
            }
        } else if let legacy = details.minecraftArguments {
            game = legacy.split(separator: " ").map(String.init).map(substitute)
        }

        var all = jvm
        all.append(details.mainClass)
        all.append(contentsOf: game)

        var plan = Plan(executable: javaExecutable, arguments: all, workingDirectory: gameDir)
        // Vulkan 加速：把 ICD 路径塞进子进程环境，
        // 让 MoltenVK 能被 Vulkan loader 找到（Homebrew 路径不在 loader 搜索范围里）。
        plan.environment = VulkanSupport.environmentOverrides()
        return plan
    }

    /// 计算 classpath（客户端 jar + 所有允许的库 jar）。
    ///
    /// ## 照抄 HMCL 的做法（不要自己发明）
    ///
    /// HMCL `DefaultLauncher.java`：
    /// ```java
    /// Set<String> libraryClasspath = getClasspath();       // 只有 libraries
    /// Path jar = instance.getInstanceJarFile();            // 原版 client jar
    /// Set<String> classpath = new LinkedHashSet<>(libraryClasspath);
    /// classpath.add(FileUtils.getAbsolutePath(jar));       // 原版 jar 放在最后
    /// configuration.put("${classpath}", String.join(File.pathSeparator, classpath));
    /// ```
    /// 也就是说 **classpath 里就该有原版混淆 jar**（Forge/NeoForge 也一样）。
    ///
    /// 真正的模块冲突是这样解决的（`LaunchManifestNormalizer.repairBootstrapLauncher`）：
    /// ```java
    /// // bootstraplauncher 0.1.17+ 只按「文件名」匹配 ignoreList，
    /// // 所以只要把 primary jar 的文件名加进 ignoreList 就行
    /// if (value.startsWith("-DignoreList=") && !contains(..., "${primary_jar_name}")) {
    ///     jvmArguments.set(i, new StringArgument(value + ",${primary_jar_name}"));
    /// }
    /// ```
    /// 加上 `${primary_jar_name}`（= `1.21.1.jar`）后，BootstrapLauncher 会把原版 jar
    /// 从模块层里排除，只保留 NeoForge 的 srg jar（模块 `minecraft`），
    /// 于是不再出现：
    /// ```
    /// java.lang.module.ResolutionException: Modules _1._21._1 and minecraft
    ///   export package net.minecraft.server to module xxx
    /// ```
    ///
    /// 我们之前的做法（把原版 jar 换成 srg jar）方向错了：
    /// srg jar 里是**已重映射**的类，和 NeoForge 自己的模块层重复，一样会冲突。
    static func classpath(details: VersionDetails,
                          librariesDir: URL,
                          clientJar: URL) -> String {
        var paths: [String] = []
        for lib in details.libraries where rulesAllow(lib.rules, features: [:]) {
            // 加载器的库可能只有 maven 坐标（fabric / quilt），也要进 classpath
            guard let artifact = lib.artifact() else { continue }
            paths.append(librariesDir.appendingPathComponent(artifact.path).path)
        }
        // 原版 client jar 放在最后（与 HMCL 一致）
        paths.append(clientJar.path)
        return paths.joined(separator: ":")
    }

    /// 主类是不是 BootstrapLauncher（Forge / NeoForge 1.17+）。
    /// 对应 HMCL `GameComponentAnalyzer.BOOTSTRAP_LAUNCHER_MAIN`。
    private static func isBootstrapLauncher(_ mainClass: String) -> Bool {
        mainClass == "cpw.mods.bootstraplauncher.BootstrapLauncher"
    }

    /// 这个版本是否走 JPMS 模块化启动（SecureJarHandler）。
    ///
    /// HMCL `GameComponentAnalyzer` 把启动器主类分成三类：
    /// ```java
    /// BOOTSTRAP_LAUNCHER_MAIN = "cpw.mods.bootstraplauncher.BootstrapLauncher"; // Forge/NeoForge 1.17+
    /// MOD_LAUNCHER_MAIN        = "cpw.mods.modlauncher.Launcher";              // 旧 Forge
    /// LAUNCH_WRAPPER_MAIN      = "net.minecraft.launchwrapper.Launch";          // 原版
    /// ```
    /// 只有第一类（BootstrapLauncher）会用 SecureJarHandler 把 classpath 上的 jar
    /// 转成 JPMS 模块，这时「多出来的一份原版客户端 jar」才会撞模块名：
    /// ```
    /// java.lang.module.ResolutionException: Modules minecraft and client
    ///   export package net.minecraft.world.level.storage.loot to module xxx
    /// ```
    /// 原版（`net.minecraft.client.main.Main`）不扫描 mods 目录、不做模块化，
    /// 多一份客户端 jar 只会变成「第二个 classpath 项」，不会致命 ——
    /// 所以**原版实例绝不能做隔离**，否则把它自己的 client.jar 挪走就启动不了了。
    ///
    /// 判据必须看「这个版本的主类」，不能看「本机有没有 srg jar」：
    /// 本机只要装过任意一个 Forge/NeoForge，srg jar 就一直在，
    /// 用那种判据会把所有原版实例的 client.jar 都误删。
    static func usesSecureJarHandler(mainClass: String) -> Bool {
        mainClass == "cpw.mods.bootstraplauncher.BootstrapLauncher"
    }

    /// 找 NeoForge / Forge 安装器生成的「已重映射」客户端 jar。
    ///
    /// 位置规律：`libraries/net/minecraft/client/<mc>-<srg 版本号>/client-<...>-srg.jar`
    /// （Forge 老版本则是 `libraries/net/minecraft/<mc>/<mc>-srg.jar`）。
    /// 找的时候按文件名含 `srg` 且不含 `slim` / `extra` 来筛。
    ///
    /// 注意：这个 jar **不进 classpath**（HMCL 也不进）。
    /// 它是 NeoForge 的模块层自己按 `production client provider` 规则加载的。
    static func remappedClientJar(librariesDir: URL) -> URL? {
        let fm = FileManager.default
        let roots = [
            librariesDir.appendingPathComponent("net/minecraft/client", isDirectory: true),
            librariesDir.appendingPathComponent("net/minecraft", isDirectory: true),
        ]
        for root in roots {
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs {
                guard let jars = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for jar in jars where jar.lastPathComponent.hasSuffix(".jar") {
                    let name = jar.lastPathComponent.lowercased()
                    // 只要 srg 版；slim（去映射的）和 extra（附加资源）都不是客户端本体
                    guard name.contains("srg"), !name.contains("slim"), !name.contains("extra") else { continue }
                    return jar
                }
            }
        }
        return nil
    }

    /// 找加载器的 client-extra jar（`neoforge-<ver>-client.jar` / `forge-<ver>-client.jar`）。
    ///
    /// 保留这个函数是为了诊断用 —— 它**不能**进 classpath（见 classpath 里的说明），
    /// 但可以确认它确实下载下来了。
    static func loaderClientExtraJar(librariesDir: URL) -> URL? {
        let fm = FileManager.default
        let roots = [
            librariesDir.appendingPathComponent("net/neoforged/neoforge", isDirectory: true),
            librariesDir.appendingPathComponent("net/minecraftforge/forge", isDirectory: true),
        ]
        for root in roots {
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs {
                guard let jars = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for jar in jars where jar.lastPathComponent.hasSuffix("-client.jar") {
                    return jar
                }
            }
        }
        return nil
    }

    /// Forge / NeoForge 由安装器现场产出的「核心文件」是否齐全。
    ///
    /// 为什么要单独查：这几个文件（`client-<mc>-<mcp>-srg.jar`、`-extra.jar`、
    /// `forge-<...>-client.jar`）**不在版本 JSON 的 libraries 里** —— 它们是安装器
    /// 用 mcp 数据现场生成/按私有路径下载的，所以启动器的依赖补齐逻辑永远看不到。
    /// 安装器被中断（超时 terminate / 用户强退 / 断网）时恰好会留下「JSON 有了、
    /// 这三个没有」的半套产物，启动时表现为：
    /// ```
    /// java.io.IOException: Invalid paths argument, contained no existing paths:
    ///   [...-srg.jar, ...-extra.jar, ...-client.jar]
    /// ```
    /// 返回缺失的文件列表（空 = 齐全，或这个版本不需要这些文件）。
    static func missingLoaderArtifacts(details: VersionDetails, librariesDir: URL) -> [URL] {
        guard isBootstrapLauncher(details.mainClass) else { return [] }
        // `--fml.*` 在 **game** 参数里（由 install_profile 写进 arguments.game），
        // 不是 jvm 参数 —— 只看 jvm 会永远取不到 mc/mcp/forge 版本，从而漏检。
        let flat = (details.arguments?.jvm ?? []).flatMap { $0.values }
                 + (details.arguments?.game ?? []).flatMap { $0.values }
        func value(after key: String) -> String? {
            guard let i = flat.firstIndex(of: key), i + 1 < flat.count else { return nil }
            let v = flat[i + 1]
            return v.hasPrefix("--") || v.hasPrefix("-D") ? nil : v
        }
        guard let mc = value(after: "--fml.mcVersion") else { return [] }
        let mcp = value(after: "--fml.mcpVersion")
        let forgeVer = value(after: "--fml.forgeVersion")
        let neoVer = value(after: "--fml.neoForgeVersion") ?? value(after: "--fml.neoformVersion")

        var expected: [URL] = []
        if let forgeVer {
            expected.append(librariesDir.appendingPathComponent(
                "net/minecraftforge/forge/\(mc)-\(forgeVer)/forge-\(mc)-\(forgeVer)-client.jar"))
        }
        if let neoVer {
            expected.append(librariesDir.appendingPathComponent(
                "net/neoforged/neoforge/\(neoVer)/neoforge-\(neoVer)-client.jar"))
        }
        if let mcp {
            let dir = librariesDir.appendingPathComponent("net/minecraft/client/\(mc)-\(mcp)")
            expected.append(dir.appendingPathComponent("client-\(mc)-\(mcp)-srg.jar"))
            expected.append(dir.appendingPathComponent("client-\(mc)-\(mcp)-extra.jar"))
        }
        return expected.filter { !FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 找 NeoForge / Forge 安装器生成的「已重映射」客户端 jar。
    ///
    /// 位置规律：`libraries/net/minecraft/client/<mc>-<srg 版本号>/client-<...>-srg.jar`
    /// （Forge 老版本则是 `libraries/net/minecraft/<mc>/<mc>-srg.jar`）。
    /// 找的时候按文件名含 `srg` 且不含 `slim` / `extra` 来筛。
    static func remappedClientJar(librariesDir: URL, details: VersionDetails) -> URL? {
        let fm = FileManager.default
        let roots = [
            librariesDir.appendingPathComponent("net/minecraft/client", isDirectory: true),
            librariesDir.appendingPathComponent("net/minecraft", isDirectory: true),
        ]
        for root in roots {
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs {
                guard let jars = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for jar in jars where jar.lastPathComponent.hasSuffix(".jar") {
                    let name = jar.lastPathComponent.lowercased()
                    // 只要 srg 版；slim（去映射的）和 extra（附加资源）都不是客户端本体
                    guard name.contains("srg"), !name.contains("slim"), !name.contains("extra") else { continue }
                    return jar
                }
            }
        }
        return nil
    }

    /// 解包原生库 jar（zip）到目标目录，可排除指定条目。
    @discardableResult
    static func unzip(_ jar: URL, to dir: URL, exclude: [String] = []) -> Bool {
        try? Paths.ensure(dir)
        var args = ["-o", "-q", jar.path, "-d", dir.path]
        if !exclude.isEmpty {
            args.append("-x")
            args.append(contentsOf: exclude)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = args
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
