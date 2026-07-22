import Foundation
import Testing

@testable import MarkdownLiteMac

// 验证单文件 HTML 在离线、路径边界和失败原子性上的完整行为。
@Suite("可携带 HTML 导出")
struct PortableHTMLExportTests {
    // 相对路径和文档目录内 file URL 都必须成为不依赖源文件的 data 图片。
    @Test("本地图片内嵌后可脱离源目录")
    func testLocalImagesRemainAfterSourceRemoval() throws {
        // 建立本测试独享根目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次随机目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 原文和输出分开放置，便于删除完整源目录验证可携带性。
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        // 创建原文图片所在的固定 assets 目录。
        let assetsDirectory = sourceDirectory.appendingPathComponent("assets", isDirectory: true)
        // 一次创建原文和 assets 两级目录。
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        // 写入已保存 Markdown 文件以建立可信图片根目录。
        let documentURL = sourceDirectory.appendingPathComponent("article.md")
        try "# 离线文章".write(to: documentURL, atomically: true, encoding: .utf8)
        // 写入系统可识别的一像素 PNG。
        let imageURL = assetsDirectory.appendingPathComponent("pixel.png")
        let imageData = try #require(Self.pngData)
        try imageData.write(to: imageURL, options: .atomic)
        // 同时覆盖相对路径和文档目录内显式 file URL。
        let markdown = "![相对图片](assets/pixel.png)\n\n![文件图片](\(imageURL.absoluteString))"
        // 输出位于源目录之外，删除源目录后仍应独立存在。
        let outputURL = root.appendingPathComponent("portable.html")

        // 使用无面板纯写入 API 原子生成单个 HTML。
        try ExportSupport.writePortableHTML(
            markdown: markdown,
            title: "离线文章",
            documentURL: documentURL,
            to: outputURL
        )
        // 读取第一次完整导出结果。
        let htmlBeforeRemoval = try String(contentsOf: outputURL, encoding: .utf8)
        // 本地 PNG 必须以内嵌 MIME 和真实 Base64 字节出现。
        let expectedDataURL = "data:image/png;base64,\(imageData.base64EncodedString())"
        #expect(htmlBeforeRemoval.contains(expectedDataURL))
        // 两种引用各自产生一张图片且保留各自替代文字。
        #expect(htmlBeforeRemoval.components(separatedBy: "<img src=\"").count - 1 == 2)
        #expect(htmlBeforeRemoval.contains("alt=\"相对图片\""))
        #expect(htmlBeforeRemoval.contains("alt=\"文件图片\""))
        // CSP 只允许内部 data 图片，不允许网络图片源。
        #expect(htmlBeforeRemoval.contains("img-src data:"))
        #expect(!htmlBeforeRemoval.contains("img-src https:"))
        #expect(!htmlBeforeRemoval.contains("img-src http:"))

        // 删除 Markdown、assets 及其全部源图片。
        try FileManager.default.removeItem(at: sourceDirectory)
        // 重新读取输出证明结果没有运行时文件依赖。
        let htmlAfterRemoval = try String(contentsOf: outputURL, encoding: .utf8)
        // 删除源目录前后单文件字节语义必须保持一致。
        #expect(htmlAfterRemoval == htmlBeforeRemoval)
        #expect(htmlAfterRemoval.contains(expectedDataURL))
    }

    // HTTP 必须完全阻止，HTTPS 只能保留用户主动点击的普通链接。
    @Test("远程图片不会自动加载")
    func testRemoteImagesNeverBecomeImageSources() throws {
        // 远图不依赖文档目录，因此未保存文档也应安全导出。
        let markdown = "![明文](http://example.com/a.png)\n\n![加密](https://example.com/b.png)"
        // 生成离线 HTML 并检查静态网络边界。
        let html = try ExportSupport.portableHTMLDocument(
            markdown: markdown,
            title: "远图策略",
            documentURL: nil
        )
        // HTTP 地址既不能加载，也不能成为可点击目标。
        #expect(!html.contains("http://example.com/a.png"))
        // HTTPS 只保留明确点击链接，正文信息仍可找回。
        #expect(html.contains("href=\"https://example.com/b.png\""))
        #expect(html.contains("远程图片未自动加载"))
        // 两种远图都不能生成 img src。
        #expect(!html.contains("<img src=\"http"))
        // CSP 同样不能授予网络图片加载权限。
        #expect(html.contains("img-src data:"))
        #expect(!html.contains("img-src https:"))
        #expect(!html.contains("img-src http:"))
    }

