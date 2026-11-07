//
//  Yggdrasil.swift
//  maccraft
//
//  外置登录（authlib-injector / 皮肤站）。不需要微软账号、不需要 Azure 应用，
//  只要在支持 Yggdrasil 协议的认证服务器上注册过账号就能登录。
//
//  ── 来源说明 ───────────────────────────────────────────────────────────
//  协议流程参考 HMCL 的开源实现（GPL-3.0）：
//      HMCLCore/src/main/java/org/jackhuang/hmcl/auth/yggdrasil/YggdrasilService.java
//      HMCLCore/src/main/java/org/jackhuang/hmcl/auth/authlibinjector/AuthlibInjectorAccount.java
//      https://github.com/HMCL-dev/HMCL
//  Yggdrasil 是公开协议规范（https://wiki.vg/Authentication），
//  authlib-injector 的注入方式见其官方技术规范。Swift 代码为重新实现。
//  ──────────────────────────────────────────────────────────────────────
//

import Foundation

// MARK: - 数据模型

nonisolated struct YggdrasilProfile: Codable, Sendable, Hashable {
    let id: String      // 32 位无横线 UUID
    let name: String

    /// 带横线的标准 UUID（游戏参数要求无横线，展示时用这个）。
    var formattedUUID: String {
        guard id.count == 32 else { return id }
        let s = id
        let parts = [s.prefix(8), s.dropFirst(8).prefix(4), s.dropFirst(12).prefix(4),
                     s.dropFirst(16).prefix(4), s.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}

nonisolated struct YggdrasilSession: Codable, Sendable {
    let accessToken: String
    let clientToken: String
    let selectedProfile: YggdrasilProfile?
    let availableProfiles: [YggdrasilProfile]?
}

nonisolated enum YggdrasilError: LocalizedError {
    case invalidCredentials
    case forbidden(String)
    case server(String)
    case malformed(String)
    case noProfile

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "账号或密码错误。"
        case .forbidden(let m):
            return m.isEmpty ? "服务器拒绝登录（可能是密码错误或账号被限制）。" : m
        case .server(let m):
            return "认证服务器出错：\(m)"
        case .malformed(let m):
            return "认证服务器返回了无法识别的内容：\(m)"
        case .noProfile:
            return "这个账号下还没有创建角色，请先去皮肤站创建一个。"
        }
    }
}

// MARK: - 协议实现

