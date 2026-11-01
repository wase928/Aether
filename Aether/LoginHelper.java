import org.jackhuang.hmcl.auth.OAuth;

import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.Properties;

/**
 * Aether 的登录辅助程序：直接调用 HMCL 的 OAuth 模块（HMCL-*.jar 作为库）。
 *
 * 之所以用 Java 而不是在 Swift 里重写：
 *   - 设备码 / 刷新令牌的客户端 ID 由 HMCL 模块自带，不需要用户自己的 Azure 应用；
 *   - Minecraft 本来就要 Java，多一个短命进程成本可以忽略；
 *   - 行为与 HMCL 完全一致（重试、错误码、scope）。
 *
 * 用法：
 *   java -cp HMCL.jar LoginHelper.java device   [clientId]
 *   java -cp HMCL.jar LoginHelper.java refresh  <refreshToken> [clientId]
 *
 * 输出（每行一个 JSON 对象，便于 Swift 逐行解析）：
 *   {"type":"device_code","user_code":"ABC123","url":"https://..."}
 *   {"type":"token","access_token":"...","refresh_token":"..."}
 *   {"type":"error","message":"..."}
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
                OAuth.Options options = new OAuth.Options(SCOPE, new Callback(cid));
                result = OAuth.MICROSOFT.refresh(refreshToken, options);
            } else {
                OAuth.Options options = new OAuth.Options(SCOPE, new Callback(cid));
                result = OAuth.MICROSOFT.authenticate(OAuth.GrantFlow.DEVICE, options);
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

    /** 从 HMCL jar 自带的 assets/hmcl.properties 里取登录用的客户端 ID。 */
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

    /** JSON 字符串转义。 */
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

    /** HMCL 的 OAuth 回调：设备码流程只需要把 code / url 报出来。 */
    private static final class Callback implements OAuth.Callback {
        private final String clientId;

        Callback(String clientId) {
            this.clientId = clientId;
        }

        @Override
        public OAuth.Session startServer() {
            return null;   // 设备码流程用不到本地回环服务器
        }

        @Override
        public void grantDeviceCode(String userCode, String verificationUri) {
            emit("{\"type\":\"device_code\",\"user_code\":\"" + esc(userCode)
                    + "\",\"url\":\"" + esc(verificationUri) + "\"}");
        }

        @Override
        public void loginCompletedDeviceCode() {
            // 不需要额外动作
        }

        @Override
        public void openBrowser(OAuth.GrantFlow flow, String url) {
            // 由 Swift 端负责打开浏览器
        }

        @Override
        public String getClientId() {
            return clientId;
        }
    }
}
