//
//  SourceHealth.swift
//  maccraft
//
//  下载源健康度 + 测速排序。
//
//  PCL2 的 NetTask 会对每个源累计 FailCount，失败到阈值就把整源禁用（SourceFail）；
//  HMCL 则在设置层用 AutoDownloadProvider 把多个 provider 串成候选链。
//  这里把两者合起来：
//   1) 连续失败 3 次的源在 10 分钟内排到最后（不是永久剔除，避免源集体挂掉时无路可走）；
//   2) 404 单独记「缺失」，不算故障，但会累积命中率 —— 命中率低的源自动降级；
//   3) 下载前对候选源做一次 256KB 小段测速，按实测吞吐排序 —— 这是解决
//      「BMCLAPI 302 到 sakura 慢节点、UI 卡在 0.0/14.5MB」的关键。
//
//  为什么需要 (2)：测速只能代表「那一个样本文件」。阿里云对 fastutil 有 8 MB/s，
//  但 Mojang 私有库（com/mojang/*）它根本没有 —— 以前靠一个样本排出来的顺序，
//  会让每个私有库都先撞一次 404。命中率是跨文件的统计，才能真正反映覆盖率。
//

import Foundation

/// 源健康度（线程安全，跨下载任务共享）。
nonisolated final class SourceHealth: @unchecked Sendable {
    static let shared = SourceHealth()

    private let lock = NSLock()
    private var failStreak: [String: Int] = [:]
    private var disabledUntil: [String: Date] = [:]
    private var speed: [String: Double] = [:]
    /// 命中 / 缺失 样本数（用来算覆盖率，跨文件累积）。
    private var hits: [String: Int] = [:]
    private var misses: [String: Int] = [:]

    private static let persistKey = "aether.sourceHealth.v1"

    init() { load() }

    private func key(_ kind: ResourceKind, _ source: String) -> String {
        "\(kind.rawValue)|\(source)"
    }

    // MARK: - 记录

    func recordSuccess(_ source: String, kind: ResourceKind) {
        lock.lock()
        let k = key(kind, source)
        failStreak[k] = 0
        disabledUntil[k] = nil
        hits[k, default: 0] += 1
        lock.unlock()
    }

    /// 404 / 内容缺失：不算源故障，但计入覆盖率分母。
    func recordMiss(_ source: String, kind: ResourceKind) {
        lock.lock()
        let k = key(kind, source)
        failStreak[k] = 0
        misses[k, default: 0] += 1
        lock.unlock()
        save()
    }

    func recordFailure(_ source: String, kind: ResourceKind) {
        lock.lock()
        let k = key(kind, source)
        let n = (failStreak[k] ?? 0) + 1
        failStreak[k] = n
        if n >= 3 {
            // 冷却 10 分钟：期间排到最后，但仍在候选链里兜底。
            disabledUntil[k] = Date().addingTimeInterval(600)
        }
        lock.unlock()
    }

    func isDisabled(_ source: String, kind: ResourceKind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = disabledUntil[key(kind, source)] else { return false }
        if until > Date() { return true }
        disabledUntil[key(kind, source)] = nil
        failStreak[key(kind, source)] = 0
        return false
    }

    /// 命中率（0...1）；样本不足时返回 -1（表示「还不知道」，不参与降级）。
    func hitRate(_ source: String, kind: ResourceKind) -> Double {
        lock.lock(); defer { lock.unlock() }
        let k = key(kind, source)
        let h = hits[k] ?? 0, m = misses[k] ?? 0
        guard h + m >= 3 else { return -1 }
        return Double(h) / Double(h + m)
    }

    func recordSpeed(_ source: String, kind: ResourceKind, bytesPerSecond: Double) {
        lock.lock(); defer { lock.unlock() }
        speed[key(kind, source)] = bytesPerSecond
    }

    func speed(of source: String, kind: ResourceKind) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return speed[key(kind, source)]
    }

    /// 按「未禁用优先 → 覆盖率优先 → 实测速度降序」重排源列表。
    func ordered(_ sources: [String], kind: ResourceKind) -> [String] {
        // 覆盖率分档：0 = 好（≥60%），1 = 差（<60%），2 = 未知。差的一定排后面。
        func tier(_ s: String) -> Int {
            let r = hitRate(s, kind: kind)
            if r < 0 { return 2 }
            return r < 0.6 ? 1 : 0
        }
        return sources.enumerated().sorted { a, b in
            let da = isDisabled(a.element, kind: kind)
            let db = isDisabled(b.element, kind: kind)
            if da != db { return !da }
            let ta = tier(a.element), tb = tier(b.element)
            if ta != tb { return ta < tb }
            let sa = speed(of: a.element, kind: kind) ?? -1
            let sb = speed(of: b.element, kind: kind) ?? -1
            if sa != sb { return sa > sb }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - 持久化（跨启动学习：某个源在你这条线路上不行，下次别再撞）

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.persistKey) as? [String: [String: Int]]
        else { return }
        hits = raw["hits"] ?? [:]
        misses = raw["misses"] ?? [:]
        // 样本太老的清掉，避免永远记仇。
        for (k, v) in hits where v > 500 { hits[k] = 500 }
        for (k, v) in misses where v > 500 { misses[k] = 500 }
    }

    private var saveScheduled = false

    private func save() {
        lock.lock()
        if saveScheduled { lock.unlock(); return }
        saveScheduled = true
        lock.unlock()
        // 攒 2 秒再写一次，避免每个文件都打 UserDefaults。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let data: [String: [String: Int]] = ["hits": self.hits, "misses": self.misses]
            self.saveScheduled = false
            self.lock.unlock()
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }
}

