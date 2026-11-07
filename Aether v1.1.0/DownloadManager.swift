//
//  DownloadManager.swift
//  maccraft
//
//  流式下载（delegate 直写磁盘，全速 + 字节级进度 + SHA-1 校验）与并发批量下载。
//
//  换源策略（对应 HMCL 的 FileDownloadTask(List<URI>) 与 PCL2 的 NetTask.Sources）：
//   · 每个文件携带候选 URL 列表，逐个尝试；
//   · 中途加「看门狗」：首字节超时 / 断流 / 平均速度过低，立刻掐断换下一个源
//     —— BMCLAPI 的 sakura 节点就是「连上了、有首字节、然后涓流」，
//        只靠 URLSession 的请求超时永远等不到，这是之前卡在 0.0/14.5MB 的根因；
//   · 最后一个候选不做速度门槛（慢也得下完，总比失败好）。
//

import Foundation
import CryptoKit

nonisolated enum LauncherError: Error, LocalizedError {
    case cannotWrite(String)
    case checksumMismatch(String, String)
    case missingClient
    case http(Int)
    case javaUnavailable
    case processFailed(Int)
    case stalled(String)

    var errorDescription: String? {
        switch self {
        case .cannotWrite(let p): return "无法写入文件：\(p)"
        case .checksumMismatch(let a, let b): return "校验和不匹配（实际 \(a) ≠ 期望 \(b)）"
        case .missingClient: return "客户端 jar 缺失"
        case .http(let code): return "HTTP \(code)"
        case .javaUnavailable: return "Java 运行时不可用（下载失败或被网络拦截）。请在「设置 → Java 运行时」里手动指定本机已安装的 JDK 目录。"
        case .processFailed(let c): return "进程退出码 \(c)"
        case .stalled(let why): return "连接停滞（\(why)）"
        }
    }
}

nonisolated struct DownloadItem {
    /// 候选下载地址（按优先级从高到低）。至少一个。
    let urls: [MirrorCandidate]
    let destination: URL
    let sha1: String?
    var size: Int64? = nil
    var kind: ResourceKind = .other
    var displayName: String { destination.lastPathComponent }

    init(urls: [MirrorCandidate], destination: URL, sha1: String?, size: Int64? = nil, kind: ResourceKind = .other) {
        self.urls = urls
        self.destination = destination
        self.sha1 = sha1
        self.size = size
        self.kind = kind
    }

    init(url: URL, destination: URL, sha1: String?, size: Int64? = nil, kind: ResourceKind = .other) {
        self.urls = [MirrorCandidate(source: "official", url: url)]
        self.destination = destination
        self.sha1 = sha1
        self.size = size
        self.kind = kind
    }
}

