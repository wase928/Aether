//
//  HMCLLogin.swift
//  maccraft
//
//  SPDX-FileCopyrightText: Copyright (C) 2026 Aether contributors
//  SPDX-License-Identifier: AGPL-3.0-or-later
//
//  借用 HMCL 的 Java 登录模块（HMCL-*.jar 作为库）在后台跑设备码登录 / 刷新令牌。
//
//  为什么这么做：
//    1. 设备码与刷新都要一个 OAuth 客户端 ID。用户自己注册 Azure 应用现在要绑卡，
//       而 HMCL 的模块自带这个 ID，直接复用就不需要用户做任何注册。
//    2. Minecraft 本来就要 Java 运行时，多一个短命进程（128MB 堆、几秒）成本可忽略。
//    3. 行为与 HMCL 完全一致（重试策略、错误码、scope），不用我们再对一遍协议。
//
//  ── 来源说明 ───────────────────────────────────────────────────────────
//  实际调用的是 HMCL 的 org.jackhuang.hmcl.auth.OAuth
//  （GPL-3.0-or-later WITH AdditionRef-HMCL）：
//      HMCLCore/src/main/java/org/jackhuang/hmcl/auth/OAuth.java
//      Copyright (C) 2021 The HMCL Authors
//      https://github.com/HMCL-dev/HMCL
//  本文件只写了「进程编排 + JSON 解析」，不含 HMCL 的代码；
//  运行所需的 HMCL jar 由用户本机提供，不随 App 分发。
//
//  为什么「不分发」是关键：HMCL 是 GPL-3.0 程序，把它的 jar 打进发行包，
//  整个包就变成 GPL-3.0 衍生作品（AGPL 兼容 GPLv3，合并后适用 GPLv3 的条款）。
//  现在这个模式（App 不含 HMCL 代码，jar 由用户自行提供）让本项目可以
//  保持 AGPL-3.0 而不产生协议冲突 —— 跟 Emacs 加载用户自行安装的插件是同一个道理。
//
//  如果将来要把 HMCL jar 一并分发，必须改用 GPL-3.0 并公开全部源码，
//  且要把 HMCL 的版权声明与许可证原文一并附上。
//  完整的第三方归属声明见仓库根目录的 NOTICE。
//  ──────────────────────────────────────────────────────────────────────
//

import Foundation

