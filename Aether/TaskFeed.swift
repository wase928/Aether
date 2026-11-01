//
//  TaskFeed.swift
//  maccraft
//
//  统一的「任务进度 + 实时日志」管道。
//
//  以前只有「版本安装」会把 progress / statusText 写回 store：
//  整合包解压、加载器安装、单个 mod 下载都只转一个转圈 —— 用户看不到任何反馈，
//  体感就是卡死。这一层把「解压 / 下载 / 安装 / 校验」全部收敛成同一个模型：
//
//    TaskProgress   → 后台线程上报一条进度（阶段 + n/m + 字节 + 当前文件 + 速度）
//    ProgressRelay  → 按阶段权重换算成整体百分比，并做 120ms 节流（避免刷爆主线程）
//    TaskFeed       → 主线程持有的一份快照 + 滚动日志，界面直接绑定
//

import Foundation
import Combine

/// 一条进度上报。
nonisolated struct TaskProgress: Sendable, Equatable {
    enum Stage: String, Sendable {
        case scan     = "扫描"
        case extract  = "解压"
        case install  = "安装"
        case loader   = "加载器"
        case merge    = "写入"
        case resolve  = "查询"
        case download = "下载"
        case verify   = "校验"
        case finish   = "收尾"
    }

    var stage: Stage = .scan
    var current: Int = 0
    var total: Int = 0          // 0 = 未知
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0
    var detail: String = ""
    var speed: Double = 0       // 字节/秒
    /// 阶段内的细分比例（0...1）。>0 时优先用它算整体进度，
    /// 用于「一个阶段里还有好几小步」的情况（加载器安装就是）。
    var ratio: Double = -1
    /// 整体进度（0...1）。<0 表示交给 ProgressRelay 按阶段权重换算。
    var overall: Double = -1
}

/// 阶段权重 + 节流。跨线程安全，可被后台任务直接调用。
nonisolated final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [TaskProgress.Stage: (base: Double, span: Double)] = [:]
    private var lastEmitAt = Date.distantPast
    private var lastStage: TaskProgress.Stage?
    private var lastBytes: Int64 = 0
    private var lastBytesAt = Date()
    private var smoothed: Double = 0
    private let emit: @Sendable (TaskProgress) -> Void

    /// - Parameter order: [(阶段, 权重)]，权重是相对值，不必加起来等于 1。
    init(order: [(TaskProgress.Stage, Double)],
         emit: @escaping @Sendable (TaskProgress) -> Void) {
        let sum = order.reduce(0.0) { $0 + max($1.1, 0.0001) }
        var base = 0.0
        for (stage, weight) in order {
            let span = max(weight, 0.0001) / sum
            spans[stage] = (base, span)
            base += span
        }
        self.emit = emit
    }

    /// 上报进度。同一阶段内最多每 120ms 发一次；换阶段 / force 时立刻发。
    func send(_ p: TaskProgress, force: Bool = false) {
        var out = p

        lock.lock()
        // 1) 整体百分比
        if out.overall < 0 {
            let (base, span) = spans[p.stage] ?? (0, 1)
            let local: Double
            if p.ratio >= 0 {
                // 有细分比例时优先用它（阶段内多小步的场景）
                local = min(1, max(0, p.ratio))
            } else if p.total > 0 {
                local = min(1, Double(p.current) / Double(p.total))
            } else if p.totalBytes > 0 {
                local = min(1, Double(p.bytes) / Double(p.totalBytes))
            } else {
                local = 0
            }
            out.overall = min(1, base + span * local)
        }

        // 2) 速度：用字节增量 / 时间，做指数平滑（换阶段时重置）
        let now = Date()
        if out.speed <= 0, p.bytes > 0 {
            if lastStage != p.stage {
                lastBytes = p.bytes
                lastBytesAt = now
            } else {
                let dt = now.timeIntervalSince(lastBytesAt)
                if dt > 0.25 {
                    let delta = max(0, p.bytes - lastBytes)
                    let instant = Double(delta) / dt
                    smoothed = smoothed == 0 ? instant : smoothed * 0.6 + instant * 0.4
                    lastBytes = p.bytes
                    lastBytesAt = now
                }
            }
            out.speed = smoothed
        }

        // 3) 节流
        let sameStage = lastStage == p.stage
        let due = now.timeIntervalSince(lastEmitAt) > 0.12
        if !force && sameStage && !due {
            lock.unlock()
            return
        }
        lastEmitAt = now
        lastStage = p.stage
        lock.unlock()

        emit(out)
    }

    /// 直接跳到某个阶段（阶段开始 / 结束时用）。
    func jump(_ stage: TaskProgress.Stage, detail: String = "") {
        send(TaskProgress(stage: stage, detail: detail), force: true)
    }

    /// 某个阶段在整体进度里的起点与跨度（供外部按比例插入子步骤）。
    func span(_ stage: TaskProgress.Stage) -> (base: Double, width: Double) {
        lock.lock(); defer { lock.unlock() }
        return spans[stage] ?? (0, 1)
    }
}