/// 下载前的小段测速（256KB Range 请求），按实测吞吐给候选源排序。
nonisolated enum SourceBenchmark {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (time: Date, order: [String])] = [:]
    private static let ttl: TimeInterval = 300

    private static func cacheLookup(_ key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[key], Date().timeIntervalSince(hit.time) < ttl else { return nil }
        return hit.order
    }

    private static func cacheStore(_ key: String, order: [String]) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = (Date(), order)
    }

    /// 测速后再排序；任何异常都会退回原顺序。
    static func rank(_ candidates: [MirrorCandidate],
                     kind: ResourceKind,
                     cacheKey: String) async -> [MirrorCandidate] {
        guard candidates.count > 1 else { return candidates }

        if let cached = cacheLookup(cacheKey) {
            let pos = Dictionary(uniqueKeysWithValues: cached.enumerated().map { ($1, $0) })
            return candidates.sorted { (pos[$0.source] ?? 99) < (pos[$1.source] ?? 99) }
        }

        var results: [String: Double] = [:]
        await withTaskGroup(of: (String, SourceBenchmark.ProbeOutcome).self) { group in
            for c in candidates {
                group.addTask {
                    let outcome = await probe(c.url)
                    return (c.source, outcome)
                }
            }
            for await (source, outcome) in group {
                switch outcome {
                case .ok(let spd):
                    results[source] = spd
                    SourceHealth.shared.recordSpeed(source, kind: kind, bytesPerSecond: spd)
                    SourceHealth.shared.recordSuccess(source, kind: kind)
                case .missing:
                    // 样本文件这个源没有 —— 只能说明覆盖率，不能说源坏了。
                    SourceHealth.shared.recordMiss(source, kind: kind)
                case .failed:
                    SourceHealth.shared.recordFailure(source, kind: kind)
                }
            }
        }

        let ranked = candidates.sorted { a, b in
            let sa = results[a.source] ?? -1
            let sb = results[b.source] ?? -1
            return sa > sb
        }

        if !results.isEmpty {
            cacheStore(cacheKey, order: ranked.map(\.source))
        }
        return ranked
    }

    /// 测速结果：区分「慢/坏」和「这个源根本没有这个文件」。
    enum ProbeOutcome {
        case ok(Double)      // 字节/秒
        case missing         // 4xx：源缺文件，不是源故障
        case failed          // 超时 / 握手失败 / 空响应
    }

    /// 下载 256KB 测速。
    static func probe(_ url: URL) async -> ProbeOutcome {
        final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
            let limit = 262_144
            var bytes = 0
            var status = 0
            var firstByteAt: Date?
            var start = Date()
            var session: URLSession?
            var task: URLSessionDataTask?
            var continuation: CheckedContinuation<Void, Never>?
            var finished = false

            func finish() {
                guard !finished else { return }
                finished = true
                continuation?.resume()
                continuation = nil
            }

            func urlSession(_ s: URLSession, dataTask: URLSessionDataTask,
                            didReceive response: URLResponse,
                            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
                if let http = response as? HTTPURLResponse {
                    status = http.statusCode
                    if http.statusCode >= 400 {
                        completionHandler(.cancel)
                        finish()
                        return
                    }
                }
                completionHandler(.allow)
            }

            func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                if firstByteAt == nil { firstByteAt = Date() }
                bytes += data.count
                if bytes >= limit { dataTask.cancel(); finish() }
            }

            func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                finish()
            }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 8
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData

        var req = URLRequest(url: url)
        req.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        req.setValue("maccraft/1.0", forHTTPHeaderField: "User-Agent")

        let d = ProbeDelegate()
        d.start = Date()
        let session = URLSession(configuration: cfg, delegate: d, delegateQueue: nil)
        d.session = session
        let task = session.dataTask(with: req)
        d.task = task

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            d.continuation = c
            task.resume()
        }
        session.invalidateAndCancel()

        if d.status >= 400 { return .missing }
        guard d.bytes > 8_192, let first = d.firstByteAt else { return .failed }
        // 扣掉首字节时延，得到「真实吞吐」，避免 TTFB 把高带宽源的评分拉低。
        let elapsed = max(Date().timeIntervalSince(first), 0.001)
        return .ok(Double(d.bytes) / elapsed)
    }
}
