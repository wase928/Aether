//
//  Models.swift
//  maccraft
//
//  Mojang 启动元数据的数据模型。
//

import Foundation

// MARK: - 规则（库 / 参数的操作系统与特性约束）

nonisolated struct Rule: Codable, Sendable {
    let action: String?        // "allow" 或 "disallow"，缺省 "allow"
    let os: OSRule?
    let features: [String: Bool]?
}

nonisolated struct OSRule: Codable, Sendable {
    let name: String?          // "osx" / "windows" / "linux"
    let arch: String?          // "aarch64" / "arm64" / "x86_64" / "x86"
    let version: String?
}

nonisolated enum Platform {
    /// 本启动器仅面向 Apple Silicon macOS。
    static let name = "osx"
    static let arch = "arm64"
}

/// 按 Mojang 规则语义求值：
/// 无规则 -> 允许；有规则 -> 仅当“最后一个匹配的规则”动作为 allow 时才允许。
nonisolated func rulesAllow(_ rules: [Rule]?, features: [String: Bool]) -> Bool {
    guard let rules, !rules.isEmpty else { return true }
    var result = false
    for rule in rules {
        var matches = true
        if let os = rule.os {
            if let name = os.name, name != Platform.name { matches = false }
            if let arch = os.arch, !archMatches(arch) { matches = false }
        }
        if let feats = rule.features {
            for (key, expected) in feats where features[key] != expected {
                matches = false
            }
        }
        if matches {
            result = (rule.action ?? "allow") == "allow"
        }
    }
    return result
}

nonisolated private func archMatches(_ required: String) -> Bool {
    switch required.lowercased() {
    case "aarch64", "arm64":
        return Platform.arch == "arm64"
    case "x86_64", "x86":
        return Platform.arch == "x86_64"
    default:
        return required.lowercased() == Platform.arch.lowercased()
    }
}

// MARK: - 版本清单

nonisolated struct VersionManifest: Codable, Sendable {
    let latest: Latest
    let versions: [VersionRef]

    struct Latest: Codable, Sendable {
        let release: String
        let snapshot: String
    }

    struct VersionRef: Codable, Identifiable, Sendable {
        public let id: String
        public let type: String
        public let url: String
        public let time: String
        public let releaseTime: String
    }

    /// 把清单内所有版本入口 URL 的镜像 host 还原为官方 host，使缓存与所选下载源无关。
    func normalizingURLs() -> VersionManifest {
        VersionManifest(
            latest: latest,
            versions: versions.map {
                VersionManifest.VersionRef(
                    id: $0.id, type: $0.type,
                    url: Mirror.toOfficial($0.url),
                    time: $0.time, releaseTime: $0.releaseTime
                )
            }
        )
    }
}

// MARK: - 版本详情

