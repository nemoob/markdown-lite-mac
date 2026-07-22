import Foundation
import ImageIO
import UniformTypeIdentifiers

// 描述图片进入文档 assets 目录后可供编辑器消费的结果。
struct ImportedImageAsset: Equatable, Sendable {
    // 保存最终落盘位置，便于调用方反馈或继续处理。
    let destinationURL: URL
    // 保存已做 URL 百分号编码的文档相对路径，可直接写入 Markdown。
    let markdownRelativePath: String

    // 生成可直接插入正文的标准 Markdown 图片语法。
    func markdown(alt: String = "") -> String {
        // 转义替代文字中的反斜杠，避免它改变后续字符语义。
        let escapedBackslashes = alt.replacingOccurrences(of: "\\", with: "\\\\")
        // 转义右方括号，避免提前结束替代文字。
        let escapedAlt = escapedBackslashes.replacingOccurrences(of: "]", with: "\\]")
        // 相对路径已经过安全编码，可直接放入目标括号。
        return "![\(escapedAlt)](\(markdownRelativePath))"
    }
}

// 汇总本地图片导入阶段可向界面明确展示的失败原因。
enum AssetSupportError: LocalizedError, Equatable {
    // 未命名文档没有稳定的同级目录，必须先保存。
    case documentMustBeSaved
    // 只允许处理用户选中的本地文件。
    case sourceMustBeLocalFile
    // 源文件不存在或不是普通文件。
    case sourceUnavailable
    // 文件扩展名不在明确允许的常见图片集合中。
    case unsupportedImageType(String)
    // 扩展名虽合法，但文件内容不是系统可识别图片。
    case invalidImageData
    // 调用方提供的建议文件名包含路径成分。
    case unsafeFileName
    // 既有 assets 路径不是安全的真实目录。
    case unsafeAssetsDirectory
    // 目标路径未落在当前文档的 assets 目录内。
    case unsafeDestination
    // 复制或写入发生系统错误。
    case writeFailed(String)

    // 返回适合直接显示给用户的中文错误说明。
    var errorDescription: String? {
        // 按具体失败原因提供可执行的下一步。
        switch self {
        case .documentMustBeSaved:
            // 未命名文档必须先建立稳定文件位置。
            return "请先保存当前 Markdown 文档，再添加本地图片。"
        case .sourceMustBeLocalFile:
            // 远程 URL 不应走本地资源复制流程。
            return "只能导入本地图片文件。"
        case .sourceUnavailable:
            // 文件丢失或不是普通文件时请重新选择。
            return "图片文件不存在、不可读取或不是普通文件。"
        case let .unsupportedImageType(fileExtension):
            // 显示实际扩展名便于用户转换格式。
            return "暂不支持 .\(fileExtension.isEmpty ? "未知" : fileExtension) 图片，请使用 PNG、JPEG、GIF、WebP、HEIC、TIFF 或 BMP。"
        case .invalidImageData:
            // 避免把伪装扩展名的任意文件复制进项目。
            return "文件内容不是可识别的图片。"
        case .unsafeFileName:
            // 路径成分可能把文件写到 assets 之外。
            return "图片文件名不安全，请移除路径符号后重试。"
        case .unsafeAssetsDirectory:
            // 软链接或普通文件都不能作为受控资源目录。
            return "当前 assets 路径不是安全目录，请检查后重试。"
        case .unsafeDestination:
            // 防御性阻止任何目录穿越结果。
            return "图片目标路径超出当前文档的 assets 目录。"
        case let .writeFailed(message):
            // 保留底层简短原因帮助定位权限或磁盘问题。
            return "图片保存失败：\(message)"
        }
    }
}