/// 并发批量下载进度计数器（线程安全）。
actor ProgressCounter {
    private(set) var done: Int = 0
    let total: Int

    /// 每个并发任务一个独立槽位。
    ///
    /// 早期版本只有一组 currentFile/currentBytes，16 路并发时后一个任务的 start()
    /// 会覆盖前一个的，导致：当前文件名乱跳、字节数算到别人头上、
    /// doneBytes 严重低估（界面显示「总 315.4/462.6 MB」但其实早就下完了）。
    /// 现在按 task id 分槽，各自累加各自的字节。
    private struct Slot {
        var name: String = ""
        var bytes: Int64 = 0
        var total: Int64 = -1
    }
    private var slots: [UInt64: Slot] = [:]
    /// 槽位 id 分配器（单调递增，不能用 slots.count —— 回收后 count 会变小导致 id 重复）。
    private var nextSlotID: UInt64 = 0
    /// 当前「最新开始」的任务，用于界面显示当前文件名。
    private var activeSlot: UInt64 = 0

    /// 已累计下载字节 / 已知总字节（用于「总 45.2/180.3 MB」展示）。
    private(set) var doneBytes: Int64 = 0
    let totalBytes: Int64
    private(set) var startedAt: Date = Date()

    /// 全局实时字节（所有并发任务累加），用于算瞬时速度。
    private var liveBytes: Int64 = 0
    private var lastSampleBytes: Int64 = 0
    private var lastSampleAt: Date = Date()
    private var smoothed: Double = 0

    init(total: Int, totalBytes: Int64 = 0) {
        self.total = total
        self.totalBytes = totalBytes
    }

    /// 分配一个任务槽位 id。
    func newSlot() -> UInt64 {
        nextSlotID += 1
        let id = nextSlotID
        slots[id] = Slot()
        return id
    }

    func start(slot: UInt64, name: String, size: Int64?) {
        slots[slot] = Slot(name: name, bytes: 0, total: size ?? -1)
        activeSlot = slot
    }

    /// 某个任务的字节进度。
    func addBytes(slot: UInt64, _ n: Int64) {
        guard var s = slots[slot] else { return }
        s.bytes = n
        slots[slot] = s
    }

    func bump(slot: UInt64) {
        if let s = slots.removeValue(forKey: slot) {
            doneBytes += max(s.bytes, 0)
        }
        done += 1
        if activeSlot == slot { activeSlot = slots.keys.max() ?? 0 }
    }

    /// 界面要显示的「当前文件」：取最近还在跑的那个槽位。
    var currentFile: String { slots[activeSlot]?.name ?? "" }
    var currentBytes: Int64 { slots[activeSlot]?.bytes ?? 0 }
    var currentTotal: Int64 { slots[activeSlot]?.total ?? -1 }
    /// 还没回收的槽位数（自检用：正常情况下任务结束时应为 0）。
    var slotCount: Int { slots.count }
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// 累加实时字节增量（并发任务共享）。
    func addDelta(_ d: Int64) {
        if d > 0 { liveBytes += d }
    }

    /// 采样瞬时速度（字节/秒），带指数平滑，避免数字乱跳。
    func sampleSpeed() -> Double {
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleAt)
        guard dt > 0.15 else { return smoothed }
        let delta = liveBytes - lastSampleBytes
        lastSampleBytes = liveBytes
        lastSampleAt = now
        let instant = Double(delta) / dt
        smoothed = smoothed == 0 ? instant : smoothed * 0.6 + instant * 0.4
        return smoothed
    }

    /// 平均吞吐（字节/秒）。
    var averageSpeed: Double {
        let dt = Date().timeIntervalSince(startedAt)
        return dt > 0.5 ? Double(liveBytes) / dt : 0
    }
    /// 所有并发任务累计下载的实时字节（含已完成 + 正在下载），
    /// 用于整体进度 / 总量展示的最准分子（比 doneBytes+activeSlot 全）。
    var liveTotalBytes: Int64 { liveBytes }
}

nonisolated /// 单文件字节增量计（换源重下时 received 会归零，需要按增量累加）。
private final class ByteMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    func delta(_ v: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let d = v - last
        last = v
        return d
    }
}

