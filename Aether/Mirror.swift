//
//  Mirror.swift
//  maccraft
//
//  SPDX-FileCopyrightText: Copyright (C) 2026 Aether contributors
//  SPDX-License-Identifier: AGPL-3.0-or-later
//
//  多镜像候选引擎。
//
//  设计依据（均已反编译 / 实测验证）：
//  · HMCL 3.16.4：每个 URL 是「候选列表」而非单地址（injectURLWithCandidates），
//    默认（自动）源在国内的候选顺序是 [BMCLAPI, 官方]；BMCLAPIDownloadProvider 的替换表见下。
//    HMCL: Copyright (C) 2021 The HMCL Authors
//    (GPL-3.0-or-later WITH AdditionRef-HMCL) ——
//    这里只参考了「多候选 + 替换表」的**设计思路**，
//    具体实现与实测数据均为本项目独立完成。
//  · PCL2：每个文件同样携带多源（NetTask.Sources），单个源失败累计 FailCount 后整源禁用，
//    libraries 同时提供 /maven 与 /libraries 两条镜像路径，Forge/Fabric/NeoForge 库源不保留官方。
//  · 本机实测（2026-10-31，直连，Range 2MB）：
//      阿里云 maven-public   5.4 MB/s   ← 类库最快
//      腾讯云 maven-public   4.9 MB/s
//      官方 libraries        1.6 MB/s
//      BMCLAPI /libraries    0.66 MB/s  （302 到 bmclapi22.sakura.sld.tw）
//      BMCLAPI /maven        0.06 MB/s  （302 到 bmclapi20.sakura.sld.tw，8 秒才回首字节）
//      BMCLAPI /assets       直接握手超时 20s
//      官方 resources CDN    9.0 MB/s
//      BMCLAPI 客户端 jar    302 回官方 piston-data 本身
//    结论：BMCLAPI 的 sakura 节点当前大面积劣化，不能当唯一镜像；
//    类库优先走阿里/腾讯云（覆盖 16/18 抽样，缺失的再用 BMCLAPI / 官方兜底）。
//

import Foundation

/// 用户的下载源偏好。
nonisolated enum DownloadSource: String, CaseIterable, Identifiable, Sendable {
    /// 镜像优先 + 实测测速排序（默认，最省心也最快）。
    case auto
    /// 镜像优先，但不做测速（按固定顺序，省流量）。
    case mirror
    /// 仅官方。
    case official

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:     return "自动（实测最快）"
        case .mirror:   return "镜像优先"
        case .official: return "仅官方"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "先镜像、再官方；下载前对每个源做一次小段测速，按实测速度排序，慢源自动降级。"
        case .mirror:
            return "固定按「阿里云 → 腾讯云 → BMCLAPI → 官方」的顺序尝试，不做测速（省流量）。"
        case .official:
            return "只用 Mojang 官方源。国内可能较慢，但数据最权威。"
        }
    }
}

/// 资源类别：决定候选源清单与测速策略。
nonisolated enum ResourceKind: String, Sendable {
    case manifest       // version_manifest(_v2).json
    case versionJSON    // piston-meta 版本 JSON / fabric meta 等
    case assetIndex     // 资源索引 JSON
    case clientJar      // piston-data 的 client.jar
    case library        // libraries.minecraft.net / maven 仓库构件
    case assetObject    // resources.download.minecraft.net 对象
    case other
}

/// 一个候选下载地址（带上它来自哪个源，便于健康度统计与日志）。
nonisolated struct MirrorCandidate: Sendable, Equatable {
    let source: String
    let url: URL

    var host: String { url.host ?? source }
}

