//
//  ZipTool.swift
//  maccraft
//
//  压缩包解压 / 目录合并（整合包导入的 IO 层）。
//
//  为什么不用 `unzip`：
//   · 实测同一个 339MB 的整合包（375MB 解压后 / 1325 个文件），
//     `/usr/bin/unzip` 要 3.1 秒，`/usr/bin/ditto -x -k` 只要 1.1 秒；
//   · ditto 走 libarchive + APFS 的 clonefile，跨目录复制 375MB 只要 0.25 秒，
//     而 FileManager.copyItem 逐文件 copy 要 2.4 秒。
//   · 以前「先解压到临时目录、再递归复制到版本目录」，等于写两遍 375MB，
//     现在解压 + clone 合并一次搞定，整个导入从 ~6 秒降到 ~1.4 秒。
//
//  ditto 不打印逐文件进度，所以解压过程中按固定间隔统计目标目录里
//  已落盘的文件数 / 字节数，用来驱动进度条 —— 这就是「实时」的来源。
//

import Foundation

nonisolated enum ZipTool {
    // MARK: - 列条目

    /// 中央目录里的全部条目（含目录项）。坏字节容错解码。
    static func entries(of url: URL) -> [String]? {
        guard let data = runCapture("/usr/bin/unzip", ["-Z1", url.path]), !data.isEmpty else { return nil }
        // 整合包里常有 Windows 打包留下的非 UTF-8 文件名，严格解码会整体返回 nil，
        // 导致格式被误判成 unknown。这里容错解码，坏字节替换成 U+FFFD。
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// 只要真实文件（去掉 `dir/` 结尾的目录项）。
    static func fileEntries(of url: URL) -> [String] {
        (entries(of: url) ?? []).filter { !$0.hasSuffix("/") }
    }

    // MARK: - 解压

    /// 用 ditto 解压，边解压边统计已落盘的文件数与字节数。
    /// - Parameters:
    ///   - expectedFiles: 压缩包里真实文件总数（进度分母，0 表示未知）。
    ///   - onTick: (已完成文件数, 已完成字节, 期望文件数)
    static func extract(_ archive: URL,
                        to dir: URL,
                        expectedFiles: Int = 0,
                        onTick: @escaping @Sendable (Int, Int64) -> Void = { _, _ in }) async throws {
        try Paths.ensure(dir)
        let ticker = ExtractTicker(expected: expectedFiles)
        let poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                let m = ticker.sample(dir)
                onTick(m.files, m.bytes)
                // 已经到齐就不用再遍历了
                if expectedFiles > 0, m.files >= expectedFiles { return }
            }
        }
        defer { poller.cancel() }
        try await runDitto(["-x", "-k", "--noqtn", archive.path, dir.path])
        let m = ticker.sample(dir)
        onTick(m.files, m.bytes)
    }

    /// 把 src 的内容合并进 dst。同卷时 ditto 走 clonefile，几乎不耗 IO。
    /// 目录是合并语义（目标独有的文件保留），文件同名才覆盖 ——
    /// 这正是 overrides 需要的：不能把刚下载的 mod 冲掉。
    /// - Parameter onItem: (当前项名, 已完成项数, 总项数)
    /// - Parameter skip: 返回 true 的顶层项会被跳过（用于剔除整合包自带的客户端 jar）
    static func merge(_ src: URL, into dst: URL,
                      onItem: @escaping @Sendable (String, Int, Int) -> Void = { _, _, _ in },
                      skip: (@Sendable (URL) -> Bool)? = nil) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        try Paths.ensure(dst)
        let items = (try? fm.contentsOfDirectory(at: src,
                                                 includingPropertiesForKeys: nil,
                                                 options: [])) ?? []
        for (i, item) in items.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            if let skip, skip(item) { continue }
            let target = dst.appendingPathComponent(item.lastPathComponent)
            try await runDitto(["--noqtn", item.path, target.path])
            onItem(item.lastPathComponent, i + 1, items.count)
        }
    }

    /// 只解压匹配的条目（`unzip` 的 include 通配），逐文件上报进度。
    /// 通用整合包常带 versions/ 下的客户端 jar、saves、甚至内置 JRE，
    /// 全量解压纯属浪费 —— 这里只取 mods / config 这些真正需要的目录。
    /// - Parameter onFile: (已完成文件数, 文件路径)
    static func extract(_ archive: URL,
                        to dir: URL,
                        including patterns: [String],
                        expectedFiles: Int,
                        onFile: @escaping @Sendable (Int, String) -> Void) async throws {
        try Paths.ensure(dir)

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            private var last = Date.distantPast
            /// 逐文件回调要节流：一个 280 mod 的包有上千行，每行都刷一次界面会卡。
            func bump(_ path: String, onFile: @Sendable (Int, String) -> Void) {
                lock.lock()
                n += 1
                let count = n
                let now = Date()
                let due = now.timeIntervalSince(last) > 0.08
                if due { last = now }
                lock.unlock()
                if due { onFile(count, path) }
            }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let box = Box()

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-o"] + patterns + [archive.path, "-d", dir.path]

            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            let pump = LinePump { lines in
                for line in lines {
                    // 输出形如 "  inflating: /tmp/x/mods/foo.jar"
                    guard let r = line.range(of: ": ") else { continue }
                    let verb = line[line.startIndex..<r.lowerBound]
                    guard verb.contains("inflating") || verb.contains("extracting") else { continue }
                    let path = String(line[r.upperBound...])
                    box.bump(path) { n, p in onFile(n, p) }
                }
            }
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    h.readabilityHandler = nil
                    pump.flushRemainder()
                    return
                }
                pump.feed(d)
            }
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                pump.flushRemainder()
                guard proc.terminationStatus == 0 else {
                    let data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let msg = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    c.resume(throwing: LauncherError.cannotWrite(
                        msg.isEmpty ? "解压失败（unzip 退出码 \(proc.terminationStatus)）" : String(msg.suffix(240))))
                    return
                }
                c.resume()
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
        onFile(max(box.value, expectedFiles), "")
    }

    // MARK: - 统计

    /// 目录下真实文件数与总字节（不读内容，只走元数据）。
    static func measure(_ dir: URL) -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir,
                                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                    options: []) else { return (0, 0) }
        var n = 0
        var b: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  v.isRegularFile == true else { continue }
            n += 1
            b += Int64(v.fileSize ?? 0)
        }
        return (n, b)
    }

    /// 解压进度用的轻量统计。
    ///
    /// 之前用 `measure` 每 300ms 遍历一次全目录（1325 个文件），
    /// 在 APFS 上每次要几百毫秒，解压 1 秒的包反而被统计拖到十几秒。
    /// 改成「增量计数」：达到预期文件数后立刻停止遍历。
    final class ExtractTicker: @unchecked Sendable {
        private let lock = NSLock()
        private var lastFiles = 0
        private var lastBytes: Int64 = 0
        private let expected: Int

        init(expected: Int) { self.expected = expected }

        /// 返回 (已完成文件数, 已完成字节)。达到预期后立刻停止遍历。
        func sample(_ dir: URL) -> (files: Int, bytes: Int64) {
            lock.lock()
            defer { lock.unlock() }
            if expected > 0, lastFiles >= expected { return (lastFiles, lastBytes) }
            let m = measure(dir)
            lastFiles = m.files
            lastBytes = m.bytes
            return m
        }
    }

    /// 判断一个 jar 是不是「Minecraft 客户端本体」（而不是 mod）。
    ///
    /// 整合包经常在根目录塞一个客户端 jar（很多整合包作者把启动器下载的 client.jar 一起打包）。
    /// 对原版实例这是无害的（启动器会用自己下的那份），但对 Forge/NeoForge 实例是致命的：
    /// 客户端 jar 会被 SecureJarHandler 按混淆包名推导出模块名 `client`，
    /// 而 NeoForge 的 srg jar 导出模块名 `minecraft`，两者都含 `net.minecraft.server` →
    /// ```
    /// java.lang.module.ResolutionException: Modules minecraft and client
    ///   export package net.minecraft.world.level.storage.loot to module xxx
    /// ```
    /// 所以导入加载器实例时必须把根目录的客户端 jar 剔掉。
    ///
    /// 判据（原版混淆 jar 的特征）：**class 几乎全在根目录，且文件名是短混淆名**。
    /// mod 的 class 都在 `modid/` 或 `net/xxx/` 这样的包路径下。
    /// 例：原版 1.21.1.jar 顶层是 `a.class`、`aa.class`、`aae$a.class`……
    static func isMinecraftClientJar(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int64, size > 8_000_000 else {
            return false
        }
        guard let data = runCapture("/usr/bin/unzip", ["-Z1", url.path]),
              let text = String(data: data, encoding: .utf8) else { return false }

        // 统计「根目录下的 class」和「带包路径的 class」
        var rootClasses = 0
        var nestedClasses = 0
        for line in text.split(separator: "\n") {
            guard line.hasSuffix(".class") else { continue }
            if line.contains("/") {
                nestedClasses += 1
            } else {
                rootClasses += 1
            }
        }
        // 混淆 jar：class 绝大多数（>90%）在根目录
        let total = rootClasses + nestedClasses
        guard total > 1000 else { return false }
        return Double(rootClasses) / Double(total) > 0.9
    }

    // MARK: - 进程

    private static func runDitto(_ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = Pipe()
            p.terminationHandler = { proc in
                guard proc.terminationStatus != 0 else { c.resume(); return }
                let data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let msg = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                c.resume(throwing: LauncherError.cannotWrite(
                    msg.isEmpty ? "ditto 退出码 \(proc.terminationStatus)" : String(msg.suffix(240))))
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    /// 同步跑一个命令并把 stdout 全部读回（`unzip -Z1` 这种小输出用）。
    private static func runCapture(_ exe: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        // stderr 直接丢弃：不读的话 64KB 管道缓冲一满，子进程就会阻塞 → readDataToEndOfFile 死锁。
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return data
    }
}