    // 相对穿越、显式外部文件和出界软链接都必须在读取前失败。
    @Test("本地路径不能越过文档目录")
    func testTraversalFileURLAndSymlinkEscapeFail() throws {
        // 建立包含文档目录和外部图片的隔离根目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后清理精确随机目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建文档专属目录。
        let documentDirectory = root.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: false)
        // 写入已保存文档地址。
        let documentURL = documentDirectory.appendingPathComponent("article.md")
        try "正文".write(to: documentURL, atomically: true, encoding: .utf8)
        // 外部图片真实有效，确保失败原因只来自路径边界。
        let outsideImageURL = root.appendingPathComponent("outside.png")
        try #require(Self.pngData).write(to: outsideImageURL, options: .atomic)
        // 在文档目录内建立指向外部图片的软链接。
        let escapedLinkURL = documentDirectory.appendingPathComponent("escaped.png")
        try FileManager.default.createSymbolicLink(
            at: escapedLinkURL,
            withDestinationURL: outsideImageURL
        )
        // 三种地址分别覆盖相对穿越、显式 file URL 和软链接出界。
        let unsafeMarkdownValues = [
            "![穿越](../outside.png)",
            "![外部](\(outsideImageURL.absoluteString))",
            "![软链](escaped.png)",
        ]

