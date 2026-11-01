# Aether 用户协议与开源许可声明

**版本 1.0.0 · 适用于 Aether v1.0.0**

本文件包含两部分：使用本软件时需同意的条款（用户协议），
以及本软件所依赖的第三方组件的许可声明（开源许可声明）。

---

# 第一部分 · 用户协议

## 1. 协议��受

本协议是你与 Aether 项目（"本软件"）之间就使用本软件所订立的协议。
下载、安装或使用本软件，即表示你已阅读并同意本协议全部条款。
若你不同意其中任何一条，请立即停止使用并删除本软件。

## 2. 本软件是什么

Aether 是一个 **Minecraft 启动器**，功能是：

- 从官方及镜像源下载 Minecraft 客户端、类库、资源文件
- 安装并启动 Fabric / Forge / NeoForge / Quilt 等加载器
- 从 Modrinth、CurseForge 下载 Mod 与整合包
- 管理本地实例、Mod、内存与分辨率设置
- 通过设备码 OAuth 登录 Minecraft 账号（可选）

**本软件本身不包含任何 Minecraft 游戏内容。**

## 3. 你需要自行拥有的东西

使用本软件下载并启动 Minecraft，你**必须**：

1. **拥有 Minecraft 正版账号**（微软账号或 Mojang 账号）。
   本软件不会、也不能提供账号，也不会绕过正版验证。
2. **自行接受 Minecraft 的最终用户许可协议（EULA）**。
   通过本软件下载并启动游戏，等同于你自行接受 Mojang Studios 的 EULA。
   本软件的作者不是 Mojang Studios 的关联方，不参与游戏内容的授权与分发。

游戏本体、纹理、音效、Mod、加载器等内容的著作权归各自权利人所有。
本软件仅提供下载、安装与启动的技术能力，不主张对这些内容的任何权利。

## 4. 允许的与不允许的

**允许：**

- 个人使用、局域网联机
- 修改本软件并公开你的修改（须遵守下文第 7 条的开源义务）
- 重新分发本软件的完整发行包（须附带本协议与源码）

**不允许：**

- 移除或篡改本协议、NOTICE、源码中的任何版权声明与许可声明
- 将本软件用于任何违法违规的用途
- 声称本软件与 Mojang Studios / Microsoft 有任何关联或认可关系
- 分发任何**绕过正版验证**的补丁、破解或本软件的修改版本

## 5. 无担保

本软件按"现状"提供，**不作任何明示或默示的担保**，包括但不限于：

- 适销性、特定用途适用性、不侵权
- 一定能成功下载、启动或运行任何特定版本的 Minecraft
- 下载的内容一定安全、一定无恶意代码

请自行判断并承担风险。若因使用本软件导致数据丢失、游戏损坏、
账号异常或任何其他损失，作者不承担责任。

## 6. 责任限制

在法律允许的最大范围内，作者不对任何间接、附带、后果性或特殊的损害承担责任，
包括利润损失、数据丢失、业务中断，即便已被告知此类损害的可能性。

## 7. 开源义务

本软件采用 **GNU Affero General Public License v3.0**（AGPL-3.0），
完整条款见 [LICENSE](LICENSE)，第三方归属见 [NOTICE](NOTICE)。

如果你**分发本软件**（无论原样还是修改版）：

1. 必须附上 AGPL-3.0 许可证全文；
2. 必须保留所有版权声明与许可声明；
3. 必须提供**完整对应源码**（https://github.com/wase928/Aether 即可）。

如果你**通过网络向他人提供本软件的功能**（例如改成 web 服务、
提供在线接口），则 AGPL 第 13 条要求你必须向使用者提供对应源码。

修改版本请合理地修改软件名或版本号以示区分（HMCL 附加条款第 1 条）。

## 8. 数据与隐私

- 本软件将游戏数据存放在 `~/Library/Application Support/maccraft/`
- **不会收集、上传或共享你的任何个人信息**
- 账号令牌保存在 macOS 钥匙串（Keychain），不落盘明文
- 唯一的对外请求是：向下载源请求文件、向认证服务器请求令牌
- 本软件**不包含任何遥测、崩溃上报或用户行为分析**

## 9. 协议变更

作者可能修订本协议。修订后的版本随软件的下一个版本发布，
并在本仓库的最新提交中记录。继续使用即视为接受修订后的条款。

## 10. 适用法律

本协议适用中华人民共和国法律（不含冲突法规则）。
如发生争议，双方应友好协商解决；协商不成，提交作者所在地有管辖权的人民法院处理。

---

# 第二部分 · 开源许可声明

本软件的许可声明如下。所有第三方组件均**按其各自许可**独立授权，
本软件作者不对第三方组件作任何担保。

## 编程语言与运行时