nonisolated enum DownloadManager {
    /// 字节数格式化为 MB（一位小数）。
    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    // MARK: - 流式下载

    /// URLSessionDataDelegate：收到数据直接追加写盘，避免 AsyncBytes 逐字节迭代的性能黑洞。
    private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        let onProgress: @Sendable (Int64, Int64) -> Void

        private let lock = NSLock()
        private var _expected: Int64 = -1
        private var _received: Int64 = 0
        private var _reported: Int64 = 0
        private var _lastChunk = Date()
        private var _status: Int = 0
        private var _abort: String?
        private var _writeError: String?

        var onFinish: ((Error?) -> Void)?

        init(handle: FileHandle, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.handle = handle
            self.onProgress = onProgress
            super.init()
        }

        var expected: Int64 { lock.lock(); defer { lock.unlock() }; return _expected }
        var received: Int64 { lock.lock(); defer { lock.unlock() }; return _received }
        var status: Int { lock.lock(); defer { lock.unlock() }; return _status }
        var abortReason: String? { lock.lock(); defer { lock.unlock() }; return _abort }
        var writeError: String? { lock.lock(); defer { lock.unlock() }; return _writeError }
        var secondsSinceChunk: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(_lastChunk)
        }

        func abort(_ reason: String) {
            lock.lock()
            if _abort == nil { _abort = reason }
            lock.unlock()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            _expected = response.expectedContentLength
            if let http = response as? HTTPURLResponse { _status = http.statusCode }
            let code = _status
            _lastChunk = Date()
            lock.unlock()

            if code >= 400 {
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // 写盘失败必须记下来：以前这里用 try? 吞掉，最后只会表现为「校验和对不上」，
            // 完全看不出是磁盘写不进去。
            do {
                try handle.write(contentsOf: data)
            } catch {
                lock.lock()
                if _writeError == nil { _writeError = error.localizedDescription }
                lock.unlock()
            }
            lock.lock()
            _lastChunk = Date()
            _received += Int64(data.count)
            let r = _received
            let e = _expected
            let shouldReport = (r - _reported >= 262_144) || (e > 0 && r >= e)
            if shouldReport { _reported = r }
            lock.unlock()
            if shouldReport { onProgress(r, e) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            onFinish?(error)
        }
    }

    /// 单文件下载：流式写盘，支持 SHA-1 校验、首字节/断流/低速看门狗。
    /// - Parameters:
    ///   - speedGuard: 是否启用速度门槛（最后一个候选源应关掉）。
    ///   - progress: (累计字节数, 内容总长；未知为 -1)
    static func download(from url: URL,
                         to destination: URL,
                         sha1: String? = nil,
                         timeout: TimeInterval = 30,
                         firstByteLimit: TimeInterval = 8,
                         minSpeed: Double = 400_000,
                         speedGuard: Bool = true,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        try Paths.ensure(destination.deletingLastPathComponent())
        let tmp = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: tmp.path) else {
            throw LauncherError.cannotWrite(tmp.path)
        }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = 3600     // 大文件靠看门狗，不靠资源超时
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 8

        let delegate = StreamDelegate(handle: handle) { received, expected in
            progress?(received, expected)
        }
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url)
        req.setValue("maccraft/1.0", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: req)
        let start = Date()

        // 看门狗：每秒巡视一次，三种情况立刻掐断让上层换源。
        let watchdog = Task { [weak delegate] in
            var sampleBytes: Int64 = 0
            var sampleAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let delegate, !Task.isCancelled else { return }
                let received = delegate.received
                let elapsed = Date().timeIntervalSince(start)
                if received == 0 {
                    if elapsed > firstByteLimit {
                        delegate.abort(String(format: "%.0f 秒无首字节", elapsed))
                        task.cancel()
                        return
                    }
                } else {
                    // 「断流」放宽到 12 秒：8 路并发大文件抢带宽时，cdn 连接偶发几秒
                    // 空档是常态，6 秒太激进会把本来很快的 cdn 连接误杀 → 掉到慢镜像。
                    if delegate.secondsSinceChunk > 12 {
                        delegate.abort("断流")
                        task.cancel()
                        return
                    }
                    // 速度护栏：只在该源「确实有数据、但持续慢」时才换源。
                    //
                    // 早先用的是「全程平均速度 + 已收 3MB 才判」，实战里两个方向都错：
                    //  · 30 KB/s 的连接要 100 秒才攒够 3MB → 这 100 秒纯浪费，还没换源
                    //  · 快的连接慢启动期平均也低，一不留神就被冤枉切走
                    // 所以改成「滑动窗口」：每 5 秒算一次最近窗口的瞬时速度，
                    // 爬坡中的快连接窗口速度会上来，真慢的连接窗口速度一直低。
                    let expected = delegate.expected
                    let dt = Date().timeIntervalSince(sampleAt)
                    if speedGuard, elapsed > 10, dt >= 5 {
                        let recent = Double(received - sampleBytes) / dt
                        sampleBytes = received
                        sampleAt = Date()
                        let done = expected > 0 && received >= expected
                        if !done, recent < minSpeed, expected <= 0 || expected > 1_000_000 {
                            delegate.abort(String(format: "速度仅 %.0f KB/s", recent / 1024))
                            task.cancel()
                            return
                        }
                    }
                }
            }
        }
        defer { watchdog.cancel() }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            delegate.onFinish = { error in
                if let reason = delegate.abortReason {
                    c.resume(throwing: LauncherError.stalled(reason))
                } else if delegate.status >= 400 {
                    c.resume(throwing: LauncherError.http(delegate.status))
                } else if let error {
                    c.resume(throwing: error)
                } else {
                    c.resume()
                }
            }
            task.resume()
        }

        // 先把句柄关掉再读回来算校验和：文件还没 close 就 hash，遇到带缓冲的
        // 写入路径会漏掉尾块，表现就是「明明下完了却校验不过」。
        try? handle.close()

        if let writeError = delegate.writeError {
            try? FileManager.default.removeItem(at: tmp)
            throw LauncherError.cannotWrite("写入失败（\(writeError)）：\(destination.lastPathComponent)")
        }

        // 完整性：Chunked 响应拿不到 Content-Length（expected = -1），能拿到就必须对得上。
        let got = delegate.received
        let want = delegate.expected
        if want > 0, got != want {
            try? FileManager.default.removeItem(at: tmp)
            throw LauncherError.stalled("内容不完整（\(got)/\(want) 字节）")
        }
        if got == 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw LauncherError.stalled("空响应")
        }

        if let sha1 {
            let computed = sha1OfFile(at: tmp)
            guard computed.lowercased() == sha1.lowercased() else {
                try? FileManager.default.removeItem(at: tmp)
                throw LauncherError.checksumMismatch(computed, sha1)
            }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    // MARK: - 候选链下载（换源核心）

    /// 按候选链逐个尝试下载同一个文件；失败的源自动降级到下一个。
    static func downloadCandidates(_ candidates: [MirrorCandidate],
                                   kind: ResourceKind,
                                   to destination: URL,
                                   sha1: String?,
                                   timeout: TimeInterval = 30,
                                   progress: (@Sendable (Int64, Int64) -> Void)? = nil,
                                   onSwitch: (@Sendable (String) -> Void)? = nil) async throws {
        guard !candidates.isEmpty else { throw LauncherError.cannotWrite(destination.path) }
        var lastError: Error?

        for (i, cand) in candidates.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let isLast = i == candidates.count - 1
            var attempt = 0
            while true {
                attempt += 1
                do {
                    progress?(0, -1)   // 换源时把进度条归零，避免显示上一个源的残留
                    try await download(from: cand.url, to: destination, sha1: sha1,
                                       timeout: timeout,
                                       speedGuard: true,
                                       progress: progress)
                    SourceHealth.shared.recordSuccess(cand.source, kind: kind)
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: destination.appendingPathExtension("part"))

                    // 「下完了但内容不对」多半是 CDN 边缘节点给了半截 / 缓存了坏副本，
                    // 同源立刻重试一次往往就对了 —— 比直接换到慢源划算得多。
                    let retriable: Bool
                    switch error {
                    case LauncherError.checksumMismatch: retriable = true
                    case LauncherError.stalled(let why): retriable = why.contains("不完整") || why.contains("空响应")
                    default: retriable = false
                    }
                    if retriable, attempt < 2 {
                        onSwitch?("↻ \(Mirror.label(cand.source)) 内容不完整，同源重试…")
                        continue
                    }

                    if case LauncherError.http(404) = error {
                        SourceHealth.shared.recordMiss(cand.source, kind: kind)   // 内容缺失，不算源故障
                    } else if case LauncherError.checksumMismatch = error {
                        SourceHealth.shared.recordMiss(cand.source, kind: kind)
                    } else if case LauncherError.http(let code) = error, (400..<500).contains(code) {
                        SourceHealth.shared.recordMiss(cand.source, kind: kind)
                    } else {
                        SourceHealth.shared.recordFailure(cand.source, kind: kind)
                    }
                    lastError = error

                    if !isLast {
                        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        onSwitch?("↻ \(Mirror.label(cand.source)) 下载失败（\(reason)），切换到 \(Mirror.label(candidates[i + 1].source))")
                    }
                    break
                }
            }
        }
        throw lastError ?? LauncherError.cannotWrite(destination.path)
    }

    /// 单 URL 下载（Java 运行时这类非 MC 资源用）。
    static func downloadResilient(from url: URL,
                                  fallback: URL?,
                                  to destination: URL,
                                  sha1: String?,
                                  timeout: TimeInterval = 60,
                                  progress: (@Sendable (Int64, Int64) -> Void)? = nil,
                                  onFallback: (@Sendable (String) -> Void)? = nil) async throws {
        var candidates = [MirrorCandidate(source: "primary", url: url)]
        if let fallback, fallback != url {
            candidates.append(MirrorCandidate(source: "fallback", url: fallback))
        }
        var lastError: Error?
        for (i, c) in candidates.enumerated() {
            do {
                try await download(from: c.url, to: destination, sha1: sha1, timeout: timeout,
                                   firstByteLimit: 12, speedGuard: i == 0, progress: progress)
                return
            } catch {
                lastError = error
                if i == 0, candidates.count > 1 {
                    onFallback?("↻ \(c.url.host ?? "主源") 失败（\(error.localizedDescription)），切换 \(candidates[1].url.host ?? "备用源")")
                    try? FileManager.default.removeItem(at: destination.appendingPathExtension("part"))
                }
            }
        }
        throw lastError ?? LauncherError.cannotWrite(destination.path)
    }

    // MARK: - 并发批量下载

    /// - Parameter tolerateFailures: 单个文件失败是否继续（预置安装器依赖时用，缺个别文件不影响大局）。
    /// - Parameter onFile: 每个文件结束后的回调 (文件名, 是否成功)，用于界面逐条显示下载日志。
    static func downloadMany(_ items: [DownloadItem],
                             counter: ProgressCounter,
                             maxConcurrent: Int = 12,
                             tolerateFailures: Bool = false,
                             onFallback: (@Sendable (String) -> Void)? = nil,
                             onFile: (@Sendable (String, Bool) -> Void)? = nil) async throws {
        guard !items.isEmpty else { return }
        var next = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            func spawn() {
                guard next < items.count else { return }
                let item = items[next]
                next += 1
                group.addTask {
                    let c = counter
                    // 每个并发任务一个独立槽位：否则 16 路并发时后一个会覆盖
                    // 前一个的当前文件名 / 字节数，界面上的「当前文件」和
                    // 「总 315.4/462.6 MB」会乱跳，甚至下载早就结束了还在显示。
                    let slot = await c.newSlot()
                    await c.start(slot: slot, name: item.displayName, size: item.size)
                    let meter = ByteMeter()
                    // 本地已有同一个文件就跳过：复用实例重导整合包时，
                    // 276 个文件里绝大多数已经在了，没必要再下一遍。
                    // 有 sha1 就比对哈希；没有就比对大小（够用了，都是 mod jar）。
                    if FileManager.default.fileExists(atPath: item.destination.path) {
                        let sha1 = item.sha1 ?? ""
                        let matches: Bool
                        if !sha1.isEmpty {
                            matches = sha1OfFile(at: item.destination).lowercased() == sha1.lowercased()
                        } else if let size = item.size, size > 0 {
                            let local = (try? FileManager.default.attributesOfItem(atPath: item.destination.path)[.size]) as? Int64 ?? 0
                            matches = local == size
                        } else {
                            matches = false
                        }
                        if matches {
                            await c.bump(slot: slot)
                            onFile?(item.destination.lastPathComponent, true)
                            return
                        }
                    }
                    do {
                        try await downloadCandidates(item.urls, kind: item.kind,
                                                     to: item.destination, sha1: item.sha1,
                                                     progress: { received, _ in
                                                         Task { await c.addBytes(slot: slot, received) }
                                                         let delta = meter.delta(received)
                                                         if delta > 0 { Task { await c.addDelta(delta) } }
                                                     },
                                                     onSwitch: onFallback)
                    } catch {
                        await c.bump(slot: slot)
                        onFile?(item.destination.lastPathComponent, false)
                        if tolerateFailures { return }
                        throw error
                    }
                    await c.bump(slot: slot)
                    onFile?(item.destination.lastPathComponent, true)
                }
            }
            let initial = min(maxConcurrent, items.count)
            for _ in 0..<initial { spawn() }
            while next < items.count {
                try await group.next()
                spawn()
            }
            try await group.waitForAll()
        }
    }

    /// 把 ProgressCounter 的变化持续喂给任务进度管道（下载阶段）。
    /// 返回的 Task 在 batch 完成或调用方 cancel 时结束。
    static func report(_ counter: ProgressCounter,
                       to relay: ProgressRelay,
                       label: String) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let d = await counter.done
                let t = await counter.total
                let name = await counter.currentFile
                let totalBytes = await counter.totalBytes
                let live = await counter.liveTotalBytes
                let speed = await counter.sampleSpeed()

                // 资源对象名是 40 位 hash，界面上截短
                let shown = name.count > 28 ? "\(name.prefix(10))…\(name.suffix(6))" : name
                // ratio / overall 一起给：不传的话阶段内的百分比算不出来，
                // 任务条会一直停在阶段起点的位置。
                // 优先用「字节进度」当 ratio：对「少量大文件」的整合包更真实、更平滑；
                // 只有在拿不到总字节（totalBytes==0）时才退回文件完成比例，
                // 否则会「字节在涨、百分比却一直是 0」的口径打架。
                // 分子用 liveTotalBytes（所有并发任务实时累计），16 路并发时也不会漏算。
                let frac: Double
                if totalBytes > 0 {
                    frac = Double(max(live, 0)) / Double(max(totalBytes, 1))
                } else {
                    frac = t > 0 ? Double(d) / Double(t) : 0
                }
                relay.send(TaskProgress(stage: .download,
                                        current: d, total: t,
                                        bytes: max(live, 0),
                                        totalBytes: totalBytes,
                                        detail: name.isEmpty ? label : "\(label) · \(shown)",
                                        speed: speed,
                                        ratio: frac))
                if d >= t { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    static func sha1OfFile(at url: URL) -> String {        guard let handle = FileHandle(forReadingAtPath: url.path) else { return "" }
        var hasher = Insecure.SHA1()
        while let data = try? handle.read(upToCount: 1_000_000), !data.isEmpty {
            hasher.update(data: data)
        }
        try? handle.close()
        return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
    }
}
