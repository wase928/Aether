//
//  ModEntry.swift
//  maccraft
//
//  版本 mods 目录的文件项（启用 / 禁用靠 .disabled 后缀，与 HMCL、PCL 一致）。
//

import Foundation

nonisolated struct ModEntry: Identifiable, Sendable, Hashable {
    let url: URL
    let name: String       // 去掉 .disabled 的显示名
    let size: Int64
    let enabled: Bool

    var id: String { url.path }

    static func scan(in dir: URL) -> [ModEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.fileSizeKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [ModEntry] = []
        for f in files {
            let ext = f.pathExtension.lowercased()
            let isDisabled = ext == "disabled"
            let baseExt = isDisabled ? f.deletingPathExtension().pathExtension.lowercased() : ext
            guard ["jar", "zip", "litemod"].contains(baseExt) else { continue }
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let display = isDisabled ? f.deletingPathExtension().lastPathComponent : f.lastPathComponent
            out.append(ModEntry(url: f, name: display, size: Int64(size), enabled: !isDisabled))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