/// 镜像替换表 + 候选生成。
nonisolated enum Mirror {
    // MARK: - 镜像根

    static let bmclapiRoot     = "https://bmclapi2.bangbang93.com"
    static let aliyunMavenRoot = "https://maven.aliyun.com/repository/public"
    static let tencentMavenRoot = "https://mirrors.cloud.tencent.com/nexus/repository/maven-public"

    /// 从 maven 根地址推断源标识（用于预置下载的日志/健康度）。
    static func host(for root: String) -> String {
        if root.contains("bangbang93") { return "bmclapi" }
        if root.contains("neoforged")  { return "neoforged" }
        if root.contains("forge")      { return "forge-maven" }
        if root.contains("fabricmc")   { return "fabric-maven" }
        return "maven"
    }

    /// 源的展示名（日志 / 设置页）。
    static func label(_ source: String) -> String {
        switch source {
        case "aliyun":         return "阿里云镜像"
        case "tencent":        return "腾讯云镜像"
        case "bmclapi":        return "BMCLAPI"
        case "bmclapi-maven":  return "BMCLAPI(maven)"
        case "official":       return "官方"
        default:               return source
        }
    }

    // MARK: - 替换规则

    /// 只存在于 Mojang 私有仓库（libraries.minecraft.net）的 group。
    /// 这些构件从来没同步到 Maven Central，公共镜像（阿里云 / 腾讯云）必然 404。
    /// 实测 26.3 的 114 个类库里有 12 个属于这些 group（authlib / brigadier /
    /// datafixerupper / jtracy 全套 natives / logging / patchy / text2speech / blocklist），
    /// 以前每个都要先撞两次 404 才换源，日志里那一屏「HTTP 404」就是它。
    private static let mojangOnlyGroups = [
        "com/mojang/", "net/minecraft/", "cpw/mods/", "optifine/", "de/oceanlabs/mcp/"
    ]

    /// Forge / NeoForge 自己的 group —— 公共云 maven 没有，但 **BMCLAPI 有**。
    ///
    /// 实测（2026-11-01，Range 500KB）：
    /// ```
    /// maven.minecraftforge.net   9075ms  55 KB/s   ← 官方源，慢到离谱
    /// bmclapi2 /maven             916ms 554 KB/s   ← 快 10 倍
    /// bmclapi2 /libraries          954ms 532 KB/s
    /// ```
    /// 之前把 `net/minecraftforge/` 也算进 mojangOnlyGroups，
    /// 于是候选顺序是「官方 → BMCLAPI」—— 每个 Forge 库都先在官方源上磨 9 秒，
    /// 58 个预置依赖光首字节就得等好几分钟。
    /// 正确做法：Forge/NeoForge 构件**优先 BMCLAPI**，官方源放最后兜底。
    private static let forgeGroups = [
        "net/minecraftforge/", "net/neoforged/"
    ]

    private static func isMojangOnly(_ path: String) -> Bool {
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return mojangOnlyGroups.contains { p.hasPrefix($0) }
    }

    /// Forge / NeoForge 自己的构件（BMCLAPI 覆盖，官方源很慢）。
    private static func isForgeOwned(_ path: String) -> Bool {
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return forgeGroups.contains { p.hasPrefix($0) }
    }

    /// 官方 URL -> 指定源的 URL；该源不支持这类资源时返回 nil。
    static func rewrite(_ raw: String, by source: String) -> String? {
        // 先归一化 http 前缀（老版本 JSON 里是 http）。
        let s = raw
            .replacingOccurrences(of: "http://resources.download.minecraft.net",
                                  with: "https://resources.download.minecraft.net")
            .replacingOccurrences(of: "http://files.minecraftforge.net",
                                  with: "https://files.minecraftforge.net")

        switch source {
        case "official":
            return raw

        // ---- 阿里云 / 腾讯云：只镜像 maven 构件（实测 5 MB/s，MC 类库覆盖 89%）----
        case "aliyun", "tencent":
            let root = source == "aliyun" ? aliyunMavenRoot : tencentMavenRoot
            if s.hasPrefix("https://libraries.minecraft.net/") {
                let path = String(s.dropFirst("https://libraries.minecraft.net/".count))
                if isMojangOnly(path) { return nil }   // 公共镜像没有，别白撞 404
                return root + "/" + path
            }
            if s.hasPrefix("https://repo1.maven.org/maven2/") {
                return root + s.dropFirst("https://repo1.maven.org/maven2".count)
            }
            if s.hasPrefix("https://repo.maven.apache.org/maven2/") {
                return root + s.dropFirst("https://repo.maven.apache.org/maven2".count)
            }
            return nil

        // ---- BMCLAPI：/libraries 与 /maven 两条路径都试（PCL2 同款策略）----
        case "bmclapi", "bmclapi-maven":
            let libSuffix = source == "bmclapi" ? "/libraries" : "/maven"
            if s.hasPrefix("https://libraries.minecraft.net/") {
                return bmclapiRoot + libSuffix + s.dropFirst("https://libraries.minecraft.net".count)
            }
            if s.hasPrefix("https://resources.download.minecraft.net/") {
                return bmclapiRoot + "/assets" + s.dropFirst("https://resources.download.minecraft.net".count)
            }
            if s.hasPrefix("https://files.minecraftforge.net/maven") {
                return bmclapiRoot + "/maven" + s.dropFirst("https://files.minecraftforge.net/maven".count)
            }
            if s.hasPrefix("https://maven.minecraftforge.net") {
                return bmclapiRoot + "/maven" + s.dropFirst("https://maven.minecraftforge.net".count)
            }
            if s.hasPrefix("https://maven.neoforged.net/releases") {
                return bmclapiRoot + "/maven" + s.dropFirst("https://maven.neoforged.net/releases".count)
            }
            if s.hasPrefix("https://maven.fabricmc.net") {
                return bmclapiRoot + "/maven" + s.dropFirst("https://maven.fabricmc.net".count)
            }
            if s.hasPrefix("https://meta.fabricmc.net") {
                return bmclapiRoot + "/fabric-meta" + s.dropFirst("https://meta.fabricmc.net".count)
            }
            if s.hasPrefix("https://authlib-injector.yushi.moe") {
                return bmclapiRoot + "/mirrors/authlib-injector"
                    + s.dropFirst("https://authlib-injector.yushi.moe".count)
            }
            if s.hasPrefix("https://repo1.maven.org/maven2") || s.hasPrefix("https://repo.maven.apache.org/maven2") {
                return nil
            }
            // launchermeta / piston-meta / piston-data / launcher.mojang：host 替换、路径保留
            for host in ["https://launchermeta.mojang.com",
                         "https://piston-meta.mojang.com",
                         "https://piston-data.mojang.com",
                         "https://launcher.mojang.com",
                         "https://launchercontent.mojang.com"] {
                if s.hasPrefix(host) {
                    return bmclapiRoot + s.dropFirst(host.count)
                }
            }
            return nil

        default:
            return nil
        }
    }

    /// 规范化：把任何镜像 URL 还原成官方 host（用于让清单缓存与所选源无关）。
    static func toOfficial(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: bmclapiRoot + "/assets",
                                   with: "https://resources.download.minecraft.net")
        s = s.replacingOccurrences(of: bmclapiRoot + "/libraries",
                                   with: "https://libraries.minecraft.net")
        s = s.replacingOccurrences(of: bmclapiRoot + "/maven",
                                   with: "https://libraries.minecraft.net")
        s = s.replacingOccurrences(of: bmclapiRoot, with: "https://piston-meta.mojang.com")
        s = s.replacingOccurrences(of: aliyunMavenRoot, with: "https://libraries.minecraft.net")
        s = s.replacingOccurrences(of: tencentMavenRoot, with: "https://libraries.minecraft.net")
        return s
    }

    // MARK: - 候选清单

    /// 某一类资源的候选源顺序（按用户偏好 + 源健康度）。
    static func candidates(for official: URL,
                           kind: ResourceKind,
                           mode: DownloadSource? = nil) -> [MirrorCandidate] {
        let mode = mode ?? SettingsKeys.downloadSourceValue

        if mode == .official {
            return [MirrorCandidate(source: "official", url: official)]
        }

        let order: [String]
        switch kind {
        case .library:
            if isForgeOwned(official.path) {
                // Forge / NeoForge 构件：BMCLAPI 有镜像且快 10 倍，官方源放最后兜底。
                order = ["bmclapi", "bmclapi-maven", "official"]
            } else if isMojangOnly(official.path) {
                // Mojang 私有库：公共镜像没有；BMCLAPI 的 sakura 节点当前又大面积劣化
                // （实测 TLS 握手 20s 超时 / 8s 无首字节），官方反而又快又稳（0.8s/文件）。
                // 直接官方优先，别让每个私有库都先卡两轮超时。
                order = ["official", "bmclapi", "bmclapi-maven"]
            } else {
                // 通用库：国内云 maven 最快，BMCLAPI 两条路径兜底，官方最后。
                order = ["aliyun", "tencent", "bmclapi", "bmclapi-maven", "official"]
            }
        case .assetObject:
            order = ["bmclapi", "official"]
        case .manifest, .versionJSON, .assetIndex, .clientJar, .other:
            order = ["bmclapi", "official"]
        }

        // 健康度：连续失败被禁用的源排到最后（但保留，避免全军覆没）。
        let ranked = SourceHealth.shared.ordered(order, kind: kind)

        var out: [MirrorCandidate] = []
        for src in ranked {
            guard let rewritten = rewrite(official.absoluteString, by: src),
                  let url = URL(string: rewritten) else { continue }
            if out.contains(where: { $0.url == url }) { continue }
            out.append(MirrorCandidate(source: src, url: url))
        }
        if out.isEmpty {
            out = [MirrorCandidate(source: "official", url: official)]
        }
        return out
    }
}
