//
//  TaskBar.swift
//  maccraft
//
//  主窗口底部的统一任务条：下载、解压、安装、校验全都走这里。
//
//  PCL2 / HMCL 的做法是「进度条 + 逐文件日志」并列，用户随时知道现在在动什么。
//  这里保留同样的信息密度，但收成一条高度 56 的窄条，展开才显示日志，
//  不占据正常浏览的空间。
//

import SwiftUI

struct TaskBar: View {
    @ObservedObject var feed: TaskFeed

    private var showLog: Bool { feed.expanded }

    var body: some View {
        if feed.snap.active {
            VStack(spacing: 0) {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    header
                    bar
                    footer
                    if showLog { logPanel.transition(.opacity.combined(with: .move(edge: .bottom))) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                // 悬浮玻璃条：透出底下的渐变，边缘有苹果那种高光
                .glassChrome()
            }
            .onChange(of: feed.snap.done) { _, done in
                // 失败时自动把日志摊开，成功则收起，别一直占着地方。
                if done { feed.expanded = feed.snap.failed }
            }
        }
    }

    // MARK: 第一行：标题 + 阶段 + 计数 + 用时

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(feed.snap.failed ? .red : (feed.snap.done ? .green : .accentColor))
                .frame(width: 16)

            Text(feed.snap.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(feed.snap.stage)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(stageColor.opacity(0.16), in: Capsule())
                .foregroundStyle(stageColor)

            if !feed.snap.counter.isEmpty {
                Text(feed.snap.counter)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(String(format: "%.0f%%", feed.snap.overall * 100))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(feed.snap.failed ? .red : .primary)

            if !feed.snap.elapsedText.isEmpty {
                Text(feed.snap.elapsedText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Button {
                withAnimation(.easeOut(duration: 0.18)) { feed.expanded.toggle() }
            } label: {
                Image(systemName: showLog ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("展开 / 收起实时日志")
            // 强制置顶：任务条玻璃层叠在上面会吃掉点击。
            .onTop()

            if feed.snap.done {
                Button {
                    feed.reset()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭")
                .onTop()
            }
        }
    }

    // MARK: 进度条

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(
                        colors: feed.snap.failed ? [.red, .orange] : [.accentColor, .cyan],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * min(max(feed.snap.overall, 0), 1)))
                    .animation(.easeOut(duration: 0.2), value: feed.snap.overall)
            }
        }
        .frame(height: 6)
    }

    // MARK: 第三行：细节

    private var footer: some View {
        HStack(spacing: 10) {
            Text(feed.snap.detail.isEmpty ? "准备中…" : feed.snap.detail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if !feed.snap.sizeText.isEmpty {
                Text(feed.snap.sizeText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !feed.snap.speedText.isEmpty {
                Label(feed.snap.speedText, systemImage: "speedometer")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !feed.snap.etaText.isEmpty {
                Text(feed.snap.etaText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 日志

    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(feed.lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .frame(height: 170)
            .background(Color.black.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onChange(of: feed.lines.count) { _, n in
                guard n > 0 else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }

    private func color(for line: String) -> Color {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("✖") { return .red }
        if t.hasPrefix("⚠") { return .orange }
        if t.hasPrefix("✔") { return .green }
        if t.hasPrefix("↻") { return .yellow }
        if t.hasPrefix("▶") { return .primary }
        if t.hasPrefix("↓") { return .secondary }
        return .secondary
    }

    private var stageColor: Color {
        if feed.snap.failed { return .red }
        if feed.snap.done { return .green }
        switch feed.snap.stage {
        case "下载": return .blue
        case "解压": return .orange
        case "写入": return .purple
        case "安装": return .teal
        case "加载器": return .pink
        default:     return .accentColor
        }
    }

    private var icon: String {
        if feed.snap.failed { return "exclamationmark.triangle.fill" }
        if feed.snap.done { return "checkmark.circle.fill" }
        switch feed.snap.stage {
        case "下载": return "arrow.down.circle.fill"
        case "解压": return "doc.zipper"
        case "写入": return "externaldrive.fill.badge.plus"
        case "安装": return "shippingbox.fill"
        case "加载器": return "cube.transparent.fill"
        default:     return "gearshape.2.fill"
        }
    }
}