nonisolated enum Yggdrasil {

    /// 规范化服务器地址：去掉尾部斜杠，没写协议时补 https。
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func post(_ url: String, _ payload: [String: Any]) async throws -> (json: [String: Any], status: Int) {
        guard let u = URL(string: url) else { throw YggdrasilError.malformed(url) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json, status)
    }

    private static func interpret(_ json: [String: Any], status: Int) throws {
        guard status >= 400 else { return }
        let error = (json["error"] as? String) ?? ""
        let message = (json["errorMessage"] as? String) ?? ""
        if error == "ForbiddenOperationException" {
            if message.localizedCaseInsensitiveContains("invalid credentials")
                || message.localizedCaseInsensitiveContains("invalid username")
                || message.localizedCaseInsensitiveContains("invalid password") {
                throw YggdrasilError.invalidCredentials
            }
            throw YggdrasilError.forbidden(message)
        }
        throw YggdrasilError.server(message.isEmpty ? "HTTP \(status)" : message)
    }

    /// 登录：用户名 + 密码 → 会话。
    static func authenticate(server: String, username: String, password: String,
                             clientToken: String) async throws -> YggdrasilSession {
        guard let base = normalize(server) else { throw YggdrasilError.malformed(server) }
        let payload: [String: Any] = [
            "agent": ["name": "Minecraft", "version": 1],
            "username": username,
            "password": password,
            "clientToken": clientToken,
            "requestUser": true
        ]
        let (json, status) = try await post("\(base)/authserver/authenticate", payload)
        try interpret(json, status: status)
        return try session(from: json, fallbackClientToken: clientToken)
    }

    /// 用已有的 accessToken 刷新（皮肤站一般 7~15 天有效）。
    static func refresh(server: String, accessToken: String, clientToken: String) async throws -> YggdrasilSession {
        guard let base = normalize(server) else { throw YggdrasilError.malformed(server) }
        let payload: [String: Any] = [
            "accessToken": accessToken,
            "clientToken": clientToken,
            "requestUser": true
        ]
        let (json, status) = try await post("\(base)/authserver/refresh", payload)
        try interpret(json, status: status)
        return try session(from: json, fallbackClientToken: clientToken)
    }

    /// 校验 accessToken 是否还有效（有效返回 true，无效返回 false）。
    static func validate(server: String, accessToken: String, clientToken: String) async -> Bool {
        guard let base = normalize(server) else { return false }
        let payload: [String: Any] = ["accessToken": accessToken, "clientToken": clientToken]
        guard let (_, status) = try? await post("\(base)/authserver/validate", payload) else { return false }
        return status == 204 || status == 200
    }

    /// 切换角色（同一账号下有多个角色时）。
    static func selectProfile(server: String, accessToken: String, clientToken: String,
                              profile: YggdrasilProfile) async throws -> YggdrasilSession {
        guard let base = normalize(server) else { throw YggdrasilError.malformed(server) }
        let payload: [String: Any] = [
            "accessToken": accessToken,
            "clientToken": clientToken,
            "requestUser": true,
            "selectedProfile": ["id": profile.id, "name": profile.name]
        ]
        let (json, status) = try await post("\(base)/authserver/refresh", payload)
        try interpret(json, status: status)
        return try session(from: json, fallbackClientToken: clientToken)
    }

    private static func session(from json: [String: Any],
                                fallbackClientToken: String) throws -> YggdrasilSession {
        guard let accessToken = json["accessToken"] as? String else {
            throw YggdrasilError.malformed("缺少 accessToken")
        }
        func profile(_ any: Any?) -> YggdrasilProfile? {
            guard let d = any as? [String: Any],
                  let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return YggdrasilProfile(id: id, name: name)
        }
        let selected = profile(json["selectedProfile"])
        let available = (json["availableProfiles"] as? [[String: Any]])?.compactMap {
            profile($0)
        }
        guard selected != nil || (available?.isEmpty == false) else {
            throw YggdrasilError.noProfile
        }
        return YggdrasilSession(accessToken: accessToken,
                                clientToken: (json["clientToken"] as? String) ?? fallbackClientToken,
                                selectedProfile: selected ?? available?.first,
                                availableProfiles: available)
    }
}

// MARK: - authlib-injector

/// 负责把 authlib-injector.jar 拿到本地，并在启动时拼出 -javaagent 参数。
nonisolated enum AuthlibInjector {

    /// 元数据源：BMCLAPI 镜像优先（国内快），官方兜底。
    private static let metadataSources = [
        "https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/latest.json",
        "https://authlib-injector.yushi.moe/artifact/latest.json"
    ]

    private static var cacheDir: URL {
        Paths.appSupport.appendingPathComponent("authlib-injector", isDirectory: true)
    }

    /// 已下载的 jar（没有则返回 nil）。
    static func cachedJar() -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return nil }
        return files.first { $0.pathExtension == "jar" }
    }

    /// 确保有可用的 jar，返回它的路径（会下载一次并缓存）。
    static func ensureJar() async throws -> URL {
        if let jar = cachedJar() { return jar }
        try Paths.ensure(cacheDir)

        var downloadURL: URL?
        var lastError: Error?
        for src in metadataSources {
            guard let metaURL = URL(string: src) else { continue }
            var req = URLRequest(url: metaURL)
            req.timeoutInterval = 12
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let raw = json["download_url"] as? String,
                  let u = URL(string: raw) else {
                lastError = YggdrasilError.server("取不到 authlib-injector 元数据")
                continue
            }
            downloadURL = u
            break
        }
        guard let downloadURL else {
            throw lastError ?? YggdrasilError.server("取不到 authlib-injector 下载地址")
        }

        let dest = cacheDir.appendingPathComponent("authlib-injector.jar")
        try await DownloadManager.downloadCandidates(
            [MirrorCandidate(source: "injector", url: downloadURL)],
            kind: .library, to: dest, sha1: nil, timeout: 20)
        return dest
    }

    /// 拼出 JVM 参数：`-javaagent:<jar>=<服务器地址>`
    /// （格式见 authlib-injector 官方「Launcher Technical Specification」）
    static func javaAgentArgument(jar: URL, server: String) -> String? {
        guard let base = Yggdrasil.normalize(server) else { return nil }
        return "-javaagent:\(jar.path)=\(base)"
    }
}