// 使用系统文件能力把本地图片安全纳入 Markdown 文档目录。
enum AssetSupport {
    // 只接受系统常见且适合文档预览的位图扩展名。
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
    ]

    // 把拖入或以文件形式粘贴的图片复制到文档同级 assets 目录。
    static func importImage(from sourceURL: URL, documentURL: URL?) throws -> ImportedImageAsset {
        // 未保存文档没有可持久引用的资源目录。
        let documentURL = try requireSavedDocument(documentURL)
        // 远程 URL 继续由预览层直接加载，不复制到本地。
        guard sourceURL.isFileURL else { throw AssetSupportError.sourceMustBeLocalFile }
        // 标准化源路径以消除无意义的点路径段。
        let standardizedSource = sourceURL.standardizedFileURL
        // 读取普通文件和软链接状态，避免复制目录或跟随伪装链接。
        let sourceValues = try? standardizedSource.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        // 只接受实际存在的非软链接普通文件。
        guard sourceValues?.isRegularFile == true, sourceValues?.isSymbolicLink != true else {
            // 给调用方返回稳定且不泄漏路径的错误。
            throw AssetSupportError.sourceUnavailable
        }
        // 使用真实文件名决定目标扩展名。
        let filename = standardizedSource.lastPathComponent
        // 在任何写入前验证扩展名白名单。
        try validateSupportedExtension(of: filename)
        // 在任何写入前验证文件内容确实是图片。
        guard isRecognizedImage(at: standardizedSource) else { throw AssetSupportError.invalidImageData }
        // 建立并验证受控 assets 目录。
        let assetsDirectory = try prepareAssetsDirectory(for: documentURL)
        // 分配不会覆盖既有文件的最终目标地址。
        let destination = try uniqueDestination(for: filename, in: assetsDirectory)

        do {
            // copyItem 在目标已存在时会失败，继续保证不覆盖。
            try FileManager.default.copyItem(at: standardizedSource, to: destination)
        } catch {
            // 把系统写入失败转换为可展示错误。
            throw AssetSupportError.writeFailed(error.localizedDescription)
        }
        // 返回落盘地址和可直接插入正文的相对路径。
        return makeResult(destination: destination)
    }

    // 把剪贴板位图数据写入文档同级 assets 目录。
    static func storeImageData(
        _ data: Data,
        preferredFilename: String = "pasted-image.png",
        documentURL: URL?
    ) throws -> ImportedImageAsset {
        // 未保存文档没有可持久引用的资源目录。
        let documentURL = try requireSavedDocument(documentURL)
        // 建议文件名必须只有一个路径组件，主动阻止目录穿越。
        guard isSafeFilename(preferredFilename) else { throw AssetSupportError.unsafeFileName }
        // 在任何写入前验证扩展名白名单。
        try validateSupportedExtension(of: preferredFilename)
        // 在任何写入前验证剪贴板数据确实是图片。
        guard isRecognizedImage(data: data) else { throw AssetSupportError.invalidImageData }
        // 建立并验证受控 assets 目录。
        let assetsDirectory = try prepareAssetsDirectory(for: documentURL)
        // 分配不会覆盖既有文件的最终目标地址。
        let destination = try uniqueDestination(for: preferredFilename, in: assetsDirectory)

        do {
            // 原子写入避免中断时留下半张图片。
            try data.write(to: destination, options: .atomic)
        } catch {
            // 把系统写入失败转换为可展示错误。
            throw AssetSupportError.writeFailed(error.localizedDescription)
        }
        // 返回落盘地址和可直接插入正文的相对路径。
        return makeResult(destination: destination)
    }

    // 要求调用方提供已保存的本地 Markdown 文档地址。
    private static func requireSavedDocument(_ documentURL: URL?) throws -> URL {
        // nil 明确表示当前文档尚未保存。
        guard let documentURL else { throw AssetSupportError.documentMustBeSaved }
        // 文档必须是本地文件才能拥有同级 assets 目录。
        guard documentURL.isFileURL else { throw AssetSupportError.documentMustBeSaved }
        // 返回消除点路径段后的稳定文件位置。
        return documentURL.standardizedFileURL
    }

    // 验证文件扩展名属于明确支持集合。
    private static func validateSupportedExtension(of filename: String) throws {
        // 使用 URL 解析末尾扩展名并统一小写。
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        // 空扩展名或未知扩展名都不允许进入 assets。
        guard supportedExtensions.contains(fileExtension) else {
            // 返回实际扩展名供界面说明。
            throw AssetSupportError.unsupportedImageType(fileExtension)
        }
    }

    // 通过系统 ImageIO 验证本地文件内容属于图片。
    private static func isRecognizedImage(at url: URL) -> Bool {
        // 只读取图片源元信息，不主动进行整图解码。
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        // 至少有一帧才是可展示图片。
        return CGImageSourceGetCount(source) > 0
    }

    // 通过系统 ImageIO 验证剪贴板数据属于图片。
    private static func isRecognizedImage(data: Data) -> Bool {
        // 只读取图片源元信息，不主动进行整图解码。
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        // 至少有一帧才是可展示图片。
        return CGImageSourceGetCount(source) > 0
    }

    // 创建或验证当前文档专属的 assets 目录。
    private static func prepareAssetsDirectory(for documentURL: URL) throws -> URL {
        // 文档所在目录是所有相对资源的安全根目录。
        let documentDirectory = documentURL.deletingLastPathComponent().standardizedFileURL
        // 固定目录名避免调用方注入任意路径。
        let assetsDirectory = documentDirectory.appendingPathComponent("assets", isDirectory: true).standardizedFileURL
        // 固定目标仍执行包含关系检查，防御未来改动引入穿越。
        guard isStrictDescendant(assetsDirectory, of: documentDirectory) else {
            // 非预期路径立即停止写入。
            throw AssetSupportError.unsafeDestination
        }

        // 区分目录已存在和首次创建两条路径。
        var isDirectory: ObjCBool = false
        // 查询固定 assets 路径状态。
        let exists = FileManager.default.fileExists(atPath: assetsDirectory.path, isDirectory: &isDirectory)
        // 既有路径必须是真实目录且不能是软链接。
        if exists {
            // 普通文件不能被当作资源目录。
            guard isDirectory.boolValue else { throw AssetSupportError.unsafeAssetsDirectory }
            // 读取软链接状态以防 assets 指向文档目录之外。
            let values = try? assetsDirectory.resourceValues(forKeys: [.isSymbolicLinkKey])
            // 软链接目录不属于受控写入范围。
            guard values?.isSymbolicLink != true else { throw AssetSupportError.unsafeAssetsDirectory }
        } else {
            do {
                // 文档目录理应已存在，因此不跨层级创建未知父目录。
                try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: false)
            } catch {
                // 把目录创建失败转换为可展示错误。
                throw AssetSupportError.writeFailed(error.localizedDescription)
            }
        }

        // 解析真实路径后再次确保 assets 没有通过中间软链接逃出文档目录。
        let resolvedDocumentDirectory = documentDirectory.resolvingSymlinksInPath().standardizedFileURL
        // 解析 assets 的所有既有软链接成分。
        let resolvedAssetsDirectory = assetsDirectory.resolvingSymlinksInPath().standardizedFileURL
        // 真实目录必须仍位于真实文档目录之内。
        guard isStrictDescendant(resolvedAssetsDirectory, of: resolvedDocumentDirectory) else {
            // 中间路径逃逸时拒绝使用该目录。
            throw AssetSupportError.unsafeAssetsDirectory
        }
        // 返回已经完成两轮边界检查的资源目录。
        return assetsDirectory
    }

    // 为同名图片分配不会覆盖既有文件的地址。
    private static func uniqueDestination(for filename: String, in assetsDirectory: URL) throws -> URL {
        // 输入必须是单个安全文件名。
        guard isSafeFilename(filename) else { throw AssetSupportError.unsafeFileName }
        // 统一保留原扩展名小写，避免不同来源制造无意义大小写差异。
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        // 去掉扩展名后得到可追加序号的名称主体。
        let rawStem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        // 空白或纯点名称回退为稳定通用名称。
        let trimmedStem = rawStem.trimmingCharacters(in: .whitespacesAndNewlines)
        // 限制主体长度，给序号和扩展名预留文件系统空间。
        let boundedStem = String(
            (trimmedStem.isEmpty || trimmedStem.allSatisfy({ $0 == "." }) ? "image" : trimmedStem).prefix(120))
        // 首次尝试保留用户原始语义名称。
        var candidateName = "\(boundedStem).\(fileExtension)"
        // 从 2 开始追加符合常见文件管理习惯的序号。
        var suffix = 2

        // 只要候选文件已存在就继续寻找下一名称。
        while FileManager.default.fileExists(atPath: assetsDirectory.appendingPathComponent(candidateName).path) {
            // 使用短横线序号保持 Markdown 路径清晰。
            candidateName = "\(boundedStem)-\(suffix).\(fileExtension)"
            // 为下一次冲突递增序号。
            suffix += 1
        }
        // 只通过安全单文件名追加最终目标。
        let destination = assetsDirectory.appendingPathComponent(candidateName, isDirectory: false).standardizedFileURL
        // 最终目标必须严格位于 assets 目录内。
        guard isStrictDescendant(destination, of: assetsDirectory) else {
            // 任何异常标准化结果都禁止写入。
            throw AssetSupportError.unsafeDestination
        }
        // 返回当前未被占用的安全目标。
        return destination
    }

    // 判断字符串能否作为单个目标文件名使用。
    private static func isSafeFilename(_ filename: String) -> Bool {
        // 去掉两侧空白后名称必须仍有内容。
        guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // 点路径段具有目录语义，不能成为文件名。
        guard filename != ".", filename != ".." else { return false }
        // 正斜杠、反斜杠和空字符都可能改变路径解释。
        guard !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else { return false }
        // Foundation 解析结果必须仍与输入完全一致。
        return URL(fileURLWithPath: filename).lastPathComponent == filename
    }

    // 生成目标结果并完成 Markdown 路径编码。
    private static func makeResult(destination: URL) -> ImportedImageAsset {
        // 使用固定 assets 目录名和最终文件名构造相对路径。
        let rawRelativePath = "assets/\(destination.lastPathComponent)"
        // 仅允许 URL 非保留字符和路径斜杠保持原样。
        var allowedCharacters = CharacterSet.alphanumerics
        // RFC 3986 非保留标点可安全出现在 Markdown URL 中。
        allowedCharacters.insert(charactersIn: "-._~/")
        // 对空格、井号、括号和 Unicode 等字符执行百分号编码。
        let encodedPath =
            rawRelativePath.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? rawRelativePath
        // 返回落盘位置和可插入正文路径。
        return ImportedImageAsset(destinationURL: destination, markdownRelativePath: encodedPath)
    }

    // 判断候选路径是否严格位于给定目录之内。
    private static func isStrictDescendant(_ candidate: URL, of directory: URL) -> Bool {
        // 标准化目录路径并补充分隔符，避免 `/doc2` 冒充 `/doc` 子路径。
        let directoryPrefix =
            directory.standardizedFileURL.path.hasSuffix("/")
            ? directory.standardizedFileURL.path
            : directory.standardizedFileURL.path + "/"
        // 标准化候选路径后执行完整目录前缀比较。
        return candidate.standardizedFileURL.path.hasPrefix(directoryPrefix)
    }
}

