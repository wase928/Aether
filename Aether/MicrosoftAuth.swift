//
//  MicrosoftAuth.swift
//  maccraft
//
//  ── 来源说明 ───────────────────────────────────────────────────────────
//  微软 / Xbox Live / Minecraft 的认证**协议流程与错误码表**参考了 HMCL 的
//  开源实现（GPL-3.0）：
//      HMCLCore/src/main/java/org/jackhuang/hmcl/auth/microsoft/MicrosoftService.java
//      https://github.com/HMCL-dev/HMCL
//  具体 Swift 代码为重新实现（未逐行翻译）；XErr 语义、调用顺序、失败判定
//  与原实现一致。协议本身（OAuth 设备码、Xbox Live 认证）是公开规范，
//  不受版权保护；若你打算字面移植 HMCL 代码，则本项目须整体改为 GPL-3.0。
//  ──────────────────────────────────────────────────────────────────────
//
//
//  微软正版登录（设备码 OAuth + Xbox Live + XSTS + Minecraft Services）。
//
//  流程：
//   1) POST /consumers/oauth2/v2.0/devicecode 拿 user_code，让用户在浏览器里输入；
//   2) 轮询 /token 直到拿到 access_token + refresh_token；
//   3) Xbox Live user.auth.xboxlive.com → XSTS xsts.auth.xboxlive.com；
//   4) api.minecraftservices.com/authentication/login_with_xbox → MC access token；
//   5) /minecraft/profile 拿 uuid / 名字 / 皮肤。
//
//  客户端 ID 默认取 HMCL 资源里公开的 hmcl.microsoft.auth.id（可在设置里换成自己的 Azure 应用）。
//

import Foundation
import Combine
import AppKit

nonisolated struct DeviceCodeInfo: Sendable {
    let userCode: String
    let deviceCode: String
    let verificationURI: String
    let interval: Int
    let expiresIn: Int
}

nonisolated struct MinecraftAccount: Codable, Sendable {
    var name: String
    var uuid: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var skinURL: String?

    // ---- 外置登录（Yggdrasil / authlib-injector）需要额外字段 ----
    // 旧存档里没有这些，保持 optional 以保证向后兼容。
    /// 账号类型："microsoft"（含从官方启动器导入）/ "yggdrasil"
    var kindRaw: String?
    /// Yggdrasil 服务器地址（仅外置登录）
    var yggdrasilServer: String?
    /// Yggdrasil 的 clientToken（登录时生成，刷新时要带上）
    var clientToken: String?

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw ?? "microsoft") ?? .microsoft }
        set { kindRaw = newValue.rawValue }
    }

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-120) }
}

nonisolated enum AccountKind: String, Sendable, Codable {
    case microsoft
    case yggdrasil

    var title: String {
        switch self {
        case .microsoft: return "正版（Microsoft）"
        case .yggdrasil: return "外置登录"
        }
    }
}

