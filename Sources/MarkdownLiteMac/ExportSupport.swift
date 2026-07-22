import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 定义公众号导出的稳定模板标识，便于菜单展示和后续持久化选择。
enum WechatExportTemplate: String, CaseIterable, Identifiable, Sendable {
    // 简洁模板延续首版默认排版，确保旧调用行为不变。
    case simple
    // 技术文模板强化代码、引用、标题和表格的层次。
    case technical

    // 使用稳定原始值满足 SwiftUI 列表的身份要求。
    var id: String { rawValue }

    // 返回面向用户的中文模板名称。
    var displayName: String {
        // 每个模板名称直接对应菜单文案。
        switch self {
        case .simple:
            return "简洁"
        case .technical:
            return "技术文"
        }
    }
}

// 保存一次公众号复制需要写入剪贴板的两种等价内容。
struct WechatExportPayload: Sendable {
    // 富文本消费者读取带内联样式的安全 HTML。
    let html: String
    // 纯文本消费者读取原始 Markdown，完整保留标题、表格、代码和引用内容。
    let plainText: String
}

// 集中定义单文件 HTML 可接受的本地图片字节预算。
struct PortableHTMLImageLimits: Equatable, Sendable {
    // 单张图片上限阻止异常文件造成过高的读取和 Base64 内存开销。
    let singleImageByteCount: Int64
    // 去重后的全部图片上限约束最终 HTML 和导出峰值内存。
    let totalImageByteCount: Int64

    // 正式导出默认允许单张图片最多二十五 MiB。
    static let standard = PortableHTMLImageLimits(
        singleImageByteCount: 25 * 1_024 * 1_024,
        // 正式导出默认允许全部唯一图片最多一百 MiB。
        totalImageByteCount: 100 * 1_024 * 1_024
    )
}

// 汇总可携带 HTML 在读取本地图片前主动识别的失败原因。
enum PortableHTMLExportError: LocalizedError, Equatable {
    // 未保存文档没有可信目录，不能解析相对或 file 图片。
    case documentMustBeSaved(String)
    // 本地引用未通过现有解析器或解析后越过文档目录。
    case unsafeLocalImageReference(String)
    // 图片不存在、不可读或不是普通文件。
    case localImageUnavailable(String)
    // 扩展名合法但内容不是系统可识别图片。
    case invalidLocalImage(String)
    // 单张真实文件超过导出预算，不能进入内存或 Base64 编码。
    case localImageTooLarge(String, Int64, Int64)
    // 去重后的图片总字节数超过整次导出预算。
    case totalLocalImagesTooLarge(String, Int64)
    // 图片读取发生系统错误。
    case localImageReadFailed(String, String)

    // 返回不泄漏额外目录信息、可直接展示给用户的中文说明。
    var errorDescription: String? {
        // 按失败原因说明必须修复的 Markdown 图片引用。
        switch self {
        case let .documentMustBeSaved(source):
            // 未命名文档先保存后才能建立图片安全根目录。
            return "本地图片“\(source)”无法导出：请先保存 Markdown 文档。"
        case let .unsafeLocalImageReference(source):
            // 越界、软链接出界和不支持的路径都使用同一安全提示。
            return "本地图片“\(source)”无法导出：路径必须位于 Markdown 文档目录内。"
        case let .localImageUnavailable(source):
            // 缺失和权限问题都要求用户修复原始资源后重试。
            return "本地图片“\(source)”无法导出：文件不存在、不可读取或不是普通文件。"
        case let .invalidLocalImage(source):
            // 伪装扩展名不能被内嵌到可携带 HTML。
            return "本地图片“\(source)”无法导出：文件内容不是可识别的图片。"
        case let .localImageTooLarge(source, _, limit):
            // 单图超限时展示可直接采取压缩行动的明确阈值。
            return "本地图片“\(source)”无法导出：单张图片不能超过\(Self.formattedByteCount(limit))。"
        case let .totalLocalImagesTooLarge(source, limit):
            // 累计超限说明当前图片触发整篇文档预算，便于用户定位和删减。
            return "本地图片“\(source)”无法导出：全部图片合计不能超过\(Self.formattedByteCount(limit))。"
        case let .localImageReadFailed(source, reason):
            // 保留系统简短原因，便于定位临时 IO 或权限失败。
            return "本地图片“\(source)”读取失败：\(reason)"
        }
    }

    // 把二进制字节预算转换成用户熟悉的简短容量说明。
    private static func formattedByteCount(_ byteCount: Int64) -> String {
        // 系统格式化器会按当前语言输出合适的 KiB 或 MiB 单位。
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .binary)
    }
}

// 标识一次目标文件提交资格，确保并发导出采用后发请求结果。
private struct PortableHTMLCommitReservation: Sendable {
    // 标准化目标路径用于区分不同导出文件。
    let destinationPath: String
    // 单调序号用于识别同一目标最后一次开始的请求。
    let generation: UInt64
}

// 用短临界区协调跨标签的同目标原子提交，不串行化不同文件的解析和图片读取。
private final class PortableHTMLCommitCoordinator: @unchecked Sendable {
    // 锁只保护序号表和最终 rename 临界区。
    private let lock = NSLock()
    // 全局单调序号为每次导出提供稳定先后关系。
    private var nextGeneration: UInt64 = 0
    // 每个标准化目标只保留最后开始请求的序号。
    private var latestGenerationByDestination: [String: UInt64] = [:]

    // 在任何耗时生成前登记本次请求，使后发请求立即令旧请求失效。
    func reserve(destination: URL) -> PortableHTMLCommitReservation {
        // 解析目标父目录软链接，避免两个目录别名绕过同一文件的提交顺序。
        let resolvedDirectory =
            destination
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        // 最终文件名保持原样，因为 rename 会替换该目录项而不是跟随既有目标链接。
        let destinationPath =
            resolvedDirectory
            .appendingPathComponent(destination.lastPathComponent, isDirectory: false)
            .path
        // 序号和字典更新必须作为一个不可分割操作。
        lock.lock()
        // 任意返回路径都释放短锁。
        defer { lock.unlock() }
        // 应用生命周期内不会耗尽 UInt64，回绕加法仍避免异常崩溃。
        nextGeneration &+= 1
        // 保存本次唯一序号。
        let generation = nextGeneration
        // 新请求登记后，同目标更早请求不能再提交。
        latestGenerationByDestination[destinationPath] = generation
        // 返回供生成结束时核对的不可变资格。
        return PortableHTMLCommitReservation(
            destinationPath: destinationPath,
            generation: generation
        )
    }

    // 只允许同目标最后登记且未取消的请求执行最终原子替换。
    func commit(
        reservation: PortableHTMLCommitReservation,
        operation: () throws -> Void
    ) throws {
        // 核对资格与 rename 必须处于同一短临界区，避免检查后被新请求插入。
        lock.lock()
        // rename 完成或抛错后立即释放，不阻塞后续不同目标提交。
        defer { lock.unlock() }
        // 字典为空或序号不同都表示本次结果已经过期。
        guard latestGenerationByDestination[reservation.destinationPath] == reservation.generation else {
            // 统一使用取消语义，让界面静默丢弃被替换的旧请求。
            throw CancellationError()
        }
        // 任务取消也必须在持锁提交点再检查一次。
        try Task.checkCancellation()
        // 调用方只在这里执行一次同目录原子 rename。
        try operation()
    }

    // 请求结束后只清理自己的最新登记，不能删除更晚请求的资格。
    func finish(reservation: PortableHTMLCommitReservation) {
        // 字典清理与并发登记使用同一把锁。
        lock.lock()
        // 所有分支都释放锁。
        defer { lock.unlock() }
        // 仅当前仍为最后请求时移除目标记录。
        guard latestGenerationByDestination[reservation.destinationPath] == reservation.generation else {
            // 更晚请求已经接管目标时保持其登记不变。
            return
        }
        // 移除完成或失败的最后请求，避免目标表长期增长。
        latestGenerationByDestination.removeValue(forKey: reservation.destinationPath)
    }
}

// 提供不依赖第三方库的 HTML 导出与公众号复制能力。
enum ExportSupport {
    // 所有文档共享提交协调器，跨标签导出同一路径仍遵循后发请求胜出。
    private static let commitCoordinator = PortableHTMLCommitCoordinator()

