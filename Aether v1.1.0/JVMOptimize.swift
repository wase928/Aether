//
//  JVMOptimize.swift
//  maccraft
//
//  JVM 调优参数。
//
//  ## 为什么启动器要管这些
//
//  Minecraft 的帧率瓶颈**大部分不在 GPU，在 CPU 和 GC**：
//
//  · **GC 停顿**：MC 每 tick 都会产生大量短命对象（方块实体更新、
//    粒子、光照传播）。默认的 G1GC 会频繁做年轻代回收，帧时间曲线全是锯齿。
//    换成 ZGC / Shenandoah 能把停顿压到亚毫秒级 —— 这是**最有效的一刀**。
//  · **JIT 预热**：前 30 秒一直在解释执行，之后才编译成机器码。
//    提前告诉 JIT 哪些方法要紧（`-XX:+UseParallelGC` 之类的）能少几百毫秒卡顿。
//  · **大页**：`-XX:+UseLargePages` 让 JVM 用 2MB 大页，
//    减少 TLB miss —— 对 MC 这种「大量小对象 + 随机访问」的负载有实测收益。
//
//  参数来源：Aikar 的 Minecraft 调优 flag（社区长期验证的那套），
//  按 JDK 版本分流 —— **JDK 21+ 默认用 ZGC**，更早的版本用 G1GC。
//
//  ## 原则
//
//  · **默认开**：这些参数对绝大多数用户都是净收益。
//  · **可关**：界面上留开关，出问题能立刻回退。
//  · **不覆盖用户的**：如果版本 JSON 自己带了 `-XX:` 参数，以用户的为准。
//

import Foundation

