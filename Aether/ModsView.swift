//
//  ModsView.swift
//  maccraft
//
//  Mod 管理：按版本列出 mods 目录，支持启用/禁用、删除、拖拽安装。
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct ModsView: View {
    @EnvironmentObject private var store: LauncherStore
    @StateObject private var drop = DropState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { store.refreshInstalled(); store.refreshMods() }
        .onDrop(of: [.fileURL], isTargeted: $drop.targeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xB57BFF))
                Text("Mod 管理").font(.system(size: 24, weight: .bold))
                Spacer(minLength: 0)
                if drop.targeted {
                    Text("松开即可安装到当前版本")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            HStack(spacing: 10) {
                Text("版本").font(.caption).foregroundStyle(.secondary)
                Menu(store.activeVersionID ?? "未选择版本") {
                    ForEach(store.installed) { v in
                        Button("\(v.id) · \(v.loader.title)（\(modCount(v.id)) 个 Mod）") {
                            store.activeVersionID = v.id
                            store.refreshMods()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 300)

                Text("\(store.modEntries.count) 个文件 · 已启用 \(store.modEntries.filter(\.enabled).count)")
                    .font(.caption).foregroundStyle(.tertiary)


                Spacer(minLength: 0)

                Button { store.refreshMods() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
                Button { store.revealModsFolder() } label: { Label("打开目录", systemImage: "folder") }
                    .controlSize(.small)
                Button { store.selectedTab = .download } label: {
                    Label("下载 Mod", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2)
                Text(modsPathText)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(20)
    }

    // MARK: 列表

    @ViewBuilder
    private var content: some View {
        if store.activeVersionID == nil {
            placeholder("先去下载并安装一个版本，Mod 会装到它的 mods 目录里")
        } else if store.modEntries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 44)).foregroundStyle(.tertiary)
                Text("这个版本还没有 Mod").font(.headline)
                Text("Mod 是按版本隔离的：\(store.activeVersionID ?? "") 的目录是空的。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Paths.modsDir(store.activeVersionID ?? "").path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                let others = store.installed
                    .map { ($0, modCount($0.id)) }
                    .filter { $0.1 > 0 }
                if !others.isEmpty {
                    Text("这些版本里已经有 Mod：").font(.caption.weight(.semibold)).padding(.top, 6)
                    ForEach(others, id: \.0.id) { pair in
                        Button {
                            store.activeVersionID = pair.0.id
                            store.refreshMods()
                        } label: {
                            Label("\(pair.0.id)（\(pair.1) 个）→ 切换过去", systemImage: "arrow.turn.down.right")
                        }
                        .controlSize(.small)
                    }
                }

                Button { store.selectedTab = .download } label: {
                    Label("去下载 Mod", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.modEntries) { entry in
                        row(entry)
                        Divider().opacity(0.4).padding(.leading, 56)
                    }
                }
                .glassPanel(radius: 12)
                .padding(20)
                // 强制置顶：列表玻璃层会盖住行内的按钮。
                .onTop()
            }
        }
    }

    private func row(_ entry: ModEntry) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(entry.enabled ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "puzzlepiece.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(entry.enabled ? Color.accentColor : .secondary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(byteText(entry.size))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { _ in store.toggleMod(entry) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(entry.enabled ? "禁用（重命名为 .disabled）" : "启用")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")

            Button {
                store.deleteMod(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red.opacity(0.8))
            .help("删除")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .opacity(entry.enabled ? 1 : 0.55)
        // 强制置顶：行里的开关 / 删除按钮不能被外层玻璃层挡住。
        .onTop()
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modsPathText: String {
        guard let id = store.activeVersionID else { return "" }
        return Paths.modsDir(id).path
    }

    /// 某个版本的 mod 文件数（枚举目录，成本很低）。
    private func modCount(_ versionID: String) -> Int {
        let dir = Paths.modsDir(versionID)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return files.filter {
            let e = ($0 as NSString).pathExtension.lowercased()
            return e == "jar" || e == "zip" || e == "litemod" || e == "disabled"
        }.count
    }

    private func byteText(_ bytes: Int64) -> String {
        if bytes > 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    // MARK: 拖拽安装

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let versionID = store.activeVersionID else { return false }
        let dir = Paths.modsDir(versionID)
        try? Paths.ensure(dir)
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: url, to: dest)
                Task { @MainActor in store.refreshMods() }
            }
        }
        return true
    }
}

/// 拖拽高亮状态。
@MainActor
final class DropState: ObservableObject {
    @Published var targeted = false
}
