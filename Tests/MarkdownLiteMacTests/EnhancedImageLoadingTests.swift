import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import MarkdownLiteMac

// 验证预览本地图片的目录边界、资源预算和后台缩略图行为。
@Suite("增强预览本地图片")
struct EnhancedImageLoadingTests {
    // 显式 file URL 必须与相对引用共用已保存文档目录边界。
    @Test("显式和相对图片只允许文档目录内真实路径")
    func testResolverRequiresSavedDocumentAndRejectsEscapes() throws {
        // 创建文档目录与外部目录共用的隔离根目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次随机目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 当前文档目录是所有可加载本地图片的唯一安全根目录。
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        // assets 子目录覆盖正常的多级相对图片引用。
        let assetsDirectory = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        // 一次创建文档及资源目录。
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        // 写入已保存文档以建立可信根目录。
        let documentURL = documentDirectory.appendingPathComponent("article.md")
        // 真实文件存在可排除无效文档地址干扰。
        try "正文".write(to: documentURL, atomically: true, encoding: .utf8)
        // 在 assets 中写入系统可识别的正常 PNG。
        let insideImageURL = assetsDirectory.appendingPathComponent("inside.png")
        // 固定小图数据避免测试依赖外部资源。
        try makePNG(width: 4, height: 3).write(to: insideImageURL, options: .atomic)
        // 真实路径作为两种安全引用的统一期望结果。
        let expectedURL = insideImageURL.resolvingSymlinksInPath().standardizedFileURL

        // 原有相对图片语法必须继续解析成功。
        let relativeResult = EnhancedImageSourceResolver.resolve(
            "assets/inside.png",
            documentURL: documentURL
        )
        // 相对引用应返回目录内图片的真实地址。
        #expect(relativeResult == expectedURL)
        // 文档目录内显式 file URL 同样允许加载。
        let explicitResult = EnhancedImageSourceResolver.resolve(
            insideImageURL.absoluteString,
            documentURL: documentURL
        )
        // 显式地址必须与相对地址收口到同一真实文件。
        #expect(explicitResult == expectedURL)
        // 未保存文档不能为显式 file URL 提供安全根目录。
        #expect(
            EnhancedImageSourceResolver.resolve(
                insideImageURL.absoluteString,
                documentURL: nil
            ) == nil
        )