nonisolated enum JVMOptimize {

    /// 启动器的 JVM 调优配置。
    struct Config: Equatable {
        /// 总开关。
        var enabled: Bool = true
        /// GC 选择，nil = 按 Java 版本自动。
        var gc: GCKind? = nil
        /// 激进的调优（大页 + JIT 预热 + young gen 划分）。
        var aggressive: Bool = false

        static let `default` = Config()
    }

    /// GC 选择：按 Java 大版本决定。
    enum GCKind: String, CaseIterable, Identifiable {
        case auto = "自动（推荐）"
        case zgc = "ZGC（停顿最低）"
        case shenandoah = "Shenandoah"
        case g1 = "G1GC（兼容性最好）"
        case parallel = "Parallel GC"

        var id: String { rawValue }

        /// 短名（主页 chip 上显示用）。
        var shortName: String {
            switch self {
            case .auto: return "GC 自动"
            case .zgc: return "ZGC"
            case .shenandoah: return "Shenandoah"
            case .g1: return "G1GC"
            case .parallel: return "Parallel GC"
            }
        }

        /// 这个 GC 需要的最小 Java 大版本。
        var minMajor: Int {
            switch self {
            case .auto: return 0
            case .zgc: return 15        // JDK 15 引入实验版，17 转正
            case .shenandoah: return 12  // JDK 12 引入
            case .g1: return 6           // JDK 7+ 都有 G1
            case .parallel: return 1
            }
        }

        /// 备选顺序（当前不可用时往下退）。
        var fallbacks: [GCKind] {
            switch self {
            case .shenandoah: return [.zgc, .g1, .parallel]
            case .zgc: return [.g1, .parallel]
            case .g1: return [.parallel]
            case .parallel: return [.g1]
            case .auto: return []
            }
        }
    }

    /// 根据 Java 大版本自动选 GC。
    /// ZGC 在 JDK 15+ 是实验性的，17+ 转正，21+ 成熟（ generational ZGC）。
    static func recommendedGC(major: Int) -> GCKind {
        switch major {
        // JDK 17 的 ZGC 是**非分代**的：每次回收都要扫全堆，吞吐比 G1 低一截。
        // Minecraft 的分配模式（海量短命对象 + 偶发大对象）正好是 G1 的强项，
        // 启动期尤其明显（mod 加载会疯狂 new）。JDK 21+ 的分代 ZGC 才值得用，
        // 这里 17/20 一律用 G1 —— Aikar 的 MC 调优也是这个结论。
        case 21...: return .zgc
        default: return .g1
        }
    }

    /// 生成 JVM 参数。
    ///
    /// - Parameters:
    ///   - major: Java 大版本（21、17、8……）
    ///   - memoryMB: 堆内存上限
    ///   - gc: GC 选择，nil = 自动
    ///   - aggressive: 是否启用大页 + 激进的 JIT 预热（要更多预留内存）
    static func arguments(major: Int, memoryMB: Int, gc: GCKind?, aggressive: Bool) -> [String] {
        var args: [String] = []
        let gcKind = gc ?? recommendedGC(major: major)

        // ---- GC 选择 ----
        switch gcKind {
        case .zgc:
            // ZGC 需要 JDK 15+（JDK 11/14 有实验版但不完整，别用）。
            // · JDK 15/16：实验特性，要 -XX:+UnlockExperimentalVMOptions
            // · JDK 17+：已转正，**加那个 flag 反而可能让 VM 初始化失败**
            // 堆上限由 LaunchService 的 -Xmx 负责，不在这里重复设 -XX:MaxHeapSize。
            if major >= 17 {
                args += ["-XX:+UseZGC"]
            } else if major >= 15 {
                args += ["-XX:+UnlockExperimentalVMOptions", "-XX:+UseZGC"]
            }
        case .shenandoah:
            // ⚠️ Shenandoah 在 JDK 12~16 是实验性的（要 UnlockExperimentalVMOptions），
            //    JDK 17+ 已转正 —— **那时候再加这个 flag 反而会让 VM 初始化失败**
            //    （实测 JDK 27：单独 -XX:+UseShenandoahGC 正常，
            //      加上 -XX:+UnlockExperimentalVMOptions 就报
            //      "Error occurred during initialization of VM"）。
            if major >= 17 {
                args += ["-XX:+UseShenandoahGC"]
            } else if major >= 12 {
                args += ["-XX:+UnlockExperimentalVMOptions", "-XX:+UseShenandoahGC"]
            }
        case .g1:
            // G1 的停顿目标：默认 200ms 对游戏卡顿太钝，30ms 又会让启动期
            // （mod 疯狂分配）回收过于频繁。40ms 是启动速度和帧时间的折中。
            //
            // 后面几项来自 Aikar 的 MC 调优（社区长期验证）：
            //  · ParallelRefProcEnabled —— 并行处理软/弱引用，**mod 多的包启动收益最明显**
            //  · G1NewSizePercent/G1MaxNewSizePercent —— 年轻代给足，减少回收次数
            //  · InitiatingHeapOccupancyPercent=20 —— 更早开始并发标记，避免 Full GC
            if major >= 12 {
                args += ["-XX:MaxGCPauseMillis=40",
                         "-XX:+ParallelRefProcEnabled",
                         "-XX:G1NewSizePercent=30",
                         "-XX:G1MaxNewSizePercent=40",
                         "-XX:G1ReservePercent=15",
                         "-XX:InitiatingHeapOccupancyPercent=20"]
            }
            args += ["-XX:+UseG1GC",
                     "-XX:+DisableExplicitGC"]
        case .parallel:
            args += ["-XX:+UseParallelGC"]
        case .auto:
            break
        }

        // ---- 通用：MC 特有的 GC 调优 ----
        //
        // MC 的对象分配模式很特殊：大量**短命**的小对象 + 偶尔的**长命**大对象
        // （比如区块数据）。
        //
        // ⚠️ 布尔型开关的写法有坑：`-XX:+UseXxx=false` 是**语法错误**，
        //    正确写法是 `-XX:-UseXxx`（实测踩过：直接导致 JVM 拒绝启动）。
        args += [
            // 字符串去重反而占内存，关掉
            "-XX:-UseStringDeduplication",
            // 压缩指针：对象头 16 字节 → 12 字节，省内存 = 缓存命中更多
            "-XX:+UseCompressedOops",
        ]

        if aggressive {
            // ⚠️ **不要加 -XX:+UseLargePages**。
            // 实测（macOS 26 / JDK 27）：
            //   -XX:+UseLargePages            → "not supported in this VM"（warning，无害但没用）
            //   -XX:+UseTransparentHugePages   → **Unrecognized VM option，JVM 直接起不来**
            // macOS 没有大页支持，别照抄 Linux/Windows 那套参数。
            //
            // macOS 上真正有意义的「激进」项：
            // · AlwaysPreTouch：启动时把堆页全部预触碰，消灭运行期的首次缺页停顿
            //   （代价是启动慢几百毫秒，换游戏内帧率稳定）
            // · TieredStopAtLevel=4：跳过 C1 编译器的低层，专注 C2 优化
            //   —— 提前拿到高性能代码，少几十秒的预热卡顿
            args += ["-XX:+AlwaysPreTouch",
                     "-XX:+TieredCompilation", "-XX:TieredStopAtLevel=4"]
        }

        // ---- 保留堆与其它 ----
        // 不设 -Xmx/-Xms（LaunchService 已经按用户设置插了），
        // 这里只管 GC 相关的。
        return args
    }

    /// 是否检测到版本 JSON 自带的 -XX: 参数（用户自己配过）。
    /// 有的话启动器不重复加同一类参数，避免打架。
    static func hasCustomGCFlags(versionArguments: [String]) -> Bool {
        versionArguments.contains { $0.hasPrefix("-XX:+Use") || $0.hasPrefix("-XX:-Use") }
    }

    /// 探测某个 GC 在这台 JVM 上**真的可用**。
    ///
    /// ## 为什么必须探测
    ///
    /// 「版本号够」不等于「有这个东西」：
    /// · Shenandoah 是 **OpenJDK 特有**的 —— Oracle JDK 从来不带！
    ///   （实测：Oracle JDK 27 上 `-XX:+UseShenandoahGC` → "Option not supported"）
    /// · ZGC 在 Oracle JDK 与 OpenJDK 都有，但要 15+。
    ///
    /// 用户在界面上选了 Shenandoah，装的是 Oracle JDK → 游戏直接起不来。
    /// 所以必须在启动前探测 + 自动降级。
    ///
    /// - Returns: 可用则返回 true
    static func isGCAvailable(_ kind: GCKind, javaExecutable: URL) -> Bool {
        guard kind != .auto else { return true }
        let flag: String
        switch kind {
        case .zgc: flag = "-XX:+UseZGC"
        case .shenandoah: flag = "-XX:+UseShenandoahGC"
        case .g1: flag = "-XX:+UseG1GC"
        case .parallel: flag = "-XX:+UseParallelGC"
        case .auto: return true
        }
        let r = validate(javaExecutable: javaExecutable, arguments: [flag])
        return r.ok
    }

    /// 选一个**这台 JVM 真的支持**的 GC。
    ///
    /// 依次尝试：用户选的 → 它的备选 → G1GC（几乎所有 JVM 都有）。
    static func resolveGC(preferred: GCKind?, javaMajor: Int, javaExecutable: URL?) -> GCKind {
        var candidate = preferred ?? recommendedGC(major: javaMajor)
        if candidate == .auto { candidate = recommendedGC(major: javaMajor) }

        guard let java = javaExecutable else {
            // 探测不了就按版本号保守选（ZGC 只在 17+ 给，Shenandoah 在 12+ 给）
            if candidate == .shenandoah && javaMajor < 12 { return .g1 }
            return candidate
        }

        // 版本号都不够的，直接退
        if javaMajor < candidate.minMajor {
            candidate = candidate.fallbacks.first { $0.minMajor <= javaMajor } ?? .g1
        }
        // 实测这个 JVM 支不支持
        if isGCAvailable(candidate, javaExecutable: java) { return candidate }
        // 不支持 → 沿备选链往下退
        for fb in candidate.fallbacks {
            if javaMajor < fb.minMajor { continue }
            if isGCAvailable(fb, javaExecutable: java) { return fb }
        }
        return .g1
    }

    /// 用真实的 java 跑一遍，验证这些参数**这台机器的 JVM 真的认**。
    ///
    /// ## 为什么必须实测
    ///
    /// JVM 参数有个恶心的地方：**不认识就直接拒绝启动**，
    /// 而且报错信息只说「Unrecognized VM option」，不告诉你是哪个。
    ///
    /// 实测踩过的坑：
    /// · `-XX:+UseStringDeduplication=false` → **致命**，JVM 起不来
    ///   （布尔开关不能带 `=false`，要写 `-XX:-UseStringDeduplication`）
    /// · `-XX:+UseTransparentHugePages` → macOS 上**致命**
    /// · `-XX:+UseLargePages` → macOS 上只是 warning，实际没生效
    ///
    /// 所以每次加了新参数，都该跑一下这个验证。
    ///
    /// ## 判定标准
    ///
    /// JVM 启动失败（退出码非 0）才算失败。
    /// **warning 不算失败** —— 比如「Ignoring option X; support was removed」，
    /// JVM 照常启动，只是那个选项没生效而已，不该因此判定参数不可用。
    ///
    /// - Returns: (通过?, 说明)
    static func validate(javaExecutable: URL, arguments: [String]) -> (ok: Bool, message: String) {
        let proc = Process()
        proc.executableURL = javaExecutable
        // 只验参数：-version 打印版本就退出，不真的开游戏
        proc.arguments = arguments + ["-version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            return (false, "无法执行 java：\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if proc.terminationStatus == 0 {
            // 把 warning 单独拎出来提示（不影响可用性）
            let warnings = out.split(separator: "\n")
                .filter { $0.contains("warning") || $0.contains("Ignoring option") }
                .map { "      ⚠︎ " + $0.trimmingCharacters(in: .whitespaces) }
            let msg = warnings.isEmpty ? "参数被 JVM 接受"
                     : "参数被接受，但有 \(warnings.count) 条 warning：\n" + warnings.joined(separator: "\n")
            return (true, msg)
        }
        // 启动失败：取第一行错误（通常是 "Unrecognized VM option 'xxx'"）
        let firstError = out.split(separator: "\n").first.map(String.init) ?? out
        return (false, firstError)
    }
}
