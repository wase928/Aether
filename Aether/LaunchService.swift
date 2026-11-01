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
                     authlibInjectorJar: URL? = nil) -> Plan {
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

        return Plan(executable: javaExecutable, arguments: all, workingDirectory: gameDir)
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