nonisolated enum HMCLLogin {

    struct DeviceCode: Sendable {
        let userCode: String
        let url: String
    }

    struct Credentials: Sendable {
        let accessToken: String
        let refreshToken: String
    }

    // MARK: - 定位依赖

    /// 找用户本机的 HMCL jar。优先设置里指定的，其次扫描常见目录取最新。
    static func findJar() throws -> URL {
        let fm = FileManager.default

        let custom = SettingsKeys.hmclJarPathValue
        if !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if fm.fileExists(atPath: url.path) { return url }
        }

        let home = NSHomeDirectory()
        let dirs = ["Documents", "Downloads", "Desktop", "Applications"]
        var found: [(url: URL, date: Date)] = []
        for d in dirs {
            let dir = URL(fileURLWithPath: home).appendingPathComponent(d)
            guard let files = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for f in files where f.pathExtension.lowercased() == "jar"
                && f.lastPathComponent.lowercased().hasPrefix("hmcl") {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                found.append((f, date))
            }
        }
        guard let newest = found.max(by: { $0.date < $1.date })?.url else {
            throw AuthError.message("没找到 HMCL 的 jar。请把 HMCL-x.x.x.jar 放到「下载」或「文档」里，或在设置里指定路径。")
        }
        return newest
    }

    /// 找一个能跑 HMCL 的 Java（HMCL 3.16 用 Java 21 编译，需要 21+）。
    static func javaRuntime() async throws -> URL {
        for major in [25, 21] {
            if let j = JavaManager.detectLocalJava(major: major) { return j }
        }
        for j in JavaManager.listLocalJVMs() {
            if let v = JavaManager.majorVersion(of: j), v >= 21 { return j }
        }
        // 本机没有就下 21（走 TUNA 镜像，几秒）
        return try await JavaManager.javaExecutable(major: 21) { _, _ in }
    }

    /// 把内置的 Java 壳写到 App Support（源码直跑，不需要 javac）。
    static func helperSource() throws -> URL {
        let dir = Paths.appSupport.appendingPathComponent("hmcl-helper", isDirectory: true)
        try Paths.ensure(dir)
        let file = dir.appendingPathComponent("LoginHelper.java")
        let content = helperJavaSource
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing == content {
            return file
        }
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - 进程登记

    /// 当前正在跑的登录进程。登录是短命任务（拿到 token 就 System.exit），
    /// 但用户可能中途取消、或者干脆不管——所以这里留一个句柄，随时能掐掉，
    /// 避免留下一个占着 128MB 堆的 JVM 在后台等 900 秒超时。
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var proc: Process?

        func set(_ p: Process?) {
            lock.lock(); proc = p; lock.unlock()
        }

        func isCurrent(_ p: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return proc === p
        }

        func clear() {
            lock.lock(); proc = nil; lock.unlock()
        }

        func currentRunning() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return proc?.isRunning ?? false
        }

        /// 终止当前进程（若有）。用于用户取消登录 / 退出 App。
        func terminateIfRunning() {
            lock.lock()
            let p = proc
            proc = nil
            lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }

    /// DispatchWorkItem 不是 Sendable，不能直接塞进 @Sendable 的 terminationHandler；
    /// 用这个薄壳包一层，只暴露 cancel()。
    private final class Canceller: @unchecked Sendable {
        private let lock = NSLock()
        private var item: DispatchWorkItem?
        func set(_ i: DispatchWorkItem) {
            lock.lock()
            let already = item?.isCancelled ?? false
            item = i
            lock.unlock()
            if already { i.cancel() }
        }
        func cancel() {
            lock.lock(); let i = item; lock.unlock()
            i?.cancel()
        }
    }

    private static let box = ProcessBox()

    /// 是否还有登录进程在跑（UI 可用来显示状态）。
    static var isRunning: Bool { box.currentRunning() }

    /// 主动结束登录进程。用户点「取消」或退出 App 时调用。
    static func terminateCurrent() {
        box.terminateIfRunning()
    }

    // MARK: - 常驻心跳

    /// 心跳进程单独占一个槽，避免和「登录 / 刷新」这类一次性命令互相踩。
    private static let daemonBox = ProcessBox()

    static var heartbeatRunning: Bool { daemonBox.currentRunning() }

    /// 停止常驻心跳（退出登录 / App 关闭时调用）。
    static func stopHeartbeat() {
        daemonBox.terminateIfRunning()
    }

    /// 启动常驻心跳：Java 侧每隔 interval 秒用 refresh_token 换一套新令牌，
    /// 一直跑直到被 stopHeartbeat() 结束或 App 退出。
    ///
    /// 这样账号不会因为 24 小时而过期，用户也不用隔天重新登录。
    /// - Parameter interval: 心跳周期，默认 30 分钟（refresh_token 有效期通常 90 天，这个频率很安全）。
    @discardableResult
    static func startHeartbeat(refreshToken: String,
                               interval: TimeInterval = 1800,
                               onToken: @escaping @Sendable (Credentials) -> Void,
                               onFailure: @escaping @Sendable (String) -> Void) -> Task<Void, Never> {
        stopHeartbeat()
        let rt = refreshToken
        return Task {
            do {
                for try await line in stream(["daemon", rt, "\(Int(interval))"],
                                             timeout: 0, slot: daemonBox) {
                    guard let json = parse(line), let type = json["type"] as? String else { continue }
                    switch type {
                    case "token":
                        if let at = json["access_token"] as? String, !at.isEmpty {
                            onToken(Credentials(accessToken: at,
                                                refreshToken: (json["refresh_token"] as? String) ?? rt))
                        }
                    case "heartbeat_error":
                        onFailure((json["message"] as? String) ?? "心跳失败")
                    case "error":
                        onFailure((json["message"] as? String) ?? "心跳启动失败")
                    default:
                        break
                    }
                }
            } catch {
                onFailure(error.localizedDescription)
            }
        }
    }

    // MARK: - 运行

    /// 启动 Java 壳，把它的每一行 JSON 输出交出去。
    /// - Parameter timeout: 兜底超时（秒）。到点强制结束进程，防止无限等待。
    private static func stream(_ args: [String],
                               timeout: TimeInterval,
                               slot: ProcessBox = box) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let jar = try findJar()
                    let java = try await javaRuntime()
                    let helper = try helperSource()

                    let proc = Process()
                    proc.executableURL = java
                    // 源码直跑：-cp 带上 HMCL jar，最后跟 .java 文件和参数
                    proc.arguments = ["-Xmx128m", "-XX:TieredStopAtLevel=1",
                                      "-cp", jar.path, helper.path] + args

                    let pipe = Pipe()
                    proc.standardOutput = pipe
                    proc.standardError = pipe

                    let pump = LinePump { lines in
                        for l in lines where !l.trimmingCharacters(in: .whitespaces).isEmpty {
                            continuation.yield(l)
                        }
                    }
                    pipe.fileHandleForReading.readabilityHandler = { h in
                        let data = h.availableData
                        if data.isEmpty {
                            h.readabilityHandler = nil
                            pump.flushRemainder()
                            return
                        }
                        pump.feed(data)
                    }
                    // 兜底超时：到点还没结果就掐掉，避免 JVM 长时间空转。
                    // 用 DispatchWorkItem 而不是 Task，是因为要能在 terminationHandler 里提前 cancel。
                    let timer = DispatchWorkItem {
                        guard proc.isRunning else { return }
                        proc.terminate()
                        continuation.finish(throwing: AuthError.message(
                            "等待登录超时（\(Int(timeout / 60)) 分钟），已结束登录进程。请重试。"))
                    }
                    let canceller = Canceller()
                    canceller.set(timer)

                    proc.terminationHandler = { p in
                        pump.flushRemainder()
                        canceller.cancel()
                        if slot.isCurrent(p) { slot.clear() }
                        if p.terminationStatus == 0 {
                            continuation.finish()
                        } else {
                            // 具体错误一般已经在 stdout 里以 {"type":"error"} 报过，
                            // 这里只在完全没输出时给个兜底。
                            continuation.finish(throwing: AuthError.message(
                                "HMCL 登录进程退出（状态码 \(p.terminationStatus)）"))
                        }
                    }
                    // 调用方提前结束（用户取消 / 视图销毁）时，把 Java 进程一起收掉
                    continuation.onTermination = { _ in
                        canceller.cancel()
                        if proc.isRunning { proc.terminate() }
                        if slot.isCurrent(proc) { slot.clear() }
                    }

                    try proc.run()
                    slot.set(proc)
                    if timeout > 0 {
                        DispatchQueue.global(qos: .utility)
                            .asyncAfter(deadline: .now() + timeout, execute: timer)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func parse(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        var out = json
        out["type"] = type
        return out
    }

    /// 设备码登录。拿到码后立刻回调（UI 显示 + 打开浏览器），然后阻塞到用户授权完成。
    /// 方法返回时（无论成功、失败还是抛错）Java 进程都已经不在了。
    static func authenticate(onDeviceCode: @escaping @Sendable (DeviceCode) -> Void) async throws -> Credentials {
        terminateCurrent()   // 清掉可能残留的上一次进程
        var result: Credentials?
        var serverError: String?
        do {
            for try await line in stream(["device"], timeout: 600) {
                guard let json = parse(line), let type = json["type"] as? String else { continue }
                switch type {
                case "device_code":
                    let code = (json["user_code"] as? String) ?? ""
                    let url = (json["url"] as? String) ?? "https://www.microsoft.com/link"
                    onDeviceCode(DeviceCode(userCode: code, url: url))
                case "token":
                    if let at = json["access_token"] as? String, !at.isEmpty {
                        result = Credentials(accessToken: at,
                                             refreshToken: (json["refresh_token"] as? String) ?? "")
                    }
                case "error":
                    serverError = (json["message"] as? String) ?? "登录失败"
                default:
                    break
                }
            }
        } catch {
            // 进程非 0 退出时，如果已经拿到明确的 message 就用它
            if let serverError { throw AuthError.message(friendly(serverError)) }
            throw error
        }
        if let serverError { throw AuthError.message(friendly(serverError)) }
        guard let result else { throw AuthError.message("没有拿到登录凭据") }
        return result
    }

    /// 用 refresh_token 续期（不需要用户再操作）。
    static func refresh(_ refreshToken: String) async throws -> Credentials {
        guard !refreshToken.isEmpty else { throw AuthError.message("没有 refresh token") }
        terminateCurrent()
        var result: Credentials?
        var serverError: String?
        do {
            for try await line in stream(["refresh", refreshToken], timeout: 45) {
                guard let json = parse(line), let type = json["type"] as? String else { continue }
                switch type {
                case "token":
                    if let at = json["access_token"] as? String, !at.isEmpty {
                        result = Credentials(accessToken: at,
                                             refreshToken: (json["refresh_token"] as? String) ?? refreshToken)
                    }
                case "error":
                    serverError = (json["message"] as? String) ?? "刷新失败"
                default:
                    break
                }
            }
        } catch {
            if let serverError { throw AuthError.message(friendly(serverError)) }
            throw error
        }
        if let serverError { throw AuthError.message(friendly(serverError)) }
        guard let result else { throw AuthError.message("刷新没有返回凭据") }
        return result
    }

    /// HMCL 抛的异常类名翻译成能看懂的提示。
    private static func friendly(_ raw: String) -> String {
        let m = raw.lowercased()
        if m.contains("credentialexpired") || m.contains("invalid_grant") {
            return "登录已过期，需要重新登录一次。"
        }
        if m.contains("noseselectedcharacter") || m.contains("no selected") {
            return "授权超时或被取消，请重试。"
        }
        if m.contains("serverdisconnect") || m.contains("unknownhost") {
            return "连不上微软登录服务器，请检查网络或代理。"
        }
        if m.contains("serverresponsemalformed") {
            return "微软返回了异常响应，稍后重试。"
        }
        return raw
    }

    // MARK: - 内置 Java 壳
    //
    // 与仓库里的 LoginHelper.java 保持一致（那一份用于阅读与单独调试）。
    // 这里内嵌一份，避免往 App bundle 里加资源。

    private static let helperJavaSource = #"""
import org.jackhuang.hmcl.auth.OAuth;

import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.Properties;

/**
 * Aether 的登录辅助程序：直接调用 HMCL 的 OAuth 模块（HMCL-*.jar 作为库）。
 * 由 Aether 的 HMCLLogin.swift 生成并调用，请勿单独修改。
 *
 * 输出（每行一个 JSON）：device_code / token / error
 */
public class LoginHelper {

    private static final String SCOPE = "XboxLive.signin offline_access";
    private static PrintStream out;

    public static void main(String[] args) {
        out = new PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.out), true, StandardCharsets.UTF_8);

        String command = args.length > 0 ? args[0] : "device";
        String clientId = null;
        String refreshToken = null;

        // daemon <refreshToken> [intervalSeconds] [clientId]
        if ("daemon".equals(command)) {
            if (args.length < 2 || args[1].isEmpty()) {
                emit("{\"type\":\"error\",\"message\":\"daemon 模式需要 refresh_token\"}");
                System.exit(2);
            }
            String rt = args[1];
            int interval = args.length > 2 ? Integer.parseInt(args[2]) : 1800;
            String cid = args.length > 3 ? args[3] : readClientIdFromJar();
            if (cid == null || cid.isEmpty()) {
                emit("{\"type\":\"error\",\"message\":\"找不到客户端 ID\"}");
                System.exit(2);
            }
            runDaemon(rt, interval, cid);
            return;
        }

        if ("refresh".equals(command) && args.length > 1) {
            refreshToken = args[1];
            if (args.length > 2) clientId = args[2];
        } else if (args.length > 1) {
            clientId = args[1];
        }

        if (clientId == null || clientId.isEmpty()) {
            clientId = readClientIdFromJar();
        }
        if (clientId == null || clientId.isEmpty()) {
            emit("{\"type\":\"error\",\"message\":\"找不到客户端 ID（HMCL jar 里的 hmcl.microsoft.auth.id 读不到）\"}");
            System.exit(2);
        }

        final String cid = clientId;
        try {
            OAuth.Result result;
            if ("refresh".equals(command)) {
                result = OAuth.MICROSOFT.refresh(refreshToken, new OAuth.Options(SCOPE, new Callback(cid)));
            } else {
                result = OAuth.MICROSOFT.authenticate(OAuth.GrantFlow.DEVICE, new OAuth.Options(SCOPE, new Callback(cid)));
            }
            emit("{\"type\":\"token\",\"access_token\":\"" + esc(result.accessToken())
                    + "\",\"refresh_token\":\"" + esc(result.refreshToken()) + "\"}");
            System.exit(0);
        } catch (Throwable t) {
            String msg = t.getMessage();
            if (msg == null || msg.isEmpty()) msg = t.getClass().getSimpleName();
            emit("{\"type\":\"error\",\"message\":\"" + esc(msg) + "\"}");
            System.exit(1);
        }
    }

    /**
     * 常驻心跳：定期用 refresh_token 换新令牌，直到进程被结束。
     * 由 Aether 在登录成功后拉起，App 退出时终止，保证账号不会因为 24 小时过期掉线。
     *
     * 输出（每小时几次，不是高频刷屏）：
     *   {"type":"token", "access_token":..., "refresh_token":..., "heartbeat":true, "at":<epoch>}
     *   {"type":"heartbeat_error", "message":..., "fails":n}
     */
    private static void runDaemon(String refreshToken, int intervalSeconds, String clientId) {
        // 父进程（Aether）退出时自己也退出，避免成为孤儿进程一直挂在后台
        try {
            ProcessHandle.current().parent().ifPresent(parent ->
                    parent.onExit().thenRun(() -> {
                        out.flush();
                        System.exit(0);
                    }));
        } catch (Throwable ignored) {
        }

        String rt = refreshToken;
        int fails = 0;
        while (true) {
            try {
                OAuth.Result r = OAuth.MICROSOFT.refresh(rt, new OAuth.Options(SCOPE, new Callback(clientId)));
                rt = r.refreshToken();
                fails = 0;
                emit("{\"type\":\"token\",\"access_token\":\"" + esc(r.accessToken())
                        + "\",\"refresh_token\":\"" + esc(r.refreshToken())
                        + "\",\"heartbeat\":true,\"at\":" + (System.currentTimeMillis() / 1000) + "}");
            } catch (Throwable t) {
                fails++;
                String msg = t.getMessage();
                if (msg == null || msg.isEmpty()) msg = t.getClass().getSimpleName();
                emit("{\"type\":\"heartbeat_error\",\"message\":\"" + esc(msg)
                        + "\",\"fails\":" + fails + "}");
                // 连续失败说明 refresh_token 已经废了（被撤销 / 改密码），没必再熬
                if (fails >= 5) System.exit(3);
            }
            try {
                Thread.sleep(Math.max(intervalSeconds, 30) * 1000L);
            } catch (InterruptedException e) {
                System.exit(0);
            }
        }
    }

    private static String readClientIdFromJar() {
        try (InputStream in = LoginHelper.class.getClassLoader()
                .getResourceAsStream("assets/hmcl.properties")) {
            if (in == null) return null;
            Properties props = new Properties();
            props.load(in);
            String v = props.getProperty("hmcl.microsoft.auth.id");
            return v == null ? null : v.trim();
        } catch (Exception e) {
            return null;
        }
    }

    private static void emit(String line) {
        out.println(line);
        out.flush();
    }

    private static String esc(String s) {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder(s.length() + 16);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        return sb.toString();
    }

    private static final class Callback implements OAuth.Callback {
        private final String clientId;

        Callback(String clientId) { this.clientId = clientId; }

        @Override public OAuth.Session startServer() { return null; }

        @Override public void grantDeviceCode(String userCode, String verificationUri) {
            emit("{\"type\":\"device_code\",\"user_code\":\"" + esc(userCode)
                    + "\",\"url\":\"" + esc(verificationUri) + "\"}");
        }

        @Override public void loginCompletedDeviceCode() { }

        @Override public void openBrowser(OAuth.GrantFlow flow, String url) { }

        @Override public String getClientId() { return clientId; }
    }
}
"""#
}