**Swift** —— 本软件使用 Swift 编写。

- 授权：Apache License 2.0
- 版权：Apple Inc. and contributors
- 主页：https://swift.org

*Built with Swift (Apache 2.0)*

Swift 的开源运行时与标准库以 Apache 2.0 授权。编译产物中包含的
Swift 运行时部分同样适用该许可。

## 系统框架

本软件调用以下 **Apple 提供的 macOS 内置框架**：

| 框架 | 用途 |
|---|---|
| SwiftUI | 界面框架 |
| AppKit | 窗口、事件、无障碍 |
| Combine | 响应式数据流 |
| CryptoKit | SHA-1 校验 |
| Foundation | 基础库 |

这些是 macOS 操作系统的内置组件，不作为独立第三方组件分发。
它们由 Apple 的 macOS 软件开发许可（Apple Developer Program License Agreement）
及相关条款管辖 —— 只要你面向 macOS 分发软件，就默认受其管辖。

**本软件未捆绑任何非 Apple 的系统级依赖。**

## 运行时依赖（会下载到用户机器上）

### Eclipse Temurin JDK（Java 运行时）

当本机没有满足版本要求的 JDK 时，本软件会自动下载 **Eclipse Temurin JDK**
（下载源：清华 TUNA 镜像 → 官方 `api.adoptium.net`），
并存放到 `~/Library/Application Support/maccraft/runtimes/temurin-<major>/`。

- 授权：**GNU General Public License, version 2 with the Classpath Exception**
  （SPDX：`GPL-2.0-only WITH Classpath-exception-2.0`）
- 版权：Eclipse Adoptium 项目及其贡献者
- 主页：https://adoptium.net · https://github.com/adoptium/temurin17-binaries

> **Classpath Exception 的意义**：Temurin 明确允许闭源程序链接与调用它的类库
> （官方 FAQ 原文：「You may freely use, modify, and share the code as described in
> the licenses included in the download」）。本软件运行 Temurin 只是**把它当作外部
> 进程启动**（`java -cp ...`），既不链接也不修改它的类库 ——
> 两种用法都不受 Temurin 许可传染。
> Temurin 是**下载到用户机器上**的，不是随本软件分发的。

### HMCL（Hello Minecraft! Launcher）

微软 / Xbox Live 登录功能需要调用 HMCL 的 OAuth 模块，
**该 jar 由用户本机提供，本软件不分发它**：

- 授权：**GPL-3.0-or-later WITH AdditionRef-HMCL**
- 版权：Copyright (C) 2021 The HMCL Authors
- 主页：https://github.com/HMCL-dev/HMCL
- 完整许可证：[LICENSE.hmcl-GPL-3.0](LICENSE.hmcl-GPL-3.0)

本软件**没有复制 HMCL 的代码**，只做了进程编排。
具体的引用来源对照表见 [NOTICE](NOTICE)。

> 若将来要把 HMCL jar 随本软件一并分发，整个发行包将成为 GPL-3.0 衍生作品
> （AGPL-3.0 与 GPL-3.0 兼容，合并后适用 GPL-3.0 的条款），
> 且必须公开全部源码并保留 HMCL 的版权声明。

## 下载的内容（运行时获取，不随软件分发）

本软件会从以下来源下载内容。这些内容**各有自己的许可**，
本软件不分发它们，仅提供下载与安装能力：

| 内容 | 来源 | 权利归属 |
|---|---|---|
| Minecraft 客户端 / 类库 / 资源 | `launchermeta.mojang.com`、`piston-data.mojang.com`、`resources.download.minecraft.net` | Mojang Studios / Microsoft |
| Java 类库（Maven 构件） | 阿里云、腾讯云、BMCLAPI、官方 | 各项目作者 |
| Mod / 整合包（Modrinth） | `api.modrinth.com`、`cdn.modrinth.com` | 各 Mod 作者 |
| Mod / 整合包（CurseForge） | `api.curseforge.com`（或免 key 代理 `mod.mcimirror.top`） | 各 Mod 作者 |
| 加载器（Fabric / Forge / NeoForge / Quilt） | 各自官方与镜像 | 各项目作者 |

镜像源（阿里云、腾讯云、BMCLAPI、清华 TUNA）只做**转发**，
不修改内容，也不改变其原始许可。

**这些内容不由本软件的作者分发或授权。** 请自行遵守各项原始许可与 EULA。

## 无第三方依赖声明

除上述**运行时下载**的内容外，本软件的**编译产物不包含任何第三方库**。
所有依赖均为 Apple 系统框架（随 macOS 提供），无 SPM / CocoaPods / Carthage 依赖。

---

**本协议与 Aether 一同分发。若你只拿到了部分文件，请访问
https://github.com/wase928/Aether 获取完整版本。**