    // 生成不会自动加载远程图片的完整 HTML 文档。
    static func htmlDocument(markdown: String, title: String) -> String {
        // 无文档上下文的旧入口保留正文结构，但所有图片采用离线占位策略。
        let body = HTMLExportRenderer.renderFragment(
            markdown,
            imageRenderer: HTMLExportRenderer.renderOfflineImage
        )
        // 统一壳层只允许内部生成的 data 图片，不允许任何网络图片请求。
        return makeHTMLDocument(body: body, title: title)
    }

    // 生成把安全本地图片直接嵌入 data URL 的单文件 HTML。
    static func portableHTMLDocument(
        markdown: String,
        title: String,
        documentURL: URL?,
        limits: PortableHTMLImageLimits = .standard
    ) throws -> String {
        // 已取消任务不再开始 Markdown 解析或本地文件访问。
        try Task.checkCancellation()
        // 每次导出使用独立解析器，缓存同图并收集首次不可恢复错误。
        let imageEmbedder = PortableHTMLImageEmbedder(documentURL: documentURL, limits: limits)
        // 正文渲染仍复用既有块和行内 Markdown 逻辑。
        let body = HTMLExportRenderer.renderFragment(
            markdown,
            imageRenderer: imageEmbedder.render
        )
        // 渲染完成后优先传播取消，避免取消请求被其他中间错误掩盖。
        try Task.checkCancellation()
        // 任一本地图片失败都阻止产出看似成功但丢图的 HTML。
        if let error = imageEmbedder.firstError { throw error }
        // 成功结果只依赖自身 data URL，不再依赖原文档目录。
        return makeHTMLDocument(body: body, title: title)
    }

    // 生成适合粘贴到公众号编辑器的内联样式 HTML 片段。
    static func wechatHTML(
        markdown: String,
        template: WechatExportTemplate = .simple
    ) -> String {
        // 公众号会清除外部样式，因此正文中的每个关键标签都使用内联样式。
        let body = HTMLExportRenderer.renderFragment(
            markdown,
            template: template,
            imageRenderer: HTMLExportRenderer.renderWechatImage
        )
        // 最外层 section 统一提供中文排版基线。
        return """
            <section style="\(template.containerStyle)">
            \(body)
            </section>
            """
    }

    // 生成一次复制所需的 HTML 与纯文本载荷，便于 UI 和自检复用。
    static func wechatPayload(
        markdown: String,
        template: WechatExportTemplate = .simple
    ) -> WechatExportPayload {
        // HTML 统一经过模板渲染、实体转义和危险协议过滤。
        let html = wechatHTML(markdown: markdown, template: template)
        // 纯文本保留 Markdown 原文，确保任何目标应用都不会丢失结构内容。
        let plainText = markdown
        // 返回可一次写入多种剪贴板类型的不可变载荷。
        return WechatExportPayload(html: html, plainText: plainText)
    }

    // 将公众号 HTML 和 Markdown 纯文本同时写入系统剪贴板。
    @MainActor
    @discardableResult
    static func copyWechatHTML(
        markdown: String,
        template: WechatExportTemplate = .simple
    ) -> Bool {
        // 先生成经过转义和协议过滤的双格式载荷。
        let payload = wechatPayload(markdown: markdown, template: template)
        // 使用通用剪贴板与其他 Mac 应用互通。
        let pasteboard = NSPasteboard.general
        // 清除旧类型，避免消费者读到过期内容。
        pasteboard.clearContents()
        // 同时声明富文本 HTML 和纯文本回退。
        pasteboard.declareTypes([.html, .string], owner: nil)
        // HTML 类型供公众号等富文本编辑器读取。
        let wroteHTML = pasteboard.setString(payload.html, forType: .html)
        // Markdown 原文供不支持 HTML 的文本应用读取。
        let wroteText = pasteboard.setString(payload.plainText, forType: .string)
        // 两种格式都成功才报告复制成功。
        return wroteHTML && wroteText
    }

    // 将完整 HTML 原子写入指定地址，便于 UI 或测试直接调用。
    static func writeHTML(markdown: String, title: String, to url: URL) throws {
        // 生成完整且自包含的 HTML 文档。
        let html = htmlDocument(markdown: markdown, title: title)
        // 原子写入避免中途失败留下不完整文件。
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    // 在没有保存面板等 UI 副作用的前提下原子写入可携带单文件 HTML。
    static func writePortableHTML(
        markdown: String,
        title: String,
        documentURL: URL?,
        to url: URL,
        limits: PortableHTMLImageLimits = .standard,
        _beforeCommit: (() -> Void)? = nil
    ) throws {
        // 标签关闭或下一次导出已经替换当前请求时不再开始处理。
        try Task.checkCancellation()
        // 在耗时生成前登记目标顺序，后发请求可以立即淘汰当前旧结果。
        let commitReservation = commitCoordinator.reserve(destination: url)
        // 成功、失败或取消都释放本次登记，但不会误删更晚请求。
        defer { commitCoordinator.finish(reservation: commitReservation) }
        // 先完整解析并验证所有本地图片，失败时目标文件保持原状。
        let html = try portableHTMLDocument(
            markdown: markdown,
            title: title,
            documentURL: documentURL,
            limits: limits
        )
        // 生成完成后再次响应取消，避免创建不再需要的临时文件。
        try Task.checkCancellation()
        // 临时文件必须与目标同目录，保证最终 rename 不会跨文件系统。
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".markdown-lite-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        // 只有 rename 成功后才停止清理临时文件。
        var didCommit = false
        // 失败、取消和测试钩子退出都会尽力删除唯一临时文件。
        defer {
            // 已提交文件的旧临时路径已经不存在，无需重复访问文件系统。
            if !didCommit {
                // unlink 不跟随软链接且不会误删目标文件。
                temporaryURL.withUnsafeFileSystemRepresentation { path in
                    // 路径转换失败时没有可删除的有效本地文件。
                    if let path { _ = Darwin.unlink(path) }
                }
            }
        }
        // 独占创建随机临时名，极端碰撞也不能覆盖其他文件。
        try Data(html.utf8).write(to: temporaryURL, options: .withoutOverwriting)
        // 测试可在临时文件完成后精确注入取消，生产调用保持 nil。
        _beforeCommit?()
        // 提交协调器在同一短临界区核对取消、后发请求和最终原子替换。
        try commitCoordinator.commit(reservation: commitReservation) {
            // 同目录 POSIX rename 以一次原子操作替换已有目标。
            let renameResult = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
                // 目标路径同样必须能转换为本地文件系统表示。
                url.withUnsafeFileSystemRepresentation { destinationPath in
                    // 任一路径转换失败都使用 EINVAL 形成稳定系统错误。
                    guard let sourcePath, let destinationPath else { return -EINVAL }
                    // rename 会替换普通旧文件或链接，但不会产生半写目标。
                    return Darwin.rename(sourcePath, destinationPath)
                }
            }
            // 系统拒绝替换时保留 errno 并由 defer 清理临时文件。
            guard renameResult == 0 else {
                // 负 EINVAL 是路径转换失败的内部标记，其他失败读取即时 errno。
                let errorCode = renameResult == -EINVAL ? EINVAL : errno
                // 标准 Cocoa 调用方可直接展示系统提供的本地化文件错误。
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errorCode),
                    userInfo: [NSFilePathErrorKey: url.path]
                )
            }
        }
        // rename 成功表示目标已经完整替换，临时路径不再需要清理。
        didCommit = true
    }

    // 弹出原生保存面板并只返回用户选择的目标；取消时返回 nil。
    @MainActor
    static func chooseHTMLDestination(suggestedFilename: String) -> URL? {
        // 配置系统保存面板，沿用原生文件访问和覆盖确认。
        let panel = NSSavePanel()
        // 仅允许导出标准 HTML 文件。
        panel.allowedContentTypes = [.html]
        // 允许用户直接在面板内新建目标文件夹。
        panel.canCreateDirectories = true
        // 保证默认文件名具有 html 扩展名。
        panel.nameFieldStringValue = normalizedHTMLFilename(suggestedFilename)
        // 只返回确认后的地址，耗时处理由调用方转到后台。
        return panel.runModal() == .OK ? panel.url : nil
    }

    // 规范保存面板中的默认 HTML 文件名。
    private static func normalizedHTMLFilename(_ filename: String) -> String {
        // 去掉首尾空白，避免生成难以辨认的文件名。
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空名称使用稳定的中文默认值。
        guard !trimmed.isEmpty else { return "未命名.html" }
        // 已有 html 或 htm 扩展名时保持原值。
        let lowercased = trimmed.lowercased()
        if lowercased.hasSuffix(".html") || lowercased.hasSuffix(".htm") {
            return trimmed
        }
        // 其他名称统一追加 html 扩展名。
        return "\(trimmed).html"
    }

    // 用统一离线 CSP 包装已经安全渲染的正文。
    private static func makeHTMLDocument(body: String, title: String) -> String {
        // 标题进入标签前统一转义，避免关闭 title 后注入标签。
        let safeTitle = HTMLExportRenderer.escapeHTML(title)
        // data 仅承载本次导出内部生成的图片，HTTP 与 HTTPS 均不具加载权限。
        return """
            <!doctype html>
            <html lang="zh-CN">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; object-src 'none'; base-uri 'none'; form-action 'none'">
              <title>\(safeTitle)</title>
            </head>
            <body style="margin:0;background:#f6f7f9;color:#24292f;font-family:-apple-system,BlinkMacSystemFont,'PingFang SC','Helvetica Neue',sans-serif;">
              <main style="box-sizing:border-box;max-width:820px;min-height:100vh;margin:0 auto;padding:48px 56px;background:#ffffff;font-size:16px;line-height:1.8;word-break:break-word;">
            \(body)
              </main>
            </body>
            </html>
            """
    }
}

