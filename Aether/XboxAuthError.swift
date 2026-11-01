//
//  XboxAuthError.swift
//  maccraft
//
//  SPDX-FileCopyrightText: Copyright (C) 2026 Aether contributors
//  SPDX-License-Identifier: AGPL-3.0-or-later
//
//  Xbox Live 授权失败时的 XErr 错误码。
//
//  ── 来源说明 ───────────────────────────────────────────────────────────
//  错误码常量与判定语义来自 HMCL 的开源实现
//  （GPL-3.0-or-later WITH AdditionRef-HMCL）：
//      HMCLCore/src/main/java/org/jackhuang/hmcl/auth/microsoft/MicrosoftService.java
//      （内部类 XboxAuthorizationException）
//      Copyright (C) 2021 The HMCL Authors
//      https://github.com/HMCL-dev/HMCL
//  这些数字是 Xbox Live 服务返回的公开协议字段，属于事实性信息；
//  Swift 实现为重新编写。
//  完整的第三方归属声明见仓库根目录的 NOTICE。
//  ──────────────────────────────────────────────────────────────────────
//

import Foundation

nonisolated enum XboxAuthError: LocalizedError {
    /// 账号被封禁
    case banned
    /// 这个微软账号还没有 Xbox 档案
    case missingXboxAccount
    /// 所在国家 / 地区不支持 Xbox Live
    case countryUnavailable
    /// 未成年账号未加入家庭组
    case addFamily
    /// 其他未知错误码
    case other(code: Int64, redirect: String?)

    // HMCL 里定义的常量
    static let bannedCode: Int64 = 2_148_916_227
    static let missingXboxAccountCode: Int64 = 2_148_916_233
    static let countryUnavailableCode: Int64 = 2_148_916_235
    static let addFamilyCode: Int64 = 2_148_916_238

    static func from(xerr code: Int64, redirect: String?) -> XboxAuthError {
        switch code {
        case bannedCode:               return .banned
        case missingXboxAccountCode:   return .missingXboxAccount
        case countryUnavailableCode:   return .countryUnavailable
        case addFamilyCode:            return .addFamily
        default:                       return .other(code: code, redirect: redirect)
        }
    }

    var errorDescription: String? {
        switch self {
        case .banned:
            return "这个 Xbox 账号已被封禁，无法登录 Minecraft。"
        case .missingXboxAccount:
            return "这个微软账号还没有 Xbox 档案。请先打开 xbox.com 用同一账号登录一次，创建档案后重试。"
        case .countryUnavailable:
            return "Xbox Live 在你所在的国家 / 地区不可用，因此无法登录 Minecraft。"
        case .addFamily:
            return "这是未成年账号，需要家长先把它加入 Microsoft 家庭组才能使用 Xbox Live。"
        case .other(let code, let redirect):
            if let redirect, !redirect.isEmpty {
                return "Xbox 授权失败（XErr \(code)）。\n按提示前往：\(redirect)"
            }
            return "Xbox 授权失败（XErr \(code)）。"
        }
    }

    /// 需要用户去网页处理时给出的链接。
    var helpURL: String? {
        switch self {
        case .missingXboxAccount: return "https://www.xbox.com/play"
        case .addFamily:          return "https://account.microsoft.com/family/"
        case .countryUnavailable: return nil
        case .banned:             return "https://support.xbox.com/help/family-online-safety/enforcement/xbox-live-ban-info"
        case .other(_, let redirect): return redirect
        }
    }
}
