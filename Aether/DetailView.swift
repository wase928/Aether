//
//  DetailView.swift
//  maccraft
//
//  “启动游戏”分页：版本信息 + 大号启动按钮 + 进度 + 运行日志。
//  PCL / HMCL 风格：一个大卡片把“选版本 + 启动”集中在一屏。
//

import SwiftUI

struct LaunchTabView: View {
    @EnvironmentObject private var store: LauncherStore

    private var ref: VersionManifest.VersionRef? {
        guard let id = store.selectedVersionID else { return nil }
        return store.manifest?.versions.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let ref {
                    hero(ref)
                } else {
                    emptyState
                }
                console
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 头部卡片
    private func hero(_ ref: VersionManifest.VersionRef) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                // 渐变图标芯片
                Image(systemName: "cube.box.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.linearGradient(
                        colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    )
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(ref.id)
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                        Badge(text: ref.type)
                    }
                    Text("发布时间：\(ref.releaseTime.prefix(10))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // 快速切换版本（不必离开本页）
                    Menu {
                        Section("正式版") {
                            ForEach(store.searchResults.filter { $0.type == "release" }) { v in
                                Button(v.id) { store.selectedVersionID = v.id }
                            }
                        }
                        Section("快照版") {
                            ForEach(store.searchResults.filter { $0.type == "snapshot" }) { v in
                                Button(v.id) { store.selectedVersionID = v.id }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.arrow.down.circle")
                            Text("切换版本")
                        }
                        .font(.caption.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .disabled(store.manifest == nil)
                }

                Spacer(minLength: 0)

                // 状态胶囊 + 手动刷新
                VStack(alignment: .trailing, spacing: 8) {
                    statusPill
                    Button {
                        store.refreshManifest()
                    } label: {
                        Label("重新刷新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(store.isBusy)
                }
            }

            Divider()

            // 进度 / 状态
            if store.isBusy || store.phase == .running {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: store.progress) {
                        Text(store.statusText)
                            .font(.caption)
                    }
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    if store.phase == .running {
                        Button(role: .destructive) { store.stop() } label: {
                            Label("停止游戏", systemImage: "stop.fill")
                        }
                        .controlSize(.small)
                    }
                }
            }

            // 启动按钮（PCL / HMCL 那种大号主按钮）
            Button {
                Task { await store.prepareAndLaunch(ref) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: store.phase == .running ? "play.circle.fill" : "play.fill")
                        .font(.title3)
                    Text(store.phase == .running ? "游戏中…" : "启动游戏")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
        }
        // 强制置顶：卡片外层 overlay 叠在上面会吃掉按钮点击。
        .onTop()
        .padding(26)
        .glassPanel(radius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: 状态胶囊
    private var statusPill: some View {
        let info = statusInfo
        return HStack(spacing: 7) {
            Circle()
                .fill(info.color)
                .frame(width: 8, height: 8)
            Text(info.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(info.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(info.color.opacity(0.14))
        )
    }

    private var statusInfo: (text: String, color: Color) {
        switch store.phase {
        case .idle:          return ("就绪", .green)
        case .loadingManifest: return ("刷新中", .blue)
        case .preparing:     return ("准备中", .blue)
        case .downloading:   return ("下载中", .orange)
        case .launching:     return ("启动中", .blue)
        case .running:       return ("运行中", .green)
        case .error:         return ("出错", .red)
        }
    }

    // MARK: 控制台
    private var console: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("运行日志", systemImage: "terminal")
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    store.logText = ""
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(store.logText.isEmpty || store.phase == .running)
            }
            TextEditor(text: .constant(store.logText))
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 260)
                .glassPanel(radius: 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("还没有选择版本")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("请先到「游戏版本」里挑一个 Minecraft 版本，回来即可一键启动。\n首次启动会自动下载客户端、依赖库、资源与匹配的 Java 运行时。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
    private var label: String {
        switch text {
        case "release":  return "正式版"
        case "snapshot": return "快照版"
        default:         return "历史版"
        }
    }
    private var color: Color {
        switch text {
        case "release":  return .green
        case "snapshot": return .orange
        default:         return .gray
        }
    }
}