// 集中提供两套仅由内联 CSS 组成的公众号样式。
private extension WechatExportTemplate {
    // 返回正文容器样式，统一字体和换行基线。
    var containerStyle: String {
        // 简洁模板保持首版色彩，技术文模板使用稍紧凑的工程化排版。
        switch self {
        case .simple:
            return
                "box-sizing:border-box;color:#2b2b2b;font-family:-apple-system,BlinkMacSystemFont,'PingFang SC','Helvetica Neue',sans-serif;font-size:16px;line-height:1.8;word-break:break-word;"
        case .technical:
            return
                "box-sizing:border-box;color:#1f2937;font-family:-apple-system,BlinkMacSystemFont,'PingFang SC','Helvetica Neue',sans-serif;font-size:16px;line-height:1.75;letter-spacing:.01em;word-break:break-word;"
        }
    }

    // 返回指定层级标题的完整内联样式。
    func headingStyle(level: Int, size: Int, alignment: String) -> String {
        // 简洁模板延续原有居中主标题和深色层级。
        switch self {
        case .simple:
            return
                "margin:28px 0 14px;color:#1f2328;font-size:\(size)px;line-height:1.35;font-weight:700;text-align:\(alignment);"
        case .technical:
            // 技术文的一、二级标题增加底部强调线，方便长文扫描。
            let border = level <= 2 ? "padding-bottom:8px;border-bottom:2px solid #99f6e4;" : ""
            // 技术文标题全部左对齐并使用青绿色强调色。
            return
                "margin:28px 0 14px;\(border)color:#0f766e;font-size:\(size)px;line-height:1.35;font-weight:700;text-align:left;"
        }
    }

    // 返回围栏代码块的完整内联样式。
    var codeBlockStyle: String {
        // 技术文采用深色代码面板，简洁模板保持浅色背景。
        switch self {
        case .simple:
            return
                "box-sizing:border-box;margin:18px 0;padding:14px 16px;overflow-x:auto;border-radius:8px;background:#f3f4f6;color:#24292f;font:14px/1.65 ui-monospace,SFMono-Regular,Menlo,Monaco,monospace;white-space:pre;"
        case .technical:
            return
                "box-sizing:border-box;margin:20px 0;padding:16px 18px;overflow-x:auto;border:1px solid #30363d;border-radius:8px;background:#0d1117;color:#e6edf3;font:14px/1.7 ui-monospace,SFMono-Regular,Menlo,Monaco,monospace;white-space:pre;"
        }
    }

    // 返回引用块的完整内联样式。
    var quoteStyle: String {
        // 技术文使用模板强调色，简洁模板保持中性灰。
        switch self {
        case .simple:
            return
                "box-sizing:border-box;margin:18px 0;padding:10px 16px;border-left:4px solid #8c959f;background:#f6f8fa;color:#57606a;"
        case .technical:
            return
                "box-sizing:border-box;margin:18px 0;padding:12px 16px;border-left:4px solid #14b8a6;background:#f0fdfa;color:#115e59;"
        }
    }

    // 返回正文段落的完整内联样式。
    var paragraphStyle: String {
        // 两套模板只调整正文色彩和行距，不改变内容结构。
        switch self {
        case .simple:
            return "margin:14px 0;color:#2b2b2b;font-size:16px;line-height:1.8;"
        case .technical:
            return "margin:14px 0;color:#1f2937;font-size:16px;line-height:1.75;"
        }
    }

    // 返回表格整体的内联样式。
    var tableStyle: String {
        // 两套模板保持一致布局，技术文稍微收紧字号。
        switch self {
        case .simple:
            return "width:100%;border-collapse:collapse;border-spacing:0;font-size:15px;line-height:1.6;"
        case .technical:
            return "width:100%;border-collapse:collapse;border-spacing:0;font-size:14px;line-height:1.6;"
        }
    }

    // 返回表头单元格的内联样式。
    var tableHeaderStyle: String {
        // 技术文表头使用强调色底纹，简洁模板保持浅灰。
        switch self {
        case .simple:
            return "padding:10px 12px;border:1px solid #d8dee4;background:#f6f8fa;text-align:left;font-weight:700;"
        case .technical:
            return
                "padding:10px 12px;border:1px solid #5eead4;background:#ccfbf1;color:#115e59;text-align:left;font-weight:700;"
        }
    }

    // 返回表体单元格的内联样式。
    var tableCellStyle: String {
        // 技术文边框呼应表头，简洁模板保持原有灰色边框。
        switch self {
        case .simple:
            return "padding:10px 12px;border:1px solid #d8dee4;vertical-align:top;"
        case .technical:
            return "padding:10px 12px;border:1px solid #99f6e4;vertical-align:top;"
        }
    }

    // 返回行内代码的完整内联样式。
    var inlineCodeStyle: String {
        // 技术文行内代码采用同主题青色，简洁模板保持首版红色。
        switch self {
        case .simple:
            return
                "padding:2px 5px;border-radius:4px;background:#f1f2f4;color:#cf222e;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,monospace;font-size:.9em;"
        case .technical:
            return
                "padding:2px 5px;border:1px solid #99f6e4;border-radius:4px;background:#f0fdfa;color:#0f766e;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,monospace;font-size:.9em;"
        }
    }

    // 返回链接的完整内联样式。
    var linkStyle: String {
        // 技术文链接使用模板强调色，简洁模板保持首版蓝色。
        switch self {
        case .simple:
            return "color:#0969da;text-decoration:none;border-bottom:1px solid #54aeff;"
        case .technical:
            return "color:#0f766e;text-decoration:none;border-bottom:1px solid #2dd4bf;"
        }
    }
}

// 为一次可携带导出解析、验证并缓存全部本地图片。
private final class PortableHTMLImageEmbedder {
    // 文档地址决定相对图片和显式 file 图片共同的安全根目录。
    private let documentURL: URL?
    // 每次导出的单图与累计预算由调用入口统一传入。
    private let limits: PortableHTMLImageLimits
    // 同一真实图片只读取和编码一次，避免重复引用扩大 CPU 与临时内存成本。
    private var dataURLByURL: [URL: String] = [:]
    // 只累计已经验证并缓存的唯一图片原始字节数。
    private var embeddedImageByteCount: Int64 = 0
    // 首次失败决定整次导出的可行动错误，后续渲染不再读取其他本地文件。
    private(set) var firstError: Error?

    // 保存调用方提供的当前 Markdown 文件地址。
    init(documentURL: URL?, limits: PortableHTMLImageLimits) {
        // 标准化本地地址以稳定后续目录比较，非本地地址保留供明确报错。
        self.documentURL = documentURL?.standardizedFileURL
        // 保存当前导出的明确字节预算，测试可使用更小阈值覆盖边界。
        self.limits = limits
    }

