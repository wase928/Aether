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
        // 只打命令与 JVM 参数，不真的起进程 —— 用户正在玩的时候用它核对参数。
        let planIdx = args.firstIndex(of: "--launch-plan")
        let installIdx = args.firstIndex(of: "--install-check")
        let modIdx = args.firstIndex(of: "--mod-check")
        let packIdx = args.firstIndex(of: "--pack-check")
        let accIdx = args.firstIndex(of: "--account-check")
        let javaIdx = args.firstIndex(of: "--java-check")
        let hmclIdx = args.firstIndex(of: "--hmcl-check")
        let unzipIdx = args.firstIndex(of: "--unzip-check")
        let counterIdx = args.firstIndex(of: "--counter-check")
        let packPreviewIdx = args.firstIndex(of: "--pack-preview")
        let packImportIdx = args.firstIndex(of: "--pack-import")
        let verifyLibIdx = args.firstIndex(of: "--verify-libraries")
        let repairLoaderIdx = args.firstIndex(of: "--repair-loader")
        let i18nIdx = args.firstIndex(of: "--i18n-prewarm")
        let patchIdx = args.firstIndex(of: "--pack-patch")
        let verifyPackIdx = args.firstIndex(of: "--pack-verify")
        guard args.contains("--selftest") || args.contains("--selftest-all") || launchIdx != nil
                || planIdx != nil
                || installIdx != nil || modIdx != nil || packIdx != nil || accIdx != nil
                || javaIdx != nil || hmclIdx != nil || unzipIdx != nil
                || counterIdx != nil || args.contains("--stale-check")
                || args.contains("--isolate-check")
                || args.contains("--perf-check")
                || args.contains("--vulkanmod-check")
                || args.contains("--loader-progress-check")
                || args.contains("--layout-check")
                || args.contains("--layout-migrate")
                || args.contains("--loader-reuse-check")
                || packPreviewIdx != nil
                || packImportIdx != nil
                || verifyLibIdx != nil
                || repairLoaderIdx != nil
                || i18nIdx != nil
                || patchIdx != nil
                || verifyPackIdx != nil else { return false }
        let full = args.contains("--selftest-all")
        let sem = DispatchSemaphore(value: 0)
        if let i = verifyPackIdx {
            let id = args.count > i + 1 ? args[i + 1] : "1.20.1"
            let fix = args.contains("--fix")
            Task.detached {
                await packVerifyCheck(id, fix: fix)
                sem.signal()
            }
        } else if let i = patchIdx {
            let id = args.count > i + 1 ? args[i + 1] : "1.20.1"
            let fix = args.contains("--fix")
            Task.detached {
                await patchCheck(id, fix: fix)
                sem.signal()
            }
        } else if let i = i18nIdx {
            let id = args.count > i + 1 ? args[i + 1] : "1.20.1"
            Task.detached {
                await i18nCheck(id)
                sem.signal()
            }
        } else if let i = repairLoaderIdx {
            let id = args.count > i + 1 ? args[i + 1] : "1.20.1"
            Task.detached {
                await repairLoaderCheck(id)
                sem.signal()
            }
        } else if let i = verifyLibIdx {
            let id = args.count > i + 1 ? args[i + 1] : "1.20.1"
            let fix = args.contains("--fix")
            Task.detached {
                await librariesCheck(id, fix: fix)
                sem.signal()
            }
        } else if hmclIdx != nil {
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
            // 可选第二参数：观察秒数（重 mod 整合包进主菜单要 60~120 秒，25 秒只看得到加载）
            let secs = Int(args.count > i + 2 ? args[i + 2] : "") ?? 25
            Task.detached {
                await launchCheck(id, seconds: secs)
                sem.signal()
            }
        } else if let i = planIdx {
            let id = args.count > i + 1 ? args[i + 1] : "26.3"
            Task.detached {
                await launchCheck(id, seconds: 0)
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
        } else if args.contains("--perf-check") {
            Task.detached {
                await perfCheck()
                sem.signal()
            }
        } else if let i = packImportIdx {
            // --pack-import <包路径> [目标 MC 版本]
            let path = args.count > i + 1 ? args[i + 1] : ""
            let over: String? = args.count > i + 2 ? args[i + 2] : nil
            Task.detached {
                await packImportCheck(path, overrideMC: over)
                sem.signal()
            }
        } else if let i = packPreviewIdx {
            let path = args.count > i + 1 ? args[i + 1] : ""
            Task.detached {
                await packPreviewCheck(path)
                sem.signal()
            }
        } else if args.contains("--loader-reuse-check") {
            Task.detached {
                loaderReuseCheck()
                sem.signal()
            }
        } else if args.contains("--layout-check") {
            Task.detached {
                layoutCheck()
                sem.signal()
            }
        } else if args.contains("--layout-migrate") {
            Task.detached {
                layoutMigrate()
                sem.signal()
            }
        } else if args.contains("--vulkanmod-check") {
            Task.detached {
                await vulkanModCheck()
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

    /// 汉化包预热（I18nUpdateMod 的缓存准备）。
    /// 用法：`--i18n-prewarm <versionID>`
    static func i18nCheck(_ versionID: String) async {
        out("=== 汉化包预热：\(versionID) ===")
        out("  缓存根：\(I18nPrewarm.cacheRoot.path)")
        let o = await I18nPrewarm.prepareIfNeeded(versionID: versionID) { out("  " + $0) }
        out("  下载 \(o.downloaded.count) 个 · 跳过 \(o.skipped) 个 · 失败 \(o.failed.count) 个")
        if let note = o.note { out("  \(note)") }
    }

    /// 整合包文件清单（.aether-files.json）自检 / 补齐。
    /// 用法：`--pack-verify <versionID> [--fix]`
    ///
    /// 清单是导入 mrpack 时从 modrinth.index.json 落的「契约」，
    /// 用它能发现「导入报成功、其实少下几个大 mod」这种隐性缺损。
    static func packVerifyCheck(_ versionID: String, fix: Bool) async {
        let dir = Paths.versionDir(versionID)
        let all = PackIntegrity.load(profileDir: dir)
        out("=== 整合包文件清单：\(versionID) ===")
        guard !all.isEmpty else {
            out("  没有 \(PackIntegrity.manifestName)（这个实例不是 mrpack 导入的）")
            return
        }
        let gap = PackIntegrity.missing(profileDir: dir)
        out("  清单 \(all.count) 项 · 缺失 \(gap.count) 项\(gap.isEmpty ? " ✔" : " ✖")")
        for it in gap.prefix(40) { out("   · \(it.path)") }
        guard fix, !gap.isEmpty else { return }
        out("  开始补齐…")
        let r = await PackIntegrity.repair(profileDir: dir,
                                           log: { out("  " + $0) },
                                           progress: { d, t in
            if d % 5 == 0 || d == t { out("  [\(d)/\(t)]") }
        })
        out("  结果：补上 \(r.fixed) 个 · 仍缺 \(r.remaining.count) 个")
        for p in r.remaining { out("   ✖ \(p)") }
    }

    /// 整合包补丁清单（missing_mods_checker.json）检查 / 补齐。
    /// 用法：`--pack-patch <versionID> [--fix]`
    ///
    /// 这份清单里的文件不在 manifest.json 里，游戏侧的 MissingModsChecker 会
    /// 在 ModLauncher 最早期弹窗并阻塞主线程 —— 缺一项就卡在 EARLYDISPLAY 之后。
    static func patchCheck(_ versionID: String, fix: Bool) async {
        let dir = Paths.versionDir(versionID)
        let manifest = PackPatch.manifestURL(profileDir: dir)
        out("=== 整合包补丁清单：\(versionID) ===")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            out("  没有 \(PackPatch.manifestRelativePath)（这个包不需要补丁）✔")
            return
        }
        let p = PackPatch.pending(profileDir: dir)
        out("  清单 \(p.checked) 项 · 缺失 \(p.missing.count) 项\(p.missing.isEmpty ? " ✔" : " ✖")")
        for e in p.missing.prefix(60) {
            out("   · [\(e.folder)] \(e.name) → \(e.fileName)")
        }
        guard fix, !p.missing.isEmpty else { return }
        out("  开始补齐…")
        let o = await PackPatch.repair(profileDir: dir,
                                       log: { out("  " + $0) },
                                       progress: { d, t in
            if d % 10 == 0 || d == t { out("  [\(d)/\(t)]") }
        })
        out("  结果：补齐 \(o.downloaded.count) 个 · 失败 \(o.failed.count) 个")
        for f in o.failed { out("   ✖ \(f)") }
    }

    /// 修复「装了一半」的 Forge / NeoForge 核心（强制重跑安装器）。
    /// 用法：`--repair-loader <versionID>`
    static func repairLoaderCheck(_ versionID: String) async {
        out("=== 加载器核心修复：\(versionID) ===")
        do {
            let r = try VersionLibrary.resolve(versionID)
            out("  继承链：\(r.chain.joined(separator: " → "))")
            let missing = LaunchService.missingLoaderArtifacts(details: r.details,
                                                               librariesDir: Paths.librariesDir)
            out("  缺失核心文件：\(missing.count) 个")
            for m in missing { out("   · \(m.path)") }
            if missing.isEmpty { out("  ✔ 无需修复（核心文件齐全）"); return }

            let major = JavaManager.requiredJavaMajor(for: r.details, hint: r.chain.last)
            let java = try await JavaManager.javaExecutable(major: major) { _, _ in }
            let id = try await Loaders.repairLoader(versionID: versionID, java: java,
                                                    log: { out("  " + $0) },
                                                    progress: { p in out("  [\(p.done)/\(p.total)] \(p.message)") })
            out("  ✔ 已修复：\(id)")

            let after = LaunchService.missingLoaderArtifacts(
                details: try VersionLibrary.resolve(versionID).details,
                librariesDir: Paths.librariesDir)
            out("  复检缺失：\(after.count) 个\(after.isEmpty ? " ✔" : " ✖")")
            for m in after { out("   · \(m.path)") }
        } catch {
            out("✖ 修复失败：\(error.localizedDescription)")
        }
    }

    /// 启动前体检：把某个版本 classpath 上的 jar 全过一遍「大小 + zip 结构」。
    /// 用法：`--verify-libraries <versionID> [--fix]`
    /// 不出问题的时候它是静默的（只打印一行统计），出问题才逐条列出来；
    /// `--fix` 会把损坏的文件删掉，下次启动下载器会自动补齐（相当于手动触发自愈）。
    static func librariesCheck(_ versionID: String, fix: Bool) async {
        out("=== 依赖库完整性检查：\(versionID) ===")
        let resolved: ResolvedVersion
        do { resolved = try VersionLibrary.resolve(versionID) }
        catch {
            out("✖ 无法解析版本：\(error.localizedDescription)")
            return
        }
        out("  继承链：\(resolved.chain.joined(separator: " → "))")

        struct Item: Sendable {
            let label: String
            let url: URL
            let want: Int64?
            let sha1: String?
        }
        var items: [Item] = []
        for lib in resolved.details.libraries where rulesAllow(lib.rules, features: [:]) {
            guard let a = lib.artifact() else { continue }
            let local = Paths.librariesDir.appendingPathComponent(a.path)
            items.append(Item(label: a.path, url: local, want: a.size, sha1: a.sha1))
        }
        let jar = Paths.clientJar(resolved.clientJarID)
        items.append(Item(label: jar.lastPathComponent, url: jar,
                          want: resolved.details.downloads?.client?.size.map(Int64.init),
                          sha1: resolved.details.downloads?.client?.sha1))

        let bad = await Task.detached(priority: .utility) { () -> [Item] in
            items.filter { !FileIntegrity.isUsable($0.url, expectedSize: $0.want, archive: true) }
        }.value

        out("  共 \(items.count) 项，异常 \(bad.count) 项")
        for b in bad {
            let exists = FileManager.default.fileExists(atPath: b.url.path)
            let state = exists ? "\(FileIntegrity.byteSize(b.url)) 字节（期望 \(b.want.map(String.init) ?? "未知")）"
                               : "文件缺失"
            out("   ✖ \(b.label)  \(state)")
            guard fix else { continue }
            // --fix：直接按 maven 相对路径重下（与启动时的下载器同一套换源逻辑）。
            // 只删不下的做法会让用户下次启动卡在下载上，这里一次修干净更好验证。
            do {
                try await DownloadManager.downloadCandidates(mavenCandidates(for: b.label),
                                                             kind: .library,
                                                             to: b.url,
                                                             sha1: b.sha1)
                let ok = FileIntegrity.isUsable(b.url, expectedSize: b.want, archive: true)
                out("     → \(ok ? "已重下 ✔" : "重下后仍不完整 ✖")（\(FileIntegrity.byteSize(b.url)) 字节）")
            } catch {
                try? FileManager.default.removeItem(at: b.url)
                out("     ✖ 重下失败：\(error.localizedDescription)（已删除，下次启动会再试）")
            }
        }
        if bad.isEmpty { out("  ✔ 全部完整（大小 + zip 结构都对得上）") }
    }

    /// 由 `libraries/` 下的相对路径拼出一组 maven 候选源（bmclapi 优先，国内最快）。
    static func mavenCandidates(for relativePath: String) -> [MirrorCandidate] {
        let roots: [(String, String)] = [
            ("bmclapi", "https://bmclapi2.bangbang93.com/maven/"),
            ("forgecdn", "https://neoforged.forgecdn.net/releases/"),
            ("forge", "https://maven.minecraftforge.net/"),
            ("neoforge", "https://maven.neoforged.net/releases/"),
            ("mojang", "https://libraries.minecraft.net/"),
            ("fabric", "https://maven.fabricmc.net/"),
        ]
        return roots.compactMap { label, root in
            URL(string: root + relativePath).map { MirrorCandidate(source: label, url: $0) }
        }
    }

    /// 只读检查：打印存储布局现状 + 迁移计划（不移动任何文件）。
    static func layoutCheck() {
        out("=== 存储布局检查（只读，不动文件）===")
        out("  appSupport     : \(Paths.appSupport.path)")
        out("  profiles/      : \(Paths.profilesDir.path)  [存在=\(Paths.isDirectory(Paths.profilesDir))]")
        out("  meta/versions/ : \(Paths.metaVersionsDir.path)  [存在=\(Paths.isDirectory(Paths.metaVersionsDir))]")
        let legacy = Paths.legacyVersionsDir
        out("  versions/      : \(legacy.path)  [软链=\(Paths.isSymlink(legacy)) 存在=\(FileManager.default.fileExists(atPath: legacy.path))]")
        out("  .packcores/    : [存在=\(FileManager.default.fileExists(atPath: Paths.packCoresDir.path))]")
        out("  需要迁移       : \(hasLegacyLayoutFlag())")
        out("")
        out("--- 迁移计划 ---")
        let steps = VersionLibrary.planMigration()
        if steps.isEmpty {
            out("  （无，已经在新布局上）")
        } else {
            for s in steps {
                out("  \(s.action.rawValue)\t\(s.id)")
            }
        }
        out("")
        out("--- 当前实例（列表只会显示这些）---")
        let installed = VersionLibrary.scan()
        if installed.isEmpty {
            out("  （空）")
        } else {
            for v in installed {
                out("  \(v.id)\t\(v.loader.title)\tbase=\(v.baseVersion ?? "-")\tjar=\(v.hasClientJar)\t\(v.dir.path)")
            }
        }
        out("")
        out("--- 继承链解析（实例 → 加载器核心 → 原版核心）---")
        for v in installed {
            if let r = try? VersionLibrary.resolve(v.id) {
                out("  ✔ \(v.id) → \(r.chain.joined(separator: " → "))  · jar=\(r.clientJarID)  · 主类=\(r.details.mainClass)")
            } else {
                out("  ✖ \(v.id) 解析失败")
            }
        }
    }

    private static func hasLegacyLayoutFlag() -> Bool { VersionLibrary.hasLegacyLayout }

    /// 验证「已装加载器复用」：Forge 传入 `forge-<mc>-<ver>`，
    /// 实际目录是 `<mc>-forge-<ver>`，两者词序不同 —— 旧实现永远匹配不到，
    /// 于是每次导入都重跑安装器。
    static func loaderReuseCheck() {
        out("=== 已装加载器复用检查 ===")
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: Paths.metaVersionsDir.path)) ?? []
        out("  meta/versions: \(entries.sorted().joined(separator: ", "))")
        out("")
        var bad = 0
        for e in entries.sorted() where e.lowercased().contains("forge") {
            let probe: String
            if let r = e.range(of: "-forge-") {
                let mc = String(e[e.startIndex..<r.lowerBound])
                let ver = String(e[r.upperBound...])
                probe = "forge-\(mc)-\(ver)"
            } else {
                probe = e
            }
            if let hit = Loaders.installedLoaderID(probe) {
                out("  ✔ \(probe) → 复用 \(hit)")
            } else {
                bad += 1
                out("  ✖ \(probe) → 未命中（会重装一遍安装器）")
            }
        }
        out("")
        out(bad == 0 ? "全部命中，重复导入不会再跑安装器。" : "有 \(bad) 个没命中。")
    }

    /// 端到端跑一次导入，用来看「目标 MC 版本」覆盖是否真的生效。
    static func packImportCheck(_ path: String, overrideMC: String?) async {
        guard !path.isEmpty else { out("用法：--pack-import <包路径> [目标MC版本]"); return }
        let url = URL(fileURLWithPath: path)
        out("=== 整合包导入（目标 MC = \(overrideMC ?? "跟随包内声明")）===")
        do {
            let r = try await ModpackImporter.import(url, baseVersionID: nil,
                                                    overrideMC: overrideMC) { line in
                out("  " + line)
            }
            out("✔ 实例：\(r.versionID) · \(r.fileCount) 个文件 · \(String(format: "%.1f", r.elapsed))s")
            let json = Paths.profileDir(r.versionID).appendingPathComponent("\(r.versionID).json")
            out("  实例 JSON：")
            for line in ((try? String(contentsOf: json, encoding: .utf8)) ?? "读取失败")
                .split(separator: "\n") {
                out("    " + line)
            }
        } catch {
            out("✖ 失败：\(error.localizedDescription)")
        }
    }

    /// 读一个整合包文件，模拟导入设置面板会显示什么（不改任何文件）。
    static func packPreviewCheck(_ path: String) async {
        guard !path.isEmpty else { out("用法：--pack-preview <整合包路径>"); return }
        let url = URL(fileURLWithPath: path)
        out("=== 整合包预览 ===")
        out("  文件: \(url.path)")
        out("  存在: \(FileManager.default.fileExists(atPath: url.path))")
        out("  识别: \(ModpackImporter.detect(url).rawValue)")
        let p = await ModpackImporter.preview(of: url)
        out("  名称: \(p.name)")
        out("  格式: \(p.kind.rawValue)")
        out("  包内声明 MC: \(p.declaredMC.isEmpty ? "（无）" : p.declaredMC)")
        out("  加载器: \(p.loader.isEmpty ? "（无）" : p.loader)")
    }

    /// 真正执行迁移（和主页「一键迁移」按钮同一条代码路径）。
    static func layoutMigrate() {
        out("=== 执行迁移 ===")
        let before = VersionLibrary.planMigration().count
        out("  计划 \(before) 项")
        do {
            let r = try VersionLibrary.migrateLegacyLayout { line in out("  · \(line)") }
            out("  完成：核心 \(r.cores) · 实例 \(r.profiles) · 跳过 \(r.skipped)")
        } catch {
            out("  ✖ 失败：\(error.localizedDescription)")
        }
        out("")
        layoutCheck()
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
    /// 找一个能用的 java（用于参数合法性实测）。
    private static func findAnyJava() -> URL? {
        // 优先用 Aether 自己下的运行时
        let runtimes = Paths.runtimesDir
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: runtimes, includingPropertiesForKeys: nil) {
            for dir in entries {
                let java = dir.appendingPathComponent("jdk-*/Contents/Home/bin/java")
                // glob 展开：直接找 Contents/Home/bin/java
                let home = dir.appendingPathComponent("Contents/Home/bin/java")
                if FileManager.default.isExecutableFile(atPath: home.path) {
                    return home
                }
                _ = java
            }
        }
        // 退到系统 java
        for p in ["/usr/bin/java",
                  "/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home/bin/java",
                  "/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home/bin/java"] {
            if FileManager.default.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    /// 性能调优自检：验证 JVM 参数生成与 Vulkan 环境探测。
    ///
    /// 这个自检不联网、不启动游戏，纯本地检查：
    /// ① JVM 调优参数在不同 Java 版本 / GC 选择下生成是否合理
    /// ② Vulkan 环境（MoltenVK / ICD / loader）探测是否准确
    /// ③ ICD 修复后 loader 能不能真的找到驱动
    private static func perfCheck() async {
        out("=== 性能调优自检 ===")

        // ---- ① JVM 参数 ----
        out("")
        out("▶ JVM 调优参数")
        for major in [8, 11, 17, 21, 25] {
            let rec = JVMOptimize.recommendedGC(major: major)
            let args = JVMOptimize.arguments(major: major, memoryMB: 4096, gc: nil, aggressive: false)
            out("  Java \(major): 推荐 GC = \(rec.rawValue)")
            out("    \(args.joined(separator: " "))")
            // 断言：参数里不能有重复 key
            var seen = Set<String>()
            for a in args {
                let key = String(a.prefix(while: { $0 != "=" }))
                if seen.contains(key) { out("    ✖ 参数重复：\(key)") }
                seen.insert(key)
            }
        }
        out("  激进模式（Java 21 + ZGC）：")
        let aggressiveArgs = JVMOptimize.arguments(major: 21, memoryMB: 4096, gc: .zgc, aggressive: true)
        out("    \(aggressiveArgs.joined(separator: " "))")

        // ---- ①.5 用真实 java 验证参数被接受 ----
        //
        // 这是最关键的一步：JVM 不认识的参数会**直接拒绝启动**，
        // 而 macOS 上有些 Linux/Windows 的参数是致命的（实测踩过）。
        out("")
        out("▶ 参数合法性实测（用真实 JVM 跑 -version）")
        if let java = findAnyJava() {
            out("  用的是：\(java.path)")
            let cases: [(String, Int, JVMOptimize.GCKind?, Bool)] = [
                ("自动·Java 8", 8, nil, false),
                ("自动·Java 21", 21, nil, false),
                ("ZGC·Java 21", 21, .zgc, false),
                ("G1GC·Java 21", 21, .g1, false),
                ("Shenandoah·Java 21", 21, .shenandoah, false),
                ("激进·Java 21", 21, .zgc, true),
            ]
            var allOK = true
            for (name, major, gc, agg) in cases {
                // 注意：这里测的是**降级后**的参数 ——
                // 用户选 Shenandoah 但 JVM 不支持时，实际用的应该是降级后的 GC。
                let effective = JVMOptimize.resolveGC(preferred: gc, javaMajor: major, javaExecutable: java)
                let args = JVMOptimize.arguments(major: major, memoryMB: 1024, gc: effective, aggressive: agg)
                let r = JVMOptimize.validate(javaExecutable: java, arguments: args)
                let suffix = (gc != nil && gc != effective) ? "（\(gc!.rawValue) → \(effective.rawValue)）" : ""
                if r.ok {
                    out("  ✔ \(name)\(suffix)")
                    if let m = r.message.contains("warning") ? r.message : nil {
                        out(m)
                    }
                } else {
                    allOK = false
                    out("  ✖ \(name)\(suffix) → \(r.message)")
                }
            }
            out(allOK ? "  全部参数通过" : "  有参数不被本机 JVM 接受")

            // ---- ①.6 GC 自动降级 ----
            //
            // 关键场景：用户选了 Shenandoah，但装的是 **Oracle JDK**（不带 Shenandoah）
            // → 必须自动退到 ZGC/G1，否则游戏起不来。
            out("")
            out("▶ GC 自动降级")
            for want in [JVMOptimize.GCKind.zgc, .shenandoah, .g1, .parallel] {
                let got = JVMOptimize.resolveGC(preferred: want, javaMajor: 21, javaExecutable: java)
                let avail = JVMOptimize.isGCAvailable(got, javaExecutable: java)
                let mark = avail ? "✔" : "✖"
                let note = (want == got) ? "" : "（降级：\(want.rawValue) → \(got.rawValue)）"
                out("  \(mark) 选 \(want.rawValue) → 实际 \(got.rawValue)\(note)")
                if !avail { allOK = false }
            }
            out(allOK ? "  降级策略正常" : "  降级策略有问题")
        } else {
            out("  △ 找不到 java，跳过")
        }

        // ---- ② Vulkan 环境 ----
        out("")
        out("▶ Vulkan 环境探测")
        let st = VulkanSupport.detect()
        out("  loader 已安装：\(st.loaderInstalled)")
        out("  MoltenVK 已安装：\(st.moltenVKInstalled)")
        out("  ICD 就绪：\(st.icdReady)")
        if let icd = st.icdPath { out("  ICD 路径：\(icd)") }
        out("  状态：\(st.summary)")

        // ---- ③ ICD 修复 ----
        out("")
        out("▶ ICD 修复")
        if st.moltenVKInstalled {
            let r = VulkanSupport.repairICD()
            out("  \(r.ok ? "✔" : "✖") \(r.message)")
            if r.ok {
                let env = VulkanSupport.environmentOverrides()
                if let icd = env["VK_ICD_FILENAMES"] {
                    out("  将注入 VK_ICD_FILENAMES=\(icd)")
                    out("  存在：\(FileManager.default.fileExists(atPath: icd))")
                } else {
                    out("  ✖ 没能生成 ICD 路径")
                }
            }
        } else {
            out("  跳过（没装 MoltenVK）")
        }

        out("")
        out("=== 性能调优自检结束 ===")
    }

    /// VulkanMod 可用性自检（联网查 Modrinth，但不实际安装）。
    private static func vulkanModCheck() async {
        out("=== VulkanMod 可用性验证 ===")

        // 找一个 Fabric / Quilt 实例
        let installed = VersionLibrary.scan()
        guard let target = installed.first(where: { $0.loader == .fabric || $0.loader == .quilt }) else {
            out("△ 本机没有 Fabric / Quilt 实例，跳过")
            out("=== 结束 ===")
            return
        }
        let mcVersion = VersionLibrary.baseMinecraftVersion(of: target.id) ?? target.id
        out("目标实例：\(target.id)（\(target.loader.title) / MC \(mcVersion)）")
        out("支持 VulkanMod：\(VulkanSupport.supportsVulkanMod(versionID: target.id))")
        out("已装 VulkanMod：\(VulkanSupport.hasVulkanMod(versionID: target.id))")

        do {
            let versions = try await Modrinth.versions(projectID: VulkanSupport.vulkanModProjectID,
                                                        mcVersion: mcVersion,
                                                        loader: target.loader)
            // 严格过滤：必须精确命中 game_versions
            // （Modrinth.versions 有「查不到就退回不限制版本」的兜底，
            //   会把不兼容的版本也带回来 —— VulkanMod 不能这么干）
            let exact = versions.filter { $0.game_versions.contains(mcVersion) }
            out("Modrinth 上共 \(versions.count) 个版本，严格匹配 MC \(mcVersion) 的有 \(exact.count) 个")
            for v in exact.prefix(6) {
                out("  · \(v.version_number) → \(v.primaryFile?.filename ?? "?")")
            }
            if let pick = exact.first {
                out("✔ 可安装：\(pick.version_number) → \(pick.primaryFile?.filename ?? "?")")
            } else {
                let newest = versions.first?.game_versions.joined(separator: ",") ?? "?"
                out("△ 没有适配 MC \(mcVersion) 的 VulkanMod（Modrinth 上最新支持 \(newest)）")
            }
        } catch {
            out("✖ 查询失败：\(error.localizedDescription)")
        }
        out("=== 结束 ===")
    }

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

    /// 找出命令行里带着这个 gameDir 的进程（`pgrep -f`）。
    /// 用来避免「自检起第二个实例」把用户正在玩的那个一起搅掉。
    private static func runningPIDs(matching pattern: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let mine = String(ProcessInfo.processInfo.processIdentifier)
        return (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != mine }
    }

    private static func launchCheck(_ versionId: String, seconds: Int = 25) async {
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
            // 和 GUI 用同一套窗口尺寸逻辑，否则 CLI 测出来的窗口行为跟用户看到的不是一回事。
            let win = DisplayDefaults.windowSize()
            out("窗口：\(win.w)×\(win.h)")

            let plan = LaunchService.plan(
                details: d, javaExecutable: java, username: SettingsKeys.usernameValue,
                memoryMB: SettingsKeys.effectiveMemoryMB, resolution: (win.w, win.h),
                gameDir: Paths.versionDir(versionId), clientJar: jar,
                librariesDir: Paths.librariesDir, nativesDir: Paths.nativesDir(versionId),
                classpath: cp, assetsRoot: Paths.assetsDir, assetsIndexName: name,
                account: imported, javaMajor: major)
            out("Java: \(java.path)（\(major)）")
            // 把真正生效的调优参数打出来 —— 做 A/B 对比时，先确认注入没被默认值盖掉。
            let effective = plan.arguments.filter {
                $0.hasPrefix("-Xmx") || $0.hasPrefix("-Xms") || $0.hasPrefix("-XX:")
                    || $0.hasPrefix("-Xlog")
            }
            out("JVM: \(effective.joined(separator: " "))")

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

            // 只打参数不启动：用户正开着游戏时也能核对注入结果，不会抢同一个 gameDir。
            guard seconds > 0 else {
                out("（--launch-plan：仅打印启动参数，未启动进程）")
                return
            }

            // 同一个实例已经有进程在跑就别再起第二个：两个进程共用一份 logs / options.txt /
            // 存档锁，退出时按 PID 杀很容易把用户正在玩的那个一起带走。
            let gameDir = Paths.versionDir(versionId)
            let running = runningPIDs(matching: gameDir.path)
            guard running.isEmpty else {
                out("✖ 该实例已有进程在运行（PID \(running.joined(separator: ", "))），为避免打断，不再启动第二个。")
                out("  只核对参数：--launch-plan \(versionId)；要测启动请先退出游戏。")
                return
            }

            out("启动游戏，观察 \(seconds) 秒…")
            try proc.run()
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 5)) * 1_000_000_000)
            if proc.isRunning { proc.terminate() }
            proc.waitUntilExit()

            let lines = box.snapshot()
            let joined = lines.joined(separator: "\n")
            // 完整输出落一份到 /tmp：堆栈关键信息（哪条路径不存在）常在被截断的尾部。
            try? joined.write(toFile: "/tmp/aether-launch-dump.log", atomically: true, encoding: .utf8)
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
