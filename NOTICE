# NOTICE

Aether
Copyright (C) 2026 Aether contributors

本程序采用 **GNU Affero General Public License v3.0**（见 [LICENSE](LICENSE)）。

---

## 第三方组件

### Hello Minecraft! Launcher (HMCL)

本项目的部分功能参考了 HMCL 的开源实现。

```
SPDX-FileCopyrightText: Copyright (C) 2021 The HMCL Authors
SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-HMCL
项目主页：https://github.com/HMCL-dev/HMCL
```

**HMCL 的完整许可证**（GPL-3.0 全文 + HMCL 附加条款）见
[LICENSE.hmcl-GPL-3.0](LICENSE.hmcl-GPL-3.0)。

#### 涉及的文件与内容

| 文件 | 关系 | 引用来源 |
|---|---|---|
| `Aether/MicrosoftAuth.swift` | **重新实现** | `HMCLCore/.../auth/microsoft/MicrosoftService.java` |
| `Aether/XboxAuthError.swift` | **重新实现**（错误码常量与判定语义） | `HMCLCore/.../auth/microsoft/MicrosoftService.java` |
| `Aether/CurseForge.swift` | **重新实现**（ForgeCDN 直链格式、文件名补全流程） | `HMCLCore/.../modpack/curse/CurseManifestFile.java`、`CurseCompletionTask.java`、`addon/repository/CurseForgeRemoteAddonRepository.java` |
| `Aether/HMCLLogin.swift` | **进程编排**，不含 HMCL 代码 | 调用 `org.jackhuang.hmcl.auth.OAuth` |
| `Aether/LoginHelper.java` | **进程编排**，不含 HMCL 代码 | 调用 `org.jackhuang.hmcl.auth.OAuth` |

上述 Swift / Java 代码均为**独立重新编写，未逐行翻译**。OAuth 设备码、Xbox Live
认证、ForgeCDN URL 格式等属于公开规范与公开事实，不受版权保护。

#### 关于 HMCL jar 的分发

`HMCLLogin` / `LoginHelper` 在运行时**调用用户本机已有的 HMCL jar**
（`java -cp HMCL.jar LoginHelper.java ...`），**该 jar 不随 Aether 分发**。

这一点是协议上的关键：

- 若把 HMCL jar 打进发行包，整个包就成为 GPL-3.0 衍生作品
  （AGPL-3.0 与 GPL-3.0 兼容，合并后适用 GPL-3.0 的条款）。
- 现在这种「App 不含 HMCL 代码、jar 由用户自行提供」的模式
  （与 Emacs 加载用户自行安装的插件同理）让本项目可以保持 AGPL-3.0。

**若将来要把 HMCL jar 一并分发**，必须：

1. 改用 GPL-3.0 许可并公开全部源码；
2. 附上 HMCL 的完整许可证（GPL-3.0 + 附加条款）与全部版权声明；
3. 按 HMCL 附加条款第 1 条，修改版本号或软件名以示区分。

### HMCL 附加条款原文

```
Additional Terms for Hello Minecraft! Launcher

  1. When you distribute a modified version of the software, you must change
the software name or the version number in a reasonable way in order to
distinguish it from the original version. Under GPLv3, 7(c).

  2. You must not remove the copyright declaration displayed in the software.
Under GPLv3, 7(b).
```

---

## 其他

Minecraft 是 Mojang Studios 的商标与产品。Minecraft、Mod、加载器、
资源文件等版权归各自作者所有。本项目仅提供下载、安装与启动能力，
不包含、不分发、不修改上述任何内容。

本项目未使用任何第三方依赖，仅依赖 macOS 系统框架
（SwiftUI / AppKit / Combine / CryptoKit / Foundation）。
