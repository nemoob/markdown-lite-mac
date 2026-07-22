import AppKit
import Foundation
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

// 提供不依赖第三方库的 HTML 导出与公众号复制能力。
enum ExportSupport {
    // 生成可直接在浏览器打开的完整 HTML 文档。
    static func htmlDocument(markdown: String, title: String) -> String {
        // 所有正文都先经过安全渲染，原始 HTML 不会原样进入结果。
        let body = HTMLExportRenderer.renderFragment(markdown)
        // 标题进入标签前统一转义，避免关闭 title 后注入标签。
        let safeTitle = HTMLExportRenderer.escapeHTML(title)

        // 使用内联样式保证单文件可用，同时用 CSP 限制脚本和危险资源。
        return """
            <!doctype html>
            <html lang="zh-CN">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
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

    // 生成适合粘贴到公众号编辑器的内联样式 HTML 片段。
    static func wechatHTML(
        markdown: String,
        template: WechatExportTemplate = .simple
    ) -> String {
        // 公众号会清除外部样式，因此正文中的每个关键标签都使用内联样式。
        let body = HTMLExportRenderer.renderFragment(markdown, template: template)
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

    // 弹出原生保存面板并保存 HTML；取消时返回 nil。
    @MainActor
    static func presentHTMLSavePanel(
        markdown: String,
        title: String,
        suggestedFilename: String
    ) throws -> URL? {
        // 配置系统保存面板，沿用原生文件访问和覆盖确认。
        let panel = NSSavePanel()
        // 仅允许导出标准 HTML 文件。
        panel.allowedContentTypes = [.html]
        // 允许用户直接在面板内新建目标文件夹。
        panel.canCreateDirectories = true
        // 保证默认文件名具有 html 扩展名。
        panel.nameFieldStringValue = normalizedHTMLFilename(suggestedFilename)
        // 用户取消时不创建任何文件。
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // 用户确认后复用原子写入 API。
        try writeHTML(markdown: markdown, title: title, to: url)
        // 返回实际地址供状态栏反馈。
        return url
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

// 将首版支持的 Markdown 块安全映射为内联样式 HTML。
private enum HTMLExportRenderer {
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

    // 将 Markdown 文本渲染成不含外层文档标签的 HTML。
    static func renderFragment(
        _ markdown: String,
        template: WechatExportTemplate = .simple
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
                blocks.append(renderTable(header: table.header, rows: table.rows, template: template))
                // 一次消费完整表格范围。
                index = table.nextIndex
                continue
            }

            // 识别一到六级 ATX 标题。
            if let heading = headingContent(line) {
                // 标题正文允许安全的行内 Markdown。
                let content = renderInline(heading.text, template: template)
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
                    .map { "<li style=\"margin:4px 0;\">\(renderInline($0, template: template))</li>" }
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
                    .map { "<li style=\"margin:4px 0;\">\(renderInline($0, template: template))</li>" }
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
                    .map { renderInline($0, template: template) }
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
            blocks.append("<p style=\"\(template.paragraphStyle)\">\(renderInline(paragraph, template: template))</p>")
        }

        // 按原文顺序输出块，并保留可读换行。
        return blocks.joined(separator: "\n")
    }

    // 通过系统 Markdown 解析器读取安全的行内语义。
    private static func renderInline(
        _ source: String,
        template: WechatExportTemplate
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

            // 图片只接受 http 或 https 地址，危险协议退化为替代文字。
            if let imageURL = run.imageURL {
                if let source = safeURLString(imageURL, allowedSchemes: ["http", "https"]) {
                    // 图片地址和替代文字都经过属性转义。
                    html +=
                        "<img src=\"\(escapeHTML(source))\" alt=\"\(safeText)\" style=\"display:block;max-width:100%;height:auto;margin:18px auto;border-radius:6px;\" loading=\"lazy\">"
                } else {
                    // 不安全图片仅保留可见说明，不发起资源请求。
                    html += safeText
                }
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
        template: WechatExportTemplate
    ) -> String {
        // 表头使用加粗和浅灰背景。
        let headerHTML =
            header
            .map { "<th style=\"\(template.tableHeaderStyle)\">\(renderInline($0, template: template))</th>" }
            .joined()
        // 每个表体单元格独立渲染行内样式。
        let rowsHTML =
            rows
            .map { row in
                let cells =
                    row
                    .map { "<td style=\"\(template.tableCellStyle)\">\(renderInline($0, template: template))</td>" }
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
        // data 图片绝不能成为 src。
        if document.contains("src=\"data:") { failures.append("危险图片协议未过滤") }
        // 两套公众号模板必须执行相同的危险协议过滤。
        for (name, html) in [("简洁", simple), ("技术文", technical)] {
            // javascript 和 data 协议都不能进入目标属性。
            if html.contains("href=\"javascript:") || html.contains("src=\"data:") {
                failures.append("\(name)模板危险协议未过滤")
            }
        }
        // 合法远程图片应保留响应式结构。
        if !document.contains("src=\"https://example.com/image.png\"") { failures.append("安全图片未输出") }
        // 表格应输出关键语义标签。
        if !document.contains("<table ") || !document.contains("<thead>") { failures.append("表格结构缺失") }
        // 完整文档必须具有基本 HTML 壳层和 CSP。
        if !document.contains("<!doctype html>") || !document.contains("Content-Security-Policy") {
            failures.append("完整文档壳层缺失")
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