    // 按远程策略或本地嵌入策略渲染一张 Markdown 图片。
    func render(_ imageURL: URL, _ alt: String) -> String {
        // 保留 Markdown 解析器得到的原始地址语义供安全解析和错误提示。
        let source = imageURL.absoluteString
        // 任何失败路径都使用不发起网络或文件请求的安全占位。
        let fallback = HTMLExportRenderer.renderOfflineImage(imageURL, alt)
        // 已有失败时不继续读取图片，最终入口会抛出首次错误。
        guard firstError == nil else { return fallback }

        do {
            // 每张图片处理前检查取消，避免继续打开本地文件。
            try Task.checkCancellation()
            // 按远程或本地策略生成当前图片的安全 HTML。
            let html = try renderChecked(imageURL, alt: alt, source: source)
            // 每张图片处理后再次检查取消，防止已取消结果进入最终文档。
            try Task.checkCancellation()
            // 只有完整处理且未取消的图片结果才交回 Markdown 渲染器。
            return html
        } catch is CancellationError {
            // 保存标准取消错误，让同步渲染结束后仍能精确传播任务取消。
            firstError = CancellationError()
        } catch let error as PortableHTMLExportError {
            // 只保留第一项，避免多个失败让状态栏说明失焦。
            firstError = error
        } catch {
            // 防御未来支撑层抛出的其他错误并转换成稳定用户说明。
            firstError = PortableHTMLExportError.localImageReadFailed(
                source,
                error.localizedDescription
            )
        }
        // 当前 HTML 最终不会返回，但中间字符串仍保持安全。
        return fallback
    }

    // 在已经检查取消的范围内区分远程占位和本地图片嵌入。
    private func renderChecked(_ imageURL: URL, alt: String, source: String) throws -> String {
        // HTTP 永久阻止，HTTPS 只输出显式链接而不创建图片请求。
        switch EnhancedImageSourceResolver.remoteImageDecision(for: source) {
        case .blocked, .requiresConfirmation:
            // 远程图片不属于本地导出失败，使用离线占位继续生成正文。
            return HTMLExportRenderer.renderOfflineImage(imageURL, alt)
        case .notRemote:
            // 本地和非法协议继续按 scheme 精确区分。
            break
        }

        // data、javascript 等非本地协议只显示替代文字，不能进入 data 图片白名单。
        if let scheme = imageURL.scheme?.lowercased(), scheme != "file" {
            // 复用离线占位保证危险协议不会进入任何属性。
            return HTMLExportRenderer.renderOfflineImage(imageURL, alt)
        }
        // 本地图必须完整解析并编码成功后才成为 img 标签。
        return try embedLocalImage(source: source, alt: alt)
    }

    // 把一张位于文档目录内的真实图片转换成受 CSP 允许的 data URL。
    private func embedLocalImage(source: String, alt: String) throws -> String {
        // 未保存或非本地文档都没有可信图片根目录。
        guard let documentURL, documentURL.isFileURL else {
            // 明确要求先保存，而不是静默丢弃本地图片。
            throw PortableHTMLExportError.documentMustBeSaved(source)
        }
        // 复用预览层对协议、扩展名、百分号和相对路径穿越的既有校验。
        guard
            let candidate = EnhancedImageSourceResolver.resolve(
                source,
                documentURL: documentURL
            ),
            candidate.isFileURL
        else {
            // 无法安全解析的本地引用不能读取或进入 HTML。
            throw PortableHTMLExportError.unsafeLocalImageReference(source)
        }

        // 文档所在目录解析所有既有软链接后成为唯一可信根目录。
        let documentDirectory = documentURL.deletingLastPathComponent()
        // realpath 解析所有既有祖先软链接，Foundation 标准化只作为异常回退。
        let resolvedDocumentDirectory =
            Self.canonicalFileURL(documentDirectory)
            ?? documentDirectory.resolvingSymlinksInPath().standardizedFileURL
        // 候选图片同样解析软链接，显式 file URL 也不能借此逃逸。
        let resolvedCandidate =
            Self.canonicalFileURL(candidate)
            ?? candidate.resolvingSymlinksInPath().standardizedFileURL
        // 真实图片必须严格位于真实文档目录之内。
        guard Self.isStrictDescendant(resolvedCandidate, of: resolvedDocumentDirectory) else {
            // 外部文件和出界软链接使用相同安全错误。
            throw PortableHTMLExportError.unsafeLocalImageReference(source)
        }
        // 重复引用直接复用完整 img 标签，避免再次读取和 Base64 编码。
        if let cachedDataURL = dataURLByURL[resolvedCandidate] {
            // 每次仍按当前 Markdown 替代文字生成独立无障碍说明。
            return HTMLExportRenderer.renderEmbeddedImage(dataURL: cachedDataURL, alt: alt)
        }

        // 使用同一文件描述符完成类型、大小和内容读取，消除按路径二次打开窗口。
        let data = try readLocalImage(
            at: resolvedCandidate,
            documentDirectory: resolvedDocumentDirectory,
            source: source
        )
        // ImageIO 只读取图片源元信息并确认至少存在一帧。
        guard
            let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(imageSource) > 0,
            let typeIdentifier = CGImageSourceGetType(imageSource),
            let imageType = UTType(typeIdentifier as String),
            let mimeType = imageType.preferredMIMEType,
            mimeType.lowercased().hasPrefix("image/")
        else {
            // 伪装扩展名或系统无法识别的内容不能嵌入。
            throw PortableHTMLExportError.invalidLocalImage(source)
        }

        // Base64 只来自刚验证的本地图片字节，不能由 Markdown 注入 data 内容。
        let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
        // 生成带安全替代文字和统一响应式样式的本地 img 标签。
        let html = HTMLExportRenderer.renderEmbeddedImage(dataURL: dataURL, alt: alt)
        // 缓存图片数据地址供同一路径的后续引用复用。
        dataURLByURL[resolvedCandidate] = dataURL
        // 只有通过 ImageIO 校验的唯一图片才进入累计预算。
        embeddedImageByteCount += Int64(data.count)
        // 返回不依赖原文件位置的内嵌图片标签。
        return html
    }

    // 使用不跟随任何软链接的同一文件描述符有界读取一张图片。
    private func readLocalImage(
        at candidate: URL,
        documentDirectory: URL,
        source: String
    ) throws -> Data {
        // O_NOFOLLOW 拒绝最终组件竞态，O_NONBLOCK 避免 FIFO 在 fstat 前阻塞。
        let descriptor = candidate.withUnsafeFileSystemRepresentation { path in
            // 无法转换成本地路径时按打开失败处理。
            guard let path else { return Int32(-1) }
            // 只读、禁止继承且不跟随最终组件软链接。
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        // 立即保存 open 的 errno，避免后续 Swift 调用覆盖失败原因。
        let openErrorCode = errno
        // 打开失败时不再使用路径 API 尝试第二次读取。
        guard descriptor >= 0 else {
            // 路径链出现软链接说明原有安全检查后发生变化或引用本身不安全。
            if openErrorCode == ELOOP {
                throw PortableHTMLExportError.unsafeLocalImageReference(source)
            }
            // 缺失、权限拒绝和特殊节点统一给出可行动的资源不可用提示。
            throw PortableHTMLExportError.localImageUnavailable(source)
        }
        // FileHandle 接管描述符并在所有成功或失败分支关闭它。
        let fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // 作用域退出前主动关闭，避免大量图片等待对象析构才释放描述符。
        defer { try? fileHandle.close() }

        // fstat 针对已经打开的同一对象读取类型与字节数。
        var fileStatus = stat()
        // 元数据读取失败时保留即时系统原因。
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            // 复制 errno 对应说明，避免后续 close 改变它。
            let reason = Self.posixReason(errno)
            // 系统级元数据失败按图片读取失败展示。
            throw PortableHTMLExportError.localImageReadFailed(source, reason)
        }
        // 目录、FIFO、设备和 socket 均不得进入图片读取循环。
        guard (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            // 非普通文件统一归入不可用资源。
            throw PortableHTMLExportError.localImageUnavailable(source)
        }

        // F_GETPATH 从已打开对象取得实际路径，识别祖先目录被瞬时替换的情况。
        var openedPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        // 使用 Swift 提供的非可变参数 fcntl 指针重载接收内核路径。
        let pathResult = openedPath.withUnsafeMutableBufferPointer { buffer in
            // 固定非空缓冲区始终提供有效首地址。
            guard let baseAddress = buffer.baseAddress else { return Int32(-1) }
            // 显式转换为原始指针，避免落入不可用的 C 可变参数声明。
            return Darwin.fcntl(
                descriptor,
                F_GETPATH,
                UnsafeMutableRawPointer(baseAddress)
            )
        }
        // 无法确认已打开对象位置时不冒险读取内容。
        guard pathResult == 0 else {
            // 读取即时 errno 形成可展示的系统原因。
            throw PortableHTMLExportError.localImageReadFailed(
                source,
                Self.posixReason(errno)
            )
        }
        // 把内核实际路径转换回标准文件 URL。
        let openedURL = openedPath.withUnsafeBufferPointer { buffer in
            // F_GETPATH 成功保证首地址包含零结尾文件系统路径。
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: false,
                relativeTo: nil
            ).standardizedFileURL
        }
        // 已打开对象仍必须严格位于 realpath 得到的文档目录内。
        guard Self.isStrictDescendant(openedURL, of: documentDirectory) else {
            // 父目录竞态或路径替换都不能越过安全根目录。
            throw PortableHTMLExportError.unsafeLocalImageReference(source)
        }