/// 界面侧的任务状态（主线程）。
@MainActor
final class TaskFeed: ObservableObject {

    struct Snapshot: Equatable, Sendable {
        var active = false
        var title = ""
        var stage = ""
        var overall: Double = 0
        var counter = ""        // "372/1325"
        var sizeText = ""       // "248.3 / 375.0 MB"
        var speedText = ""      // "12.4 MB/s"
        var elapsedText = ""    // "已用 3.2s"
        var etaText = ""        // "剩余 5.1s"
        var detail = ""
        var done = false
        var failed = false
    }

    @Published private(set) var snap = Snapshot()
    /// 实时日志（只留最近 600 行，完整日志在 logs/latest.log）。
    @Published private(set) var lines: [String] = []
    @Published var expanded = false

    private var startedAt = Date()
    private var ticker: Task<Void, Never>?

    var isActive: Bool { snap.active }

    // MARK: - 生命周期

    func begin(_ title: String) {
        startedAt = Date()
        lines = []
        // 全新任务：把上一个任务的完成态清干净
        snap = Snapshot(active: true, title: title, stage: "准备中")
        startTicker()
    }

    func apply(_ p: TaskProgress) {
        // 任务已结束后不接受新进度：否则残留的监控任务会把「已完成」
        // 又改回「下载中」，界面上就出现「运行中但进度条还在下载」的矛盾状态。
        guard !snap.done else { return }
        var s = snap
        s.active = true
        s.stage = p.stage.rawValue
        // 整体进度：阶段权重换算出来的值本身就是单调的（阶段按顺序推进）。
        // 这里允许「新阶段的值比旧阶段低」—— 换源重下 / 阶段回退时进度条回一点，
        // 比卡在原地不动更诚实。真正需要防的是同阶段内抖动，那由 ProgressRelay 节流负责。
        s.overall = min(1, p.overall < 0 ? s.overall : p.overall)
        // 计数：普通阶段显示 n/m；有细分比例的阶段（加载器安装）显示步数没意义，
        // 那种情况下 detail 里已经写清楚了。
        s.counter = (p.ratio >= 0) ? "" : (p.total > 0 ? "\(p.current)/\(p.total)" : "")
        if p.totalBytes > 0 {
            s.sizeText = "\(DownloadManager.mb(p.bytes)) / \(DownloadManager.mb(p.totalBytes)) MB"
        } else if p.bytes > 0 {
            s.sizeText = "\(DownloadManager.mb(p.bytes)) MB"
        } else {
            s.sizeText = ""
        }
        s.speedText = p.speed > 0 ? String(format: "%.1f MB/s", p.speed / 1_048_576) : ""
        if !p.detail.isEmpty { s.detail = p.detail }
        snap = s
    }

    func log(_ line: String) {
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
    }

    func clearLog() { lines = [] }

    func finish(ok: Bool, _ summary: String = "") {
        ticker?.cancel()
        ticker = nil
        var s = snap
        s.done = true
        s.failed = !ok
        s.overall = ok ? 1 : s.overall
        s.speedText = ""
        s.etaText = ""
        s.stage = ok ? "完成" : "失败"
        // 清掉计数和大小：任务结束了还挂着「3828/5147」会让人以为还在下。
        s.counter = ""
        s.sizeText = ""
        if !summary.isEmpty { s.detail = summary }
        s.elapsedText = String(format: "用时 %.1fs", Date().timeIntervalSince(startedAt))
        snap = s
        log(ok ? "✔ \(summary)" : "✖ \(summary)")
    }

    func reset() {
        ticker?.cancel()
        ticker = nil
        snap = Snapshot()
        lines = []
    }

    // MARK: - 计时

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                var s = self.snap
                guard s.active, !s.done else { return }
                let elapsed = Date().timeIntervalSince(self.startedAt)
                s.elapsedText = String(format: "已用 %.1fs", elapsed)
                if s.overall > 0.03, s.overall < 1 {
                    let remain = elapsed / s.overall - elapsed
                    s.etaText = remain > 0.5 ? String(format: "剩余 %.0fs", remain) : ""
                } else {
                    s.etaText = ""
                }
                self.snap = s
            }
        }
    }
}