        // 文档目录外创建一张真实有效图片。
        let outsideImageURL = root.appendingPathComponent("outside.png")
        // 外部图片内容有效，拒绝原因只能来自目录边界。
        try makePNG(width: 2, height: 2).write(to: outsideImageURL, options: .atomic)
        // 显式外部 file URL 必须在读取前被拒绝。
        #expect(
            EnhancedImageSourceResolver.resolve(
                outsideImageURL.absoluteString,
                documentURL: documentURL
            ) == nil
        )
        // 在文档目录内创建指向外部图片的软链接。
        let escapedLinkURL = assetsDirectory.appendingPathComponent("escaped.png")
        // 软链接目标明确位于安全根目录之外。
        try FileManager.default.createSymbolicLink(
            at: escapedLinkURL,
            withDestinationURL: outsideImageURL
        )
        // 相对软链接必须解析真实目标后识别越界。
        #expect(
            EnhancedImageSourceResolver.resolve(
                "assets/escaped.png",
                documentURL: documentURL
            ) == nil
        )
        // 显式软链接同样不能绕过统一真实路径检查。
        #expect(
            EnhancedImageSourceResolver.resolve(
                escapedLinkURL.absoluteString,
                documentURL: documentURL
            ) == nil
        )
    }

    // 打开时的文件描述符校验必须继续阻止最终或中间路径软链接。
    @Test("解码器拒绝打开阶段的软链接替换")
    func testDecoderRejectsFinalAndIntermediateSymlinks() throws {
        // 创建安全目录和外部目录共用的隔离根目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次随机目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 安全目录模拟来源解析器已经核对过的文档目录。
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        // 外部目录保存不应由安全路径别名打开的真实图片。
        let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
        // 分别创建两级真实目录。
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: false
        )
        // 外部目录独立创建，避免继承文档目录边界。
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: false
        )
        // 写入系统可正常解码的外部 PNG。
        let outsideImageURL = outsideDirectory.appendingPathComponent("outside.png")
        // 有效内容保证失败只来自文件描述符路径门禁。
        try makePNG(width: 2, height: 2).write(to: outsideImageURL, options: .atomic)

        // 最终组件软链接模拟解析后图片文件本身被替换。
        let finalLinkURL = documentDirectory.appendingPathComponent("final-link.png")
        // 软链接目标明确指向外部真实图片。
        try FileManager.default.createSymbolicLink(
            at: finalLinkURL,
            withDestinationURL: outsideImageURL
        )
        // O_NOFOLLOW 必须在读取任何数据前拒绝最终软链接。
        #expect(EnhancedLocalImageDecoder.decodeThumbnail(at: finalLinkURL) == nil)

        // 中间目录软链接模拟 resolver 与 open 之间父目录项被替换。
        let intermediateLinkURL = documentDirectory.appendingPathComponent(
            "linked-assets",
            isDirectory: true
        )
        // 中间链接把看似文档内路径导向外部目录。
        try FileManager.default.createSymbolicLink(
            at: intermediateLinkURL,
            withDestinationURL: outsideDirectory
        )
        // 构造保留文档内词法路径的最终图片地址。
        let escapedCandidate = intermediateLinkURL.appendingPathComponent("outside.png")
        // F_GETPATH 必须发现实际打开路径与调用方预期路径不同。
        #expect(EnhancedLocalImageDecoder.decodeThumbnail(at: escapedCandidate) == nil)
    }

    // 正常图片应在非主线程完成解码，并按最长边生成缩略图。
    @Test("正常图片在后台生成受限缩略图")
    func testNormalImageDecodesOffMainThreadAsThumbnail() async throws {
        // 创建本测试独享目录。
        let root = try makeTemporaryDirectory()
        // 测试完成后清理唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 写入宽大于高的有效 PNG 以验证缩略图比例。
        let imageURL = root.appendingPathComponent("normal.png")
        // 四乘三图片在最长边限制为二时应缩为二乘一或二乘二的系统结果。
        try makePNG(width: 4, height: 3).write(to: imageURL, options: .atomic)
        // 测试预算保留充足字节与像素，只把缩略图最长边压到二。
        let limits = EnhancedLocalImageLimits(
            maximumByteCount: 1_024,
            maximumPixelCount: 12,
            maximumThumbnailPixelSize: 2
        )

        // 与正式加载器一致，在 detached 后台任务执行文件读取和 ImageIO 解码。
        let decodedThumbnail = await Task.detached(priority: .utility) {
            // 当前闭包内同步完成缩略图像素生成。
            EnhancedLocalImageDecoder.decodeThumbnail(
                at: imageURL,
                limits: limits
            )
        }.value

        // 有效图片必须成功得到已解码 CGImage。
        let thumbnail = try #require(decodedThumbnail)
        // 最长边必须遵守测试配置的两像素硬上限。
        #expect(max(thumbnail.cgImage.width, thumbnail.cgImage.height) <= 2)
        // 缩略图两边都必须保留至少一个像素。
        #expect(thumbnail.cgImage.width > 0)
        // 高度同样必须形成有效像素内容。
        #expect(thumbnail.cgImage.height > 0)
    }

    // 外层预览任务取消必须终止不继承结构化取消的 detached worker。
    @Test("预览取消传播到后台图片 worker")
    func testOuterCancellationStopsDetachedWorker() async throws {
        // 创建本测试独享目录。
        let root = try makeTemporaryDirectory()
        // 测试完成后清理唯一目录和稀疏图片。
        defer { try? FileManager.default.removeItem(at: root) }
        // 先写入可正常解码的 PNG 内容。
        let imageURL = root.appendingPathComponent("cancelled.png")
        // 有效首帧保证没有取消时可以生成缩略图。
        try makePNG(width: 4, height: 3).write(to: imageURL, options: .atomic)
        // 稀疏扩展提供足够读取窗口，让取消传播测试不依赖微秒级调度顺序。
        let handle = try FileHandle(forWritingTo: imageURL)
        // 四 MiB 仍远低于正式上限，并能被 PNG 解码器忽略为帧后数据。
        try handle.truncate(atOffset: UInt64(4 * 1_024 * 1_024))
        // 主动关闭写句柄，保证后台读取看到稳定文件大小。
        try handle.close()
        // 未取消基线必须证明稀疏扩展后的图片仍是有效测试输入。
        let baseline = await EnhancedLocalImageDecoder.decodeThumbnailInBackground(at: imageURL)
        // 基线失败会让后续 nil 无法证明取消传播。
        #expect(baseline != nil)

        // 建立已经取消的外层任务，模拟 SwiftUI 图片块快速离开可见区。
        let cancelledResult = await Task.detached {
            // 在调用后台入口前先设置取消状态，要求 handler 立即取消新 worker。
            withUnsafeCurrentTask { currentTask in
                // 当前 detached 测试任务始终存在。
                currentTask?.cancel()
            }
            // detached worker 本身不会自动继承当前取消，必须依赖生产 cancellation handler。
            return await EnhancedLocalImageDecoder.decodeThumbnailInBackground(at: imageURL)
        }.value

        // 取消后的调用不得返回旧图片或继续完成完整解码。
        #expect(cancelledResult == nil)
    }

    // fstat 字节预算必须在读取超大稀疏文件前生效。
    @Test("超过字节上限的图片在读取前失败")
    func testOversizedByteCountFails() throws {
        // 创建本测试独享目录。
        let root = try makeTemporaryDirectory()
        // 测试完成后清理唯一目录和稀疏文件。
        defer { try? FileManager.default.removeItem(at: root) }
        // 先写入合法 PNG 头，确保扩展名与前缀不会提前造成无关失败。
        let imageURL = root.appendingPathComponent("oversized.png")
        // 使用小图作为稀疏扩展前的有效内容。
        try makePNG(width: 1, height: 1).write(to: imageURL, options: .atomic)
        // 打开文件并把逻辑大小扩展到正式上限之外一字节。
        let handle = try FileHandle(forWritingTo: imageURL)
        // 稀疏扩展不会真正写入二十五 MiB 数据，测试保持快速。
        try handle.truncate(
            atOffset: UInt64(EnhancedLocalImageLimits.standard.maximumByteCount + 1)
        )
        // 主动关闭写句柄，确保解码器读取稳定元数据。
        try handle.close()

        // 默认预览预算必须直接拒绝超限文件。
        let thumbnail = EnhancedLocalImageDecoder.decodeThumbnail(at: imageURL)
        // nil 证明没有为超限输入生成可显示图片。
        #expect(thumbnail == nil)
    }

    // 像素预算必须在 ImageIO 创建真实位图之前阻止解码炸弹形态。
    @Test("超过像素上限的图片在解码前失败")
    func testOversizedPixelCountFails() throws {
        // 创建本测试独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后清理唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 写入四乘三的有效 PNG，源图总像素为十二。
        let imageURL = root.appendingPathComponent("too-many-pixels.png")
        // 有效编码确保失败只来自像素预算。
        try makePNG(width: 4, height: 3).write(to: imageURL, options: .atomic)
        // 测试预算只允许十一像素，恰好比源图少一。
        let limits = EnhancedLocalImageLimits(
            maximumByteCount: 1_024,
            maximumPixelCount: 11,
            maximumThumbnailPixelSize: 2
        )

        // ImageIO 读取元数据后必须在真正生成缩略图前拒绝源图。
        let thumbnail = EnhancedLocalImageDecoder.decodeThumbnail(
            at: imageURL,
            limits: limits
        )
        // nil 证明像素预算没有被缩略图尺寸掩盖。
        #expect(thumbnail == nil)
    }

    // 使用 CoreGraphics 和 ImageIO 生成指定尺寸的确定性测试 PNG。
    private func makePNG(width: Int, height: Int) throws -> Data {
        // sRGB 色彩空间足以覆盖普通文档图片解码路径。
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        // 创建每像素四字节的非透明位图上下文。
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        // 填充固定颜色保证编码器拥有完整像素数据。
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        // 覆盖整张测试画布。
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 从上下文取得不可变源图。
        let image = try #require(context.makeImage())
        // 使用可变数据承接 ImageIO 编码结果。
        let data = NSMutableData()
        // public.png 是系统稳定的 PNG 类型标识。
        let destination = try #require(
            CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        )
        // 把唯一测试帧加入输出目标。
        CGImageDestinationAddImage(destination, image, nil)
        // 编码失败不能产生伪造的空测试图片。
        #expect(CGImageDestinationFinalize(destination))
        // Foundation 可变数据复制为值类型交给文件写入。
        return data as Data
    }

    // 为每项测试创建不会与并行进程冲突的独立目录。
    private func makeTemporaryDirectory() throws -> URL {
        // UUID 确保同一测试并发执行时仍使用不同地址。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLiteImageLoading-\(UUID().uuidString)", isDirectory: true)
        // 一次创建精确目录，不复用其他测试残留。
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // 返回供调用方按作用域清理的地址。
        return directory
    }
}