nonisolated enum AuthError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published var account: MinecraftAccount?
    @Published var device: DeviceCodeInfo?
    @Published var status: String = ""
    @Published var busy = false
    /// 借 HMCL 模块登录时，当前要用户输入的设备码。
    @Published var hmclUserCode: String?
    /// 登录面板是否展开（放这里避免视图用 @State）。
    @Published var showLoginSheet = false

    private var pollTask: Task<Void, Never>?
    private var accountFile: URL { Paths.appSupport.appendingPathComponent("account.json") }

    /// 只使用用户自己的 Azure 应用 ID（不内置任何第三方 client id）。
    var clientID: String? {
        let v = SettingsKeys.microsoftClientIDValue
        return v.isEmpty ? nil : v
    }

    var needsClientID: Bool { clientID == nil }

    init() {
        load()
        // App 冷启动：如果上次是登录状态，直接把心跳拉起来
        startHeartbeatIfNeeded()
    }

    // MARK: - 持久化

    func load() {
        guard let data = try? Data(contentsOf: accountFile) else { return }
        account = try? JSONDecoder().decode(MinecraftAccount.self, from: data)
    }

    private func save() {
        try? Paths.ensure(Paths.appSupport)
        if let data = try? JSONEncoder().encode(account) {
            try? data.write(to: accountFile, options: .atomic)
        }
    }

    func logout() {
        stopHeartbeat()
        pollTask?.cancel()
        account = nil
        device = nil
        status = "已退出登录"
        try? FileManager.default.removeItem(at: accountFile)
    }

    // MARK: - 登录

    func startLogin() {
        guard !busy else { return }
        guard clientID != nil else {
            status = "✖ 请先填写你自己的 Azure 客户端 ID（见下方步骤）"
            return
        }
        pollTask?.cancel()
        busy = true
        status = "正在申请设备码…"
        pollTask = Task { await self.runLogin() }
    }

    // MARK: - 自动续期（按 HMCL 的方式）

    // HMCL 没有常驻心跳：MicrosoftAccount.logIn() 只在
    // `currentTimeMillis() > session.notAfter()` 或令牌校验失败时才 refresh，
    // 即「用到才检查、过期才刷」。这里照做：
    //   · 每 5 分钟静默检查一次（不产生网络请求）
    //   · 只有剩余寿命不足 2 小时才真正刷新，Java 进程只在刷新那几秒存在
    //   · 整个 App 生命周期内一直保持，退出即停止

    /// 自动续期是否已开启（登录后为 true）。
    @Published var heartbeatActive = false
    /// 最近一次成功续期的时间。
    @Published var lastHeartbeat: Date?

    private var renewTimer: Timer?
    /// 刷新期间避免重入。
    private var renewBusy = false

    /// 登录成功后调用：开启「自动续期」。
    func startHeartbeatIfNeeded() {
        guard let acc = account, acc.kind == .microsoft, !acc.refreshToken.isEmpty else { return }
        renewTimer?.invalidate()

        // 测试可用 AETHER_RENEW_CHECK=10 把检查间隔缩到 10 秒
        var checkInterval: TimeInterval = 300
        if let raw = ProcessInfo.processInfo.environment["AETHER_RENEW_CHECK"],
           let v = Double(raw), v >= 3 {
            checkInterval = v
        }

        heartbeatActive = true
        renewTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
        // 启动时先看一次（不动网络，只在快过期时才刷）
        refreshIfNeeded()
    }

    /// 检查并（必要时）续期。
    /// - Parameter force: true 时忽略剩余寿命直接刷新。
    func refreshIfNeeded(force: Bool = false) {
        guard var acc = account, acc.kind == .microsoft, !acc.refreshToken.isEmpty else { return }
        // HMCL 的判定：没过期就不动。这里留 2 小时余量，避免游戏跑着跑着掉线。
        if !force, acc.expiresAt.timeIntervalSinceNow > 2 * 3600 { return }
        guard !renewBusy else { return }

        renewBusy = true
        status = "正在续期登录凭据…"
        let refreshToken = acc.refreshToken

        Task {
            defer { renewBusy = false }
            do {
                // 一次性 Java 进程：拿到令牌就退出，不做常驻
                let cred = try await HMCLLogin.refresh(refreshToken)
                let xbl = try await xboxLiveAuth(cred.accessToken)
                let xsts = try await xstsAuth(xbl.token, uhs: xbl.uhs)
                let mc = try await minecraftLogin(xsts: xsts.token, uhs: xsts.uhs)

                guard var latest = account else { return }
                latest.accessToken = mc
                latest.refreshToken = cred.refreshToken
                latest.expiresAt = Date().addingTimeInterval(24 * 3600)
                account = latest
                save()
                heartbeatActive = true
                lastHeartbeat = Date()
                status = "✔ 登录凭据已续期（有效 24 小时）"
            } catch {
                // 不打断使用：真正过期时启动流程里的 validAccount 会兜底
                status = "续期暂时失败：\(error.localizedDescription)"
                heartbeatActive = false
            }
        }
    }

    /// 停止自动续期（退出登录时）。
    func stopHeartbeat() {
        renewTimer?.invalidate()
        renewTimer = nil
        HMCLLogin.stopHeartbeat()
        HMCLLogin.terminateCurrent()
        heartbeatActive = false
    }

    /// 借 HMCL 的 Java 登录模块完成微软登录。
    /// 不需要用户自己注册 Azure 应用（不用绑卡），也不需要先在官方启动器登录过。
    /// 后台会起一个短命 Java 进程（HMCL jar 当库），走标准设备码流程。
    func loginViaHMCL() {
        guard !busy else { return }
        pollTask?.cancel()
        busy = true
        hmclUserCode = nil
        status = "正在准备 HMCL 登录模块…"
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cred = try await HMCLLogin.authenticate { dc in
                    Task { @MainActor in
                        self.hmclUserCode = dc.userCode
                        self.status = "请在浏览器输入 \(dc.userCode)"
                        if let url = URL(string: dc.url) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                await MainActor.run { self.status = "正在验证 Xbox 账号…" }
                let xbl = try await self.xboxLiveAuth(cred.accessToken)
                await MainActor.run { self.status = "正在获取 XSTS 授权…" }
                let xsts = try await self.xstsAuth(xbl.token, uhs: xbl.uhs)
                await MainActor.run { self.status = "正在登录 Minecraft…" }
                let mc = try await self.minecraftLogin(xsts: xsts.token, uhs: xsts.uhs)
                await MainActor.run { self.status = "正在读取角色信息…" }
                let profile = try await self.fetchProfile(token: mc)

                await MainActor.run {
                    self.account = MinecraftAccount(name: profile.name,
                                                    uuid: profile.id,
                                                    accessToken: mc,
                                                    refreshToken: cred.refreshToken,
                                                    expiresAt: Date().addingTimeInterval(24 * 3600),
                                                    skinURL: profile.skinURL,
                                                    kindRaw: AccountKind.microsoft.rawValue,
                                                    yggdrasilServer: nil,
                                                    clientToken: nil)
                    self.save()
                    self.hmclUserCode = nil
                    self.status = "✔ 已登录：\(profile.name)"
                    self.busy = false
                    // 登进去就把心跳挂上，之后令牌自动续期到 App 关闭
                    self.startHeartbeatIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.status = "✖ \(error.localizedDescription)"
                    self.hmclUserCode = nil
                    self.busy = false
                }
            }
        }
    }

    /// 外置登录（Yggdrasil / authlib-injector）。不需要微软账号，也不需要 Azure 应用。
    func loginYggdrasil(server: String, username: String, password: String) {
        guard !busy else { return }
        let normalized = Yggdrasil.normalize(server)
        guard let normalized else {
            status = "✖ 服务器地址不合法"
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            status = "✖ 请填写账号和密码"
            return
        }
        busy = true
        status = "正在连接 \(normalized)…"
        Task {
            do {
                let clientToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let session = try await Yggdrasil.authenticate(server: normalized,
                                                               username: username,
                                                               password: password,
                                                               clientToken: clientToken)
                guard let profile = session.selectedProfile else { throw YggdrasilError.noProfile }
                account = MinecraftAccount(name: profile.name,
                                           uuid: profile.id,
                                           accessToken: session.accessToken,
                                           refreshToken: "",
                                           expiresAt: Date().addingTimeInterval(7 * 24 * 3600),
                                           skinURL: nil,
                                           kindRaw: AccountKind.yggdrasil.rawValue,
                                           yggdrasilServer: normalized,
                                           clientToken: session.clientToken)
                save()
                device = nil
                status = "✔ 已登录：\(profile.name)（\(normalized)）"
            } catch {
                status = "✖ \(error.localizedDescription)"
            }
            busy = false
        }
    }

    func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        busy = false
        device = nil
        status = "已取消登录"
    }

    private func runLogin() async {
        do {
            let dc = try await requestDeviceCode()
            device = dc
            status = "请在浏览器输入 \(dc.userCode)"
            if let url = URL(string: dc.verificationURI) {
                NSWorkspace.shared.open(url)
            }

            let oauth = try await pollForToken(dc)
            status = "正在验证 Xbox 账号…"
            let xbl = try await xboxLiveAuth(oauth.accessToken)
            status = "正在获取 XSTS 授权…"
            let xsts = try await xstsAuth(xbl.token, uhs: xbl.uhs)
            status = "正在登录 Minecraft…"
            let mc = try await minecraftLogin(xsts: xsts.token, uhs: xsts.uhs)
            status = "正在读取角色信息…"
            let profile = try await fetchProfile(token: mc)

            account = MinecraftAccount(name: profile.name,
                                       uuid: profile.id,
                                       accessToken: mc,
                                       refreshToken: oauth.refreshToken,
                                       expiresAt: Date().addingTimeInterval(TimeInterval(oauth.expiresIn)),
                                       skinURL: profile.skinURL)
            save()
            device = nil
            status = "✔ 已登录：\(profile.name)"
        } catch is CancellationError {
            status = "已取消登录"
        } catch {
            status = "✖ 登录失败：\(error.localizedDescription)"
        }
        busy = false
    }

    /// 从官方启动器 / HMCL 导入已登录的账号（不需要 Azure 应用）。
    func importFromLauncher() {
        guard !busy else { return }
        busy = true
        status = "正在读取本机登录凭据…"
        Task {
            do {
                let acc = try await AccountImport.importAccount()
                account = acc
                save()
                device = nil
                status = "✔ 已导入：\(acc.name)（24 小时内有效，过期需重新导入）"
            } catch {
                status = "✖ \(error.localizedDescription)"
            }
            busy = false
        }
    }

    /// 启动前取一个可用 token（过期就用 refresh_token 续）。
    func validAccount() async -> MinecraftAccount? {
        guard var acc = account else { return nil }
        if !acc.isExpired { return acc }
        // 心跳在跑、且刚推过新令牌，直接用（避免重复走一遍刷新把心跳打断）
        if HMCLLogin.heartbeatRunning, let t = lastHeartbeat,
           Date().timeIntervalSince(t) < 3600 {
            return acc
        }

        // 外置登录：用 refresh 接口续期（皮肤站令牌一般 7~15 天）
        if acc.kind == .yggdrasil {
            guard let server = acc.yggdrasilServer, let ct = acc.clientToken else {
                status = "✖ 外置登录信息不完整，请重新登录"
                return nil
            }
            status = "正在刷新外置登录凭据…"
            do {
                let session = try await Yggdrasil.refresh(server: server,
                                                          accessToken: acc.accessToken,
                                                          clientToken: ct)
                guard let profile = session.selectedProfile else {
                    status = "✖ 认证服务器没有返回角色"
                    return nil
                }
                acc.accessToken = session.accessToken
                acc.clientToken = session.clientToken
                acc.name = profile.name
                acc.uuid = profile.id
                acc.expiresAt = Date().addingTimeInterval(7 * 24 * 3600)
                account = acc
                save()
                status = "✔ 外置登录凭据已续期"
                return acc
            } catch {
                status = "✖ 外置登录已过期：\(error.localizedDescription)"
                return nil
            }
        }

        // 从其它启动器导入的账号没有 refresh token —— 直接回钥匙串重读一次：
        // 官方启动器每次启动都会自动续期，钥匙串里就是最新的令牌。
        if acc.refreshToken.isEmpty {
            status = "凭据已过期，正在从官方启动器重新读取…"
            if let fresh = try? await AccountImport.importAccount() {
                account = fresh
                save()
                status = "✔ 已从官方启动器续期：\(fresh.name)"
                return fresh
            }
            status = "✖ 登录已过期。请打开官方启动器点一次「开始游戏」让它续期，再回来重新导入。"
            return nil
        }
        // 有 refresh token 时优先借 HMCL 模块续期：
        // 它自带 OAuth 客户端 ID，不需要用户自己注册 Azure 应用。
        if !acc.refreshToken.isEmpty {
            status = "刷新登录凭据…"
            do {
                let cred = try await HMCLLogin.refresh(acc.refreshToken)
                let xbl = try await xboxLiveAuth(cred.accessToken)
                let xsts = try await xstsAuth(xbl.token, uhs: xbl.uhs)
                let mc = try await minecraftLogin(xsts: xsts.token, uhs: xsts.uhs)
                acc.accessToken = mc
                acc.refreshToken = cred.refreshToken
                acc.expiresAt = Date().addingTimeInterval(24 * 3600)
                account = acc
                save()
                status = "✔ 凭据已自动续期"
                return acc
            } catch {
                // HMCL 模块不可用时，退回用户自己 client id 的 OAuth 刷新
                if clientID != nil, let oauth = try? await refreshToken(acc.refreshToken) {
                    acc.accessToken = oauth.accessToken
                    acc.refreshToken = oauth.refreshToken
                    acc.expiresAt = Date().addingTimeInterval(TimeInterval(oauth.expiresIn))
                    account = acc
                    save()
                    return acc
                }
                status = "✖ 登录已过期：\(error.localizedDescription)\n点「用 HMCL 模块登录」重新授权即可。"
                return nil
            }
        }

        status = "✖ 登录已过期，请重新登录"
        return nil
    }

    // MARK: - OAuth

    private struct TokenResult {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }

    private func requestDeviceCode() async throws -> DeviceCodeInfo {
        guard let clientID else { throw AuthError.message("未配置客户端 ID") }
        let body = "client_id=\(clientID)&scope=XboxLive.signin%20offline_access"
        let json = try await postForm("https://login.microsoftonline.com/common/oauth2/v2.0/devicecode", body)
        guard let code = json["user_code"] as? String,
              let device = json["device_code"] as? String else {
            let raw = errorText(json) ?? "devicecode 返回异常"
            if raw.contains("unauthorized_client") || raw.contains("invalid_client") {
                throw AuthError.message("客户端 ID 无效，或该应用未允许「公共客户端流」。请在应用的「身份验证」里把「允许公共客户端流」设为是。")
            }
            throw AuthError.message(raw)
        }
        return DeviceCodeInfo(userCode: code,
                              deviceCode: device,
                              verificationURI: (json["verification_uri"] as? String) ?? "https://microsoft.com/link",
                              interval: (json["interval"] as? Int) ?? 5,
                              expiresIn: (json["expires_in"] as? Int) ?? 900)
    }

    private func pollForToken(_ info: DeviceCodeInfo) async throws -> TokenResult {
        let deadline = Date().addingTimeInterval(TimeInterval(info.expiresIn))
        var interval = max(info.interval, 5)
        while Date() < deadline {
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try Task.checkCancellation()

            guard let clientID else { throw AuthError.message("未配置客户端 ID") }
            let body = "grant_type=urn:ietf:params:oauth:grant-type:device_code"
                + "&client_id=\(clientID)&device_code=\(info.deviceCode)"
            do {
                let json = try await postForm("https://login.microsoftonline.com/common/oauth2/v2.0/token", body)
                guard let token = json["access_token"] as? String else {
                    throw AuthError.message(errorText(json) ?? "token 返回异常")
                }
                return TokenResult(accessToken: token,
                                   refreshToken: (json["refresh_token"] as? String) ?? "",
                                   expiresIn: (json["expires_in"] as? Int) ?? 3600)
            } catch AuthError.message(let msg) where msg == "authorization_pending" {
                continue
            } catch AuthError.message(let msg) where msg == "slow_down" {
                interval += 5
                continue
            }
        }
        throw AuthError.message("授权超时，请重新登录")
    }

    private func refreshToken(_ refresh: String) async throws -> TokenResult {
        guard let clientID else { throw AuthError.message("未配置客户端 ID") }
        let body = "grant_type=refresh_token&client_id=\(clientID)"
            + "&refresh_token=\(refresh)&scope=XboxLive.signin%20offline_access"
        let json = try await postForm("https://login.microsoftonline.com/common/oauth2/v2.0/token", body)
        guard let token = json["access_token"] as? String else {
            throw AuthError.message(errorText(json) ?? "刷新失败")
        }
        return TokenResult(accessToken: token,
                           refreshToken: (json["refresh_token"] as? String) ?? refresh,
                           expiresIn: (json["expires_in"] as? Int) ?? 3600)
    }

    // MARK: - Xbox / Minecraft

    private func xboxLiveAuth(_ accessToken: String) async throws -> (token: String, uhs: String) {
        let payload: [String: Any] = [
            "Properties": [
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                "RpsTicket": "d=\(accessToken)"
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT"
        ]
        let json = try await postJSON("https://user.auth.xboxlive.com/user/authenticate", payload)
        guard let token = json["Token"] as? String,
              let claims = json["DisplayClaims"] as? [String: Any],
              let xui = (claims["xui"] as? [[String: Any]])?.first,
              let uhs = xui["uhs"] as? String else {
            throw AuthError.message("Xbox Live 认证失败")
        }
        return (token, uhs)
    }

    private func xstsAuth(_ xblToken: String, uhs: String) async throws -> (token: String, uhs: String) {
        let payload: [String: Any] = [
            "Properties": ["SandboxId": "RETAIL", "UserTokens": [xblToken]],
            "RelyingParty": "rp://api.minecraftservices.com/",
            "TokenType": "JWT"
        ]
        // HMCL 的 XboxAuthorizationException：XSTS 失败时返回体里有 XErr 码，
        // 需要据此给出可操作的提示，而不是笼统的"认证失败"。
        let (json, status) = try await postJSONRaw("https://xsts.auth.xboxlive.com/xsts/authorize", payload)

        if let code = jsonInt(json["XErr"]) {
            throw XboxAuthError.from(xerr: code, redirect: json["Redirect"] as? String)
        }
        guard status == 200, let token = json["Token"] as? String else {
            throw AuthError.message(errorText(json) ?? "XSTS 授权失败（HTTP \(status)）")
        }
        // XSTS 也会带 DisplayClaims.xui[0].uhs，需与 XBL 阶段一致（HMCL 会核对）
        if let claims = json["DisplayClaims"] as? [String: Any],
           let xui = (claims["xui"] as? [[String: Any]])?.first,
           let newUHS = xui["uhs"] as? String, newUHS != uhs {
            throw AuthError.message("Xbox 返回的用户哈希不一致，请重新登录")
        }
        return (token, uhs)
    }

    private func minecraftLogin(xsts: String, uhs: String) async throws -> String {
        let payload: [String: Any] = ["identityToken": "XBL3.0 x=\(uhs);\(xsts)"]
        let json = try await postJSON("https://api.minecraftservices.com/authentication/login_with_xbox", payload)
        guard let token = json["access_token"] as? String else {
            throw AuthError.message(errorText(json) ?? "Minecraft 登录失败（可能没有正版）")
        }
        // HMCL 在拿到 token 后还会查 entitlements/mcstore 确认拥有游戏（GitHub#2979）。
        // /minecraft/profile 返回 404 也能判断，但那要等下一步；这里提前给明确结论。
        try await checkGameOwnership(token: token)
        return token
    }

    /// 校验账号确实拥有 Minecraft（HMCL 的 Check MC ownership 步骤）。
    /// 只会抛"没有游戏"，网络异常不阻断登录（离线可用性优先）。
    private func checkGameOwnership(token: String) async throws {
        guard let url = URL(string: "https://api.minecraftservices.com/entitlements/mcstore") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 {
            throw AuthError.message("Minecraft 令牌无效，请重新登录")
        }
        guard http.statusCode == 200 else { return }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let items = (json["items"] as? [[String: Any]]) ?? []
        let names = items.compactMap { $0["name"] as? String }
        // 有 game_minecraft / product_minecraft 才算拥有 Java 版
        if !names.isEmpty,
           !names.contains(where: { $0.contains("minecraft") }) {
            throw AuthError.message("这个账号没有 Minecraft Java 版（只有其他产品）")
        }
    }

    /// 兼容 Int / Int64 / Double / String 的数值解析。
    private func jsonInt(_ any: Any?) -> Int64? {
        switch any {
        case let v as Int: return Int64(v)
        case let v as Int64: return v
        case let v as Double: return Int64(v)
        case let v as NSNumber: return v.int64Value
        case let v as String: return Int64(v)
        default: return nil
        }
    }

    /// 不会因 HTTP 错误而抛异常的 POST（用于需要读取 XErr 的接口）。
    private func postJSONRaw(_ url: String, _ payload: [String: Any]) async throws -> ([String: Any], Int) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 25
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private struct Profile {
        let id: String
        let name: String
        let skinURL: String?
    }

    private func fetchProfile(token: String) async throws -> Profile {
        var req = URLRequest(url: URL(string: "https://api.minecraftservices.com/minecraft/profile")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
            throw AuthError.message("这个账号没有 Minecraft Java 版")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let id = json["id"] as? String, let name = json["name"] as? String else {
            throw AuthError.message("读取角色信息失败")
        }
        let skins = json["skins"] as? [[String: Any]]
        return Profile(id: id, name: name, skinURL: skins?.first?["url"] as? String)
    }

    // MARK: - HTTP

    private func postForm(_ url: String, _ body: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let err = json["error"] as? String {
            throw AuthError.message(err)
        }
        return json
    }

    private func postJSON(_ url: String, _ payload: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 25
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400, json["Token"] == nil {
            throw AuthError.message(errorText(json) ?? "HTTP \(http.statusCode)")
        }
        return json
    }

    /// 微软错误响应里最有用的一段文字。
    private func errorText(_ json: [String: Any]) -> String? {
        if let desc = json["error_description"] as? String { return desc }
        if let msg = json["Message"] as? String { return msg }
        if let err = json["error"] as? String { return err }
        return nil
    }
}
