# Aether v1.0.0

首个公开版本。

**macOS 26+ · Apple Silicon (arm64)**

## 下载

- `Aether-v1.0.0-arm64.dmg` — 推荐，双击挂载后拖进「应用程序」
- `Aether-v1.0.0-arm64.zip` — 备用，解压后拖 `Aether.app` 进「应用程序」

## 首次打开

这个构建没有 Apple 开发者证书签名，Gatekeeper 会拦第一次打开。
**在「访达」里右键点 Aether.app → 打开** 即可（之后正常双击启动）。

命令行方式：

```bash
xattr -d com.apple.quarantine /Applications/Aether.app
```

## 功能

**下载与安装**
- 原版 / Fabric / Forge / NeoForge / Quilt
- Modrinth、CurseForge 的 Mod / 整合包 / 光影浏览与安装
- 本地整合包导入（`.mrpack` 与通用 zip）
- Java 运行时自动探测本机 JDK，缺失时从 Adoptium Temurin 下载

**多源下载**
- 候选源竞速排序，实测速度决定优先级
- 看门狗自动换源：连接停滞、校验失败、超时立刻切下一个
- 源健康度冷却，避免反复撞同一个坏节点

**实例管理**
- Mod 启用 / 禁用 / 删除
- 内存与自定义分辨率
- 版本目录、整合包实例的导入复用

**账号**
- 离线模式 / Microsoft OAuth / Yggdrasil（HMCL、旧正版）导入

**界面**
- macOS 26 原生液态玻璃：侧边栏、卡片、按钮都是系统 `glassEffect`
- 自定义壁纸，玻璃自己去折射它
- 底部常驻任务条：阶段进度 + 实时日志，可展开

## 技术要点

- **零第三方依赖**，只用 AppKit / SwiftUI / Combine / CryptoKit / Foundation
- 13 组命令行自检，覆盖下载源链路、并发计数、启动隔离、进度单调性等
- Forge / NeoForge 1.17+ 的 JPMS 模块冲突按 HMCL 规则处理
  （classpath 顺序、`-DignoreList` 文件名匹配、原版实例绝不隔离客户端 jar）

## 系统要求

- macOS 26 或更高
- Apple Silicon (arm64)

## 许可

[GNU Affero General Public License v3.0](https://github.com/wase928/Aether/blob/main/LICENSE)
· [NOTICE](https://github.com/wase928/Aether/blob/main/NOTICE)

选 AGPL 而不是 MIT，是因为这个启动器会下载并运行第三方内容（游戏本体、Mod、加载器）。
AGPL 第 13 条要求：**通过网络提供功能时，必须向使用者提供对应源码**。
本项目不提供在线服务，但一旦你把它改成 web 端或加上远程接口，这一条就会生效。

### 第三方归属

本项目部分功能参考了 **HMCL**（Hello Minecraft! Launcher）：

```
Copyright (C) 2021 The HMCL Authors
SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-HMCL
```

HMCL 的 jar **不随本程序分发**（需要用户本机已安装 HMCL）。
完整的归属声明与引用来源对照表见
[NOTICE](https://github.com/wase928/Aether/blob/main/NOTICE)。

### 分发时请一并附上

- 本仓库的**完整源码**：https://github.com/wase928/Aether
- [AGPL-3.0 许可证全文](https://github.com/wase928/Aether/blob/main/LICENSE)
- [NOTICE](https://github.com/wase928/Aether/blob/main/NOTICE)
- 保留所有版权声明

Mod、游戏本体及加载器的著作权归各自作者所有，本项目仅提供下载与启动能力。
