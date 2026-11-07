//
//  InstalledIndex.swift
//  maccraft
//
//  记录"哪些 Modrinth 项目已安装到哪个版本"。
//  Modrinth 下载的文件名里不带 project id，光看目录无法判断归属，
//  所以这里落一份 JSON 索引（App Support/installed-projects.json），并校验文件是否还在。
//

import Foundation

nonisolated struct InstalledRecord: Codable, Sendable {
    let projectID: String
    let title: String
    let filename: String
    let type: String        // mod / shader / resourcepack
    let versionID: String   // mod 用目标版本；光影/资源包用 "-"
    let date: Date
}

nonisolated enum InstalledIndex {
    private static var fileURL: URL {
        Paths.appSupport.appendingPathComponent("installed-projects.json")
    }

    static func all() -> [InstalledRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([InstalledRecord].self, from: data) else { return [] }
        return list
    }

    /// 记录的 key：光影/资源包是全局的，mod 按版本区分。
    static func key(type: ResourceType, versionID: String, projectID: String) -> String {
        let scope = type == .mod ? versionID : "-"
        return "\(type.rawValue)|\(scope)|\(projectID)"
    }

    static func installedKeys(type: ResourceType, versionID: String) -> Set<String> {
        var out = Set<String>()
        for r in all() where r.type == type.rawValue {
            let scope = type == .mod ? versionID : "-"
            guard r.versionID == scope else { continue }
            // 文件被删了就当作没装
            let dir = type.destination(versionID: versionID)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(r.filename).path) {
                out.insert(key(type: type, versionID: versionID, projectID: r.projectID))
            }
        }
        return out
    }

    /// 归一化：只留字母数字，用来比对"文件名里是否包含项目名"。
    private static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 索引没记录时（例如用户在推出索引前就装过），用文件名启发式判断是否已安装。
    /// 例：slug "complementary-reimagined" ↔ 文件 "ComplementaryReimagined_r5.9.3.zip"。
    static func matchedFile(type: ResourceType, versionID: String,
                            slug: String, title: String) -> URL? {
        let dir = type.destination(versionID: versionID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) else { return nil }
        let keys = [norm(slug), norm(title)].filter { $0.count >= 4 }
        guard !keys.isEmpty else { return nil }
        for f in files {
            let n = norm(f.lastPathComponent)
            if keys.contains(where: { n.contains($0) }) { return f }
        }
        return nil
    }

    static func record(projectID: String, title: String, type: ResourceType,
                       versionID: String, file: URL) {
        let scope = type == .mod ? versionID : "-"
        var list = all().filter {
            !($0.projectID == projectID && $0.type == type.rawValue && $0.versionID == scope)
        }
        list.append(InstalledRecord(projectID: projectID, title: title,
                                    filename: file.lastPathComponent,
                                    type: type.rawValue, versionID: scope, date: Date()))
        try? Paths.ensure(Paths.appSupport)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: fileURL, options: .atomic) }
    }

    static func remove(projectID: String, type: ResourceType, versionID: String) {
        let scope = type == .mod ? versionID : "-"
        let list = all().filter {
            !($0.projectID == projectID && $0.type == type.rawValue && $0.versionID == scope)
        }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: fileURL, options: .atomic) }
    }
}
