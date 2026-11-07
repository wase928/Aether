//
//  PackIndex.swift
//  maccraft
//
//  记录"哪个整合包文件导入成了哪个实例"。
//
//  为什么需要：
//  整合包一次导入就是 1GB+（实测 276 个 mod / 1.1GB）。同一个包重复导入时，
//  如果每次都新建实例，用户会莫名其妙攒下好几份完全一样的 1.1GB 目录。
//  这里用「源文件的 路径 + 大小 + 修改时间」当指纹记住映射，
//  重复导入同一个文件时直接复用原实例目录（覆盖更新），
//  换文件（同名但内容不同）才新建。
//

import Foundation

nonisolated struct PackRecord: Codable, Sendable {
    /// 源文件的绝对路径。
    let source: String
    /// 源文件大小（字节）。
    let size: Int64
    /// 源文件修改时间。
    let modified: Date
    /// 导入后生成的实例 id。
    let versionID: String
    /// 整合包显示名。
    let title: String
    let date: Date
}

nonisolated enum PackIndex {
    private static var fileURL: URL {
        Paths.appSupport.appendingPathComponent("installed-packs.json")
    }

    static func all() -> [PackRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([PackRecord].self, from: data) else { return [] }
        return list
    }

    /// 源文件的指纹（路径 + 大小 + 修改时间）。
    /// 同一个文件重新下载后修改时间会变，所以能识别出「换了内容」。
    static func fingerprint(_ url: URL) -> (path: String, size: Int64, modified: Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date.distantPast
        return (url.resolvingSymlinksInPath().path, size, modified)
    }

    /// 找同一份源文件之前导入出来的实例。文件被删了 / 实例目录没了就当没导入过。
    static func existing(for url: URL) -> PackRecord? {
        guard let fp = fingerprint(url) else { return nil }
        for r in all() {
            guard r.source == fp.path, r.size == fp.size, r.modified == fp.modified else { continue }
            // 实例目录还在才算有效
            guard FileManager.default.fileExists(atPath: Paths.versionJSON(r.versionID).path) else { continue }
            return r
        }
        return nil
    }

    /// 记下这次的导入结果。
    static func record(source url: URL, versionID: String, title: String) {
        guard let fp = fingerprint(url) else { return }
        var list = all().filter { $0.source != fp.path }
        list.append(PackRecord(source: fp.path, size: fp.size, modified: fp.modified,
                                versionID: versionID, title: title, date: Date()))
        try? Paths.ensure(Paths.appSupport)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 实例被删了就把索引条目一并清掉，避免下次误判成「已导入」。
    static func forget(versionID: String) {
        let list = all().filter { $0.versionID != versionID }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
