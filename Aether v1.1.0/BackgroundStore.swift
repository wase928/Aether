//
//  BackgroundStore.swift
//  maccraft
//
//  自定义窗口背景（壁纸）。
//
//  ## 为什么要有
//
//  背景是**一张普通壁纸**，不是液态玻璃的一部分：
//  · 壁纸保持清晰 —— 模糊和折射是**玻璃**该干的活，
//    背景自己再糊一层就成了「毛玻璃上的毛玻璃」，既看不出壁纸本身，
//    又白白多出几次全屏合成（卡顿）。
//  · 玻璃侧栏 / 卡片浮在壁纸上，它们自己去折射这张壁纸。
//
//  ## 持久化分工（踩过坑）
//
//  图片**复制**进 `~/Library/Application Support/maccraft/background/`，
// 不用原图路径 —— 否则用户挪走/删了原图，界面就变成一块碎图或空白。
//
//  两个设置项（文件名 / 压暗）都用 **View 侧的 `@AppStorage`** 存：
//  `@AppStorage` 是 View 的 property wrapper，放进 ObservableObject 里
//  **不会自动更新也不会自动写回**（早先踩过：界面上显示 0，UserDefaults 里却没这个键）。
// 所以这里只留纯静态的图片管理逻辑，值的读写交给 View。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 背景图的文件管理（纯逻辑，无状态）。
nonisolated enum Background {
    /// UserDefaults 键名（View 侧用 @AppStorage 读同样的键）。
    enum Key {
        static let file = "aether.background.file"
        /// 压暗强度（只为文字可读）。
        static let dim = "aether.background.dim"
    }

    /// 背景副本目录。
    static var directory: URL {
        Paths.appSupport.appendingPathComponent("background", isDirectory: true)
    }

    /// 模糊图的最大边长。
    ///
    /// 不用原图尺寸：4K 图模糊 + 编码一次要好几秒，
    /// 而且显示时根本用不到那么细 —— 缩到 1920 已经足够。
    private static let maxDimension: CGFloat = 1920

    /// 由 UserDefaults 里记的文件名解析出实际路径（文件不存在则 nil）。
    static func imageURL(storedFile: String) -> URL? {
        guard !storedFile.isEmpty else { return nil }
        let url = directory.appendingPathComponent(storedFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 选一张图：复制进本地目录，返回要存进 UserDefaults 的文件名。
    static func pickAndStore() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .jpeg, .png, .heic, .tiff]
        panel.message = "选择窗口背景图片"
        panel.prompt = "设为背景"
        guard panel.runModal() == .OK, let src = panel.url else { return nil }
        return store(src)
    }

    /// 把图片复制进本地目录，返回文件名（失败返回 nil）。
    ///
    /// 复制时会**缩放 + 转 jpg** —— 用户挑的往往是一张 4K/20MB 的原图，
    /// 直接存下来每次启动都要解码 20MB（解码本身就要 100ms+），
    /// 缩到 1920 宽足够铺满窗口，体积能降到几百 KB。
    @discardableResult
    static func store(_ src: URL) -> String? {
        do {
            try Paths.ensure(directory)
            clearFiles()
            let name = "background.jpg"
            let dest = directory.appendingPathComponent(name)
            if let scaled = downscale(src, maxDimension: maxDimension) {
                try scaled.write(to: dest)
            } else {
                // 缩放失败就退回复制原图
                try FileManager.default.copyItem(at: src, to: dest)
            }
            return name
        } catch {
            NSLog("[Background] 设置背景失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 缩放图片并转成 jpg 数据（失败返回 nil）。
    private static func downscale(_ src: URL, maxDimension: CGFloat) -> Data? {
        guard let image = CIImage(contentsOf: src),
              image.extent.width > 1, image.extent.height > 1 else { return nil }
        let scale = min(1, maxDimension / max(image.extent.width, image.extent.height))
        let scaled = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let ctx = CIContext(options: [.cacheIntermediates: false])
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    /// 删掉本地副本（恢复默认时用）。
    static func clearFiles() {
        let dir = directory
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in items {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// 清理旧版本留下的模糊缓存（`blur-*.jpg`）。
    ///
    /// ## 为什么需要
    ///
    /// 早期版本会给背景做「预模糊」（Core Image 一次性模糊 → 存 jpg），
    /// 缓存文件名是 `blur-<半径>.jpg`。
    /// 现在背景改成普通壁纸（模糊是玻璃的活），这些文件纯属垃圾，
    /// 而且 `blur-12.jpg` 还有 65KB —— 每次启动白读一遍。
    ///
    /// 只在启动时调一次，用完即删。
    static func purgeLegacyBlurCaches() {
        let dir = directory
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in items where name.hasPrefix("blur-") && name.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