        // 普通文件的 fstat 大小必须为非负值。
        let fileByteCount = Int64(fileStatus.st_size)
        // 异常负数元数据不能进入容量计算。
        guard fileByteCount >= 0 else {
            // 非法大小视为资源不可用。
            throw PortableHTMLExportError.localImageUnavailable(source)
        }
        // 在分配或读取任何图片内容前拒绝超过单图预算的文件。
        guard fileByteCount <= limits.singleImageByteCount else {
            // 错误携带实际大小和阈值供测试及用户说明。
            throw PortableHTMLExportError.localImageTooLarge(
                source,
                fileByteCount,
                limits.singleImageByteCount
            )
        }
        // 使用溢出安全加法计算 fstat 时刻的预计累计字节数。
        let (projectedByteCount, didOverflow) = embeddedImageByteCount.addingReportingOverflow(
            fileByteCount
        )
        // 在读取前拒绝累计超限或整数溢出。
        guard !didOverflow, projectedByteCount <= limits.totalImageByteCount else {
            // 累计错误只需展示整次导出阈值。
            throw PortableHTMLExportError.totalLocalImagesTooLarge(
                source,
                limits.totalImageByteCount
            )
        }

        // 并发增长时最多读取剩余预算加一字节，硬性限制峰值内存。
        let remainingTotalByteCount = limits.totalImageByteCount - embeddedImageByteCount
        // 单图和累计剩余额度取较小值作为本次硬上限。
        let effectiveByteLimit = min(limits.singleImageByteCount, remainingTotalByteCount)
        // 以固定块循环读取，避免 readToEnd 绕过文件增长保护。
        let data = try readBoundedData(
            from: fileHandle,
            expectedByteCount: fileByteCount,
            maximumByteCount: effectiveByteLimit
        )
        // 文件在 fstat 后增长超过单图阈值时仍给出精确单图错误。
        guard Int64(data.count) <= limits.singleImageByteCount else {
            // 实际读取到阈值加一即可证明超限，无需继续读取其余内容。
            throw PortableHTMLExportError.localImageTooLarge(
                source,
                Int64(data.count),
                limits.singleImageByteCount
            )
        }
        // 文件增长超过累计剩余额度时拒绝当前图片。
        guard Int64(data.count) <= remainingTotalByteCount else {
            // 目标文件尚未写入，因此累计失败不会留下部分结果。
            throw PortableHTMLExportError.totalLocalImagesTooLarge(
                source,
                limits.totalImageByteCount
            )
        }
        // 返回由同一已校验描述符读取的完整图片字节。
        return data
    }

    // 从普通文件描述符最多读取给定上限加一字节。
    private func readBoundedData(
        from fileHandle: FileHandle,
        expectedByteCount: Int64,
        maximumByteCount: Int64
    ) throws -> Data {
        // 预留 fstat 大小但不超过硬上限，降低正常文件扩容次数。
        var data = Data()
        // 当前生产阈值远低于 Int.max，转换前仍执行安全截断。
        let reserveByteCount = min(expectedByteCount, maximumByteCount, Int64(Int.max))
        // 非负预留值可安全转换成本机 Int。
        data.reserveCapacity(Int(max(0, reserveByteCount)))
        // 加一字节用于在不无界读取的前提下识别并发增长。
        let (incrementedStopByteCount, didStopByteCountOverflow) = maximumByteCount.addingReportingOverflow(1)
        // Int64 最大值无法再表示证明超限的额外字节，此时直接采用其自身作为理论上限。
        let stopByteCount = didStopByteCountOverflow ? maximumByteCount : incrementedStopByteCount

        // 每轮读取固定小块并在块间响应任务取消。
        while Int64(data.count) < stopByteCount {
            // 大图读取期间及时停止已被替换的导出任务。
            try Task.checkCancellation()
            // 剩余字节数包含用于识别超限的最后一个字节。
            let remainingByteCount = stopByteCount - Int64(data.count)
            // 单次最多读取六十四 KiB，限制临时块分配。
            let chunkByteCount = Int(min(64 * 1_024, remainingByteCount))
            // FileHandle 始终从同一已校验描述符继续读取。
            guard let chunk = try fileHandle.read(upToCount: chunkByteCount), !chunk.isEmpty else {
                // 空数据表示已经到达普通文件末尾。
                break
            }
            // 追加当前块后再进入下一轮取消和上限检查。
            data.append(chunk)
        }
        // 最后一块完成后也检查取消，避免返回已作废图片。
        try Task.checkCancellation()
        // 返回完整文件或刚好证明超限的上限加一字节。
        return data
    }

    // 将即时 POSIX errno 复制成不会随线程状态变化的中文错误详情。
    private static func posixReason(_ errorCode: Int32) -> String {
        // strerror 返回系统本地化说明，立即构造 Swift 字符串保存副本。
        String(cString: Darwin.strerror(errorCode))
    }

    // 使用 realpath 为既有文件或目录生成真实绝对地址。
    private static func canonicalFileURL(_ url: URL) -> URL? {
        // PATH_MAX 大小的固定缓冲区足以承接 macOS realpath 结果。
        var canonicalPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        // 本地文件系统表示只在闭包作用域内有效。
        let didResolve = url.withUnsafeFileSystemRepresentation { path in
            // 非本地或无法表示的 URL 不能调用 realpath。
            guard let path else { return false }
            // 可变缓冲区保存零结尾真实路径。
            return canonicalPath.withUnsafeMutableBufferPointer { buffer in
                // 固定非空缓冲区应始终提供首地址。
                guard let baseAddress = buffer.baseAddress else { return false }
                // realpath 成功返回同一缓冲区指针。
                return Darwin.realpath(path, baseAddress) != nil
            }
        }
        // 不存在或无法解析的路径交给调用方采用安全回退。
        guard didResolve else { return nil }
        // 将完整真实路径转换为标准文件 URL。
        return canonicalPath.withUnsafeBufferPointer { buffer in
            // realpath 成功保证首地址是有效零结尾字符串。
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: false,
                relativeTo: nil
            ).standardizedFileURL
        }
    }

    // 判断真实候选路径是否严格位于真实文档目录内。
    private static func isStrictDescendant(_ candidate: URL, of directory: URL) -> Bool {
        // 根目录单独保留一个斜杠，其他目录补充分隔符防止相似前缀误命中。
        let directoryPrefix = directory.path == "/" ? "/" : directory.path + "/"
        // 图片路径必须包含完整目录分隔边界且不能等于目录自身。
        return candidate.path.hasPrefix(directoryPrefix)
    }
}

// 将首版支持的 Markdown 块安全映射为内联样式 HTML。
private enum HTMLExportRenderer {
    // 图片渲染策略按完整离线 HTML 与公众号兼容输出分离。
    typealias ImageRenderer = (_ imageURL: URL, _ alt: String) -> String

    // 普通文本和属性值共用严格的 HTML 实体转义。
    static func escapeHTML(_ value: String) -> String {
        // 预留接近原文长度的容量，降低长文档扩容次数。
        var escaped = String()
        escaped.reserveCapacity(value.utf8.count)

        // 逐字符转义所有能改变标签或属性边界的字符。
        for character in value {
            switch character {
            case "&":
                escaped += "&amp;"
            case "<":
                escaped += "&lt;"
            case ">":
                escaped += "&gt;"
            case "\"":
                escaped += "&quot;"
            case "'":
                escaped += "&#39;"
            default:
                escaped.append(character)
            }
        }

        // 返回不会打开新标签或属性的安全文本。
        return escaped
    }

    // 保持公众号既有 HTTP/HTTPS 图片输出，其余协议继续退化为替代文字。
    static func renderWechatImage(_ imageURL: URL, _ alt: String) -> String {
        // 替代文字始终先完成实体转义。
        let safeAlt = escapeHTML(alt)
        // 公众号兼容路径继续只接受原有 HTTP 与 HTTPS 白名单。
        guard let source = safeURLString(imageURL, allowedSchemes: ["http", "https"]) else {
            // data、file 和 javascript 等协议不进入目标属性。
            return safeAlt
        }
        // 远程图片沿用原响应式结构，避免改变已公开的公众号载荷。
        return
            "<img src=\"\(escapeHTML(source))\" alt=\"\(safeAlt)\" style=\"display:block;max-width:100%;height:auto;margin:18px auto;border-radius:6px;\" loading=\"lazy\">"
    }