nonisolated struct VersionDetails: Decodable, Sendable {
    let id: String
    let type: String
    let mainClass: String
    let assetIndex: AssetIndex?
    let assets: String?                 // 旧版（1.12-）用此字段
    let libraries: [Library]
    let downloads: Downloads?
    let arguments: Arguments?
    let minecraftArguments: String?      // 旧版参数（单字符串）
    let javaVersion: JavaVersion?
    /// Forge / Fabric / Quilt / NeoForge 的版本 JSON 靠继承原版：libraries/arguments 与父版本合并。
    let inheritsFrom: String?

    enum CodingKeys: String, CodingKey {
        case id, type, mainClass, assetIndex, assets
        case libraries, downloads, arguments, minecraftArguments, javaVersion
        case inheritsFrom, jar, minimumLauncherVersion
    }

    /// 宽容解码：加载器写出的 JSON 经常缺 downloads / type / assets 等字段。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? "release"
        mainClass = (try? c.decode(String.self, forKey: .mainClass)) ?? ""
        assetIndex = try? c.decodeIfPresent(AssetIndex.self, forKey: .assetIndex)
        assets = try? c.decodeIfPresent(String.self, forKey: .assets)
        libraries = (try? c.decode([Library].self, forKey: .libraries)) ?? []
        downloads = try? c.decodeIfPresent(Downloads.self, forKey: .downloads)
        arguments = try? c.decodeIfPresent(Arguments.self, forKey: .arguments)
        minecraftArguments = try? c.decodeIfPresent(String.self, forKey: .minecraftArguments)
        javaVersion = try? c.decodeIfPresent(JavaVersion.self, forKey: .javaVersion)
        inheritsFrom = try? c.decodeIfPresent(String.self, forKey: .inheritsFrom)
    }

    /// 合并父版本（子版本字段优先，libraries/arguments 叠加）。
    static func merge(child: VersionDetails, parent: VersionDetails) -> VersionDetails {
        // 去重键用 group:artifact（忽略版本）——Fabric 会校验 classpath 上不能有重复的 ASM 类，
        // 只按完整坐标去重会让 vanilla 和 loader 的 asm 同时上 classpath。子版本优先。
        func artifactKey(_ lib: Library) -> String {
            let parts = lib.name.split(separator: ":").map(String.init)
            guard parts.count >= 2 else { return lib.name }
            let classifier = parts.count > 3 ? ":\(parts[3])" : ""
            return "\(parts[0]):\(parts[1])\(classifier)"
        }

        var seen = Set<String>()
        var libs: [Library] = []
        for lib in child.libraries + parent.libraries {
            let key = artifactKey(lib)
            if seen.contains(key) { continue }
            seen.insert(key)
            libs.append(lib)
        }

        func combine(_ a: Arguments?, _ b: Arguments?) -> Arguments? {
            switch (a, b) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return Arguments(game: x.game + y.game, jvm: x.jvm + y.jvm)
            }
        }

        return VersionDetails(
            id: child.id,
            type: child.type,
            mainClass: child.mainClass.isEmpty ? parent.mainClass : child.mainClass,
            assetIndex: child.assetIndex ?? parent.assetIndex,
            assets: child.assets ?? parent.assets,
            libraries: libs,
            downloads: child.downloads ?? parent.downloads,
            arguments: combine(child.arguments, parent.arguments),
            minecraftArguments: child.minecraftArguments ?? parent.minecraftArguments,
            javaVersion: child.javaVersion ?? parent.javaVersion,
            inheritsFrom: nil
        )
    }

    /// 内部成员初始化（合并 / 构造用）。
    init(id: String, type: String, mainClass: String, assetIndex: AssetIndex?, assets: String?,
         libraries: [Library], downloads: Downloads?, arguments: Arguments?,
         minecraftArguments: String?, javaVersion: JavaVersion?, inheritsFrom: String?) {
        self.id = id
        self.type = type
        self.mainClass = mainClass
        self.assetIndex = assetIndex
        self.assets = assets
        self.libraries = libraries
        self.downloads = downloads
        self.arguments = arguments
        self.minecraftArguments = minecraftArguments
        self.javaVersion = javaVersion
        self.inheritsFrom = inheritsFrom
    }

    struct JavaVersion: Codable, Sendable {
        let component: String
        let majorVersion: Int
    }

    struct AssetIndex: Codable, Sendable {
        let id: String
        let url: String
        let sha1: String
        let size: Int
        let totalSize: Int
    }

    struct Downloads: Codable, Sendable {
        let client: Artifact?
    }

    struct Library: Codable, Identifiable, Sendable {
        public let name: String
        public var id: String { name }

        let downloads: LibraryDownloads?
        let natives: [String: String]?
        let rules: [Rule]?
        let extract: Extract?
        let url: String?                 // 非 Mojang 库（如 Forge）的 maven 根地址

        /// 解析出可下载的 artifact：
        /// 1) `downloads.artifact` 有完整地址就用它；
        /// 2) 否则用 `url`（maven 根）+ 坐标拼路径（Fabric / Quilt / 部分 Forge 库走这条）。
        func artifact() -> (url: String, path: String, sha1: String?, size: Int64?)? {
            if let a = downloads?.artifact {
                let path = a.path ?? Maven.path(for: name)
                return (a.url, path, a.sha1, a.size.map(Int64.init))
            }
            let root = url ?? "https://libraries.minecraft.net/"
            var base = root
            if !base.hasSuffix("/") { base += "/" }
            let path = Maven.path(for: name)
            return (base + path, path, nil, nil)
        }
    }

    struct LibraryDownloads: Codable, Sendable {
        let artifact: Artifact?
        let classifiers: [String: Artifact]?
    }

    struct Artifact: Codable, Sendable {
        let url: String
        let sha1: String?
        let size: Int?
        let path: String?
    }

    struct Extract: Codable, Sendable {
        let exclude: [String]?
    }

    struct Arguments: Codable, Sendable {
        let game: [Arg]
        let jvm: [Arg]
    }
}

// MARK: - 参数（异构：字符串 或 {rules, value}）

nonisolated enum Arg: Codable, Sendable {
    case string(String)
    case compound(rules: [Rule], value: ArgValue)

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = .string(s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rules = try c.decode([Rule].self, forKey: .rules)
        let value = try c.decode(ArgValue.self, forKey: .value)
        self = .compound(rules: rules, value: value)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let s):
            try s.encode(to: encoder)
        case .compound(let rules, let value):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(rules, forKey: .rules)
            try value.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case rules, value }

    var values: [String] {
        switch self {
        case .string(let s): return [s]
        case .compound(_, let v): return v.items
        }
    }

    func allowed(features: [String: Bool]) -> Bool {
        switch self {
        case .string: return true
        case .compound(let rules, _): return rulesAllow(rules, features: features)
        }
    }
}

nonisolated enum ArgValue: Codable, Sendable {
    case single(String)
    case multiple([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .single(s)
            return
        }
        self = .multiple(try c.decode([String].self))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .single(let s): try s.encode(to: encoder)
        case .multiple(let a): try a.encode(to: encoder)
        }
    }

    var items: [String] {
        switch self {
        case .single(let s): return [s]
        case .multiple(let a): return a
        }
    }
}

// MARK: - 资源索引

nonisolated struct AssetIndexFile: Codable, Sendable {
    let objects: [String: AssetObject]

    struct AssetObject: Codable, Sendable {
        let hash: String
        let size: Int
    }
}
