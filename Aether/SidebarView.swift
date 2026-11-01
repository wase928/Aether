//
//  SidebarView.swift
//  maccraft
//
//  「版本」分页：本机已安装的实例（原版 + 各种加载器），可切换当前版本、启动、删除。
//

import SwiftUI
import AppKit
import Combine

struct VersionsTabView: View {
    @EnvironmentObject private var store: LauncherStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.installed.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.installed) { v in
                            row(v)
                            Divider().opacity(0.4).padding(.leading, 62)
                        }
                    }
                    .glassPanel(radius: 12)
                    .padding(20)
                    // 强制置顶：列表玻璃层会盖住行内的按钮。
                    .onTop()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { store.refreshInstalled() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue)
            Text("已安装版本").font(.system(size: 24, weight: .bold))
            Text("\(store.installed.count)").font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { store.refreshInstalled() } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            Button { store.selectedTab = .download } label: {
                Label("安装新版本", systemImage: "plus")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    private func row(_ v: InstalledVersion) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(hex: v.loader.tintHex).opacity(0.18))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: icon(v.loader))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: v.loader.tintHex))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(v.id)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(v.loader.title)\(v.baseVersion.map { " · MC \($0)" } ?? "")\(v.hasClientJar ? "" : " · 缺客户端")")
                    .font(.caption2)
                    .foregroundStyle(v.hasClientJar ? Color.secondary : Color.orange)
            }

            Spacer(minLength: 0)

            if store.activeVersionID == v.id {
                Label("当前", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }

            Button("启动") {
                store.activeVersionID = v.id
                Task { await store.launch(versionID: v.id) }
            }
            .controlSize(.small)
            .disabled(store.isBusy)

            Button {
                store.activeVersionID = v.id
                store.refreshMods()
                store.selectedTab = .mods
            } label: {
                Image(systemName: "puzzlepiece.extension")
            }
            .buttonStyle(.borderless)
            .help("管理这个版本的 Mod")

            Button {
                NSWorkspace.shared.open(v.dir)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("打开版本目录")

            Button {
                store.deleteVersion(v.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red.opacity(0.75))
            .help("删除版本")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { store.activeVersionID = v.id }
        .opacity(store.activeVersionID == v.id ? 1 : 0.92)
        // 强制置顶：行里的「启动 / 删除」按钮不能被外层玻璃层挡住。
        .onTop()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 46)).foregroundStyle(.tertiary)
            Text("还没有安装版本").font(.headline)
            Text("去「下载」里装原版，或者加 Forge / Fabric / NeoForge / Quilt。")
                .font(.caption).foregroundStyle(.secondary)
            Button { store.selectedTab = .download } label: {
                Label("去下载", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func icon(_ loader: LoaderKind) -> String {
        switch loader {
        case .vanilla:  return "cube.fill"
        case .fabric:   return "square.stack.3d.up.fill"
        case .forge:    return "hammer.fill"
        case .neoforge: return "flame.fill"
        case .quilt:    return "square.grid.3x3.fill"
        }
    }
}