    // 把完整 HTML 中的远程图片转换为不自动联网的文字或显式链接。
    static func renderOfflineImage(_ imageURL: URL, _ alt: String) -> String {
        // 默认说明保留用户写下的替代文字。
        let safeAlt = escapeHTML(alt.isEmpty ? "图片" : alt)
        // 复用预览策略区分永久阻止的 HTTP 与可显式访问的 HTTPS。
        switch EnhancedImageSourceResolver.remoteImageDecision(for: imageURL.absoluteString) {
        case .blocked:
            // HTTP 和无有效主机的地址仅保留说明，不输出可请求属性。
            return "<span role=\"img\">已阻止远程图片：\(safeAlt)</span>"
        case let .requiresConfirmation(request):
            // HTTPS 只成为用户主动点击的普通链接，绝不成为 img src。
            return
                "<a href=\"\(escapeHTML(request.url.absoluteString))\" target=\"_blank\" rel=\"noopener noreferrer\" style=\"color:#0969da;text-decoration:none;border-bottom:1px solid #54aeff;\">远程图片未自动加载：\(safeAlt)（\(escapeHTML(request.displayHost))）</a>"
        case .notRemote:
            // 没有可用本地上下文或协议非法时只保留可读替代文字。
            return safeAlt
        }
    }

    // 只供已验证本地图片生成 data img 标签。
    static func renderEmbeddedImage(dataURL: String, alt: String) -> String {
        // data URL 来自内部编码，仍统一执行属性转义保持边界稳定。
        let safeSource = escapeHTML(dataURL)
        // 替代文字来自 Markdown，必须严格转义引号和标签边界。
        let safeAlt = escapeHTML(alt)
        // 单文件图片沿用既有响应式尺寸与懒加载表现。
        return
            "<img src=\"\(safeSource)\" alt=\"\(safeAlt)\" style=\"display:block;max-width:100%;height:auto;margin:18px auto;border-radius:6px;\" loading=\"lazy\">"
    }

    // 将 Markdown 文本渲染成不含外层文档标签的 HTML。
    static func renderFragment(
        _ markdown: String,
        template: WechatExportTemplate = .simple,
        imageRenderer: ImageRenderer
    ) -> String {
        // 统一 Windows 和旧 Mac 换行符，保证块识别稳定。
        let normalized =
            markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // 保留空行用于判断段落边界。
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 预留与行数接近的结果容量。
        var blocks: [String] = []
        blocks.reserveCapacity(lines.count)
        // 从首行开始执行单向扫描。
        var index = 0

        // 每轮至少消费一行，避免无效输入导致死循环。
        while index < lines.count {
            // 读取当前原始行。
            let line = lines[index]
            // 空行只分隔块，不输出多余标签。
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            // 优先处理围栏代码，内部 Markdown 不再解释。
            if let fence = fenceMarker(line) {
                // 跳过起始围栏。
                index += 1
                // 收集代码原文并保留换行。
                var codeLines: [String] = []
                // 读取到匹配围栏或文档末尾。
                while index < lines.count, !closesFence(lines[index], marker: fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                // 存在闭合围栏时将其一并消费。
                if index < lines.count { index += 1 }
                // 代码只做实体转义，彻底阻断标签注入。
                let code = escapeHTML(codeLines.joined(separator: "\n"))
                // 使用等宽字体和横向滚动保持代码可读。
                blocks.append("<pre style=\"\(template.codeBlockStyle)\"><code>\(code)</code></pre>")
                continue
            }

            // 表格依赖下一行的分隔符，因此要在普通段落前识别。
            if let table = parseTable(lines: lines, start: index) {
                // 输出带横向滚动容器的表格。
                blocks.append(
                    renderTable(
                        header: table.header,
                        rows: table.rows,
                        template: template,
                        imageRenderer: imageRenderer
                    ))
                // 一次消费完整表格范围。
                index = table.nextIndex
                continue
            }

            // 识别一到六级 ATX 标题。
            if let heading = headingContent(line) {
                // 标题正文允许安全的行内 Markdown。
                let content = renderInline(
                    heading.text,
                    template: template,
                    imageRenderer: imageRenderer
                )
                // 根据级别选择紧凑字号并保持统一中文排版。
                let size = headingFontSize(heading.level)
                // 一级标题居中，其余标题左对齐。
                let alignment = heading.level == 1 ? "center" : "left"
                // 输出语义化标题标签。
                let style = template.headingStyle(level: heading.level, size: size, alignment: alignment)
                // 标题的全部视觉差异都写入当前标签，避免目标编辑器依赖外部 CSS。
                blocks.append("<h\(heading.level) style=\"\(style)\">\(content)</h\(heading.level)>")
                index += 1
                continue
            }

            // 常见分割线输出轻量边框。
            if isDivider(line) {
                blocks.append("<hr style=\"height:1px;margin:28px 0;border:0;background:#d8dee4;\">")
                index += 1
                continue
            }

            // 连续无序项合并为一个列表。
            if unorderedContent(line) != nil {
                // 收集相邻列表项。
                var items: [String] = []
                while index < lines.count, let item = unorderedContent(lines[index]) {
                    items.append(item)
                    index += 1
                }
                // 每个列表项独立解析行内样式。
                let content =
                    items
                    .map {
                        "<li style=\"margin:4px 0;\">\(renderInline($0, template: template, imageRenderer: imageRenderer))</li>"
                    }
                    .joined()
                // 输出语义化无序列表。
                blocks.append("<ul style=\"margin:14px 0;padding-left:1.5em;\">\(content)</ul>")
                continue
            }

            // 连续数字项合并为一个有序列表。
            if orderedContent(line) != nil {
                // 收集相邻数字列表项。
                var items: [String] = []
                while index < lines.count, let item = orderedContent(lines[index]) {
                    items.append(item)
                    index += 1
                }
                // 每个列表项独立解析行内样式。
                let content =
                    items
                    .map {
                        "<li style=\"margin:4px 0;\">\(renderInline($0, template: template, imageRenderer: imageRenderer))</li>"
                    }
                    .joined()
                // 输出语义化有序列表。
                blocks.append("<ol style=\"margin:14px 0;padding-left:1.7em;\">\(content)</ol>")
                continue
            }

            // 连续引用行合并为一个引用块。
            if quoteContent(line) != nil {
                // 收集去掉引用标记后的正文。
                var quoteLines: [String] = []
                while index < lines.count, let quote = quoteContent(lines[index]) {
                    quoteLines.append(quote)
                    index += 1
                }
                // 保留引用内部的显式换行。
                let content =
                    quoteLines
                    .map {
                        renderInline(
                            $0,
                            template: template,
                            imageRenderer: imageRenderer
                        )
                    }
                    .joined(separator: "<br>")
                // 用左边框形成公众号兼容的引用样式。
                blocks.append("<blockquote style=\"\(template.quoteStyle)\">\(content)</blockquote>")
                continue
            }

            // 其他连续内容归并为普通段落。
            var paragraphLines = [line]
            // 首行已经消费，继续查看后续块边界。
            index += 1
            // 只合并不属于新块的软换行文本。
            while index < lines.count, !startsBlock(lines: lines, at: index) {
                paragraphLines.append(lines[index])
                index += 1
            }
            // 普通软换行按空格连接，避免意外挤成一个单词。
            let paragraph = paragraphLines.joined(separator: " ")
            // 输出支持行内样式的正文段落。
            blocks.append(
                "<p style=\"\(template.paragraphStyle)\">\(renderInline(paragraph, template: template, imageRenderer: imageRenderer))</p>"
            )
        }

        // 按原文顺序输出块，并保留可读换行。
        return blocks.joined(separator: "\n")
    }

    // 通过系统 Markdown 解析器读取安全的行内语义。
    private static func renderInline(
        _ source: String,
        template: WechatExportTemplate,
        imageRenderer: ImageRenderer
    ) -> String {
        // 仅启用行内语法，避免输入片段改变外层块结构。
        guard
            let attributed = try? AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        else {
            // 解析失败时完整转义原文，保证内容仍可导出。
            return escapeHTML(source)
        }

        // 预留近似原文长度，减少连续拼接扩容。
        var html = String()
        html.reserveCapacity(source.utf8.count)

        // 按系统解析得到的行内属性逐段输出。
        for run in attributed.runs {
            // 读取当前属性片段的可见文本。
            let text = String(attributed[run.range].characters)
            // 可见文本始终先做实体转义。
            let safeText = escapeHTML(text)

            // 图片由当前导出目标的独立策略生成完整安全标签或占位。
            if let imageURL = run.imageURL {
                // 策略接收原始替代文字并负责属性转义，避免双重实体编码。
                html += imageRenderer(imageURL, text)
                continue
            }

            // 从安全纯文本开始叠加有限的语义标签。
            var piece = safeText
            // 代码优先使用等宽样式，内部不解释其他 Markdown。
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece = "<code style=\"\(template.inlineCodeStyle)\">\(piece)</code>"
            } else {
                // 加粗语义映射为 strong。
                if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                    piece = "<strong style=\"font-weight:700;\">\(piece)</strong>"
                }
                // 斜体语义映射为 em。
                if run.inlinePresentationIntent?.contains(.emphasized) == true {
                    piece = "<em style=\"font-style:italic;\">\(piece)</em>"
                }
                // 删除线语义映射为 del。
                if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                    piece = "<del style=\"color:#656d76;\">\(piece)</del>"
                }
            }