// 提供无界面的图片导入、命名和路径安全回归检查。
enum AssetSupportSelfCheck {
    // 运行所有断言并返回通过项目数。
    @discardableResult
    static func run(printResults: Bool = true) -> Int {
        // 为本轮自检建立唯一临时目录，避免污染用户文档。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLiteMac-AssetCheck-\(UUID().uuidString)", isDirectory: true)
        // 无论成功或断言失败前都尽力回收临时资源。
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            // 建立临时文档目录。
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // 模拟已经保存的 Markdown 文件位置。
            let documentURL = root.appendingPathComponent("文章.md")
            // 写入最小正文使路径语义与真实文档一致。
            try Data("# 自检\n".utf8).write(to: documentURL, options: .atomic)
            // 生成一张真实的单像素 PNG 用于系统图片识别。
            let pngData = makeTestPNGData()
            // 源文件名包含空格以覆盖 Markdown 百分号编码。
            let sourceURL = root.appendingPathComponent("封面 image.png")
            // 把测试图片写到 assets 之外模拟拖入文件。
            try pngData.write(to: sourceURL, options: .atomic)

            // 第一次导入应保留语义名称并编码空格和中文。
            let first = try AssetSupport.importImage(from: sourceURL, documentURL: documentURL)
            // 导入结果必须实际存在。
            precondition(FileManager.default.fileExists(atPath: first.destinationURL.path), "图片首次导入未落盘")
            // 相对路径必须位于固定 assets 目录且不含原始空格。
            precondition(first.markdownRelativePath.hasPrefix("assets/"), "图片相对路径目录错误")
            // 路径中的空格必须经过百分号编码。
            precondition(first.markdownRelativePath.contains("%20"), "图片相对路径未编码空格")
            // 预览解析器必须按当前文档目录还原相对图片地址。
            let resolvedPreviewURL = EnhancedImageSourceResolver.resolve(
                first.markdownRelativePath,
                documentURL: documentURL
            )
            // 解析结果应精确指向本次导入的目标文件。
            precondition(resolvedPreviewURL == first.destinationURL, "相对图片预览地址解析错误")
            // 带当前目录前缀的常见相对写法也应得到相同结果。
            let dottedPreviewURL = EnhancedImageSourceResolver.resolve(
                "./\(first.markdownRelativePath)",
                documentURL: documentURL
            )
            // 折叠当前目录标记后仍应指向同一图片。
            precondition(dottedPreviewURL == first.destinationURL, "点前缀相对图片解析错误")
            // 显式 file URL 必须继续支持现有本地 Markdown 文档。
            let resolvedFileURL = EnhancedImageSourceResolver.resolve(
                first.destinationURL.absoluteString,
                documentURL: documentURL
            )
            // file URL 标准化结果应保持目标地址。
            precondition(resolvedFileURL == first.destinationURL, "file URL 图片解析错误")
            // 未确认的 HTTPS 图片不能从本地解析器取得可加载地址。
            let remoteSource = "https://example.com/image.png"
            // 远程图片必须由预览确认分支单独持有请求地址。
            precondition(
                EnhancedImageSourceResolver.resolve(remoteSource, documentURL: nil) == nil,
                "HTTPS 图片绕过了确认策略"
            )

            // 第二次导入同名源文件不得覆盖第一次结果。
            let second = try AssetSupport.importImage(from: sourceURL, documentURL: documentURL)
            // 重名结果必须分配不同地址。
            precondition(second.destinationURL != first.destinationURL, "重名图片覆盖了既有文件")
            // 常见序号规则应追加 -2。
            precondition(second.destinationURL.deletingPathExtension().lastPathComponent.hasSuffix("-2"), "重名图片未追加序号")

            // 未命名文档必须得到明确的先保存错误。
            var rejectedUntitled = false
            // 捕获预期错误而不终止其余自检。
            do {
                // nil 文档地址模拟新建但尚未保存的正文。
                _ = try AssetSupport.importImage(from: sourceURL, documentURL: nil)
            } catch AssetSupportError.documentMustBeSaved {
                // 记录错误类型符合预期。
                rejectedUntitled = true
            }
            // 缺少明确错误视为回归。
            precondition(rejectedUntitled, "未命名文档未要求先保存")

            // 伪装为 PDF 的图片内容仍必须因扩展名被拒绝。
            let illegalURL = root.appendingPathComponent("伪装.pdf")
            // 写入有效图片数据以确保检查确实发生在类型白名单。
            try pngData.write(to: illegalURL, options: .atomic)
            // 记录非法扩展名是否被拒绝。
            var rejectedType = false
            // 捕获预期错误而不终止其余自检。
            do {
                // PDF 不属于允许导入的图片扩展名。
                _ = try AssetSupport.importImage(from: illegalURL, documentURL: documentURL)
            } catch AssetSupportError.unsupportedImageType {
                // 记录错误类型符合预期。
                rejectedType = true
            }
            // 非白名单类型必须被拒绝。
            precondition(rejectedType, "非法图片类型未被拒绝")

            // 剪贴板接口必须拒绝带目录穿越的建议文件名。
            var rejectedTraversal = false
            // 捕获预期错误而不终止其余自检。
            do {
                // 恶意建议名称尝试逃离 assets 目录。
                _ = try AssetSupport.storeImageData(pngData, preferredFilename: "../逃逸.png", documentURL: documentURL)
            } catch AssetSupportError.unsafeFileName {
                // 记录目录穿越被正确识别。
                rejectedTraversal = true
            }
            // 目录穿越必须被拒绝。
            precondition(rejectedTraversal, "图片文件名目录穿越未被拒绝")
            // 预览层同样必须拒绝经过百分号编码的父目录穿越。
            let escapedPreviewURL = EnhancedImageSourceResolver.resolve(
                "%2E%2E/逃逸.png",
                documentURL: documentURL
            )
            // 非 nil 表示预览可能越权读取文档目录之外文件。
            precondition(escapedPreviewURL == nil, "相对图片预览目录穿越未被拒绝")

            // 输出稳定通过数供应用总自检汇总。
            let passedChecks = 10
            // 调用方可关闭标准输出，仅消费返回值。
            if printResults {
                // 简洁列出本模块覆盖范围。
                print("AssetSupportSelfCheck 通过 \(passedChecks) 项：相对/file/HTTPS 预览、路径编码、重名不覆盖、未命名文档、类型白名单、写入与预览目录穿越")
            }
            // 返回通过项目数。
            return passedChecks
        } catch {
            // 非预期系统错误直接终止自检并保留原因。
            preconditionFailure("AssetSupportSelfCheck 失败：\(error.localizedDescription)")
        }
    }

    // 使用系统 ImageIO 生成不依赖外部资源的最小测试 PNG。
    private static func makeTestPNGData() -> Data {
        // 单像素使用不透明蓝色 RGBA 数据。
        let pixelData = Data([0, 122, 255, 255])
        // 数据提供器把四个字节交给 Core Graphics 图片对象。
        let provider = CGDataProvider(data: pixelData as CFData)!
        // 使用标准设备 RGB 色彩空间。
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // 每像素四通道且 alpha 位于末尾。
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        // 构造一乘一像素的有效 CGImage。
        let image = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        // 使用可增长内存承接 PNG 编码结果。
        let output = NSMutableData()
        // 指定系统 PNG 类型且只写入一帧。
        let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        // 把单像素图片加入编码目标。
        CGImageDestinationAddImage(destination, image, nil)
        // 编码失败属于测试基础设施错误，应立即报告。
        precondition(CGImageDestinationFinalize(destination), "测试 PNG 生成失败")
        // 返回不可变数据供导入和剪贴板接口共同验证。
        return output as Data
    }
}

// 允许仅编译图片模块时直接执行自检，不影响应用正式入口。
#if ASSET_SUPPORT_STANDALONE
    @main
    private enum AssetSupportStandaloneCheck {
        // 独立进程只运行图片资源与路径安全检查。
        static func main() {
            // 默认打印本模块覆盖结果。
            AssetSupportSelfCheck.run()
        }
    }
#endif