        // 每种越界方式都必须得到同一稳定安全错误。
        for markdown in unsafeMarkdownValues {
            do {
                // 任何成功结果都表示本地目录边界被绕过。
                _ = try ExportSupport.portableHTMLDocument(
                    markdown: markdown,
                    title: "越界测试",
                    documentURL: documentURL
                )
                Issue.record("越界图片被错误导出：\(markdown)")
            } catch let error as PortableHTMLExportError {
                // 三类越界都应明确归入不安全引用。
                guard case .unsafeLocalImageReference = error else {
                    Issue.record("越界图片错误类型不正确：\(error)")
                    continue
                }
            }
        }
    }

    // 缺失、伪图片和未保存文档都不能留下伪成功输出。
    @Test("本地图片失败明确且不覆盖旧输出")
    func testMissingInvalidAndUnsavedImagesFailWithoutOverwrite() throws {
        // 建立文档与输出共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后清理本次随机目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 写入真实 Markdown 文件建立本地图片根目录。
        let documentURL = root.appendingPathComponent("article.md")
        try "正文".write(to: documentURL, atomically: true, encoding: .utf8)
        // 预先写入旧输出，用来验证失败不会覆盖。
        let outputURL = root.appendingPathComponent("existing.html")
        try "旧导出".write(to: outputURL, atomically: true, encoding: .utf8)

        do {
            // 缺失图片必须在生成完整 HTML 之前失败。
            try ExportSupport.writePortableHTML(
                markdown: "![缺失](missing.png)",
                title: "缺失",
                documentURL: documentURL,
                to: outputURL
            )
            Issue.record("缺失图片被错误导出")
        } catch let error as PortableHTMLExportError {
            // 缺失普通文件应提供可修复的资源不可用错误。
            guard case .localImageUnavailable = error else {
                Issue.record("缺失图片错误类型不正确：\(error)")
                return
            }
        }
        // 失败发生在原子写入前，旧输出必须完全保留。
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "旧导出")

        // 使用允许扩展名写入无法被 ImageIO 识别的伪图片。
        let invalidURL = root.appendingPathComponent("invalid.png")
        try Data("not-an-image".utf8).write(to: invalidURL, options: .atomic)
        do {
            // 真实可读校验必须拒绝伪装扩展名。
            _ = try ExportSupport.portableHTMLDocument(
                markdown: "![伪图片](invalid.png)",
                title: "非法",
                documentURL: documentURL
            )
            Issue.record("非法图片被错误导出")
        } catch let error as PortableHTMLExportError {
            // ImageIO 识别失败必须与缺失文件区分。
            guard case .invalidLocalImage = error else {
                Issue.record("非法图片错误类型不正确：\(error)")
                return
            }
        }

        do {
            // 未保存文档不能猜测相对图片的当前工作目录。
            _ = try ExportSupport.portableHTMLDocument(
                markdown: "![未保存](assets/pixel.png)",
                title: "未保存",
                documentURL: nil
            )
            Issue.record("未保存文档的本地图片被错误导出")
        } catch let error as PortableHTMLExportError {
            // 用户应得到先保存 Markdown 的明确下一步。
            guard case .documentMustBeSaved = error else {
                Issue.record("未保存文档错误类型不正确：\(error)")
                return
            }
        }
    }

    // 单张与累计图片预算都必须在提交前失败并保留已有目标。
    @Test("图片大小预算拒绝异常导出")
    func testImageSizeLimitsFailWithoutOverwrite() throws {
        // 建立文档、图片和旧输出共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后清理精确随机目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 写入已保存文档以建立可信图片根目录。
        let documentURL = root.appendingPathComponent("article.md")
        try "正文".write(to: documentURL, atomically: true, encoding: .utf8)
        // 预先写入旧目标以验证两种超限都不会覆盖。
        let outputURL = root.appendingPathComponent("existing.html")
        try "旧导出".write(to: outputURL, atomically: true, encoding: .utf8)

        // 先写入合法 PNG 头，确保错误优先来自 fstat 大小而不是扩展名。
        let oversizedImageURL = root.appendingPathComponent("oversized.png")
        try #require(Self.pngData).write(to: oversizedImageURL, options: .atomic)
        // 使用稀疏扩展快速构造超过正式单图阈值一字节的文件。
        let oversizedHandle = try FileHandle(forWritingTo: oversizedImageURL)
        // 测试文件大小精确落在二十五 MiB 边界之外。
        try oversizedHandle.truncate(
            atOffset: UInt64(PortableHTMLImageLimits.standard.singleImageByteCount + 1)
        )
        // 关闭测试写句柄，保证导出读取稳定的最终大小。
        try oversizedHandle.close()

        do {
            // 正式默认阈值必须在读取大文件内容前拒绝。
            try ExportSupport.writePortableHTML(
                markdown: "![过大](oversized.png)",
                title: "单图超限",
                documentURL: documentURL,
                to: outputURL
            )
            Issue.record("超过单图上限的图片被错误导出")
        } catch let error as PortableHTMLExportError {
            // 单图错误应同时携带观测大小与正式阈值。
            guard case let .localImageTooLarge(_, actualByteCount, limit) = error else {
                Issue.record("单图超限错误类型不正确：\(error)")
                return
            }
            // fstat 必须在内容读取前观测到精确稀疏文件大小。
            #expect(actualByteCount == PortableHTMLImageLimits.standard.singleImageByteCount + 1)
            // 错误中的阈值必须与正式配置一致。
            #expect(limit == PortableHTMLImageLimits.standard.singleImageByteCount)
        }
        // 单图超限不能覆盖已经存在的完整输出。
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "旧导出")

        // 写入两张不同路径的有效 PNG，防止同路径缓存消除累计计数。
        let firstImageURL = root.appendingPathComponent("first.png")
        let secondImageURL = root.appendingPathComponent("second.png")
        let imageData = try #require(Self.pngData)
        try imageData.write(to: firstImageURL, options: .atomic)
        try imageData.write(to: secondImageURL, options: .atomic)
        // 测试阈值允许任一单图，但比两图合计少一字节。
        let testLimits = PortableHTMLImageLimits(
            singleImageByteCount: Int64(imageData.count),
            totalImageByteCount: Int64(imageData.count * 2 - 1)
        )

        do {
            // 第二张有效图片应在累计预算检查时终止整次导出。
            try ExportSupport.writePortableHTML(
                markdown: "![第一张](first.png)\n\n![第二张](second.png)",
                title: "累计超限",
                documentURL: documentURL,
                to: outputURL,
                limits: testLimits
            )
            Issue.record("超过累计上限的图片被错误导出")
        } catch let error as PortableHTMLExportError {
            // 累计预算必须与单图错误清晰区分。
            guard case let .totalLocalImagesTooLarge(source, limit) = error else {
                Issue.record("累计超限错误类型不正确：\(error)")
                return
            }
            // 首图可成功进入预算，第二张图才应触发累计拒绝。
            #expect(source.contains("second.png"))
            // 错误携带当前测试配置的累计阈值。
            #expect(limit == testLimits.totalImageByteCount)
        }
        // 累计超限同样不能覆盖已有输出。
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "旧导出")

        // 极大调用方阈值不能在 limit + 1 计算时溢出并把合法小图误判为空数据。
        let maximumLimits = PortableHTMLImageLimits(
            singleImageByteCount: .max,
            totalImageByteCount: .max
        )
        // 使用同一有效小图验证 Int64.max 配置仍能完成正常读取与内嵌。
        let maximumLimitHTML = try ExportSupport.portableHTMLDocument(
            markdown: "![极大阈值](first.png)",
            title: "极大阈值",
            documentURL: documentURL,
            limits: maximumLimits
        )
        // 成功结果必须包含系统识别后的 PNG data URL。
        #expect(maximumLimitHTML.contains("data:image/png;base64,"))
    }

    // 标签关闭或新导出替换旧任务时，已取消请求不能覆盖目标文件。
    @Test("生成完成到提交前取消不覆盖目标")
    func testCancelledExportDoesNotWriteDestination() async throws {
        // 建立本次取消验证独享的文件目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次随机目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 写入可信文档位置供导出 API 建立本地安全根目录。
        let documentURL = root.appendingPathComponent("article.md")
        try "正文".write(to: documentURL, atomically: true, encoding: .utf8)
        // 预留旧输出验证取消不会执行最终原子替换。
        let outputURL = root.appendingPathComponent("existing.html")
        try "旧导出".write(to: outputURL, atomically: true, encoding: .utf8)

        // 在独立任务中等待临时文件完整生成后再精确注入取消。
        let wasCancelled = await Task.detached {
            do {
                // 提交前钩子模拟生成期间被新导出替换的旧任务。
                try ExportSupport.writePortableHTML(
                    markdown: "# 新导出",
                    title: "取消测试",
                    documentURL: documentURL,
                    to: outputURL,
                    _beforeCommit: {
                        // 当前任务在临时文件完成后、rename 之前进入取消状态。
                        withUnsafeCurrentTask { currentTask in
                            // 取消标记由紧随钩子的最终检查读取。
                            currentTask?.cancel()
                        }
                    }
                )
                // 没有抛出取消表示后台门禁失效。
                return false
            } catch is CancellationError {
                // 精确取消错误证明调用在目标写入前结束。
                return true
            } catch {
                // 其他错误不能伪装成任务取消。
                return false
            }
        }.value

        // 正式 API 必须识别当前任务已经取消。
        #expect(wasCancelled)
        // 原有输出不得被被取消的请求覆盖。
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "旧导出")
        // 取消路径必须可靠清理同目录的唯一临时文件。
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        // 目录中不能残留任何 Markdown Lite 导出临时文件。
        #expect(!remainingNames.contains(where: { $0.hasPrefix(".markdown-lite-") }))
    }

    // 两个标签同时导出到同一地址时，较慢的旧请求不能覆盖已经完成的后发请求。
    @Test("同目标并发导出以后发请求为准")
    func testConcurrentExportsKeepLatestRequest() async throws {
        // 建立两个任务共享但不影响其他测试的唯一目录。
        let root = try makeTemporaryDirectory()
        // 测试完成后精确清理当前目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 无本地图正文仍使用已保存文档地址，保持调用形态与真实标签一致。
        let documentURL = root.appendingPathComponent("article.md")
        try "正文".write(to: documentURL, atomically: true, encoding: .utf8)
        // 创建真实输出目录和指向它的父目录软链接，覆盖路径别名边界。
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        // 别名目录与真实目录最终指向同一文件系统位置。
        let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: aliasDirectory,
            withDestinationURL: realDirectory
        )
        // 先发请求使用真实父目录路径。
        let outputURL = realDirectory.appendingPathComponent("same-target.html")
        // 后发请求使用软链接父目录，但实际替换相同目录项。
        let aliasedOutputURL = aliasDirectory.appendingPathComponent("same-target.html")
        // 信号量只用于让旧请求稳定停在临时文件完成后的提交点。
        let firstReachedCommit = DispatchSemaphore(value: 0)
        // 第二个信号允许后发请求提交后再释放旧请求。
        let releaseFirstCommit = DispatchSemaphore(value: 0)

        // 先发请求在提交钩子等待，模拟大文档生成较慢的真实交错。
        let firstTask = Task.detached { () -> Bool in
            do {
                // 使用正式写入 API 和同一目标登记第一代结果。
                try ExportSupport.writePortableHTML(
                    markdown: "# 先发正文",
                    title: "先发",
                    documentURL: documentURL,
                    to: outputURL,
                    _beforeCommit: {
                        // 通知测试第一份临时文件已完整生成。
                        firstReachedCommit.signal()
                        // 最多等待五秒，测试异常时也不会永久挂起。
                        _ = releaseFirstCommit.wait(timeout: .now() + 5)
                    }
                )
                // 旧请求成功提交表示后发资格检查失效。
                return false
            } catch is CancellationError {
                // 后发请求登记后，旧请求应以正常取消结束。
                return true
            } catch {
                // 其他错误不能证明提交顺序正确。
                return false
            }
        }
        // 必须先确认第一份结果已经登记并等待提交，阻塞等待放到 GCD 工作线程。
        let firstWasReady = await withCheckedContinuation { continuation in
            // 同步信号量只占用独立 utility 队列，不阻塞测试异步执行器。
            DispatchQueue.global(qos: .utility).async {
                // 将限时等待结果一次恢复给异步测试。
                continuation.resume(
                    returning: firstReachedCommit.wait(timeout: .now() + 5) == .success
                )
            }
        }
        // 第一任务未就绪时也释放信号，避免异常路径遗留后台等待。
        guard firstWasReady else {
            // 解除可能刚到达钩子的旧任务。
            releaseFirstCommit.signal()
            // 明确记录无法建立预期交错。
            Issue.record("先发导出未在期限内到达提交点")
            // 等待旧任务收尾后结束本测试。
            _ = await firstTask.value
            return
        }

        // 后发请求在旧请求等待期间登记更高序号并正常提交。
        let secondSucceeded = await Task.detached { () -> Bool in
            do {
                // 相同目标和不同正文用于验证最终胜出内容。
                try ExportSupport.writePortableHTML(
                    markdown: "# 后发正文",
                    title: "后发",
                    documentURL: documentURL,
                    to: aliasedOutputURL
                )
                // 完整写入结束表示后发请求已经原子提交。
                return true
            } catch {
                // 任意错误都表示后发请求未完成预期提交。
                return false
            }
        }.value
        // 后发提交结束后允许旧请求继续核对资格。
        releaseFirstCommit.signal()
        // 旧请求此时必须识别自己的序号已经过期。
        let firstWasSuperseded = await firstTask.value

        // 后发请求必须成功，旧请求必须被淘汰。
        #expect(secondSucceeded)
        #expect(firstWasSuperseded)
        // 最终文件必须只包含后发正文。
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(html.contains("后发正文"))
        #expect(!html.contains("先发正文"))
        // 两条路径结束后都不能残留同目录临时文件。
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: realDirectory.path)
        #expect(!remainingNames.contains(where: { $0.hasPrefix(".markdown-lite-") }))
    }

    // 固定一像素 PNG 避免测试依赖 AppKit 绘图或外部资源。
    private static let pngData = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )

    // 为每项测试创建不会与并行进程冲突的独立目录。
    private func makeTemporaryDirectory() throws -> URL {
        // UUID 确保同一测试并发执行时仍使用不同地址。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLitePortableHTML-\(UUID().uuidString)", isDirectory: true)
        // 一次创建精确目录，不复用其他测试残留。
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // 返回供调用方按作用域清理的地址。
        return directory
    }
}
