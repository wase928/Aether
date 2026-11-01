//
//  AccountView.swift
//  maccraft
//
//  正版登录 UI：侧栏账号胶囊 + 登录面板（设备码登录 / 从本机启动器导入）。
//

import SwiftUI
import AppKit
import Combine

/// 侧栏底部的账号入口。
struct AccountChip: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        Button {
            account.showLoginSheet = true
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(account.account == nil
                          ? AnyShapeStyle(Color.secondary.opacity(0.18))
                          : AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x5AD1FF), Color(hex: 0x2A6BFF)],
                                                         startPoint: .top, endPoint: .bottom)))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: account.account == nil ? "person.fill" : "person.crop.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(account.account == nil ? Color.secondary : .white)
                    )

                VStack(alignment: .leading, spacing: 0) {
                    Text(account.account?.name ?? "未登录")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(account.account == nil ? "点此正版登录" : "微软正版")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

/// 登录面板。
struct LoginSheet: View {
    @EnvironmentObject private var account: AccountStore
    @AppStorage(SettingsKeys.microsoftClientID) private var clientID = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("账号").font(.headline)
                    Text("登录后可联机、显示正版皮肤；也能用外置登录（皮肤站）。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let dev = account.device {
                        deviceCodeCard(dev)
                    } else if let acc = account.account {
                        loggedInCard(acc)
                    } else {
                        loginSection
                    }

                    if !account.status.isEmpty {
                        Text(account.status)
                            .font(.caption)
                            .foregroundStyle(account.status.hasPrefix("✖") ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    DisclosureGroup("正版直登需要自己的 Azure 应用（展开看步骤）") {
                        setupGuide.padding(.top, 6)
                    }
                    .font(.caption)
                    .disabled(account.device != nil)
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer(minLength: 0)
                Button("关闭") { account.showLoginSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 600)
    }

    // MARK: 未登录

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 主推：借 HMCL 的登录模块。不需要注册 Azure 应用、不用绑卡。
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    account.loginViaHMCL()
                } label: {
                    Label("用 HMCL 登录模块登录", systemImage: "person.badge.shield.checkmark.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(account.busy)

                Text("后台调用本机的 HMCL jar，用它自带的客户端 ID 走设备码登录。不用注册 Azure 应用、不用绑卡，登录后还能自动续期。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let code = account.hmclUserCode {
                    hmclCodeCard(code)
                }
            }

            Divider()
            importSection
            Divider()

            // 次要路径：用户自己的 Azure 应用（要绑卡才能注册）
            VStack(alignment: .leading, spacing: 7) {
                Text("或者：用你自己的 Azure 应用登录（注册需绑卡）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    account.startLogin()
                } label: {
                    Label(account.needsClientID ? "Microsoft 登录（需先填客户端 ID）" : "Microsoft 登录",
                          systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(account.busy || account.needsClientID)
            }
        }
    }

    /// 借 HMCL 模块登录时显示的设备码。
    private func hmclCodeCard(_ code: String) -> some View {
        VStack(spacing: 8) {
            Text("在浏览器里输入这个代码")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 2)
            HStack(spacing: 8) {
                Button("复制代码") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .controlSize(.small)
                Button("打开登录页") {
                    if let u = URL(string: "https://www.microsoft.com/link") {
                        NSWorkspace.shared.open(u)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 从本机已登录的启动器导入（不需要 Azure 应用、不需要绑卡）。
    private var importSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("从本机已登录的启动器导入", systemImage: "square.and.arrow.down")
                .font(.callout.weight(.semibold))

            ForEach(AccountImport.sources(), id: \.name) { src in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: src.available ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(src.available ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(src.name).font(.caption.weight(.medium))
                        Text(src.detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }

            Button {
                account.importFromLauncher()
            } label: {
                Label("导入账号", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .controlSize(.large)
            .disabled(account.busy)

            Text("导入的是访问令牌（约 24 小时有效）。过期后回原启动器点一次启动再导入即可，全程不需要 Azure 应用或绑卡。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: 设备码

    private func deviceCodeCard(_ dev: DeviceCodeInfo) -> some View {
        VStack(spacing: 12) {
            Text("在浏览器里输入下面的代码").font(.caption).foregroundStyle(.secondary)
            Text(dev.userCode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .tracking(4)
                .textSelection(.enabled)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .glassPanel(radius: 12)

            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(dev.userCode, forType: .string)
                } label: {
                    Label("复制代码", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    if let url = URL(string: dev.verificationURI) { NSWorkspace.shared.open(url) }
                } label: {
                    Label("打开登录页", systemImage: "safari")
                }
                .controlSize(.small)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("等待授权…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Button("取消登录", role: .destructive) { account.cancelLogin() }
                .controlSize(.small)
        }
        .padding(14)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: 已登录

    private func loggedInCard(_ acc: MinecraftAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AsyncImage(url: acc.skinURL.flatMap(URL.init)) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(acc.name).font(.headline)
                    Text(acc.uuid).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("退出登录", role: .destructive) { account.logout() }
                    .controlSize(.small)
            }

            if acc.refreshToken.isEmpty {
                Text("这个账号是从本机导入的，令牌约 24 小时有效；过期后回原启动器点一次启动再导入。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                heartbeatRow
            }
        }
        .padding(12)
        .glassPanel(radius: 12)
    }

    /// 自动续期状态行
    private var heartbeatRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(account.heartbeatActive ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(account.heartbeatActive ? "自动续期已开启" : "自动续期未开启")
                .font(.caption2.weight(.medium))
                .foregroundStyle(account.heartbeatActive ? Color.green : Color.orange)
            if let t = account.lastHeartbeat {
                Text("· 上次续期 " + t.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Text("临近过期自动刷新")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 注册指引

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("注册应用要先有 Entra 目录，新建目录现在要验证信用卡", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 6) {
                step(1, "微软 2024-06 起禁止无目录注册应用；而新建租户（Azure 免费 / M365 沙箱）都要账单验证，官方文档写的是必须提供信用卡。")
                step(2, "免卡的只有：已有工作/学校账号（直接在它的目录里建应用），或学生认证的 Azure for Students。")
                step(3, "有目录后：应用注册 → 新注册 → 账户类型选「任何组织目录中的账户和个人 Microsoft 账户」")
                step(4, "身份验证 → 允许公共客户端流 = 是")
                step(5, "API 权限 → 我的组织使用的 API → 搜 Xbox Live → 勾 XboxLive.signin、offline_access")
                step(6, "复制「应用程序(客户端) ID」填到下面")
            }

            HStack(spacing: 6) {
                linkButton("Azure for Students（免卡）", "https://azure.microsoft.com/free/students/")
                linkButton("打开应用注册", "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")
            }

            TextField("应用程序(客户端) ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(12)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func linkButton(_ title: String, _ url: String) -> some View {
        Button(title) {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
        .controlSize(.mini)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(n).").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            Text(text).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
