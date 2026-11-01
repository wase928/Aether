//
//  HomeView.swift
//  maccraft
//
//  主页：PCL2 那种「一张大卡片 + 大号启动按钮」的布局。
//  左侧竖栏负责导航，这里只放当前版本、状态、快捷入口和运行日志。
//

import SwiftUI
import AppKit
import Combine

extension Color {
    /// 0xRRGGBB -> Color
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: LauncherStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let version = store.activeVersion {
                    hero(version)
                } else {
                    emptyState
                }
                quickActions
                console
            }
            .padding(24)
            .frame(maxWidth: 1020, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await store.loadManifest(); store.refreshInstalled() }
    }

    // MARK: - 主卡片

    private func hero(_ version: InstalledVersion) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: gradient(for: version.loader),
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 76, height: 76)
                    .overlay(
                        Image(systemName: icon(for: version.loader))
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: gradient(for: version.loader).first!.opacity(0.35), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 7) {
                    Text(version.id)
                        .font(.system(size: 27, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        chip(version.loader.title, color: Color(hex: version.loader.tintHex))
                        if let base = version.baseVersion {
                            chip("Minecraft \(base)", color: .secondary)
                        }
                        if version.type == "snapshot" {
                            chip("快照", color: .orange)
                        }
                        chip("Java \(javaMajor(version))", color: .secondary)
                    }

                    Text(version.dir.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 10) {
                    statusPill
                    versionMenu(current: version)
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }

            if store.phase == .running {
                // 游戏在跑：不要再显示下载进度条 —— 那是上一阶段的残留，
                // 满格的进度条配一句「下载资源 3828/5147」特别误导。
                // 这里改成运行状态提示 + 停止按钮。
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(store.statusText.isEmpty ? "游戏运行中" : store.statusText)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(role: .destructive) { store.stop() } label: {
                        Label("停止游戏", systemImage: "stop.fill")
                    }
                    .controlSize(.small)
                }
            } else if store.isBusy {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: store.progress) {
                        Text(store.statusText).font(.caption).lineLimit(1)
                    }
                    .progressViewStyle(.linear)
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task { await store.launch(versionID: version.id) }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: store.phase == .running ? "gamecontroller.fill" : "play.fill")
                            .font(.title3)
                        Text(store.phase == .running ? "游戏中…" : "启动游戏")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .controlSize(.large)
                // 突出玻璃按钮：按下去会有高光变化，比纯色按钮更有质感。
                // tint 必须在 buttonStyle **之前** —— 反过来的话 glassProminent
                // 拿不到 tint，按钮会是一片没有颜色的透明玻璃。
                .tint(gradient(for: version.loader).first!)
                .buttonStyle(.glassProminent)
                .disabled(store.isBusy)
                // 强制置顶：卡片外层的 overlay 叠在上面会把点击吃掉。
                .onTop()

                Button {
                    NSWorkspace.shared.open(version.dir)
                } label: {
                    Image(systemName: "folder")
                        .font(.title3)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("打开版本目录")
                .onTop()
            }
            // 卡片内容整体置顶，压过下面两个 overlay。
            .onTop(1)
        }
        .padding(24)
        .glassPanel(radius: 22)
        // 加载器色调的渐变：放**背景层**，不放在 overlay 里 ——
        // overlay 会在内容之上，既拦截点击又把按钮文字冲淡成灰色。
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [gradient(for: version.loader).first!.opacity(0.16), .clear],
                                     startPoint: .topLeading, endPoint: .center))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - 快捷入口

    private var quickActions: some View {
        HStack(spacing: 14) {
            actionCard("下载游戏", "游戏本体 / 加载器 / Mod / 光影", "arrow.down.circle.fill", .cyan) {
                store.selectedTab = .download
            }
            actionCard("Mod 管理", "启用、禁用、删除已装 Mod", "puzzlepiece.extension.fill", .purple) {
                store.selectedTab = .mods
            }
            actionCard("实例版本", "查看本机已安装的版本", "square.stack.3d.up.fill", .blue) {
                store.selectedTab = .versions
            }
            actionCard("打开游戏目录", Paths.appSupport.path, "folder.fill", .orange) {
                NSWorkspace.shared.open(Paths.appSupport)
            }
        }
    }

    private func actionCard(_ title: String, _ subtitle: String, _ icon: String,
                            _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassPanel(radius: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        // 强制置顶：卡片自己的 overlay 叠在上面会把点击吃掉。
        .onTop()
    }

    // MARK: - 日志

    private var console: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("运行日志", systemImage: "terminal").font(.headline)
                Spacer(minLength: 0)
                Button {
                    NSWorkspace.shared.open(Paths.logsDir.appendingPathComponent("latest.log"))
                } label: {
                    Label("完整日志", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
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
                .frame(minHeight: 220)
                .glassPanel(radius: 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("还没有安装任何版本").font(.title3.weight(.semibold))
            Text("先去「下载」里装一个原版，再加 Forge / Fabric 之类的加载器。")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                store.selectedTab = .download
            } label: {
                Label("去下载", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .glassPanel(radius: 22)
    }

    // MARK: - 小组件

    private func versionMenu(current: InstalledVersion) -> some View {
        Menu {
            ForEach(store.installed) { v in
                Button {
                    store.activeVersionID = v.id
                    store.refreshMods()
                } label: {
                    Text("\(v.id)  ·  \(v.loader.title)")
                }
            }
            Divider()
            Button("刷新版本列表") { store.refreshInstalled() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down.circle")
                Text("切换版本")
            }
            .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    private var statusPill: some View {
        let info = statusInfo
        return HStack(spacing: 7) {
            Circle().fill(info.color).frame(width: 8, height: 8)
            Text(info.text).font(.caption.weight(.semibold)).foregroundStyle(info.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(info.color.opacity(0.14)))
    }

    private var statusInfo: (text: String, color: Color) {
        switch store.phase {
        case .idle:            return ("就绪", .green)
        case .loadingManifest: return ("刷新中", .blue)
        case .preparing:       return ("准备中", .blue)
        case .downloading:     return ("下载中", .orange)
        case .launching:       return ("启动中", .blue)
        case .running:         return ("运行中", .green)
        case .error:           return ("出错", .red)
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    private func gradient(for loader: LoaderKind) -> [Color] {
        switch loader {
        case .vanilla:  return [Color(hex: 0x62D08A), Color(hex: 0x2E9E6B)]
        case .fabric:   return [Color(hex: 0xF2C46B), Color(hex: 0xD0902F)]
        case .forge:    return [Color(hex: 0x6E9BFF), Color(hex: 0x3B5FD0)]
        case .neoforge: return [Color(hex: 0xFFA86B), Color(hex: 0xD9691F)]
        case .quilt:    return [Color(hex: 0xD77BEC), Color(hex: 0x9B3FBF)]
        }
    }

    private func icon(for loader: LoaderKind) -> String {
        switch loader {
        case .vanilla:  return "cube.fill"
        case .fabric:   return "square.stack.3d.up.fill"
        case .forge:    return "hammer.fill"
        case .neoforge: return "flame.fill"
        case .quilt:    return "square.grid.3x3.fill"
        }
    }

    private func javaMajor(_ v: InstalledVersion) -> Int {
        if let r = try? VersionLibrary.resolve(v.id) {
            return JavaManager.requiredJavaMajor(for: r.details,
                                                 hint: r.chain.count > 1 ? r.chain.last : r.details.id)
        }
        return 21
    }
}
