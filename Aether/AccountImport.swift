//
//  AccountImport.swift
//  maccraft
//
//  从本机其它启动器导入已登录的账号（不需要 Azure 应用、不需要绑卡）。
//
//  来源：
//   1. 官方启动器（2.x）：令牌存在 macOS 钥匙串
//        service = "mojangTokenService"
//        account = <localId>（取自 launcher_accounts.json 的 activeAccountLocalId）
//      值格式为 "<容器UUID(36)><版本(8)><IV(16)><JWT>"，JWT 从 "eyJ" 开始，
//      kid=049181 即 Minecraft 的签名密钥 —— 它本身就是可直接使用的 access token。
//   2. 官方启动器（旧版 Java Launcher）：~/Library/Application Support/minecraft/launcher_accounts.json
//   3. HMCL：~/Library/Application Support/hmcl/config/user-accounts.json（若含 token 字段）
//
//  说明：导入的是「访问令牌」，Minecraft 的 token 约 24 小时过期，
//  续期需要原启动器的 client id，所以过期后要在原启动器里点一下再导入一次。
//

import Foundation

nonisolated enum AccountImport {

    struct Source: Sendable {
        let name: String
        let detail: String
        let available: Bool
    }

    /// 官方启动器（2.x）在钥匙串里的 service 名。account 为 localId。
    private static let keychainService = "mojangTokenService"

    private static var launcherAccountsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/minecraft/launcher_accounts.json")
    }

    private static var hmclAccounts: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/hmcl/config/user-accounts.json")
    }

    // MARK: - 探测

    static func sources() -> [Source] {
        var out: [Source] = []

        let ids = launcherLocalIDs()
        let hasLauncherFile = FileManager.default.fileExists(atPath: launcherAccountsURL.path)
        var keychainAvailable = false
        var detail = "没找到 launcher_accounts.json（官方启动器未登录过）"
        if hasLauncherFile {
            if ids.isEmpty {
                detail = "账号文件里没有 localId"
            } else if keychainHasItem(account: ids[0]) {
                keychainAvailable = true
                detail = "钥匙串里找到登录凭据（\(ids.count) 个账号）"
            } else {
                detail = "账号文件在，但钥匙串里没有令牌 — 请先在官方启动器登录一次"
            }
        }
        out.append(Source(name: "官方启动器（新版）", detail: detail, available: keychainAvailable))

        let legacy = legacyTokenState()
        out.append(Source(name: "官方启动器（旧版 Java）", detail: legacy.detail, available: legacy.ok))

        var hmclDetail = "未找到 HMCL 账号文件"
        var hmclOK = false
        if let data = try? Data(contentsOf: hmclAccounts),
           let text = String(data: data, encoding: .utf8) {
            hmclOK = text.contains("accessToken")
            hmclDetail = hmclOK ? "找到带 token 的账号记录" : "文件存在，但没有保存 token（HMCL 未持久化）"
        }
        out.append(Source(name: "HMCL", detail: hmclDetail, available: hmclOK))

        return out
    }

    /// launcher_accounts.json 里所有账号的 localId（活跃账号排最前）。
    private static func launcherLocalIDs() -> [String] {
        guard let data = try? Data(contentsOf: launcherAccountsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let accounts = json["accounts"] as? [String: Any] ?? [:]
        var ids: [String] = []
        if let active = json["activeAccountLocalId"] as? String, accounts[active] != nil {
            ids.append(active)
        }
        for key in accounts.keys where !ids.contains(key) { ids.append(key) }
        return ids
    }

    /// 旧版 launcher_accounts.json 可能只是空壳（有 accounts 但没有 accessToken）。
    private static func legacyTokenState() -> (ok: Bool, detail: String) {
        guard let data = try? Data(contentsOf: launcherAccountsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "没找到 \(launcherAccountsURL.lastPathComponent)")
        }
        let accounts = json["accounts"] as? [String: Any] ?? [:]
        let tokens = accounts.values.compactMap { ($0 as? [String: Any])?["accessToken"] as? String }
            .filter { !$0.isEmpty }
        if tokens.isEmpty {
            return (false, "文件存在但 accessToken 为空（2.x 版把令牌放在钥匙串里）")
        }
        return (true, "\(tokens.count) 个带 token 的账号")
    }

    // MARK: - 导入

    static func importAccount() async throws -> MinecraftAccount {
        // 1) 新版官方启动器（钥匙串）
        for localID in launcherLocalIDs() {
            guard let secret = keychainSecret(account: localID),
                  let token = extractAccessToken(from: secret) else { continue }
            if let acc = try? await validate(token: token) { return acc }
        }
        // 2) 旧版 launcher_accounts.json 里直接存的 token
        if let acc = try? importLegacyLauncher() { return acc }
        // 3) HMCL
        if let acc = try? importHMCL() { return acc }

        throw AuthError.message("没找到可用的登录凭据。请先打开官方启动器登录一次，再回来点「导入」。\n（首次导入会弹一次钥匙串授权框，输入 Mac 登录密码并选「始终允许」即可。）")
    }

    // MARK: - 各来源实现

    private static func importLegacyLauncher() throws -> MinecraftAccount {
        guard let data = try? Data(contentsOf: launcherAccountsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.message("读不到官方启动器的账号文件")
        }
        let accounts = json["accounts"] as? [String: Any] ?? [:]
        let activeLocalID = json["activeAccountLocalId"] as? String

        var candidates: [[String: Any]] = []
        if let activeLocalID, let a = accounts[activeLocalID] as? [String: Any] {
            candidates.append(a)
        }
        candidates.append(contentsOf: accounts.values.compactMap { $0 as? [String: Any] })

        for a in candidates {
            guard let token = a["accessToken"] as? String, !token.isEmpty else { continue }
            let profiles = a["profiles"] as? [String: Any] ?? [:]
            let first = profiles.values.compactMap { $0 as? [String: Any] }.first
            let name = (first?["name"] as? String) ?? "Player"
            let uuid = (first?["id"] as? String) ?? ""
            return MinecraftAccount(name: name, uuid: uuid, accessToken: token,
                                    refreshToken: "",
                                    expiresAt: expiry(of: token) ?? Date().addingTimeInterval(24 * 3600),
                                    skinURL: nil)
        }
        throw AuthError.message("官方启动器账号文件里没有可用 token")
    }

    private static func importHMCL() throws -> MinecraftAccount {
        guard let data = try? Data(contentsOf: hmclAccounts),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [[String: Any]] else {
            throw AuthError.message("读不到 HMCL 账号文件")
        }
        for a in accounts where (a["type"] as? String) == "microsoft" {
            let tokenDict = a["token"] as? [String: Any]
            if let token = tokenDict?["accessToken"] as? String, !token.isEmpty {
                let profile = a["profile"] as? [String: Any]
                return MinecraftAccount(name: (profile?["name"] as? String) ?? "Player",
                                        uuid: (profile?["id"] as? String) ?? "",
                                        accessToken: token, refreshToken: "",
                                        expiresAt: expiry(of: token) ?? Date().addingTimeInterval(24 * 3600),
                                        skinURL: nil)
            }
        }
        throw AuthError.message("HMCL 账号文件里没有保存 token")
    }

    // MARK: - 钥匙串

    /// 探测条目是否存在（不带 -w，不会触发授权框）。
    private static func keychainHasItem(account: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-a", account]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// 读取钥匙串里的值。
    /// 首次会弹系统授权框（要的是 **Mac 登录密码**，不是 Apple ID 密码）；
    /// 选「始终允许」之后就不再询问。
    private static func keychainSecret(account: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        // 先读完再 waitUntilExit，避免管道写满导致死锁
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从任意 JSON/文本里找 Minecraft 访问令牌（JWT 或纯 token 字段）。
    private static func extractAccessToken(from blob: String) -> String? {
        if let data = blob.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let t = findToken(in: json) { return t }
        }
        // 钥匙串值形如 "<uuid36><ver8><iv16>eyJ..."，直接从 eyJ 起挑出三段 JWT
        let pattern = #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: blob, range: NSRange(blob.startIndex..., in: blob)),
           let r = Range(m.range, in: blob) {
            return String(blob[r])
        }
        return nil
    }

    private static func findToken(in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            for key in ["accessToken", "access_token", "mcToken", "token"] {
                if let t = dict[key] as? String, t.count > 40, !t.hasPrefix("http") { return t }
            }
            for value in dict.values {
                if let t = findToken(in: value) { return t }
            }
        } else if let arr = object as? [Any] {
            for value in arr {
                if let t = findToken(in: value) { return t }
            }
        }
        return nil
    }

    // MARK: - JWT 辅助

    /// 从 JWT payload 里取 exp（过期时间）。
    static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let data = Data(base64Encoded: s),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - 校验

    /// 用 /minecraft/profile 验证 token 并补齐名字 / uuid / 皮肤。
    static func validate(token: String) async throws -> MinecraftAccount {
        var req = URLRequest(url: URL(string: "https://api.minecraftservices.com/minecraft/profile")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AuthError.message("校验失败：无响应")
        }
        guard http.statusCode == 200 else {
            throw AuthError.message(http.statusCode == 401
                                    ? "凭据已过期，请在原启动器里重新登录后再导入"
                                    : "校验失败（HTTP \(http.statusCode)）")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let name = json["name"] as? String, let id = json["id"] as? String else {
            throw AuthError.message("这个账号没有 Minecraft Java 版")
        }
        let skins = json["skins"] as? [[String: Any]]
        return MinecraftAccount(name: name, uuid: id, accessToken: token, refreshToken: "",
                                expiresAt: expiry(of: token) ?? Date().addingTimeInterval(24 * 3600),
                                skinURL: skins?.first?["url"] as? String)
    }
}