            // 链接只接受常见安全协议，其他协议退化为普通文本。
            if let link = run.link,
                let target = safeURLString(link, allowedSchemes: ["http", "https", "mailto"])
            {
                // 新窗口链接增加隔离属性，避免反向控制来源页面。
                piece =
                    "<a href=\"\(escapeHTML(target))\" target=\"_blank\" rel=\"noopener noreferrer\" style=\"\(template.linkStyle)\">\(piece)</a>"
            }

            // 将当前安全片段追加到结果。
            html += piece
        }

        // 返回只含受控标签的行内 HTML。
        return html
    }

    // 只允许明确白名单中的 URL 协议。
    private static func safeURLString(_ url: URL, allowedSchemes: Set<String>) -> String? {
        // 无协议的相对地址不进入可独立传播的导出文档。
        guard let scheme = url.scheme?.lowercased() else { return nil }
        // 拒绝 javascript、data、file 等主动或本地协议。
        guard allowedSchemes.contains(scheme) else { return nil }
        // URL 类型已经完成基础解析，返回其规范字符串。
        return url.absoluteString
    }

    // 识别一到六级标题并返回正文。
    private static func headingContent(_ line: String) -> (level: Int, text: String)? {
        // 容忍标题前的普通空白。
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 统计开头井号数量。
        let level = trimmed.prefix(while: { $0 == "#" }).count
        // 只接受一到六级且标记后存在空格的标题。
        guard (1...6).contains(level), trimmed.dropFirst(level).first == " " else { return nil }
        // 去掉标记和首个空格。
        return (level, String(trimmed.dropFirst(level + 1)))
    }

    // 返回标题级别对应的像素字号。
    private static func headingFontSize(_ level: Int) -> Int {
        // 首三级形成明显层级，后三级保持正文附近尺寸。
        switch level {
        case 1: return 30
        case 2: return 24
        case 3: return 20
        case 4: return 18
        default: return 17
        }
    }

    // 识别围栏标记，语言提示不会进入 HTML 属性。
    private static func fenceMarker(_ line: String) -> String? {
        // 忽略围栏两侧空白。
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 支持常见反引号围栏。
        if trimmed.hasPrefix("```") { return "```" }
        // 同时支持波浪线围栏。
        if trimmed.hasPrefix("~~~") { return "~~~" }
        // 其他行不是代码围栏。
        return nil
    }

    // 判断当前行是否关闭指定围栏。
    private static func closesFence(_ line: String, marker: String) -> Bool {
        // 只要求去掉前导空白后以同类标记开始。
        line.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
    }

    // 提取无序列表正文。
    private static func unorderedContent(_ line: String) -> String? {
        // 去掉首尾空白以兼容轻量缩进。
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 标记后必须存在一个空格。
        guard trimmed.count >= 2,
            let marker = trimmed.first,
            "-*+".contains(marker),
            trimmed.dropFirst().first == " "
        else { return nil }
        // 去掉标记和首个空格。
        return String(trimmed.dropFirst(2))
    }

    // 提取数字列表正文。
    private static func orderedContent(_ line: String) -> String? {
        // 去掉首尾空白以兼容轻量缩进。
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 找到数字后的第一个点号。
        guard let dot = trimmed.firstIndex(of: ".") else { return nil }
        // 点号前必须全部为数字且不能为空。
        let number = trimmed[..<dot]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        // 点号后必须有一个空格。
        let afterDot = trimmed.index(after: dot)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        // 返回空格后的正文。
        return String(trimmed[trimmed.index(after: afterDot)...])
    }

    // 提取引用正文。
    private static func quoteContent(_ line: String) -> String? {
        // 去掉前导空白后判断引用标记。
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 引用必须以大于号开始。
        guard trimmed.first == ">" else { return nil }
        // 去掉引用标记。
        let content = trimmed.dropFirst()
        // 最多再去掉一个分隔空格。
        return String(content.first == " " ? content.dropFirst() : content[...])
    }

    // 判断是否为三个以上相同标记组成的分割线。
    private static func isDivider(_ line: String) -> Bool {
        // 忽略标记之间的普通空白。
        let compact = line.filter { !$0.isWhitespace }
        // 只接受 Markdown 常用的三类标记。
        guard compact.count >= 3,
            let marker = compact.first,
            "-*_".contains(marker)
        else { return false }
        // 所有字符必须使用同一种标记。
        return compact.allSatisfy { $0 == marker }
    }

    // 判断指定行是否开启一个新块。
    private static func startsBlock(lines: [String], at index: Int) -> Bool {
        // 越界表示当前段落自然结束。
        guard index < lines.count else { return true }
        // 读取待判断行。
        let line = lines[index]
        // 空行和所有已支持块都会结束当前段落。
        return line.trimmingCharacters(in: .whitespaces).isEmpty || fenceMarker(line) != nil
            || parseTable(lines: lines, start: index) != nil || headingContent(line) != nil || isDivider(line)
            || unorderedContent(line) != nil || orderedContent(line) != nil || quoteContent(line) != nil
    }

    // 保存一次表格解析结果及下一行位置。
    private struct ParsedTable {
        // 首行作为表头。
        let header: [String]
        // 分隔行后的内容作为表体。
        let rows: [[String]]
        // 调用方从该位置继续扫描。
        let nextIndex: Int
    }

    // 识别最小 GitHub 风格表格。
    private static func parseTable(lines: [String], start: Int) -> ParsedTable? {
        // 表格至少需要表头和分隔行。
        guard start + 1 < lines.count else { return nil }
        // 表头必须能拆出至少两列。
        guard let header = tableCells(lines[start]), header.count >= 2 else { return nil }
        // 第二行的每列都必须是合法分隔符。
        guard let separators = tableCells(lines[start + 1]),
            separators.count == header.count,
            separators.allSatisfy(isTableSeparator)
        else { return nil }

        // 从分隔行之后开始读取表体。
        var index = start + 2
        // 保存所有列数匹配的连续数据行。
        var rows: [[String]] = []
        while index < lines.count,
            !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
            let cells = tableCells(lines[index]),
            cells.count == header.count
        {
            rows.append(cells)
            index += 1
        }

        // 返回完整表格和消费边界。
        return ParsedTable(header: header, rows: rows, nextIndex: index)
    }

    // 将一行按未转义的竖线拆成单元格。
    private static func tableCells(_ line: String) -> [String]? {
        // 没有竖线的行不可能是多列表格。
        guard line.contains("|") else { return nil }
        // 去掉首尾空白后再处理可选的边界竖线。
        var content = line.trimmingCharacters(in: .whitespaces)
        // 去掉可选的起始边界。
        if content.first == "|" { content.removeFirst() }
        // 去掉可选的结束边界。
        if content.last == "|" { content.removeLast() }

        // 保存拆分后的单元格。
        var cells: [String] = []
        // 收集当前单元格字符。
        var current = String()
        // 记录反斜杠是否在转义下一个字符。
        var escaping = false

        // 单次扫描避免对大表格反复正则匹配。
        for character in content {
            // 转义状态下原样加入当前字符。
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            // 反斜杠只负责转义下一字符，不进入结果。
            if character == "\\" {
                escaping = true
                continue
            }
            // 未转义竖线结束当前单元格。
            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            // 普通字符加入当前单元格。
            current.append(character)
        }

        // 行尾单独的反斜杠按可见字符保留。
        if escaping { current.append("\\") }
        // 保存最后一个单元格。
        cells.append(current.trimmingCharacters(in: .whitespaces))
        // 只有确实拆成多列时才视为表格行。
        return cells.count >= 2 ? cells : nil
    }

    // 验证表格分隔单元格，例如 ---、:---:。
    private static func isTableSeparator(_ cell: String) -> Bool {
        // 去掉对齐标记和周围空白。
        let marker = cell.trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        // 至少需要三个连字符。
        guard marker.count >= 3 else { return false }
        // 分隔符中不能混入其他字符。
        return marker.allSatisfy { $0 == "-" }
    }

    // 输出带内联样式的表格。
    private static func renderTable(
        header: [String],
        rows: [[String]],
        template: WechatExportTemplate,
        imageRenderer: ImageRenderer
    ) -> String {
        // 表头使用加粗和浅灰背景。
        let headerHTML =
            header
            .map {
                "<th style=\"\(template.tableHeaderStyle)\">\(renderInline($0, template: template, imageRenderer: imageRenderer))</th>"
            }
            .joined()
        // 每个表体单元格独立渲染行内样式。
        let rowsHTML =
            rows
            .map { row in
                let cells =
                    row
                    .map {
                        "<td style=\"\(template.tableCellStyle)\">\(renderInline($0, template: template, imageRenderer: imageRenderer))</td>"
                    }
                    .joined()
                return "<tr>\(cells)</tr>"
            }
            .joined()
        // 横向滚动容器避免窄屏表格撑破正文。
        return
            "<div style=\"max-width:100%;margin:18px 0;overflow-x:auto;\"><table style=\"\(template.tableStyle)\"><thead><tr>\(headerHTML)</tr></thead><tbody>\(rowsHTML)</tbody></table></div>"
    }
}

