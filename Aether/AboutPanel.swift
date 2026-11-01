//
//  AboutPanel.swift
//  maccraft
//
//  「关于 Aether」面板：系统 About 面板 + 自定义说明文字。
//  用 credits 塞几行简介，既不换掉原生样式，又能说清楚这软件是干什么的。
//

import AppKit

nonisolated enum AboutPanel {

    @MainActor
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Aether",
            .applicationVersion: version,
            .version: build,
            .credits: credits(version: version, build: build)
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private static func credits(version: String, build: String) -> NSAttributedString {
        let arch = currentArchitecture()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3

        let text = NSMutableAttributedString()

        func line(_ s: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
            text.append(NSAttributedString(string: s + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]))
        }

        line("Minecraft 启动器 · 原生 Swift / \(arch)",
             size: 11.5, color: .labelColor, weight: .medium)
        line("原版 · Forge · Fabric · NeoForge · Quilt",
             size: 11, color: .secondaryLabelColor)
        line("整合包、Mod、光影、资源包一键安装",
             size: 11, color: .secondaryLabelColor)
        line("仅支持 macOS 26+ / Apple 芯片",
             size: 10.5, color: .tertiaryLabelColor)

        // 末尾去掉最后一个换行，避免面板底部多一条空白
        if text.length > 0 {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
        return text
    }

    /// 运行架构（arm64 / x86_64），给「原生」两个字做佐证。
    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
