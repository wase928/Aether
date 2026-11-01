//
//  SelfTest.swift
//  maccraft
//
//  命令行自检：`maccraft.app/Contents/MacOS/maccraft --selftest`
//  用真实网络跑一遍「候选清单 → 竞速取 JSON → 候选链下载类库/资源」，
//  打印每个源的实际命中与耗时，并校验 SHA-1。
//

import Foundation
import CryptoKit

nonisolated enum SelfTest {
    /// 若命令行带 --selftest / --selftest-all / --launch-check，则跑自检并返回 true（调用方据此退出）。
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        let launchIdx = args.firstIndex(of: "--launch-check")
        let installIdx = args.firstIndex(of: "--install-check")
        let modIdx = args.firstIndex(of: "--mod-check")
        let packIdx = args.firstIndex(of: "--pack-check")
        let accIdx = args.firstIndex(of: "--account-check")
        let javaIdx = args.firstIndex(of: "--java-check")
        let hmclIdx = args.firstIndex(of: "--hmcl-check")
        let unzipIdx = args.firstIndex(of: "--unzip-check")
        let counterIdx = args.firstIndex(of: "--counter-check")
        guard args.contains("--selftest") || args.contains("--selftest-all") || launchIdx != nil
                || installIdx != nil || modIdx != nil || packIdx != nil || accIdx != nil
                || javaIdx != nil || hmclIdx != nil || unzipIdx != nil
                || counterIdx != nil || args.contains("--stale-check")
                || args.contains("--isolate-check")
                || args.contains("--loader-progress-check") else { return false }
        let full = args.contains("--selftest-all")
        let sem = DispatchSemaphore(value: 0)
        if hmclIdx != nil {
            Task.detached {
                await hmclCheck()
                sem.signal()
            }
        } else if let i = javaIdx {
            let major = Int(args.count > i + 1 ? args[i + 1] : "21") ?? 21
            Task.detached {
                await javaCheck(major)
                sem.signal()
            }
        } else if accIdx != nil {
            Task.detached {
                await accountCheck()
                sem.signal()
            }
        } else if let i = packIdx {
            let path = args.count > i + 1 ? args[i + 1] : ""
            Task.detached {
                await packCheck(path)
                sem.signal()
            }
        } else if let i = modIdx {
            // --mod-check <versionID> <query> [mod|shader|resourcepack]
            let vid = args.count > i + 1 ? args[i + 1] : "fabric-loader-0.20.1-1.21.4"
            let query = args.count > i + 2 ? args[i + 2] : "sodium"
            let type = args.count > i + 3 ? (ResourceType(rawValue: args[i + 3]) ?? .mod) : .mod
            Task.detached {
                await modCheck(versionID: vid, query: query, type: type)
                sem.signal()
            }
        } else if let i = installIdx {
            let mc = args.count > i + 1 ? args[i + 1] : "1.21.4"
            let kind = args.count > i + 2 ? args[i + 2] : "fabric"
            Task.detached {
                await installCheck(mc: mc, kind: kind)
                sem.signal()
            }
        } else if let i = launchIdx {
            let id = args.count > i + 1 ? args[i + 1] : "26.3"
            Task.detached {
                await launchCheck(id)
                sem.signal()
            }
        } else if let i = unzipIdx {
            let path = args.count > i + 1 ? args[i + 1] : ""
            Task.detached {
                await unzipCheck(path)
                sem.signal()
            }
        } else if counterIdx != nil {
            Task.detached {
                await counterCheck()
                sem.signal()
            }
        } else if args.contains("--stale-check") {
            Task.detached {
                await staleCheck()
                sem.signal()
            }
        } else if args.contains("--isolate-check") {
            Task.detached {
                await isolateCheck()
                sem.signal()
            }
        } else if args.contains("--loader-progress-check") {
            Task.detached {
                await loaderProgressCheck()
                sem.signal()
            }
        } else {
            Task.detached {
                await run(full: full)
                sem.signal()
            }
        }
        sem.wait()
        return true
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
    }

    private static func run(full: Bool) async {
        let tmp = URL(fileURLWithPath: "/tmp/maccraft-selftest")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        out("=== A. 候选链（library / manifest / asset）===")
        let lib = URL(string: "https://libraries.minecraft.net/it/unimi/dsi/fastutil/8.5.18/fastutil-8.5.18.jar")!
        for c in Mirror.candidates(for: lib, kind: .library) {
            out("  library  \(Mirror.label(c.source).padding(toLength: 14, withPad: " ", startingAt: 0)) \(c.url.absoluteString)")
        }
        // Mojang 私有库：不该再出现阿里云 / 腾讯云（它们根本没有，之前就是这一屏 404 的元凶）
        let mojangLib = URL(string: "https://libraries.minecraft.net/com/mojang/authlib/10.0.77/authlib-10.0.77.jar")!
        out("  [Mojang 私有库]")
        for c in Mirror.candidates(for: mojangLib, kind: .library) {
            out("  library  \(Mirror.label(c.source).padding(toLength: 14, withPad: " ", startingAt: 0)) \(c.url.absoluteString)")
        }
        for c in Mirror.candidates(for: MojangAPI.manifestURL, kind: .manifest) {
            out("  manifest \(Mirror.label(c.source).padding(toLength: 14, withPad: " ", startingAt: 0)) \(c.url.absoluteString)")
        }
        let asset = URL(string: "https://resources.download.minecraft.net/ab/abcdef0123456789")!
        for c in Mirror.candidates(for: asset, kind: .assetObject) {
            out("  asset    \(Mirror.label(c.source).padding(toLength: 14, withPad: " ", startingAt: 0)) \(c.url.absoluteString)")
        }

        out("\n=== B. 竞速取清单 ===")
        var t0 = Date()
        do {
            let m = try await MojangAPI.fetchManifest()
            out("  OK \(m.versions.count) 个版本，最新 \(m.latest.release)，耗时 \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            guard let ref = m.versions.first(where: { $0.id == "26.3" }) ?? m.versions.first else { return }

            out("\n=== C. 版本 JSON + 资源索引 ===")
            t0 = Date()
            let d = try await MojangAPI.fetchVersionDetails(ref)
            out("  \(d.id) 主类 \(d.mainClass)，\(d.libraries.count) 个库，耗时 \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            t0 = Date()
            let (idx, name) = try await MojangAPI.fetchAssetIndex(details: d)
            out("  资源索引 \(name)，\(idx.objects.count) 个对象，耗时 \(Int(Date().timeIntervalSince(t0) * 1000))ms")

            out("\n=== D. 类库实测（候选链 + 测速排序）===")
            let order = await SourceBenchmark.rank(
                Mirror.candidates(for: lib, kind: .library), kind: .library, cacheKey: "selftest-lib")
            for c in order {
                let spd = SourceHealth.shared.speed(of: c.source, kind: .library) ?? 0
                out("  \(Mirror.label(c.source).padding(toLength: 14, withPad: " ", startingAt: 0)) \(String(format: "%7.2f MB/s", spd / 1_048_576))")
            }

            let bigLibs = d.libraries
                .compactMap { $0.downloads?.artifact }
                .filter { ($0.size ?? 0) > 1_000_000 }
                .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
                .prefix(2)

            for a in bigLibs {
                let dest = tmp.appendingPathComponent(a.path?.split(separator: "/").last.map(String.init) ?? "lib.jar")
                let official = URL(string: Mirror.toOfficial(a.url))!
                let cands = Mirror.candidates(for: official, kind: .library)
                t0 = Date()
                do {
                    try await DownloadManager.downloadCandidates(cands, kind: .library, to: dest, sha1: a.sha1)
                    let dt = Date().timeIntervalSince(t0)
                    let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                    out("  ✔ \(dest.lastPathComponent) \(String(format: "%.1f", Double(size ?? 0) / 1_048_576))MB \(Int(dt * 1000))ms \(String(format: "%.2f", Double(size ?? 0) / max(dt, 0.001) / 1_048_576))MB/s")
                } catch {
                    out("  ✖ \(dest.lastPathComponent) 失败：\(error.localizedDescription)")
                }
            }

            out("\n=== E. 资源对象实测（含测速排序）===")
            let objs = idx.objects.values.sorted { $0.size > $1.size }.prefix(3)
            if let probeObj = objs.first {
                let prefix = String(probeObj.hash.prefix(2))
                let probe = URL(string: "https://resources.download.minecraft.net/\(prefix)/\(probeObj.hash)")!
                let ranked = await SourceBenchmark.rank(
                    Mirror.candidates(for: probe, kind: .assetObject), kind: .assetObject, cacheKey: "selftest-asset")
                for c in ranked {
                    let spd = SourceHealth.shared.speed(of: c.source, kind: .assetObject) ?? 0
                    out("  \(Mirror.label(c.source).padding(toLength: 14, withPad: " ", startingAt: 0)) \(String(format: "%7.2f MB/s", spd / 1_048_576))")
                }
            }
            for o in objs {
                let prefix = String(o.hash.prefix(2))
                let official = URL(string: "https://resources.download.minecraft.net/\(prefix)/\(o.hash)")!
                let dest = tmp.appendingPathComponent(o.hash)
                t0 = Date()
                do {
                    try await DownloadManager.downloadCandidates(
                        Mirror.candidates(for: official, kind: .assetObject),
                        kind: .assetObject, to: dest, sha1: o.hash)
                    out("  ✔ \(o.hash.prefix(10)) \(String(format: "%.0f", Double(o.size) / 1024))KB \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                } catch {
                    out("  ✖ \(o.hash.prefix(10)) 失败：\(error.localizedDescription)")
                }
            }
            if full {
                await fullRun(d, idx)
            }
        } catch {
            out("  ✖ 失败：\(error.localizedDescription)")
        }
        out("\n=== 自检结束 ===")
    }

    // MARK: - HMCL 登录模块验证

    private static func hmclCheck() async {
        do {
            let jar = try HMCLLogin.findJar()
            out("✔ HMCL jar：\(jar.lastPathComponent)")
            out("  \(jar.path)")
            let java = try await HMCLLogin.javaRuntime()
            out("✔ Java：\(java.path)")
            out("\n启动设备码流程（15 秒后自动结束）…")
            let task = Task {
                do {
                    let cred = try await HMCLLogin.authenticate { dc in
                        out("\n★ 设备码：\(dc.userCode)")
                        out("★ 登录地址：\(dc.url)")
                        out("（去浏览器输入即可；本测试不会等待授权完成）")
                    }
                    out("✔ 拿到令牌：accessToken \(cred.accessToken.count) 字符，refreshToken \(cred.refreshToken.count) 字符")
                } catch {
                    out("流程：\(error.localizedDescription)")
                }
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            task.cancel()
            out("\n=== HMCL 登录验证结束 ===")
        } catch {
            out("✖ \(error.localizedDescription)")
        }
    }

    // MARK: - Java 下载验证

    private static func javaCheck(_ major: Int) async {
        out("目标 Java 大版本：\(major)")
        out("本地探测：\(JavaManager.detectLocalJava(major: major)?.path ?? "无")")
        out("TUNA 索引：\(await JavaManager.tunaArchiveURL(major: major)?.absoluteString ?? "未找到")")
        out("\n开始下载…")
        let t0 = Date()
        let tick = Tick()
        do {
            let java = try await JavaManager.javaExecutable(major: major) { received, expected in
                let now = Date()
                guard tick.shouldEmit() else { return }
                if expected > 0 {
                    let pct = Double(received) / Double(expected) * 100
                    let spd = Double(received) / max(now.timeIntervalSince(t0), 0.001)
                    out(String(format: "  %5.1f%%  %@ / %@  %@/s",
                               pct, DownloadManager.mb(received), DownloadManager.mb(expected),
                               DownloadManager.mb(Int64(spd))))
                } else {
                    out("  已下载 \(DownloadManager.mb(received))")
                }
            }
            let dt = Date().timeIntervalSince(t0)
            out("\n✔ 完成：\(java.path)")
            out("  用时 \(String(format: "%.1f", dt))s")
            out("  版本 \(JavaManager.majorVersion(of: java).map(String.init) ?? "?")")
        } catch {
            out("✖ 失败：\(error.localizedDescription)")
        }
        out("\n=== Java 下载验证结束 ===")
    }

    // MARK: - 账号导入验证

    private static func accountCheck() async {
        out("=== 1. 来源探测 ===")
        for s in AccountImport.sources() {
            out("  [\(s.available ? "✔" : "·")] \(s.name)：\(s.detail)")
        }
        out("\n=== 2. 尝试导入 ===")
        do {
            let acc = try await AccountImport.importAccount()
            out("  ✔ 导入成功")
            out("     角色名：\(acc.name)")
            out("     UUID  ：\(acc.uuid)")
            out("     皮肤  ：\(acc.skinURL ?? "无")")
            out("     过期  ：\(acc.expiresAt)（剩余 \(Int(acc.expiresAt.timeIntervalSinceNow / 60)) 分钟）")
            out("     刷新牌：\(acc.refreshToken.isEmpty ? "无（靠钥匙串续期）" : "有")")
        } catch {
            out("  ✖ 失败：\(error.localizedDescription)")
        }
        out("\n=== 账号导入验证结束 ===")
    }

    // MARK: - 整合包导入验证

    private static func packCheck(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        out("整合包：\(path)")
        out("识别类型：\(ModpackImporter.detect(url).rawValue)")

        // 进度：每跨 10% 打一行，模拟任务条显示的内容
        final class Box: @unchecked Sendable { var last = -1.0; let lock = NSLock() }
        let box = Box()
        let relay = ProgressRelay(order: [
            (.scan, 0.02), (.extract, 0.08), (.install, 0.05),
            (.loader, 0.30), (.merge, 0.05), (.resolve, 0.10),
            (.download, 0.38), (.finish, 0.02)
        ]) { p in
            box.lock.lock()
            let bucket = floor(p.overall * 10)
            let changed = bucket != box.last
            if changed { box.last = bucket }
            box.lock.unlock()
            guard changed else { return }
            out(String(format: "  [%3.0f%%] %@ %d/%d %@", p.overall * 100,
                       p.stage.rawValue, p.current, p.total, p.detail))
        }

        do {
            let t0 = Date()
            let r = try await ModpackImporter.import(url, baseVersionID: "fabric-loader-0.20.1-1.21.4",
                                                     relay: relay) { msg in
                out("  " + msg)
            }
            out("✔ 实例 \(r.versionID) · 文件 \(r.fileCount) · 用时 \(Int(Date().timeIntervalSince(t0)))s")

            let resolved = try VersionLibrary.resolve(r.versionID)
            out("继承链：\(resolved.chain.joined(separator: " → "))")
            out("主类：\(resolved.details.mainClass)")
            let dir = Paths.versionDir(r.versionID)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            out("实例目录内容：\(entries.joined(separator: ", "))")
            if let mods = try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("mods").path) {
                out("mods：\(mods.joined(separator: ", "))")
            }
            out("\n=== 整合包导入验证结束 ===")
        } catch {
            out("✖ 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 并发进度计数验证

    /// 验证 ProgressCounter 的并发计数与字节统计。
    ///
    /// 背景：早期版本所有并发任务共用一组 currentFile/currentBytes，
    /// 16 路并发时后一个任务的 start() 会覆盖前一个的，导致：
    ///   · 界面「当前文件名」乱跳
    ///   · doneBytes 严重低估（显示「总 315.4/462.6 MB」但其实早下完了）
    ///   · 任务条百分比恒为 0（overall 没传）
    /// 这个自检用本地 HTTP 无关的方式模拟：直接驱动 counter 的槽位 API。
    private static func counterCheck() async {
        out("=== 并发进度计数验证 ===")
        let counter = ProgressCounter(total: 20, totalBytes: 2000)

        // 20 个并发任务，每个 100 字节
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let slot = await counter.newSlot()
                    await counter.start(slot: slot, name: "file-\(i).jar", size: 100)
                    // 分 10 次上报，模拟真实下载的字节回调
                    for step in 1...10 {
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        await counter.addBytes(slot: slot, Int64(step * 10))
                        await counter.addDelta(10)
                    }
                    await counter.bump(slot: slot)
                }
            }
        }

        let done = await counter.done
        let doneBytes = await counter.doneBytes
        let file = await counter.currentFile
        let slotsLeft = await counter.slotCount

        out("完成计数：\(done) / 20")
        out("累计字节：\(doneBytes) / 2000")
        out("残留槽位：\(slotsLeft)")
        out("当前文件：\(file.isEmpty ? "(无)" : file)")

        var ok = true
        if done != 20 {
            out("✖ 完成计数不对（应为 20）"); ok = false
        } else { out("✔ 完成计数正确") }

        if doneBytes != 2000 {
            out("✖ 累计字节不对（应为 2000，实际 \(doneBytes)）—— 并发槽位串了")
            ok = false
        } else { out("✔ 累计字节正确（各任务字节没串）") }

        if slotsLeft != 0 {
            out("✖ 有 \(slotsLeft) 个槽位没回收"); ok = false
        } else { out("✔ 槽位全部回收") }

        out(ok ? "\n✔ 并发计数验证通过" : "\n✖ 并发计数验证失败")
    }

    // MARK: - 残留进度污染验证

    /// 验证「上一次任务的残留监控任务不会覆盖新任务的状态」。
    ///
    /// 背景（录屏里的真 BUG）：
    ///   第一次启动下到 3828/5147 时用户中断了，监控任务没退出；
    ///   第二次启动时旧任务还在每 150ms 往界面写旧计数，
    ///   于是屏幕上一边是「3828/5147」一边是新任务 —— 完全对不上。
    ///
    /// 修复点有三处：
    ///   1) 监控循环用 `try await Task.sleep`（取消会抛），取消后立刻退出；
    ///   2) TaskFeed.apply 拒绝接受已完成任务的后续进度；
    ///   3) TaskFeed.begin 重置完成态。
    private static func staleCheck() async {
        out("=== 残留进度污染验证 ===")

        // 注意：这里不能用 @MainActor 的 Task —— 自检的 sem.wait() 会占住主线程，
        // MainActor 上的 Task 永远排不上执行，Swift 运行时直接把进程 SIGTERM 掉。
        // 改用一个普通 actor 模拟「界面快照」。
        actor Box {
            var applied: [String] = []
            func append(_ s: String) { applied.append(s) }
            var count: Int { applied.count }
        }
        let box = Box()

        // 模拟一个「旧任务」的监控循环
        let oldTask = Task {
            var n = 0
            while !Task.isCancelled {
                n += 1
                // 旧任务持续上报 3828/5147
                let p = TaskProgress(stage: .download, current: 3828, total: 5147,
                                     detail: "下载资源", ratio: 3828.0 / 5147.0,
                                     overall: 3828.0 / 5147.0)
                await box.append("旧:\(p.current)/\(p.total)")
                do {
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    break   // 取消 → 退出循环
                }
            }
        }

        // 让旧任务跑一会儿
        try? await Task.sleep(nanoseconds: 200_000_000)
        let beforeCount = await box.count
        out("旧任务已上报 \(beforeCount) 次")

        // 取消旧任务（模拟 downloadAssets 里的 defer { mon.cancel() }）
        oldTask.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterCount = await box.count
        try? await Task.sleep(nanoseconds: 300_000_000)
        let finalCount = await box.count

        out("取消后立即计数：\(afterCount)，再等 0.3s：\(finalCount)")
        if finalCount == afterCount {
            out("✔ 旧任务已停止上报（取消后不再写界面）")
        } else {
            out("✖ 旧任务仍在写界面（取消后多上报了 \(finalCount - afterCount) 次）")
        }

        // 模拟新任务开始 → 完成 → 旧任务再来一次上报（时序交错）
        // 注意：TaskFeed 是 @MainActor，自检的 sem.wait() 占着主线程，
        // 不能直接 await 它。这里用同样的判定规则手算一遍。
        var snap = (stage: "准备中", counter: "", overall: 0.0, done: false)
        // begin()
        snap = (stage: "准备中", counter: "", overall: 0, done: false)
        // apply(下载中)
        let p1 = TaskProgress(stage: .download, current: 100, total: 200,
                              detail: "下载资源", ratio: 0.5, overall: 0.5)
        snap.stage = p1.stage.rawValue
        snap.counter = (p1.ratio >= 0) ? "" : "\(p1.current)/\(p1.total)"
        snap.overall = p1.overall
        // finish(ok)
        snap.stage = "完成"
        snap.done = true
        snap.counter = ""
        snap.overall = 1
        // 旧任务又来一条进度 —— TaskFeed.apply 会因为 done 而拒绝
        if !snap.done {
            snap.stage = p1.stage.rawValue
            snap.counter = "\(p1.current)/\(p1.total)"
            snap.overall = p1.overall
        }
        out("新任务完成后被旧任务覆盖？阶段=\(snap.stage) 计数=\(snap.counter.isEmpty ? "(空)" : snap.counter)")
        if snap.stage == "完成" && snap.counter.isEmpty {
            out("✔ 已完成任务不被旧进度覆盖")
        } else {
            out("✖ 旧进度覆盖了已完成任务")
        }
        out("=== 残留进度污染验证结束 ===")
    }

    // MARK: - 原版 / 加载器实例隔离逻辑验证

    /// 验证「隔离冲突客户端 jar」这个动作**只**发生在 SecureJarHandler 版本上。
    ///
    /// 真实事故（2026-11-01）：
    /// 启动原版 1.20.1 报 `Could not find or load main class net.minecraft.client.main.Main`。
    /// 根因是隔离逻辑的判据用了「本机存在 srg jar」——
    /// 本机装过 NeoForge，所以判据恒为真，原版实例**自己的** `1.20.1.jar`
    /// 被当成「多出来的客户端 jar」挪进了 `.aether-conflicts/`，
    /// classpath 指向空文件 → 主类找不到。
    ///
    /// 正确判据（HMCL `GameComponentAnalyzer`）：看**这个版本的主类**。
    private static func isolateCheck() async {
        out("=== 原版 / 加载器实例隔离逻辑验证 ===")

        // 1) 各版本主类 → 是否走 SecureJarHandler
        let cases: [(String, String, Bool)] = [
            ("原版 1.20.1", "net.minecraft.client.main.Main", false),
            ("原版 26.3", "net.minecraft.client.main.Main", false),
            ("旧版 Forge", "cpw.mods.modlauncher.Launcher", false),
            ("原版 launchwrapper", "net.minecraft.launchwrapper.Launch", false),
            ("NeoForge 1.21.1", "cpw.mods.bootstraplauncher.BootstrapLauncher", true),
        ]
        var ok = true
        for (name, mainClass, expect) in cases {
            let actual = LaunchService.usesSecureJarHandler(mainClass: mainClass)
            let mark = actual == expect ? "✔" : "✖"
            if actual != expect { ok = false }
            out("  \(mark) \(name)：\(mainClass) → 隔离=\(actual)（期望 \(expect)）")
        }

        // 2) 真实检查本机各已安装版本：原版实例的 client jar 必须还在原位
        let fm = FileManager.default
        let versionsDir = Paths.versionsDir
        let entries = (try? fm.contentsOfDirectory(atPath: versionsDir.path)) ?? []
        for v in entries.sorted() {
            guard v.hasPrefix("pack-") == false else { continue }   // 整合包实例跳过
            guard let data = try? Data(contentsOf: Paths.versionJSON(v)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mainClass = json["mainClass"] as? String else { continue }
            let jar = Paths.clientJar(v)
            let quarantined = Paths.versionDir(v).appendingPathComponent(".aether-conflicts/\(v).jar")
            let jarExists = fm.fileExists(atPath: jar.path)
            let inQuarantine = fm.fileExists(atPath: quarantined.path)
            let shouldIsolate = LaunchService.usesSecureJarHandler(mainClass: mainClass)
            if shouldIsolate {
                continue    // 加载器版本不检查
            }
            if jarExists && !inQuarantine {
                out("  ✔ \(v)（原版）：client jar 在原位")
            } else {
                ok = false
                out("  ✖ \(v)（原版）：client jar 缺失或被误隔离！"
                    + "（原位=\(jarExists) 隔离区=\(inQuarantine)）")
                // 自动恢复
                if !jarExists && inQuarantine {
                    try? fm.createDirectory(at: Paths.versionDir(v).appendingPathComponent(".aether-conflicts"),
                                            withIntermediateDirectories: true)
                    try? fm.moveItem(at: quarantined, to: jar)
                    out("    ↩ 已自动恢复 \(v).jar")
                }
            }
        }

        // 3) Modpack 的 isLoaderInstance：只看包自己声明的加载器，不看本机全局状态
        out("  加载器判定（只看包声明的加载器 id）：")
        for (id, expect) in [("neoforge-21.1.248", true), ("1.21.1-forge-47.4.28", true),
                             ("fabric-loader-0.20.1-1.21.4", false), ("1.21.1", false)] {
            let actual = ModpackImporter.isLoaderInstanceForCheck(id)
            let mark = actual == expect ? "✔" : "✖"
            if actual != expect { ok = false }
            out("    \(mark) \(id) → \(actual)（期望 \(expect)）")
        }

        out(ok ? "✔ 隔离逻辑验证全部通过" : "✖ 隔离逻辑验证有问题")
        out("=== 隔离逻辑验证结束 ===")
    }

    // MARK: - 加载器进度单调性验证

    /// 验证加载器安装的进度条**不会抽风**。
    ///
    /// 真实事故（2026-11-01）：装 Forge 时进度条在 62% / 76% 之间来回跳。
    /// 根因是**两个进度来源各算各的**：
    ///   · `progress` 回调走 `Loaders.Progress.ratio` = `(step-1+fraction)/total`
    ///   · `onFile` 回调走 `0.30 + 0.50*fraction`
    /// 第 2 步时前者算出 0.47~0.63、后者算出 0.30~0.80，两个值交叉 → 视觉上抽风。
    ///
    /// 现在两个来源统一用 `Loaders.taskOverall(done:fraction:)`，
    /// 本自检验证：① 两路同输入必须同输出；② 整体必须单调不减。
    private static func loaderProgressCheck() async {
        out("=== 加载器进度单调性验证 ===")

        // 1) 两路来源一致性：progress 路径与 onFile 路径必须给出同一个值
        var consistent = true
        for step in 1...3 {
            for f in stride(from: 0.0, through: 1.0, by: 0.05) {
                // progress 路径：Progress.ratio + taskOverall
                let p = Loaders.Progress(message: "x", done: step, total: 3, fraction: f)
                let viaProgress = Loaders.taskOverall(done: p.done, fraction: p.fraction)
                // onFile 路径：同一个 fraction（两路共用同一个计数器，值必然相同）
                let fp = Loaders.FileProgress(name: "x.jar", done: Int(f * 50), total: 50)
                let viaFile = Loaders.taskOverall(done: 2, fraction: f)
                if step == 2, abs(viaProgress - viaFile) > 1e-9 {
                    consistent = false
                    out("  ✖ 第2步 f=\(String(format: "%.2f", f))：progress=\(viaProgress) file=\(viaFile)")
                }
            }
        }
        out(consistent ? "  ✔ 两路进度来源算出的值一致（不会再互相覆盖）"
                        : "  ✖ 两路进度来源的值不一致（进度条会抽风）")

        // 2) 整体单调性：按真实执行顺序扫一遍
        var last = -1.0
        var mono = true
        var samples: [String] = []
        func step(_ done: Int, _ f: Double, _ label: String) {
            let v = Loaders.taskOverall(done: done, fraction: f)
            if v < last - 1e-9 {
                mono = false
                samples.append("✖ \(label) \(String(format: "%.3f", v)) < 上一个 \(String(format: "%.3f", last))")
            }
            last = v
        }
        // 子步1：下载安装器
        for f in stride(from: 0.0, through: 1.0, by: 0.25) { step(1, f, "下载安装器") }
        // 子步2：预置依赖（58 个文件，逐个推进）
        for i in 0...58 { step(2, Double(i) / 58.0, "预置依赖 \(i)") }
        // 子步3：跑安装器
        for f in stride(from: 0.0, through: 1.0, by: 0.25) { step(3, f, "跑安装器") }
        for s in samples.prefix(5) { out("  \(s)") }
        out(mono ? "  ✔ 整体进度单调不减（0% → 100%）" : "  ✖ 出现回退")

        // 3) 阶段内比例（relay 用）也要单调
        var lastR = -1.0
        var monoR = true
        for done in 1...3 {
            for f in stride(from: 0.0, through: 1.0, by: 0.05) {
                let r = Loaders.stageRatio(done: done, total: 3, fraction: f)
                if r < lastR - 1e-9 { monoR = false }
                lastR = r
            }
        }
        out(monoR ? "  ✔ 阶段内比例单调" : "  ✖ 阶段内比例有回退")

        out("=== 加载器进度单调性验证结束 ===")
    }

    // MARK: - 解压 / 合并吞吐验证

    private static func unzipCheck(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            out("✖ 文件不存在：\(path)"); return
        }
        let entries = ZipTool.fileEntries(of: url)
        out("压缩包：\(path)")
        out("条目数（文件）：\(entries.count)")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unzip-check-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let t0 = Date()
        do {
            try await ZipTool.extract(url, to: dir, expectedFiles: entries.count) { files, bytes in
                let el = Date().timeIntervalSince(t0)
                out(String(format: "  进度 %4d/%-5d %7.1f MB  %.2fs", files, entries.count,
                           Double(bytes) / 1_048_576, el))
            }
            let m = ZipTool.measure(dir)
            out(String(format: "✔ ditto 解压：%d 文件 / %.1f MB / %.2fs",
                       m.files, Double(m.bytes) / 1_048_576, Date().timeIntervalSince(t0)))

            // clone 合并（APFS clonefile）
            let dst = dir.deletingLastPathComponent()
                .appendingPathComponent(dir.lastPathComponent + "-dst", isDirectory: true)
            let t1 = Date()
            try await ZipTool.merge(dir, into: dst)
            let m2 = ZipTool.measure(dst)
            out(String(format: "✔ clone 合并到另一目录：%d 文件 / %.1f MB / %.2fs",
                       m2.files, Double(m2.bytes) / 1_048_576, Date().timeIntervalSince(t1)))

            // 对照：FileManager 逐文件递归复制（旧实现）
            let dst2 = dir.deletingLastPathComponent()
                .appendingPathComponent(dir.lastPathComponent + "-cp", isDirectory: true)
            let t2 = Date()
            copyRecursively(dir, dst2)
            out(String(format: "· 旧实现（copyItem 递归）：%.2fs", Date().timeIntervalSince(t2)))

            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.removeItem(at: dst2)
            out("\n=== 解压验证结束 ===")
        } catch {
            out("✖ \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static func copyRecursively(_ src: URL, _ dst: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for item in items {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            let srcIsDir = fm.fileExists(atPath: item.path, isDirectory: &isDir) && isDir.boolValue
            if srcIsDir {
                copyRecursively(item, target)
            } else {
                try? fm.removeItem(at: target)
                try? fm.copyItem(at: item, to: target)
            }
        }
    }

    // MARK: - 资源（Mod / 光影 / 资源包）安装验证

    private static func modCheck(versionID: String, query: String, type: ResourceType) async {
        do {
            let resolved = try VersionLibrary.resolve(versionID)
            let mc = resolved.chain.last ?? resolved.details.id
            let loader = VersionLibrary.detectLoader(id: versionID, raw: "")
            out("版本 \(versionID) · MC \(mc) · \(loader.title) · 类型 \(type.title)")

            out("\n=== 1. 搜索「\(query)」===")
            let hits = try await Modrinth.search(type, query: query, mcVersion: mc, loader: loader).hits
            out("  命中 \(hits.count) 个")
            for h in hits.prefix(5) {
                out("  · \(h.title)  (\(h.downloads / 1000)k 下载) — \(h.slug)")
            }
            guard let project = hits.first else { out("  ✖ 没有结果"); return }

            out("\n=== 2. 取兼容版本并安装 ===")
            let versions = try await Modrinth.versions(projectID: project.project_id,
                                                       mcVersion: mc, loader: loader, type: type)
            out("  兼容文件 \(versions.count) 个")
            guard let v = versions.first, let file = v.primaryFile else { out("  ✖ 无兼容文件"); return }
            out("  选择：\(v.version_number) → \(file.filename)（\(file.size / 1024) KB）")

            let dest = try await Modrinth.install(v, type: type, versionID: versionID) { r, e in
                if e > 0, r % (2 * 1_048_576) < 262_144 {
                    out("    \(DownloadManager.mb(r))/\(DownloadManager.mb(e)) MB")
                }
            }
            InstalledIndex.record(projectID: project.project_id, title: project.title,
                                  type: type, versionID: versionID, file: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            out("  ✔ 已安装：\(dest.path)（\(size ?? 0) 字节）")

            out("\n=== 3. 目录检查 ===")
            let dir = type.destination(versionID: versionID)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            out("  \(dir.path) 内共 \(files.count) 个文件")
            for f in files.prefix(6) { out("    " + f) }
            out("\n=== 资源安装验证结束 ===")
        } catch {
            out("✖ 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 加载器安装验证

    private static func installCheck(mc: String, kind: String) async {
        do {
            let m = try await MojangAPI.fetchManifest()
            guard let ref = m.versions.first(where: { $0.id == mc }) else { out("✖ 找不到 \(mc)"); return }

            out("=== 1. 安装原版 \(mc) ===")
            let t0 = Date()
            _ = try await VersionLibrary.installVanilla(ref) { received, expected in
                if expected > 0, received % (8 * 1_048_576) < 524_288 {
                    out("  \(DownloadManager.mb(received))/\(DownloadManager.mb(expected)) MB")
                }
            }
            out("  ✔ 原版就绪 \(Int(Date().timeIntervalSince(t0)))s")

            let id: String
            out("\n=== 2. 安装 \(kind) ===")
            switch kind {
            case "fabric":
                let vs = await Loaders.fabricLoaderVersions(mc: mc)
                out("  可用 loader：\(vs.prefix(3).joined(separator: ", "))")
                guard let v = vs.first else { out("  ✖ 没有可用版本"); return }
                id = try await Loaders.installFabric(mc: mc, loader: v)
            case "quilt":
                let vs = await Loaders.quiltLoaderVersions(mc: mc)
                guard let v = vs.first else { out("  ✖ 没有可用版本"); return }
                id = try await Loaders.installQuilt(mc: mc, loader: v)
            case "forge":
                let vs = await Loaders.forgeVersions(mc: mc)
                out("  可用版本：\(vs.prefix(3).joined(separator: ", "))")
                guard let v = vs.first else { out("  ✖ 没有可用版本"); return }
                let java = try await JavaManager.javaExecutable(major: JavaManager.requiredJavaMajor(for: try VersionLibrary.resolve(mc).details, hint: mc)) { _, _ in }
                id = try await Loaders.installForge(mc: mc, version: v, java: java,
                                                     log: { s in out("  " + s) },
                                                     progress: { p in out("  [\(p.done)/\(p.total)] \(p.message)") })
            case "neoforge":
                let vs = await Loaders.neoForgeVersions(mc: mc)
                guard let v = vs.first else { out("  ✖ 没有可用版本"); return }
                let java = try await JavaManager.javaExecutable(major: 21) { _, _ in }
                id = try await Loaders.installNeoForge(mc: mc, version: v, java: java,
                                                        log: { s in out("  " + s) },
                                                        progress: { p in out("  [\(p.done)/\(p.total)] \(p.message)") })
            default:
                out("  ✖ 未知加载器 \(kind)"); return
            }
            out("  ✔ 已安装：\(id)")

            out("\n=== 3. 继承合并检查 ===")
            let r = try VersionLibrary.resolve(id)
            out("  继承链：\(r.chain.joined(separator: " → "))")
            out("  主类：\(r.details.mainClass)")
            out("  client jar 归属：\(r.clientJarID)")
            out("  库数量：\(r.details.libraries.count)")
            out("  资源索引：\(r.details.assetIndex?.id ?? r.details.assets ?? "-")")
            out("  JVM 参数组：\(r.details.arguments?.jvm.count ?? 0)，游戏参数组：\(r.details.arguments?.game.count ?? 0)")

            out("\n=== 4. 库文件齐全性 ===")
            var missing = 0, present = 0
            for lib in r.details.libraries where rulesAllow(lib.rules, features: [:]) {
                guard let a = lib.artifact() else { continue }
                let local = Paths.librariesDir.appendingPathComponent(a.path)
                if FileManager.default.fileExists(atPath: local.path) { present += 1 } else { missing += 1 }
            }
            out("  已存在 \(present)，缺失 \(missing)")
            if missing > 0 {
                out("  正在补下缺失库…")
                var items: [DownloadItem] = []
                for lib in r.details.libraries where rulesAllow(lib.rules, features: [:]) {
                    guard let a = lib.artifact() else { continue }
                    let local = Paths.librariesDir.appendingPathComponent(a.path)
                    if FileManager.default.fileExists(atPath: local.path) { continue }
                    let official = URL(string: Mirror.toOfficial(a.url)) ?? URL(string: a.url)!
                    items.append(DownloadItem(urls: Mirror.candidates(for: official, kind: .library),
                                              destination: local, sha1: a.sha1, size: a.size, kind: .library))
                }
                let t1 = Date()
                try await DownloadManager.downloadMany(items, counter: ProgressCounter(total: items.count), maxConcurrent: 12)
                out("  ✔ 补下 \(items.count) 个，用时 \(Int(Date().timeIntervalSince(t1)))s")
            }
            out("\n=== 安装验证结束 ===")
        } catch {
            out("✖ 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 真实启动验证（跑 25 秒后自动结束，检查日志关键字）

    private static func launchCheck(_ versionId: String) async {
        do {
            // 支持加载器版本：先按继承链合并
            let resolved = try VersionLibrary.resolve(versionId)
            let d = resolved.details
            out("继承链：\(resolved.chain.joined(separator: " → "))")
            out("主类：\(d.mainClass) · 库 \(d.libraries.count) 个")

            let (index, name) = try await MojangAPI.fetchAssetIndex(details: d)
            out("资源索引 \(name)（\(index.objects.count) 对象）→ \(Paths.assetIndexFile(name).path)")

            // 补齐缺失库
            var items: [DownloadItem] = []
            for lib in d.libraries where rulesAllow(lib.rules, features: [:]) {
                guard let a = lib.artifact() else { continue }
                let local = Paths.librariesDir.appendingPathComponent(a.path)
                if FileManager.default.fileExists(atPath: local.path) { continue }
                let official = URL(string: Mirror.toOfficial(a.url)) ?? URL(string: a.url)!
                items.append(DownloadItem(urls: Mirror.candidates(for: official, kind: .library),
                                          destination: local, sha1: a.sha1, size: a.size, kind: .library))
            }
            if !items.isEmpty {
                out("补下 \(items.count) 个缺失库…")
                try await DownloadManager.downloadMany(items, counter: ProgressCounter(total: items.count))
            }

            // 补资源对象（缺资源会导致贴图/声音缺失）
            var assetItems: [DownloadItem] = []
            for (_, o) in index.objects {
                let dest = Paths.assetsObjectsDir
                    .appendingPathComponent(String(o.hash.prefix(2)), isDirectory: true)
                    .appendingPathComponent(o.hash)
                if FileManager.default.fileExists(atPath: dest.path) { continue }
                let official = URL(string: "https://resources.download.minecraft.net/\(o.hash.prefix(2))/\(o.hash)")!
                assetItems.append(DownloadItem(urls: Mirror.candidates(for: official, kind: .assetObject),
                                               destination: dest, sha1: o.hash,
                                               size: Int64(o.size), kind: .assetObject))
            }
            if !assetItems.isEmpty {
                out("补下 \(assetItems.count) 个资源…")
                try await DownloadManager.downloadMany(assetItems, counter: ProgressCounter(total: assetItems.count),
                                                       maxConcurrent: 16)
            }

            let major = JavaManager.requiredJavaMajor(for: d,
                                                     hint: resolved.chain.count > 1 ? resolved.chain.last : d.id)
            let java = try await JavaManager.javaExecutable(major: major) { _, _ in }
            let jar = Paths.clientJar(resolved.clientJarID)
            let cp = LaunchService.classpath(details: d, librariesDir: Paths.librariesDir, clientJar: jar)
            out("classpath \(cp.split(separator: ":").count) 项")

            // 有可导入的正版凭据就用正版账号启动（验证 msa 链路）
            let imported = try? await AccountImport.importAccount()
            if let imported {
                out("账号：\(imported.name)（正版，msa）")
            } else {
                out("账号：\(SettingsKeys.usernameValue)（离线）")
            }
            let plan = LaunchService.plan(
                details: d, javaExecutable: java, username: SettingsKeys.usernameValue,
                memoryMB: SettingsKeys.memoryMBValue, resolution: nil,
                gameDir: Paths.versionDir(versionId), clientJar: jar,
                librariesDir: Paths.librariesDir, nativesDir: Paths.nativesDir(versionId),
                classpath: cp, assetsRoot: Paths.assetsDir, assetsIndexName: name,
                account: imported)
            out("Java: \(java.path)（\(major)）")

            let proc = Process()
            proc.executableURL = plan.executable
            proc.arguments = plan.arguments
            proc.currentDirectoryURL = plan.workingDirectory
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            let box = LineBox()
            let pump = LinePump { lines in box.append(lines) }
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; return }
                pump.feed(data)
            }

            out("启动游戏，观察 25 秒…")
            try proc.run()
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if proc.isRunning { proc.terminate() }
            proc.waitUntilExit()

            let lines = box.snapshot()
            let joined = lines.joined(separator: "\n")
            out("\n--- 抓到的输出（\(lines.count) 行）---")
            for l in lines.prefix(25) { out("  " + l.prefix(160)) }
            out("\n--- 判定 ---")
            let badIndex = joined.contains("Can't open the resource index")
            let missingSound = joined.components(separatedBy: "Missing sound for event").count - 1
            let reachedResource = joined.contains("Reloading ResourceManager")
            let hasMainMenu = joined.contains("Backend library") && joined.contains("Using graphics device")
            out("  资源索引报错：\(badIndex ? "有 ✖" : "无 ✔")")
            out("  Missing sound 行数：\(missingSound)")
            out("  已进入资源加载：\(reachedResource ? "是 ✔" : "否 ✖")")
            out("  图形后端初始化：\(hasMainMenu ? "是 ✔" : "否 ✖")")
            let auth401 = joined.contains("InvalidCredentialsException") || joined.contains("Failed to fetch user properties")
            out("  正版验证 401：\(auth401 ? "有 ✖（仍在离线）" : "无 ✔（msa 生效）")")
            out("\n=== 启动验证结束 ===")
        } catch {
            out("✖ 启动验证失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 全量下载（与启动器同一套候选链，写入真实数据目录）

    private static func fullRun(_ d: VersionDetails, _ idx: AssetIndexFile) async {
        out("\n=== F. 全量下载（真实数据目录）===")

        // 1) 客户端
        if let client = d.downloads?.client {
            let dest = Paths.clientJar(d.id)
            if FileManager.default.fileExists(atPath: dest.path) {
                out("  客户端已存在，跳过")
            } else {
                let official = URL(string: Mirror.toOfficial(client.url))!
                let t0 = Date()
                do {
                    try await DownloadManager.downloadCandidates(
                        Mirror.candidates(for: official, kind: .clientJar),
                        kind: .clientJar, to: dest, sha1: client.sha1)
                    let dt = Date().timeIntervalSince(t0)
                    let mb = Double(client.size ?? 0) / 1_048_576
                    out("  ✔ 客户端 \(String(format: "%.1f", mb))MB \(Int(dt * 1000))ms \(String(format: "%.2f", mb / max(dt, 0.001)))MB/s")
                } catch {
                    out("  ✖ 客户端：\(error.localizedDescription)")
                }
            }
        }

        // 2) 类库
        var libPending: [(official: URL, local: URL, sha1: String?, size: Int64?)] = []
        for lib in d.libraries where rulesAllow(lib.rules, features: [:]) {
            guard let a = lib.downloads?.artifact else { continue }
            let local = Paths.librariesDir.appendingPathComponent(a.path ?? Maven.path(for: lib.name))
            if FileManager.default.fileExists(atPath: local.path) { continue }
            libPending.append((URL(string: Mirror.toOfficial(a.url))!, local, a.sha1, a.size.map(Int64.init)))
        }
        if libPending.isEmpty {
            out("  类库已全部存在")
        } else {
            let totalMB = Double(libPending.reduce(Int64(0)) { $0 + ($1.size ?? 0) }) / 1_048_576
            let probe = libPending.max { ($0.size ?? 0) < ($1.size ?? 0) }!.official
            let ranked = await SourceBenchmark.rank(
                Mirror.candidates(for: probe, kind: .library), kind: .library, cacheKey: "selftest-full-lib")
            let order = ranked.map(\.source)
            let items = libPending.map { p -> DownloadItem in
                let cands = Mirror.candidates(for: p.official, kind: .library).sorted {
                    (order.firstIndex(of: $0.source) ?? 99) < (order.firstIndex(of: $1.source) ?? 99)
                }
                return DownloadItem(urls: cands, destination: p.local, sha1: p.sha1,
                                    size: p.size, kind: .library)
            }
            let counter = ProgressCounter(total: items.count,
                                          totalBytes: items.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
            let t0 = Date()
            do {
                try await DownloadManager.downloadMany(items, counter: counter, maxConcurrent: 12)
                let dt = Date().timeIntervalSince(t0)
                out("  ✔ 类库 \(items.count) 个 / \(String(format: "%.1f", totalMB))MB 用时 \(Int(dt))s \(String(format: "%.2f", totalMB / max(dt, 0.001)))MB/s")
            } catch {
                out("  ✖ 类库：\(error.localizedDescription)")
            }
        }

        // 3) 资源
        let objectsDir = Paths.assetsDir.appendingPathComponent("objects", isDirectory: true)
        var assetPending: [(hash: String, size: Int64)] = []
        for (_, o) in idx.objects {
            let dest = objectsDir.appendingPathComponent(String(o.hash.prefix(2)), isDirectory: true)
                .appendingPathComponent(o.hash)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            assetPending.append((o.hash, Int64(o.size)))
        }
        if assetPending.isEmpty {
            out("  资源已全部存在")
        } else {
            let totalMB = Double(assetPending.reduce(Int64(0)) { $0 + $1.size }) / 1_048_576
            let probeObj = assetPending.max { $0.size < $1.size }!
            let probe = URL(string: "https://resources.download.minecraft.net/\(probeObj.hash.prefix(2))/\(probeObj.hash)")!
            let ranked = await SourceBenchmark.rank(
                Mirror.candidates(for: probe, kind: .assetObject), kind: .assetObject, cacheKey: "selftest-full-asset")
            let order = ranked.map(\.source)
            let items = assetPending.map { p -> DownloadItem in
                let dest = objectsDir.appendingPathComponent(String(p.hash.prefix(2)), isDirectory: true)
                    .appendingPathComponent(p.hash)
                let official = URL(string: "https://resources.download.minecraft.net/\(p.hash.prefix(2))/\(p.hash)")!
                let cands = Mirror.candidates(for: official, kind: .assetObject).sorted {
                    (order.firstIndex(of: $0.source) ?? 99) < (order.firstIndex(of: $1.source) ?? 99)
                }
                return DownloadItem(urls: cands, destination: dest, sha1: p.hash,
                                    size: p.size, kind: .assetObject)
            }
            let counter = ProgressCounter(total: items.count,
                                          totalBytes: items.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
            let t0 = Date()
            do {
                try await DownloadManager.downloadMany(items, counter: counter, maxConcurrent: 16)
                let dt = Date().timeIntervalSince(t0)
                out("  ✔ 资源 \(items.count) 个 / \(String(format: "%.1f", totalMB))MB 用时 \(Int(dt))s \(String(format: "%.2f", totalMB / max(dt, 0.001)))MB/s")
            } catch {
                out("  ✖ 资源：\(error.localizedDescription)")
            }
        }

        // 4) 源健康度总览
        out("\n  源健康度：")
        for src in ["aliyun", "tencent", "bmclapi", "bmclapi-maven", "official"] {
            var line = "    \(Mirror.label(src).padding(toLength: 14, withPad: " ", startingAt: 0))"
            for kind in [ResourceKind.library, .assetObject, .manifest] {
                let s = SourceHealth.shared.speed(of: src, kind: kind)
                let dead = SourceHealth.shared.isDisabled(src, kind: kind)
                line += " \(kind.rawValue):" + (dead ? "禁用" : (s.map { String(format: "%.1fMB/s", $0 / 1_048_576) } ?? "—"))
            }
            out(line)
        }
    }
}


/// 采集进程输出（线程安全）。
nonisolated final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ new: [String]) {
        lock.lock(); defer { lock.unlock() }
        if lines.count < 20_000 { lines.append(contentsOf: new) }
    }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}


/// 进度节流（跨并发闭包安全）。
nonisolated final class Tick: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func shouldEmit(_ interval: TimeInterval = 0.4) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(last) >= interval {
            last = now
            return true
        }
        return false
    }
}