// 为无需启动 GUI 的导出逻辑提供快速自检。
enum ExportSupportSelfCheck {
    // 返回所有失败项；空数组表示自检通过。
    static func run() -> [String] {
        // 构造覆盖标签、属性、危险协议、表格和代码的输入。
        let markdown = """
            # <script>alert("x")</script> & '标题'

            **加粗**、[安全链接](https://example.com?a=1&b=2) 与 [危险链接](javascript:alert(1))。

            ![安全图片](https://example.com/image.png)
            ![危险图片](data:text/html;base64,PHNjcmlwdD4=)

            > 引用内容与 `行内代码`

            | 名称 | 内容 |
            | --- | --- |
            | A | <b>不能注入</b> |

            ```html
            <img src=x onerror=alert(1)>
            ```
            """
        // 生成完整文档用于安全断言。
        let document = ExportSupport.htmlDocument(markdown: markdown, title: "<不安全标题>")
        // 生成默认简洁模板，验证旧调用仍然可用。
        let simple = ExportSupport.wechatHTML(markdown: markdown)
        // 生成技术文模板，验证菜单可选择的第二套风格。
        let technical = ExportSupport.wechatHTML(markdown: markdown, template: .technical)
        // 生成双格式载荷，验证复制时不会丢失纯文本回退。
        let payload = ExportSupport.wechatPayload(markdown: markdown, template: .technical)
        // 收集所有失败原因，便于一次定位多项问题。
        var failures: [String] = []

        // 原始脚本标签绝不能进入导出结果。
        if document.contains("<script>") { failures.append("原始 script 标签未转义") }
        // 标题标签中的用户文本必须完成实体转义。
        if !document.contains("<title>&lt;不安全标题&gt;</title>") { failures.append("文档标题未转义") }
        // 正文中的尖括号必须以实体形式保留。
        if !document.contains("&lt;script&gt;") { failures.append("正文标签未转义") }
        // 安全链接应保留可点击结构。
        if !document.contains("href=\"https://example.com?a=1&amp;b=2\"") { failures.append("安全链接未输出") }
        // javascript 协议绝不能成为 href。
        if document.contains("href=\"javascript:") { failures.append("危险链接协议未过滤") }
        // 用户输入的 data 图片绝不能成为 src。
        if document.contains("src=\"data:") { failures.append("危险图片协议未过滤") }
        // 两套公众号模板必须执行相同的危险协议过滤。
        for (name, html) in [("简洁", simple), ("技术文", technical)] {
            // javascript 和 data 协议都不能进入目标属性。
            if html.contains("href=\"javascript:") || html.contains("src=\"data:") {
                failures.append("\(name)模板危险协议未过滤")
            }
        }
        // 完整 HTML 的 HTTPS 图片只能保留显式链接，不能自动加载。
        if document.contains("src=\"https://example.com/image.png\"")
            || !document.contains("href=\"https://example.com/image.png\"")
        {
            failures.append("完整 HTML 远程图片未保持离线")
        }
        // 公众号载荷继续保留既有远程图片结构，避免兼容性回退。
        if !simple.contains("src=\"https://example.com/image.png\"")
            || !technical.contains("src=\"https://example.com/image.png\"")
        {
            failures.append("公众号远程图片兼容性回退")
        }
        // 表格应输出关键语义标签。
        if !document.contains("<table ") || !document.contains("<thead>") { failures.append("表格结构缺失") }
        // 完整文档必须具有基本 HTML 壳层和 CSP。
        if !document.contains("<!doctype html>") || !document.contains("Content-Security-Policy") {
            failures.append("完整文档壳层缺失")
        }
        // 完整文档 CSP 只允许内部 data 图片，不能授予 HTTP 或 HTTPS 图片权限。
        if !document.contains("img-src data:") || document.contains("img-src https:")
            || document.contains("img-src http:")
        {
            failures.append("完整文档 CSP 允许网络图片")
        }
        // 公众号输出必须是内联样式片段而非完整页面。
        if !simple.contains("<section style=") || simple.contains("<!doctype html>") { failures.append("公众号片段结构错误") }
        // 默认模板必须继续使用首版浅色代码块。
        if !simple.contains("background:#f3f4f6") { failures.append("简洁模板默认样式不兼容") }
        // 技术文模板必须使用深色代码块形成肉眼可见的区别。
        if !technical.contains("background:#0d1117") { failures.append("技术文代码样式缺失") }
        // 技术文模板必须对标题和引用使用青绿色强调色。
        if !technical.contains("color:#0f766e") || !technical.contains("border-left:4px solid #14b8a6") {
            failures.append("技术文标题或引用样式缺失")
        }
        // 两套模板必须真的输出不同 HTML，避免菜单只切换名称。
        if simple == technical { failures.append("两套公众号模板没有关键差异") }
        // 标题、引用、代码和表格都必须带内联样式，方便公众号保留排版。
        for marker in ["<h1 style=", "<blockquote style=", "<pre style=", "<table style=", "<th style=", "<td style="] {
            // 任一关键结构缺少样式都视为粘贴兼容性退化。
            if !simple.contains(marker) || !technical.contains(marker) {
                failures.append("关键结构缺少内联样式：\(marker)")
            }
        }
        // 公众号片段不允许依赖 style 标签或外部样式表。
        if simple.contains("<style") || technical.contains("<style") {
            failures.append("公众号模板包含非内联样式")
        }
        // HTML 载荷必须与直接渲染 API 完全一致。
        if payload.html != technical { failures.append("双格式载荷 HTML 不一致") }
        // 纯文本载荷必须完整保留原始 Markdown 结构和内容。
        if payload.plainText != markdown { failures.append("双格式载荷纯文本不完整") }
        // 模板枚举必须提供稳定的两个中文展示名。
        if WechatExportTemplate.allCases.map(\.displayName) != ["简洁", "技术文"] {
            failures.append("公众号模板展示名错误")
        }

        // 返回可由测试或命令行入口判断的结果。
        return failures
    }
}

#if EXPORT_SUPPORT_SELF_CHECK
    // 允许单独编译本文件并执行无界面自检。
    @main
    private enum ExportSupportSelfCheckMain {
        // 执行自检并用进程状态表达结果。
        static func main() {
            // 获取全部失败原因。
            let failures = ExportSupportSelfCheck.run()
            // 任一断言失败都终止进程并输出细节。
            precondition(failures.isEmpty, failures.joined(separator: "；"))
            // 输出稳定成功标记供脚本和人工确认。
            print("ExportSupportSelfCheck: OK")
        }
    }
#endif
