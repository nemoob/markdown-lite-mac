import AppKit
import Darwin
import Dispatch
import Foundation
import ImageIO
import SwiftUI

// 表示增强预览支持的任务状态。
enum EnhancedTaskState: Equatable, Sendable {
    // 未完成任务对应 GFM 的空复选框。
    case unchecked
    // 已完成任务对应 GFM 的选中复选框。
    case checked
}

// 保存增强列表中的单个条目。
struct EnhancedListItem: Equatable, Sendable {
    // 保存去掉列表标记和任务标记后的正文。
    let text: String
    // 普通列表项为 nil，任务列表项保存勾选状态。
    let taskState: EnhancedTaskState?
}

// 表示 GFM 表格列的对齐方式。
enum EnhancedTableAlignment: Equatable, Sendable {
    // 未声明对齐时按 Markdown 默认左对齐。
    case leading
    // 两侧冒号声明居中对齐。
    case center
    // 右侧冒号声明右对齐。
    case trailing
}

// 表示增强 Markdown 预览中的一个可独立渲染块。
struct EnhancedPreviewBlock: Identifiable, Equatable, Sendable {
    // 每类块只保存渲染所需的数据，避免预览层再次解析原文。
    enum Kind: Equatable, Sendable {
        // 标题保存一到六级层级及其行内 Markdown 正文。
        case heading(level: Int, text: String)
        // 段落保存合并软换行后的正文。
        case paragraph(String)
        // 无序列表保存普通项或任务项。
        case unorderedList([EnhancedListItem])
        // 有序列表额外保存原文起始编号。
        case orderedList(start: Int, items: [EnhancedListItem])
        // 引用保留多行正文，交给系统行内解析器渲染。
        case quote(String)
        // 围栏代码保存可选语言和原始代码。
        case code(language: String?, text: String)
        // 分割线不需要附加内容。
        case divider
        // 独占一行的图片保存替代文字、地址和可选标题。
        case image(alt: String, source: String, title: String?)
        // GFM 表格保存表头、对齐声明和所有数据行。
        case table(headers: [String], alignments: [EnhancedTableAlignment], rows: [[String]])
    }

    // 使用块起始行号作为稳定标识，降低 SwiftUI 更新时的视图抖动。
    let id: Int
    // 保存已经识别的具体块类型。
    let kind: Kind
}

// 使用一次线性扫描把 Markdown 转换为增强预览块。
enum EnhancedMarkdownParser {
    // 保存围栏字符、长度和可选语言，供闭合判断复用。
    private struct Fence {
        // 支持反引号和波浪号两种 GFM 围栏字符。
        let marker: Character
        // 闭合围栏至少需要与起始围栏等长。
        let length: Int
        // 起始围栏后第一段文字作为语言提示。
        let language: String?
    }

    // 保存解析完成的独占行图片信息。
    private struct ImageInfo {
        // 图片加载失败时仍展示替代文字。
        let alt: String
        // 图片地址保持原文，避免解析层擅自改写相对路径。
        let source: String
        // 可选标题用于预览中的辅助说明。
        let title: String?
    }

    // 将 Markdown 拆成可按块懒加载渲染的数据。
    static func parse(_ markdown: String) -> [EnhancedPreviewBlock] {
        // 已过期的 detached 任务在任何整文扫描前直接退出。
        guard !Task.isCancelled else { return [] }
        // 仅在必要时统一 Windows 和旧式 Mac 换行，常见输入不产生副本。
        let normalized: String
        // 含回车的文档需要转换为单一换行格式。
        if markdown.utf8.contains(13) {
            // 先处理 Windows 双字符换行，再处理残余单回车。
            normalized =
                markdown
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        } else {
            // 已是 Unix 换行时直接复用原字符串存储。
            normalized = markdown
        }

        // 换行规范化期间收到取消时不继续拆分和解析全文。
        guard !Task.isCancelled else { return [] }
        // 使用 Substring 保留对原文存储的共享，识别阶段避免逐行复制。
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        // 整文拆分完成后再次响应取消，避免继续占用旧预览的 CPU。
        guard !Task.isCancelled else { return [] }
        // 预留常见块数量，降低长文档结果数组扩容次数。
        var blocks: [EnhancedPreviewBlock] = []
        // 块数量通常小于行数，因此先按一半行数预留且不设过大的固定值。
        blocks.reserveCapacity((lines.count + 1) / 2)
        // 从文档首行开始扫描。
        var index = 0

        // 每轮至少消费一行，整体识别复杂度保持线性。
        while index < lines.count {
            // 新输入取消旧解析时立即丢弃不完整块并停止主扫描。
            guard !Task.isCancelled else { return [] }
            // 读取当前行的共享切片。
            let line = lines[index]
            // 空白行只负责结束前一个块。
            if isBlank(line) {
                // 跳过空白分隔行。
                index += 1
                // 继续识别下一个非空块。
                continue
            }

            // 围栏代码优先识别，避免内部 Markdown 被解释成其他块。
            if let fence = openingFence(line) {
                // 保存起始行作为稳定块 ID。
                let start = index
                // 收集围栏内部原始行。
                var codeLines: [Substring] = []
                // 起始围栏自身不属于代码正文。
                index += 1
                // 扫描到匹配闭合围栏或文档结尾。
                while !Task.isCancelled, index < lines.count, !isClosingFence(lines[index], opening: fence) {
                    // 保留每行原始空白供代码预览使用。
                    codeLines.append(lines[index])
                    // 移动到下一行代码。
                    index += 1
                }
                // 取消时不再拼接可能很大的代码正文。
                guard !Task.isCancelled else { return [] }
                // 存在闭合围栏时跳过闭合行。
                if index < lines.count {
                    // 闭合围栏不生成额外块。
                    index += 1
                }
                // 仅在生成模型时把代码切片合并为独立字符串。
                let code = codeLines.joined(separator: "\n")
                // 输出带语言提示的代码块。
                blocks.append(.init(id: start, kind: .code(language: fence.language, text: code)))
                // 当前代码块已完整消费。
                continue
            }

            // 识别一到六级 ATX 标题。
            if let heading = headingContent(line) {
                // 标题正文继续支持粗体、斜体和链接等行内语法。
                blocks.append(.init(id: index, kind: .heading(level: heading.level, text: heading.text)))
                // 标题只消费当前一行。
                index += 1
                // 继续识别后续块。
                continue
            }

            // 分割线必须先于减号列表识别，避免 `---` 变成列表项。
            if isDivider(line) {
                // 输出无附加数据的原生分割线块。
                blocks.append(.init(id: index, kind: .divider))
                // 分割线只消费当前一行。
                index += 1
                // 继续识别后续块。
                continue
            }

            // 表头行和紧随其后的对齐声明共同构成 GFM 表格起点。
            if let table = tableStart(lines: lines, at: index) {
                // 保存表格起始行作为稳定块 ID。
                let start = index
                // 对齐声明已经由 tableStart 验证。
                let alignments = table.alignments
                // 表头决定最终列数。
                let headers = table.headers
                // 跳过表头和对齐声明两行。
                index += 2
                // 收集后续非空表格数据行。
                var rows: [[String]] = []
                // 连续含管道符的行属于当前表格。
                while !Task.isCancelled, index < lines.count, !isBlank(lines[index]), lines[index].contains("|") {
                    // 按表头列数补齐或裁剪当前数据行。
                    guard let cells = tableCells(lines[index]) else { break }
                    // 保存标准化后的表格行。
                    rows.append(normalizeTableRow(cells, columnCount: headers.count))
                    // 消费当前数据行。
                    index += 1
                }
                // 取消时不再组装可能很大的表格块。
                guard !Task.isCancelled else { return [] }
                // 输出完整 GFM 表格块。
                blocks.append(
                    .init(
                        id: start,
                        kind: .table(headers: headers, alignments: alignments, rows: rows)
                    ))
                // 当前表格已经完整消费。
                continue
            }

            // 独占一行的图片生成可异步加载的图片块。
            if let image = imageInfo(line) {
                // 保留替代文字、原始地址和可选标题。
                blocks.append(
                    .init(
                        id: index,
                        kind: .image(alt: image.alt, source: image.source, title: image.title)
                    ))
                // 图片只消费当前一行。
                index += 1
                // 继续识别后续块。
                continue
            }

            // 连续无序项组成一个列表块。
            if let firstContent = unorderedContent(line) {
                // 保存列表起始行作为稳定块 ID。
                let start = index
                // 复用首次识别结果，避免同一首行再次解析和复制正文。
                var items = [listItem(from: firstContent)]
                // 首个无序项已经写入结果，继续扫描剩余同类行。
                index += 1
                // 后续同类无序项保持在同一列表中。
                while !Task.isCancelled, index < lines.count, let content = unorderedContent(lines[index]) {
                    // 去掉可选任务标记并保存勾选状态。
                    items.append(listItem(from: content))
                    // 消费当前列表行。
                    index += 1
                }
                // 取消时丢弃未完成的长列表。
                guard !Task.isCancelled else { return [] }
                // 输出完整无序列表。
                blocks.append(.init(id: start, kind: .unorderedList(items)))
                // 当前列表已经完整消费。
                continue
            }

            // 连续数字项组成一个有序列表块。
            if let firstItem = orderedContent(line) {
                // 保存列表起始行作为稳定块 ID。
                let start = index
                // 原文首个编号用于正确显示非 1 起始列表。
                let startingNumber = firstItem.number
                // 复用首次识别结果，避免同一首行再次解析编号和复制正文。
                var items = [listItem(from: firstItem.text)]
                // 首个有序项已经写入结果，继续扫描剩余同类行。
                index += 1
                // 后续同类有序项保持在同一列表中。
                while !Task.isCancelled, index < lines.count, let content = orderedContent(lines[index]) {
                    // 去掉可选任务标记并保存勾选状态。
                    items.append(listItem(from: content.text))
                    // 消费当前列表行。
                    index += 1
                }
                // 取消时丢弃未完成的长列表。
                guard !Task.isCancelled else { return [] }
                // 输出带真实起始编号的有序列表。
                blocks.append(.init(id: start, kind: .orderedList(start: startingNumber, items: items)))
                // 当前列表已经完整消费。
                continue
            }

            // 连续引用行组成一个引用块。
            if let firstContent = quoteContent(line) {
                // 保存引用起始行作为稳定块 ID。
                let start = index
                // 复用首次识别结果，避免同一首行再次解析和复制正文。
                var quoteLines = [firstContent]
                // 首个引用行已经写入结果，继续扫描剩余连续引用。
                index += 1
                // 后续连续大于号行属于同一引用块。
                while !Task.isCancelled, index < lines.count, let content = quoteContent(lines[index]) {
                    // 保留引用内部换行以维持可读性。
                    quoteLines.append(content)
                    // 消费当前引用行。
                    index += 1
                }
                // 取消时不再拼接可能很大的引用正文。
                guard !Task.isCancelled else { return [] }
                // 输出完整引用块。
                blocks.append(.init(id: start, kind: .quote(quoteLines.joined(separator: "\n"))))
                // 当前引用已经完整消费。
                continue
            }

            // 剩余连续普通文本合并成一个段落。
            let start = index
            // 当前行已经完整通过全部块分类，直接作为段落首行复用。
            var paragraphLines = [String(line)]
            // 首行已经写入结果，后续扫描无需再次执行同一组分类函数。
            index += 1
            // 从第二行起扫描到空行或下一个明确块起点。
            while !Task.isCancelled, index < lines.count, !isBlank(lines[index]),
                !startsBlock(lines: lines, at: index)
            {
                // 普通行只在形成最终模型时复制。
                paragraphLines.append(String(lines[index]))
                // 消费当前段落行。
                index += 1
            }
            // 取消时不再拼接可能很大的段落正文。
            guard !Task.isCancelled else { return [] }
            // 软换行按空格合并，符合常用 Markdown 显示行为。
            blocks.append(.init(id: start, kind: .paragraph(paragraphLines.joined(separator: " "))))
        }

        // 返回前最后响应一次取消，避免边界竞态发布已经过期的完整结果。
        guard !Task.isCancelled else { return [] }
        // 返回按原文顺序排列的增强块。
        return blocks
    }

    // 判断段落扫描是否遇到新的明确块起点。
    private static func startsBlock(lines: [Substring], at index: Int) -> Bool {
        // 当前调用只处理有效行号。
        let line = lines[index]
        // 空行始终结束当前段落。
        if isBlank(line) {
            // 返回明确块边界。
            return true
        }
        // 围栏、标题和分割线始终开始新块。
        if openingFence(line) != nil || headingContent(line) != nil || isDivider(line) {
            // 返回明确块边界。
            return true
        }
        // 图片、列表和引用始终开始新块。
        if imageInfo(line) != nil || unorderedContent(line) != nil || orderedContent(line) != nil
            || quoteContent(line) != nil
        {
            // 返回明确块边界。
            return true
        }
        // 表格需要当前行与下一行共同确认。
        if tableStart(lines: lines, at: index) != nil {
            // 返回明确块边界。
            return true
        }
        // 普通文本继续归入当前段落。
        return false
    }

    // 判断一行是否只含空格或制表符。
    private static func isBlank(_ line: Substring) -> Bool {
        // 不创建修剪后的字符串即可完成空白判断。
        line.allSatisfy { character in
            // 超长空白行扫描期间也应及时响应旧预览取消。
            guard !Task.isCancelled else { return false }
            // Markdown 块边界只需识别常见横向空白。
            return character == " " || character == "\t"
        }
    }

    // 去掉一行两侧的空格和制表符，同时保持共享字符串存储。
    private static func trimSpaces(_ line: Substring) -> Substring {
        // 从原切片开始收缩边界。
        var result = line
        // 移除左侧横向空白。
        while !Task.isCancelled, let first = result.first, first == " " || first == "\t" {
            // 丢弃首个空白字符。
            result = result.dropFirst()
        }
        // 移除右侧横向空白。
        while !Task.isCancelled, let last = result.last, last == " " || last == "\t" {
            // 丢弃末尾空白字符。
            result = result.dropLast()
        }
        // 返回仍共享原文存储的切片。
        return result
    }

    // 只去掉行首空格和制表符，供块标记识别使用。
    private static func trimLeadingSpaces(_ line: Substring) -> Substring {
        // 从原切片开始移动左边界。
        var result = line
        // Markdown Lite 首版宽容任意常见缩进。
        while !Task.isCancelled, let first = result.first, first == " " || first == "\t" {
            // 丢弃首个缩进字符。
            result = result.dropFirst()
        }
        // 返回保留行尾内容的切片。
        return result
    }

    // 解析一到六级 ATX 标题。
    private static func headingContent(_ line: Substring) -> (level: Int, text: String)? {
        // 标题允许存在前导缩进。
        let trimmed = trimLeadingSpaces(line)
        // 最多统计六个井号，更多井号按普通文本处理。
        let level = trimmed.prefix(while: { $0 == "#" }).count
        // 仅接受一到六级标题。
        guard (1...6).contains(level) else { return nil }
        // 定位井号后的字符。
        let contentStart = trimmed.index(trimmed.startIndex, offsetBy: level)
        // 井号后没有内容时允许空标题。
        if contentStart == trimmed.endIndex {
            // 返回空正文标题。
            return (level, "")
        }
        // 非空正文前必须有空格或制表符。
        guard trimmed[contentStart] == " " || trimmed[contentStart] == "\t" else { return nil }
        // 跳过标题标记后的首个空白。
        let textStart = trimmed.index(after: contentStart)
        // 去掉正文两侧多余空白后保存。
        return (level, String(trimSpaces(trimmed[textStart...])))
    }

    // 解析起始代码围栏及其语言提示。
    private static func openingFence(_ line: Substring) -> Fence? {
        // 围栏允许存在前导缩进。
        let trimmed = trimLeadingSpaces(line)
        // 围栏必须以反引号或波浪号开始。
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        // 统计连续围栏字符数量。
        let length = trimmed.prefix(while: { $0 == marker }).count
        // GFM 围栏至少需要三个相同字符。
        guard length >= 3 else { return nil }
        // 定位围栏字符后的可选信息串。
        let infoStart = trimmed.index(trimmed.startIndex, offsetBy: length)
        // 去掉信息串两侧空白。
        let info = trimSpaces(trimmed[infoStart...])
        // 空信息串不声明语言。
        let language =
            info.isEmpty ? nil : String(info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? info)
        // 返回闭合判断所需的围栏信息。
        return Fence(marker: marker, length: length, language: language)
    }

    // 判断当前行是否闭合指定代码围栏。
    private static func isClosingFence(_ line: Substring, opening: Fence) -> Bool {
        // 闭合围栏允许存在前导缩进。
        let trimmed = trimLeadingSpaces(line)
        // 闭合行必须使用相同围栏字符。
        guard trimmed.first == opening.marker else { return false }
        // 统计闭合围栏字符数量。
        let length = trimmed.prefix(while: { $0 == opening.marker }).count
        // 闭合围栏不能短于起始围栏。
        guard length >= opening.length else { return false }
        // 定位围栏字符后的剩余内容。
        let remainderStart = trimmed.index(trimmed.startIndex, offsetBy: length)
        // 闭合围栏后只允许横向空白。
        return trimSpaces(trimmed[remainderStart...]).isEmpty
    }

    // 判断一行是否为 Markdown 分割线。
    private static func isDivider(_ line: Substring) -> Bool {
        // 分割线允许两侧存在空白。
        let trimmed = trimSpaces(line)
        // 分割线首字符只能是三种标准标记之一。
        guard let marker = trimmed.first, marker == "-" || marker == "*" || marker == "_" else { return false }
        // 统计有效标记数量。
        var markerCount = 0
        // 验证整行除空白外只含同一种标记。
        for character in trimmed {
            // 超长候选分割线被取消时立即停止逐字符扫描。
            guard !Task.isCancelled else { return false }
            // 同类标记计入有效数量。
            if character == marker {
                // 累加标记数量。
                markerCount += 1
            } else if character != " " && character != "\t" {
                // 出现其他字符时不是分割线。
                return false
            }
        }
        // 标准分割线至少需要三个标记。
        return markerCount >= 3
    }

    // 解析无序列表正文。
    private static func unorderedContent(_ line: Substring) -> String? {
        // 列表标记允许存在前导缩进。
        let trimmed = trimLeadingSpaces(line)
        // 无序列表只接受减号、星号或加号。
        guard let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        // 定位列表标记后的字符。
        let spacingIndex = trimmed.index(after: trimmed.startIndex)
        // 标记后必须存在空格或制表符。
        guard spacingIndex < trimmed.endIndex, trimmed[spacingIndex] == " " || trimmed[spacingIndex] == "\t" else {
            return nil
        }
        // 跳过一个分隔空白并返回正文。
        return String(trimmed[trimmed.index(after: spacingIndex)...])
    }

    // 解析有序列表编号和正文。
    private static func orderedContent(_ line: Substring) -> (number: Int, text: String)? {
        // 列表标记允许存在前导缩进。
        let trimmed = trimLeadingSpaces(line)
        // 空行不可能是有序列表。
        guard !trimmed.isEmpty else { return nil }
        // 从行首扫描连续数字。
        var cursor = trimmed.startIndex
        // 至少需要一个数字。
        var digitCount = 0
        // 只接受 ASCII 数字，避免 Int 转换遇到其他数字字符。
        while !Task.isCancelled, cursor < trimmed.endIndex, trimmed[cursor].isASCII, trimmed[cursor].isNumber {
            // 累加数字位数。
            digitCount += 1
            // 移动到下一个字符。
            cursor = trimmed.index(after: cursor)
        }
        // 没有数字时不是有序列表。
        guard digitCount > 0, cursor < trimmed.endIndex else { return nil }
        // GFM 常用点号或右括号作为编号结束符。
        guard trimmed[cursor] == "." || trimmed[cursor] == ")" else { return nil }
        // 定位结束符后的空白。
        let spacingIndex = trimmed.index(after: cursor)
        // 编号结束符后必须存在空格或制表符。
        guard spacingIndex < trimmed.endIndex, trimmed[spacingIndex] == " " || trimmed[spacingIndex] == "\t" else {
            return nil
        }
        // 提取数字切片用于保留真实起始编号。
        let numberSlice = trimmed[..<cursor]
        // 过大的编号安全回退为普通文本。
        guard let number = Int(numberSlice) else { return nil }
        // 跳过一个分隔空白并返回正文。
        return (number, String(trimmed[trimmed.index(after: spacingIndex)...]))
    }

    // 把列表正文中的 GFM 任务标记转换为结构化状态。
    private static func listItem(from content: String) -> EnhancedListItem {
        // 小写 x 和大写 X 都表示任务完成。
        if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
            // 去掉四字符任务标记后保存正文。
            return .init(text: String(content.dropFirst(4)), taskState: .checked)
        }
        // 空方括号表示任务未完成。
        if content.hasPrefix("[ ] ") {
            // 去掉四字符任务标记后保存正文。
            return .init(text: String(content.dropFirst(4)), taskState: .unchecked)
        }
        // 没有任务标记时保留普通列表正文。
        return .init(text: content, taskState: nil)
    }

    // 解析引用行正文。
    private static func quoteContent(_ line: Substring) -> String? {
        // 引用标记允许存在前导缩进。
        let trimmed = trimLeadingSpaces(line)
        // 引用必须以大于号开头。
        guard trimmed.first == ">" else { return nil }
        // 去掉引用标记。
        var content = trimmed.dropFirst()
        // 标记后的单个空格或制表符只负责分隔。
        if let first = content.first, first == " " || first == "\t" {
            // 去掉分隔空白。
            content = content.dropFirst()
        }
        // 返回保持行尾内容的引用正文。
        return String(content)
    }

    // 解析独占一行的 Markdown 图片。
    private static func imageInfo(_ line: Substring) -> ImageInfo? {
        // 图片语法允许两侧存在空白。
        let trimmed = trimSpaces(line)
        // 图片必须以感叹号和左方括号开始并以右括号结束。
        guard trimmed.hasPrefix("!["), trimmed.last == ")" else { return nil }
        // 从替代文字起点开始查找右方括号。
        let altStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        // 找到替代文字结束位置。
        guard let altEnd = trimmed[altStart...].firstIndex(of: "]") else { return nil }
        // 右方括号后必须紧跟左圆括号。
        let openParenthesis = trimmed.index(after: altEnd)
        // 缺少目标地址括号时不是完整图片。
        guard openParenthesis < trimmed.endIndex, trimmed[openParenthesis] == "(" else { return nil }
        // 最后一个字符已经确认是右圆括号。
        let closeParenthesis = trimmed.index(before: trimmed.endIndex)
        // 提取并修剪括号内部地址及标题。
        let destination = trimSpaces(trimmed[trimmed.index(after: openParenthesis)..<closeParenthesis])
        // 空地址不生成可加载图片块。
        guard !destination.isEmpty else { return nil }
        // 按首个横向空白拆分地址和可选标题。
        let separator = destination.firstIndex(where: { $0 == " " || $0 == "\t" })
        // 没有标题时整段都是地址。
        let sourceSlice = separator.map { destination[..<$0] } ?? destination[...]
        // 地址不能为空。
        guard !sourceSlice.isEmpty else { return nil }
        // 存在剩余内容时尝试解析引号标题。
        let title: String?
        // 仅在找到分隔位置时读取标题。
        if let separator {
            // 去掉标题两侧空白。
            let rawTitle = trimSpaces(destination[separator...])
            // 成对单引号或双引号包裹的内容才视为标题。
            if rawTitle.count >= 2,
                let first = rawTitle.first,
                let last = rawTitle.last,
                (first == "\"" && last == "\"") || (first == "'" && last == "'")
            {
                // 去掉成对引号保存标题正文。
                title = String(rawTitle.dropFirst().dropLast())
            } else {
                // 非标准标题不阻止图片地址本身渲染。
                title = nil
            }
        } else {
            // 没有剩余内容时不声明标题。
            title = nil
        }
        // 保存替代文字、地址和可选标题。
        return ImageInfo(alt: String(trimmed[altStart..<altEnd]), source: String(sourceSlice), title: title)
    }

    // 检查当前两行是否构成 GFM 表格起点。
    private static func tableStart(
        lines: [Substring],
        at index: Int
    ) -> (headers: [String], alignments: [EnhancedTableAlignment])? {
        // 表格至少需要表头和下一行对齐声明。
        guard index + 1 < lines.count else { return nil }
        // 管道符是表格的低成本预筛条件。
        guard lines[index].contains("|"), lines[index + 1].contains("-") else { return nil }
        // 解析表头单元格。
        guard let headers = tableCells(lines[index]), !headers.isEmpty else { return nil }
        // 解析对齐声明单元格。
        guard let alignmentCells = tableCells(lines[index + 1]), alignmentCells.count == headers.count else {
            return nil
        }
        // 每个对齐单元格都必须符合冒号加至少三个减号的格式。
        let alignments = alignmentCells.compactMap(tableAlignment)
        // 任意无效对齐声明都会让当前行保持普通段落语义。
        guard alignments.count == headers.count else { return nil }
        // 返回经过验证的表头和对齐方式。
        return (headers, alignments)
    }

    // 按未转义管道符拆分表格单元格。
    private static func tableCells(_ line: Substring) -> [String]? {
        // 表格行允许两侧存在空白。
        var trimmed = trimSpaces(line)
        // 至少需要一个管道符才能形成 GFM 表格。
        guard trimmed.contains("|") else { return nil }
        // 记录是否存在可省略的首管道符。
        let hadLeadingPipe = trimmed.first == "|"
        // 记录是否存在可省略的尾管道符。
        let hadTrailingPipe = trimmed.last == "|"
        // 首管道符只负责标记表格边界。
        if hadLeadingPipe {
            // 去掉首边界符。
            trimmed = trimmed.dropFirst()
        }
        // 尾管道符只负责标记表格边界。
        if hadTrailingPipe, !trimmed.isEmpty {
            // 去掉尾边界符。
            trimmed = trimmed.dropLast()
        }
        // 至少准备第一个单元格缓冲区。
        var cells: [String] = [""]
        // 反斜杠用于转义单元格内的管道符。
        var escaping = false
        // 单次扫描完成拆分，避免正则表达式开销。
        for character in trimmed {
            // 超宽表格行被取消时立即停止拆分。
            guard !Task.isCancelled else { return nil }
            // 转义状态下保留被转义字符本身。
            if escaping {
                // 非管道符转义继续保留反斜杠，避免改写原文。
                if character != "|" {
                    // 恢复原始反斜杠。
                    cells[cells.count - 1].append("\\")
                }
                // 追加当前被转义字符。
                cells[cells.count - 1].append(character)
                // 当前转义已经消费。
                escaping = false
            } else if character == "\\" {
                // 延迟写入反斜杠以判断是否转义管道符。
                escaping = true
            } else if character == "|" {
                // 未转义管道符开始下一个单元格。
                cells.append("")
            } else {
                // 普通字符写入当前单元格。
                cells[cells.count - 1].append(character)
            }
        }
        // 行尾孤立反斜杠必须保留。
        if escaping {
            // 恢复未实际转义任何字符的反斜杠。
            cells[cells.count - 1].append("\\")
        }
        // 去掉每个单元格两侧布局空白。
        return cells.map { cell in
            // 仅复制最终修剪后的单元格正文。
            String(trimSpaces(cell[...]))
        }
    }

    // 解析单个 GFM 表格对齐声明。
    private static func tableAlignment(_ cell: String) -> EnhancedTableAlignment? {
        // 对齐声明单元格已经去掉两侧空白。
        var marker = cell[...]
        // 左冒号声明左边界或居中。
        let leadingColon = marker.first == ":"
        // 去掉可选左冒号后验证减号。
        if leadingColon {
            // 移除左对齐标记。
            marker = marker.dropFirst()
        }
        // 右冒号声明右边界或居中。
        let trailingColon = marker.last == ":"
        // 去掉可选右冒号后验证减号。
        if trailingColon {
            // 移除右对齐标记。
            marker = marker.dropLast()
        }
        // GFM 对齐声明至少保留三个减号。
        guard marker.count >= 3,
            marker.allSatisfy({ !Task.isCancelled && $0 == "-" })
        else { return nil }
        // 两侧冒号共同声明居中。
        if leadingColon && trailingColon {
            // 返回居中对齐。
            return .center
        }
        // 只有右冒号声明右对齐。
        if trailingColon {
            // 返回右对齐。
            return .trailing
        }
        // 默认或只有左冒号均按左对齐。
        return .leading
    }

    // 把数据行调整到表头列数，避免渲染层索引越界。
    private static func normalizeTableRow(_ cells: [String], columnCount: Int) -> [String] {
        // 超出表头的单元格按 GFM 宽容策略裁剪。
        if cells.count >= columnCount {
            // 只保留表头定义的列数。
            return Array(cells.prefix(columnCount))
        }
        // 缺少的尾部单元格使用空字符串补齐。
        return cells + Array(repeating: "", count: columnCount - cells.count)
    }
}

// 用纯逻辑选择预览滚动锚点，避免视图层把光标提前跳到尚未经过的下一个块。
enum EnhancedPreviewAnchor {
    // 返回目标行之前最后一个块；目标位于首块之前时安全回退到首块。
    static func blockID(in orderedBlockIDs: [Int], atOrBefore targetLine: Int) -> Int? {
        // 空预览没有可滚动目标。
        guard let firstBlockID = orderedBlockIDs.first else { return nil }
        // 默认采用首块，覆盖目标行早于首块的防御性场景。
        var selectedBlockID = firstBlockID
        // 解析器按原文顺序输出递增行号，遇到目标之后的块即可停止。
        for blockID in orderedBlockIDs {
            // 目标之后的块不能成为当前章节的滚动锚点。
            guard blockID <= targetLine else { break }
            // 保存截至目标行最后出现的块。
            selectedBlockID = blockID
        }
        // 返回不晚于目标行的稳定锚点。
        return selectedBlockID
    }
}

// 使用 Foundation 原生 AttributedString 解析粗体、斜体、行内代码和链接。
private func enhancedInlineMarkdown(_ text: String) -> AttributedString {
    // 行内模式保留用户空白且不把正文误解释为块级语法。
    (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
}

// 对围栏代码执行轻量关键词着色，不引入语法高亮依赖。
private func enhancedHighlightedCode(_ code: String, language: String?) -> AttributedString {
    // 常见语言共享一组高辨识度关键词，未知语言仍可获得基础高亮。
    let keywords: Set<String> = [
        "actor", "async", "await", "break", "case", "catch", "class", "const", "continue",
        "def", "do", "else", "enum", "export", "extends", "false", "final", "for", "func",
        "function", "guard", "if", "import", "in", "interface", "let", "match", "nil", "null",
        "package", "private", "protocol", "public", "return", "self", "static", "struct", "switch",
        "throw", "throws", "true", "try", "typealias", "var", "while", "yield",
    ]
    // 语言提示目前只用于未来扩展，读取它可明确保持 API 语义。
    _ = language
    // 累积最终带颜色的代码文本。
    var highlighted = AttributedString()
    // 暂存连续标识符字符。
    var token = ""

    // 把已收集标识符追加到结果并按关键词着色。
    func flushToken() {
        // 空标识符无需生成片段。
        guard !token.isEmpty else { return }
        // 从原始标识符生成可修改属性片段。
        var fragment = AttributedString(token)
        // 关键词使用系统强调色形成轻量高亮。
        if keywords.contains(token) {
            // 紫色在浅色和深色系统主题下均保持较高辨识度。
            fragment.foregroundColor = .purple
            // 关键词使用中等字重进一步区分。
            fragment.font = .system(.body, design: .monospaced, weight: .semibold)
        }
        // 把当前标识符追加到最终结果。
        highlighted.append(fragment)
        // 清空缓冲区供后续字符使用。
        token.removeAll(keepingCapacity: true)
    }

    // 单次扫描代码字符，避免正则表达式对长代码块的额外成本。
    for character in code {
        // 字母、数字和下划线共同组成待判断标识符。
        if character.isLetter || character.isNumber || character == "_" {
            // 把当前字符加入标识符缓冲区。
            token.append(character)
        } else {
            // 标点或空白前先输出已完成标识符。
            flushToken()
            // 非标识符按原文直接追加。
            highlighted.append(AttributedString(String(character)))
        }
    }
    // 输出文末可能残留的标识符。
    flushToken()
    // 返回适合 Text 直接渲染的轻量高亮结果。
    return highlighted
}

// 渲染增强列表中的一个普通项或任务项。
private struct EnhancedListRow: View {
    // 保存已经去掉 Markdown 列表标记的条目。
    let item: EnhancedListItem
    // 普通项显示圆点或真实编号。
    let marker: String
    // 保存条目在 Markdown 源文件中的零基逻辑行。
    let sourceLine: Int
    // 预览可交互时把源行、正文和旧状态交给上层严格核对。
    let onToggleTask: ((Int, String, Bool) -> Void)?

    // 构造紧凑且支持行内 Markdown 的列表行。
    var body: some View {
        // 首行基线对齐可避免多行正文让标记垂直居中。
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 任务项使用系统复选框图标表达状态。
            if let taskState = item.taskState {
                // 原生按钮同时提供鼠标、键盘和 VoiceOver 操作语义。
                Button {
                    // 未接入源文件动作的兼容预览保持安全空操作。
                    guard let onToggleTask else { return }
                    // 把解析快照一并回传，防止旧预览修改后来出现的新任务。
                    onToggleTask(sourceLine, item.text, taskState == .checked)
                } label: {
                    // 根据解析状态选择空框或选中图标。
                    Image(systemName: taskState == .checked ? "checkmark.square.fill" : "square")
                        // 已完成任务使用强调色，未完成任务使用次级色。
                        .foregroundStyle(taskState == .checked ? Color.accentColor : Color.secondary)
                        // 图标提供稳定宽度，避免列表正文左右抖动。
                        .frame(width: 16)
                }
                // 无边框样式保持原有列表排版和系统图标尺寸。
                .buttonStyle(.plain)
                // 旧调用方没有写回闭包时不伪装成可操作控件。
                .disabled(onToggleTask == nil)
                // VoiceOver 朗读真实任务正文而不是系统图标名称。
                .accessibilityLabel(item.text.isEmpty ? "任务" : item.text)
                // 当前完成状态作为独立值便于快速浏览任务列表。
                .accessibilityValue(taskState == .checked ? "已完成" : "未完成")
                // 明确操作会同步修改 Markdown 原文。
                .accessibilityHint("切换任务状态并同步到 Markdown 原文")
            } else {
                // 普通列表显示圆点或有序编号。
                Text(marker)
                    // 标记弱化以突出正文。
                    .foregroundStyle(.secondary)
                    // 短标记至少占用稳定宽度。
                    .frame(minWidth: 16, alignment: .trailing)
            }
            // 正文交给系统行内 Markdown 解析器处理。
            Text(enhancedInlineMarkdown(item.text))
                // 长列表项占满剩余宽度并左对齐。
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// 把 Markdown 图片地址解析为可由预览层加载的受控 URL。
enum EnhancedImageSourceResolver {
    // 保存一张经过协议和主机校验、但尚未获得用户加载许可的 HTTPS 图片。
    struct RemoteImageRequest: Equatable {
        // URL 只有在用户点击当前视图按钮后才可交给 AsyncImage。
        let url: URL
        // 界面只展示目标主机，不暴露可能含隐私参数的完整路径和查询串。
        let displayHost: String
    }

    // 用纯逻辑区分本地来源、永久阻止的 HTTP 和需要逐图确认的 HTTPS。
    enum RemoteImageDecision: Equatable {
        // 没有 HTTP(S) 协议时继续进入本地图片解析。
        case notRemote
        // HTTP 或无有效主机的远程地址永不创建网络请求。
        case blocked
        // 合法 HTTPS 地址必须等待当前图片视图的明确按钮点击。
        case requiresConfirmation(RemoteImageRequest)
    }

    // 在不发起网络请求的前提下判定远程图片加载策略。
    static func remoteImageDecision(for source: String) -> RemoteImageDecision {
        // 去掉 Markdown 地址两侧不具 URL 语义的空白。
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空地址属于普通无效来源，不进入远程图片分支。
        guard !trimmedSource.isEmpty else { return .notRemote }
        // 只有可解析且显式声明协议的地址可能属于远程图片。
        guard let url = URL(string: trimmedSource), let rawScheme = url.scheme else { return .notRemote }
        // 协议统一小写以阻止大小写变体绕过策略。
        let scheme = rawScheme.lowercased()
        // 明文 HTTP 永久阻止，界面不会提供加载按钮。
        if scheme == "http" { return .blocked }
        // 其他协议继续交给本地 file 或非法协议处理逻辑。
        guard scheme == "https" else { return .notRemote }
        // HTTPS 必须携带真实目标主机，避免对残缺地址提供误导性确认。
        guard let rawHost = url.host, !rawHost.isEmpty else { return .blocked }
        // 主机统一小写，界面不显示路径、查询或用户信息。
        let normalizedHost = rawHost.lowercased()
        // 去掉 DNS 可选尾点，避免同一主机呈现两种形式。
        let displayHost =
            normalizedHost.hasSuffix(".")
            ? String(normalizedHost.dropLast())
            : normalizedHost
        // 空主机防御性阻止，不能生成没有明确来源的按钮。
        guard !displayHost.isEmpty else { return .blocked }
        // 返回仍需当前视图逐图确认的受控请求描述。
        return .requiresConfirmation(RemoteImageRequest(url: url, displayHost: displayHost))
    }

    // 解析现有 HTTP(S)、file URL 或相对当前文档的本地图片地址。
    static func resolve(_ source: String, documentURL: URL?) -> URL? {
        // 去掉 Markdown 地址两侧不具语义的空白。
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空地址不能生成图片请求。
        guard !trimmedSource.isEmpty else { return nil }

        // 先应用远程图片隐私策略，任何远程地址都不能从本地解析接口取得可加载 URL。
        switch remoteImageDecision(for: trimmedSource) {
        case .requiresConfirmation:
            // HTTPS 只能由确认分支持有请求描述，通用解析入口不得绕过授权。
            return nil
        case .blocked:
            // 明文 HTTP 和残缺 HTTPS 永久拒绝。
            return nil
        case .notRemote:
            // 非远程来源继续执行下方本地路径校验。
            break
        }

        // 任何本地图片都必须依赖已经保存的 Markdown 文档位置建立安全根目录。
        guard let documentURL, documentURL.isFileURL else { return nil }
        // 文档同级目录是显式和相对本地图片共同的唯一安全根目录。
        let documentDirectory = documentURL.deletingLastPathComponent().standardizedFileURL
        // 解析文档目录真实路径，避免父目录软链接让字符串前缀产生错误边界。
        let resolvedRoot = documentDirectory.resolvingSymlinksInPath().standardizedFileURL

        // 先识别带显式 scheme 的完整 URL。
        if let absoluteURL = URL(string: trimmedSource), let scheme = absoluteURL.scheme?.lowercased() {
            // data、javascript 等其他 scheme 一律拒绝。
            guard scheme == "file", absoluteURL.isFileURL else { return nil }
            // 显式 file URL 同样只接受明确图片扩展名。
            guard isSupportedLocalImage(absoluteURL) else { return nil }
            // 标准化点路径段后再解析全部既有软链接。
            let resolvedCandidate =
                absoluteURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            // 显式地址的真实路径也必须严格位于当前文档目录内。
            guard isStrictDescendant(resolvedCandidate, of: resolvedRoot) else { return nil }
            // 返回真实文件地址，避免后续加载再次跟随已校验软链接。
            return resolvedCandidate
        }

        // 裸绝对路径必须改用显式 file URL，避免模糊权限边界。
        guard !trimmedSource.hasPrefix("/"), !trimmedSource.hasPrefix("~") else { return nil }
        // 未编码的查询或片段字符会改变 URL 语义，不作为本地文件名处理。
        guard !trimmedSource.contains("?"), !trimmedSource.contains("#") else { return nil }
        // 非法百分号序列不能被可靠解释为文件路径。
        guard let decodedPath = trimmedSource.removingPercentEncoding else { return nil }
        // 空字符不能进入系统文件路径。
        guard !decodedPath.contains("\0") else { return nil }
        // 按路径组件检查编码前后的点路径段。
        let components = decodedPath.split(separator: "/", omittingEmptySubsequences: false)
        // 空组件和父目录都拒绝，彻底阻止相对路径穿越。
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != ".." })
        else { return nil }
        // 当前目录组件没有权限语义，可安全折叠以兼容 `./assets` 写法。
        let safeComponents = components.filter { $0 != "." }
        // 只有当前目录标记而没有图片名称时不能生成地址。
        guard !safeComponents.isEmpty else { return nil }
        // 反斜杠在跨平台 Markdown 中可能具有目录语义，因此不作为普通文件名接受。
        guard !decodedPath.contains("\\") else { return nil }

        // 逐个安全组件追加，避免把完整字符串再次解释为绝对路径。
        var candidate = documentDirectory
        // 保持组件顺序构造最终本地地址。
        for component in safeComponents {
            // 每个组件已通过点路径和空值检查。
            candidate.appendPathComponent(String(component), isDirectory: false)
        }
        // 统一消除标准化可折叠路径段。
        candidate = candidate.standardizedFileURL
        // 相对本地图片同样只接受明确图片扩展名。
        guard isSupportedLocalImage(candidate) else { return nil }

        // 解析候选路径中的所有既有软链接成分。
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        // 候选真实地址必须严格位于文档目录内。
        guard isStrictDescendant(resolvedCandidate, of: resolvedRoot) else { return nil }
        // 返回真实文件地址，避免后续加载再次跟随已校验软链接。
        return resolvedCandidate
    }

    // 判断本地地址是否使用允许的常见图片扩展名。
    private static func isSupportedLocalImage(_ url: URL) -> Bool {
        // 扩展名统一小写后复用导入模块白名单。
        AssetSupport.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // 判断候选路径是否严格位于指定目录之内。
    private static func isStrictDescendant(_ candidate: URL, of directory: URL) -> Bool {
        // 目录前缀补充分隔符，避免相似名称目录误匹配。
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        // 完整路径前缀比较只允许真实子路径。
        return candidate.path.hasPrefix(directoryPath)
    }
}

// 定义预览单张本地图片的硬性资源预算。
struct EnhancedLocalImageLimits: Equatable, Sendable {
    // 单张图片最多读取二十五 MiB，与可携带 HTML 的单图上限保持一致。
    static let standard = EnhancedLocalImageLimits(
        maximumByteCount: 25 * 1_024 * 1_024,
        maximumPixelCount: 40_000_000,
        maximumThumbnailPixelSize: 1_024
    )

    // 限制压缩文件字节数，避免稀疏文件或并发增长造成无界读取。
    let maximumByteCount: Int64
    // 限制源图宽高乘积，避免小体积解码炸弹耗尽内存。
    let maximumPixelCount: Int64
    // 限制实际解码缩略图最长边，预览无需保留超大原始位图。
    let maximumThumbnailPixelSize: Int
}

// 保存已经在后台完成解码的不可变缩略图。
struct EnhancedLocalImageThumbnail: @unchecked Sendable {
    // CGImage 已由 ImageIO 强制解码，可安全交给主线程包装为 NSImage。
    let cgImage: CGImage
}

// 使用有界文件读取和 ImageIO 在调用线程生成本地图片缩略图。
enum EnhancedLocalImageDecoder {
    // 最多同时处理两张本地图，把极端峰值控制在两份字节预算和缩略图内。
    private static let decodeSlots = DispatchSemaphore(value: 2)

    // 在 detached 后台任务执行同步解码，并把调用方取消显式传给 worker。
    static func decodeThumbnailInBackground(
        at url: URL,
        limits: EnhancedLocalImageLimits = .standard
    ) async -> EnhancedLocalImageThumbnail? {
        // detached 保证文件读取和 ImageIO 不继承可能存在的 MainActor。
        let worker = Task.detached(priority: .utility) {
            // 同步实现会在排队、读取、元数据和解码阶段持续检查此 worker 的取消状态。
            decodeThumbnail(at: url, limits: limits)
        }
        // 外层 SwiftUI `.task` 取消时必须主动终止不继承取消关系的 detached worker。
        return await withTaskCancellationHandler {
            // 正常路径等待同一后台 worker 返回缩略图或失败。
            await worker.value
        } onCancel: {
            // 快速滚动或图片地址变化后不允许旧 worker 继续占用读取和解码槽位。
            worker.cancel()
        }
    }

    // 读取、校验并立即解码一张受控缩略图，任何失败都安全返回 nil。
    static func decodeThumbnail(
        at url: URL,
        limits: EnhancedLocalImageLimits = .standard
    ) -> EnhancedLocalImageThumbnail? {
        // 只处理经过来源解析器认可的本地文件 URL。
        guard url.isFileURL else { return nil }
        // 非正预算无法容纳任何有效图片，直接拒绝异常调用参数。
        guard limits.maximumByteCount > 0,
            limits.maximumPixelCount > 0,
            limits.maximumThumbnailPixelSize > 0
        else { return nil }
        // 当前实现需要把上限加一转换成 Int 以识别并发增长。
        guard limits.maximumByteCount < Int64(Int.max) else { return nil }
        // 已取消请求不能继续排队或占用正式解码并发名额。
        guard acquireDecodeSlot() else { return nil }
        // 当前图片完成或失败后立即唤醒下一张可见图片。
        defer { decodeSlots.signal() }
        // 获得槽位与开始打开文件之间仍需响应取消。
        guard !Task.isCancelled else { return nil }

        // 来源解析器已经返回打开前校验过的真实路径，此处只做不访问文件系统的标准化。
        let expectedURL = url.standardizedFileURL
        // O_NOFOLLOW 阻止安全解析后最终文件被瞬时替换为软链接。
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            // 无法形成文件系统路径时按打开失败处理。
            guard let path else { return Int32(-1) }
            // 只读且不跟随最终软链接，O_NONBLOCK 避免特殊节点阻塞。
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        // 打开失败不再退回会跟随软链接的路径读取 API。
        guard descriptor >= 0 else { return nil }
        // FileHandle 接管描述符并负责最终关闭。
        let fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // 所有成功和失败路径都立即释放当前图片文件描述符。
        defer { try? fileHandle.close() }

        // F_GETPATH 从同一已打开对象取得实际路径，识别中间目录被瞬时替换的情况。
        var openedPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        // 固定缓冲区接收内核返回的零结尾文件系统路径。
        let pathResult = openedPath.withUnsafeMutableBufferPointer { buffer in
            // 非空 MAXPATHLEN 缓冲区应始终拥有有效首地址。
            guard let baseAddress = buffer.baseAddress else { return Int32(-1) }
            // 使用非可变参数重载把原始缓冲区交给 macOS fcntl。
            return Darwin.fcntl(
                descriptor,
                F_GETPATH,
                UnsafeMutableRawPointer(baseAddress)
            )
        }
        // 无法确认已打开对象的实际位置时不冒险读取内容。
        guard pathResult == 0 else { return nil }
        // 把内核实际路径转换为标准本地文件 URL。
        let openedURL = openedPath.withUnsafeBufferPointer { buffer in
            // F_GETPATH 成功保证首地址包含有效零结尾路径。
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: false,
                relativeTo: nil
            ).standardizedFileURL
        }
        // 中间目录在 resolve 与 open 之间被替换时，实际打开路径会与预期目标不同。
        guard openedURL.path == expectedURL.path else { return nil }

        // fstat 对已经打开的同一对象读取类型和字节数，避免路径二次查询竞态。
        var fileStatus = stat()
        // 元数据读取失败时不尝试加载未知对象。
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else { return nil }
        // 目录、FIFO、设备和 socket 都不能进入图片读取循环。
        guard (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        // 负数文件大小属于异常元数据。
        guard fileStatus.st_size >= 0 else { return nil }
        // 在任何内容分配前拒绝超过正式字节预算的文件。
        guard Int64(fileStatus.st_size) <= limits.maximumByteCount else { return nil }

        // 上限加一字节足以发现 fstat 后继续增长的文件。
        let stopByteCount = Int(limits.maximumByteCount) + 1
        // 正常文件按 fstat 大小预留容量但绝不超过硬上限。
        var data = Data()
        // 预留仅减少扩容，不触发超过正式预算的内存申请。
        data.reserveCapacity(min(Int(fileStatus.st_size), Int(limits.maximumByteCount)))
        // 以固定小块读取，避免单次临时分配整份大文件。
        while data.count < stopByteCount {
            // SwiftUI 取消不可见图片任务时及时停止后台工作。
            guard !Task.isCancelled else { return nil }
            // 当前块包含最多一个用于证明超限的额外字节。
            let chunkByteCount = min(64 * 1_024, stopByteCount - data.count)
            // 保存当前块，读取错误与正常文件末尾需要分开处理。
            let chunk: Data
            // 始终从同一已校验描述符继续读取。
            do {
                // nil 或空数据都表示普通文件已经完整读到末尾。
                guard let readChunk = try fileHandle.read(upToCount: chunkByteCount),
                    !readChunk.isEmpty
                else { break }
                // 成功读取的非空块进入统一追加路径。
                chunk = readChunk
            } catch {
                // 系统读取错误不能产生部分图片。
                return nil
            }
            // 把当前有界块追加到待识别图片数据。
            data.append(chunk)
        }
        // 文件在 fstat 后增长时，上限加一字节会触发拒绝。
        guard data.count <= Int(limits.maximumByteCount) else { return nil }
        // 空文件不可能形成有效图片。
        guard !data.isEmpty else { return nil }
        // 读取完成后再次响应视图取消。
        guard !Task.isCancelled else { return nil }

        // 创建图片源时禁止隐式缓存原始全尺寸位图。
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        // ImageIO 只从受字节预算保护的内存读取图片元数据和像素。
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        // 至少需要一帧才能生成预览缩略图。
        guard CGImageSourceGetCount(imageSource) > 0 else { return nil }
        // 图片源识别完成后若视图已经离屏，不再读取宽高元数据。
        guard !Task.isCancelled else { return nil }
        // 先读取首帧宽高元数据，在实际解码前执行像素预算。
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as NSDictionary?,
            let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return nil }
        // 转成有符号整数便于执行正值和溢出检查。
        let pixelWidth = widthNumber.int64Value
        // 高度与宽度使用相同安全表示。
        let pixelHeight = heightNumber.int64Value
        // 零或负尺寸不是可显示图片。
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        // 溢出安全乘法避免恶意尺寸绕过像素上限。
        let (pixelCount, didPixelCountOverflow) = pixelWidth.multipliedReportingOverflow(
            by: pixelHeight
        )
        // 乘法溢出或总像素超过预算时不进入解码。
        guard !didPixelCountOverflow, pixelCount <= limits.maximumPixelCount else { return nil }
        // 像素预算通过后仍先处理取消，避免进入最昂贵的位图生成阶段。
        guard !Task.isCancelled else { return nil }

        // 最长边不超过正式缩略图尺寸，同时不放大小图。
        let thumbnailPixelSize = min(
            Int64(limits.maximumThumbnailPixelSize),
            max(pixelWidth, pixelHeight)
        )
        // 正尺寸图片和正预算应始终得到至少一个像素。
        guard thumbnailPixelSize > 0, thumbnailPixelSize <= Int64(Int.max) else { return nil }
        // ImageIO 在当前后台线程完成旋转、缩放和像素缓存。
        let thumbnailOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(thumbnailPixelSize),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        // 强制生成受最长边约束的已解码位图。
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                thumbnailOptions
            )
        else { return nil }
        // ImageIO 调用无法中途打断，返回后必须丢弃已取消请求的结果。
        guard !Task.isCancelled else { return nil }
        // 把不可变缩略图交给主线程状态层展示。
        return EnhancedLocalImageThumbnail(cgImage: cgImage)
    }

    // 以短超时轮询取得全局解码槽位，使排队中的取消无需等待其他大图完成。
    private static func acquireDecodeSlot() -> Bool {
        // 只有取得槽位或当前任务取消才结束等待。
        while !Task.isCancelled {
            // 二十毫秒轮询兼顾取消响应与低调度开销。
            if decodeSlots.wait(timeout: .now() + .milliseconds(20)) == .success {
                // 成功调用方负责通过 defer 归还唯一槽位。
                return true
            }
        }
        // 取消请求不会再进入文件读取或 ImageIO。
        return false
    }
}

// 在后台读取并解码本地图片，避免文件 IO 或 ImageIO 阻塞编辑输入线程。
@MainActor
private final class EnhancedLocalImageLoader: ObservableObject {
    // 保存加载成功的系统图片。
    @Published private(set) var image: NSImage?
    // 保存加载失败状态供界面显示替代文字。
    @Published private(set) var failed = false
    // 记录已完成或正在处理的地址，避免 SwiftUI 重绘重复读取。
    @Published private(set) var loadedURL: URL?

    // 按地址异步加载一张本地图片。
    func load(_ url: URL) async {
        // 同一地址已有确定结果时直接复用。
        if loadedURL == url, image != nil || failed { return }
        // 地址变化时清空上一张图片。
        image = nil
        // 地址变化时恢复加载中状态。
        failed = false
        // 记录当前请求地址以抑制重复任务。
        loadedURL = url
        // 后台入口显式传播 SwiftUI 取消，并把同时读取解码限制为两张图片。
        let thumbnail = await EnhancedLocalImageDecoder.decodeThumbnailInBackground(at: url)
        // SwiftUI 取消不可见块任务时不更新过期状态。
        guard !Task.isCancelled, loadedURL == url else { return }
        // 主线程只把已经解码的不可变 CGImage 包装为 AppKit 展示对象。
        image = thumbnail.map {
            // 以像素尺寸创建 NSImage，SwiftUI 后续仅负责布局缩放。
            NSImage(
                cgImage: $0.cgImage,
                size: NSSize(width: $0.cgImage.width, height: $0.cgImage.height)
            )
        }
        // nil 表示文件缺失、权限不足或内容无法解码。
        failed = image == nil
    }
}

// 渲染远程或本地 Markdown 图片，并在失败时保留可读替代信息。
private struct EnhancedImageView: View {
    // 保存图片替代文字。
    let alt: String
    // 保存未经改写的图片地址。
    let source: String
    // 保存可选图片标题。
    let title: String?
    // 保存当前文档地址，用于解析相对本地图片路径。
    let documentURL: URL?
    // 每个可见图片块维护独立的本地异步加载状态。
    @StateObject private var localLoader = EnhancedLocalImageLoader()
    // 只记录当前图片视图实例内明确点击过的 HTTPS 地址，不写入全局或文档设置。
    @State private var approvedRemoteURL: URL?

    // 根据地址有效性选择异步图片或占位信息。
    @ViewBuilder
    var body: some View {
        // 先以纯逻辑判断远程协议，判定过程本身不会创建任何网络请求。
        let remoteDecision = EnhancedImageSourceResolver.remoteImageDecision(for: source)
        // 本地分支继续解析显式 file URL 和文档相对路径。
        let resolvedURL = EnhancedImageSourceResolver.resolve(source, documentURL: documentURL)
        // 按远程策略优先处理永久阻止和逐图确认，不让 HTTPS 落入自动加载路径。
        switch remoteDecision {
        case let .requiresConfirmation(request):
            // 只有当前视图实例已经明确批准同一 URL 时才创建 AsyncImage。
            if approvedRemoteURL == request.url {
                // 用户点击后的网络加载仍沿用系统异步图片组件。
                remoteImage(request.url)
            } else {
                // 默认只展示脱敏主机和明确加载按钮。
                remoteImageConfirmation(request)
            }
        case .blocked:
            // 明文 HTTP 和残缺 HTTPS 永远只显示无网络占位。
            imageFallback
        case .notRemote:
            // 只有通过目录和扩展名校验的 file URL 才进入本地加载器。
            if let url = resolvedURL, url.isFileURL {
                // Group 统一承载任务，地址变化时即使已有旧图也会重新加载。
                Group {
                    // 只有加载结果属于当前地址时才显示本地图片。
                    if localLoader.loadedURL == url, let image = localLoader.image {
                        // AppKit 图片转换为 SwiftUI 图片后支持自适应缩放。
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 520)
                            .accessibilityLabel(alt.isEmpty ? "Markdown 图片" : alt)
                    } else if localLoader.loadedURL == url, localLoader.failed {
                        // 本地路径失效或内容损坏时保留替代信息。
                        imageFallback
                    } else {
                        // 后台读取期间使用轻量进度指示器。
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 96)
                    }
                }
                // 视图进入可见区域或地址变化后触发后台文件读取。
                .task(id: url) {
                    // 等待当前图片加载完成或任务被滚动取消。
                    await localLoader.load(url)
                }
            } else {
                // 无文档基址、非法协议或不安全路径明确展示原始引用。
                imageFallback
            }
        }
        // 可选标题作为图片下方说明。
        if let title, !title.isEmpty {
            // 标题使用次级小字号避免抢占正文层级。
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // 用户确认后才创建系统远程图片组件。
    private func remoteImage(_ url: URL) -> some View {
        // AsyncImage 的初始化是唯一可能发起远程图片请求的路径。
        AsyncImage(url: url) { phase in
            // 根据加载阶段提供明确反馈。
            switch phase {
            case let .success(image):
                // 图片按原比例缩放到预览宽度内。
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 520)
                    .accessibilityLabel(alt.isEmpty ? "Markdown 图片" : alt)
            case .empty:
                // 加载中使用轻量进度指示器。
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 96)
            case .failure:
                // 图片加载失败时保留替代文字，正文信息不会丢失。
                imageFallback
            @unknown default:
                // 未知系统状态同样安全回退为文字。
                imageFallback
            }
        }
    }

    // 为尚未授权的 HTTPS 图片展示脱敏来源和逐图按钮。
    private func remoteImageConfirmation(
        _ request: EnhancedImageSourceResolver.RemoteImageRequest
    ) -> some View {
        // 纵向布局确保来源说明和操作按钮在窄预览区仍清晰可读。
        VStack(alignment: .leading, spacing: 10) {
            // 明确说明默认未联网，而不是伪装成加载失败。
            Label("远程图片未加载", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
            // 只显示主机，不展示可能携带令牌或追踪参数的完整 URL。
            Text("来源：\(request.displayHost)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // 按钮只批准当前视图实例中的这一条 HTTPS URL。
            Button("加载远程图片") {
                // 状态变化后当前分支才会创建 AsyncImage。
                approvedRemoteURL = request.url
            }
            .buttonStyle(.bordered)
        }
        // 确认区域占满可用宽度并保持左对齐。
        .frame(maxWidth: .infinity, alignment: .leading)
        // 与普通图片占位保持一致内边距。
        .padding(12)
        // 使用系统次级背景适配明暗主题。
        .background(Color.secondary.opacity(0.08))
        // 圆角与其他图片状态保持一致。
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // 构造图片不可加载时的原生占位视图。
    private var imageFallback: some View {
        // 图标和文字横向排列便于快速识别。
        HStack(spacing: 10) {
            // 使用系统图片图标而非自带资源文件。
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            // 优先显示作者提供的替代文字。
            Text(alt.isEmpty ? source : alt)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 占位内容与普通正文保持适当间距。
        .padding(12)
        // 使用系统次级背景适配明暗主题。
        .background(Color.secondary.opacity(0.08))
        // 圆角与代码块保持一致。
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// 渲染 GFM 表格中的一行固定列宽单元格。
private struct EnhancedTableRow: View {
    // 保存当前行所有单元格。
    let cells: [String]
    // 保存每列对齐方式。
    let alignments: [EnhancedTableAlignment]
    // 表头使用更强字重和背景。
    let isHeader: Bool

    // 使用横向布局保持各行列边界一致。
    var body: some View {
        // 单元格之间不额外留缝，由边框提供分隔。
        HStack(spacing: 0) {
            // 按索引读取对齐配置。
            ForEach(cells.indices, id: \.self) { index in
                // 单元格支持粗体、斜体、代码和链接。
                Text(enhancedInlineMarkdown(cells[index]))
                    // 表头使用系统中等字重。
                    .fontWeight(isHeader ? .semibold : .regular)
                    // 固定列宽让不同行保持精确对齐，超长表格可横向滚动。
                    .frame(width: 180, alignment: swiftUIAlignment(alignments[index]))
                    // 单元格内部提供可读留白。
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    // 每个单元格绘制轻量边框。
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.22), lineWidth: 0.5))
                    // 表头使用次级背景区分数据行。
                    .background(isHeader ? Color.secondary.opacity(0.09) : Color.clear)
            }
        }
    }

    // 把解析层对齐枚举映射为 SwiftUI 布局对齐。
    private func swiftUIAlignment(_ alignment: EnhancedTableAlignment) -> Alignment {
        // 按三种 GFM 对齐声明返回对应布局值。
        switch alignment {
        case .leading:
            // 默认列左对齐。
            return .leading
        case .center:
            // 双冒号列居中对齐。
            return .center
        case .trailing:
            // 右冒号列右对齐。
            return .trailing
        }
    }
}

// 使用懒加载行容器渲染完整 GFM 表格。
private struct EnhancedTableView: View {
    // 保存表头单元格。
    let headers: [String]
    // 保存每列对齐方式。
    let alignments: [EnhancedTableAlignment]
    // 保存所有数据行。
    let rows: [[String]]

    // 横向滚动避免宽表压缩正文。
    var body: some View {
        // 宽表只在自身区域横向滚动。
        ScrollView(.horizontal) {
            // LazyVStack 延迟创建长表格数据行。
            LazyVStack(alignment: .leading, spacing: 0) {
                // 表头始终作为第一行显示。
                EnhancedTableRow(cells: headers, alignments: alignments, isHeader: true)
                // 仅为进入可见区域的数据行创建视图。
                ForEach(rows.indices, id: \.self) { index in
                    // 渲染当前标准化表格行。
                    EnhancedTableRow(cells: rows[index], alignments: alignments, isHeader: false)
                }
            }
        }
    }
}

// 把一个增强块映射成原生 SwiftUI 预览视图。
struct EnhancedPreviewBlockView: View {
    // 保存当前待渲染块。
    let block: EnhancedPreviewBlock
    // 保存当前文档位置供图片块解析相对路径。
    let documentURL: URL?
    // 任务项点击时把精确解析快照交给当前文档动作。
    let onToggleTask: ((Int, String, Bool) -> Void)?

    // 允许旧调用方省略文档位置和任务动作，保持只读预览兼容。
    init(
        block: EnhancedPreviewBlock,
        documentURL: URL? = nil,
        onToggleTask: ((Int, String, Bool) -> Void)? = nil
    ) {
        // 保存解析完成的预览块。
        self.block = block
        // 保存可选文档位置。
        self.documentURL = documentURL
        // 保存可选任务切换动作。
        self.onToggleTask = onToggleTask
    }

    // 根据块类型选择对应原生组件。
    @ViewBuilder
    var body: some View {
        // 每种关联值由解析层一次性提供。
        switch block.kind {
        case let .heading(level, text):
            // 标题正文继续支持行内 Markdown。
            Text(enhancedInlineMarkdown(text))
                // 标题级别映射为清晰但紧凑的系统字号。
                .font(.system(size: headingSize(level), weight: .bold))
                // 所有标题与正文左边界对齐。
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .paragraph(text):
            // 普通段落使用系统行内 Markdown 解析器。
            Text(enhancedInlineMarkdown(text))
                // 增加少量行距提升长文可读性。
                .lineSpacing(4)
                // 段落占满预览宽度并左对齐。
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .unorderedList(items):
            // 长列表按可见范围延迟创建交互按钮，避免一次生成数万无障碍节点。
            LazyVStack(alignment: .leading, spacing: 7) {
                // 按稳定数组索引渲染每个列表项。
                ForEach(items.indices, id: \.self) { index in
                    // 普通无序项使用圆点，任务项由行视图改用复选框。
                    EnhancedListRow(
                        item: items[index],
                        marker: "•",
                        sourceLine: block.id + index,
                        onToggleTask: onToggleTask
                    )
                }
            }
        case let .orderedList(start, items):
            // 有序长列表同样延迟创建每行视图并保持原编号计算。
            LazyVStack(alignment: .leading, spacing: 7) {
                // 按稳定数组索引渲染每个列表项。
                ForEach(items.indices, id: \.self) { index in
                    // 从原文起始编号连续生成可见编号。
                    EnhancedListRow(
                        item: items[index],
                        marker: "\(start + index).",
                        sourceLine: block.id + index,
                        onToggleTask: onToggleTask
                    )
                }
            }
        case let .quote(text):
            // 引用使用竖线和次级文字色区分正文。
            HStack(alignment: .top, spacing: 12) {
                // 系统颜色竖线自动适配明暗主题。
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 4)
                // 引用正文仍支持行内 Markdown。
                Text(enhancedInlineMarkdown(text))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .code(language, text):
            // 代码过宽时只在代码块内部横向滚动。
            ScrollView(.horizontal) {
                // 使用轻量关键词着色后的 AttributedString。
                Text(enhancedHighlightedCode(text, language: language))
                    // 未着色字符统一使用等宽字体。
                    .font(.system(.body, design: .monospaced))
                    // 保留原始空白并允许复制选择。
                    .textSelection(.enabled)
                    // 代码正文与容器边缘保持间距。
                    .padding(14)
            }
            // 使用系统次级色背景适配明暗模式。
            .background(Color.secondary.opacity(0.08))
            // 圆角明确代码块边界。
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .divider:
            // 分割线直接使用系统组件。
            Divider()
        case let .image(alt, source, title):
            // 图片加载与失败回退都由独立视图处理。
            EnhancedImageView(alt: alt, source: source, title: title, documentURL: documentURL)
        case let .table(headers, alignments, rows):
            // 表格支持横向滚动并懒加载数据行。
            EnhancedTableView(headers: headers, alignments: alignments, rows: rows)
        }
    }

    // 返回对应标题级别的系统字号。
    private func headingSize(_ level: Int) -> CGFloat {
        // 六级标题映射到逐步收敛的视觉层级。
        switch level {
        case 1:
            // 一级标题作为页面主标题。
            return 30
        case 2:
            // 二级标题作为主要章节标题。
            return 24
        case 3:
            // 三级标题作为次级章节标题。
            return 20
        case 4:
            // 四级标题略高于正文。
            return 17
        case 5:
            // 五级标题接近正文但保留粗体。
            return 15
        default:
            // 六级及防御性未知层级使用紧凑字号。
            return 14
        }
    }
}

// 提供可直接替换现有预览区域的懒加载增强预览。
struct EnhancedMarkdownPreview: View {
    // 保存当前文档解析得到的块数组。
    let blocks: [EnhancedPreviewBlock]
    // 保存当前文档地址供相对本地图片解析使用。
    let documentURL: URL?
    // 保存大纲或编辑器请求跳转的零基行号。
    let scrollTargetLine: Int?
    // 保存任务清单写回当前活动源文件的可选动作。
    let onToggleTask: ((Int, String, Bool) -> Void)?

    // 提供兼容旧调用的默认文档地址和滚动目标参数。
    init(
        blocks: [EnhancedPreviewBlock],
        documentURL: URL? = nil,
        scrollTargetLine: Int? = nil,
        onToggleTask: ((Int, String, Bool) -> Void)? = nil
    ) {
        // 保存解析层生成的块数组。
        self.blocks = blocks
        // 保存已命名文档地址，未命名文档保持 nil。
        self.documentURL = documentURL
        // 保存由大纲或编辑器提供的可选目标行号。
        self.scrollTargetLine = scrollTargetLine
        // 保存可选任务动作，nil 时继续提供兼容只读预览。
        self.onToggleTask = onToggleTask
    }

    // 使用单一滚动容器承载所有块。
    var body: some View {
        // ScrollViewReader 允许大纲按解析块行号驱动预览定位。
        ScrollViewReader { proxy in
            // 预览区域允许纵向滚动长文档。
            ScrollView {
                // LazyVStack 只创建可见块，避免大文档一次性生成全部视图。
                LazyVStack(alignment: .leading, spacing: 16) {
                    // 稳定行号 ID 帮助 SwiftUI 复用未变化块。
                    ForEach(blocks) { block in
                        // 把当前模型映射为对应增强视图。
                        EnhancedPreviewBlockView(
                            block: block,
                            documentURL: documentURL,
                            onToggleTask: onToggleTask
                        )
                        // 显式块 ID 作为 ScrollViewReader 的跳转锚点。
                        .id(block.id)
                    }
                }
                // 所有预览文本允许原生选择和复制。
                .textSelection(.enabled)
                // 正文与窗口边缘保持舒适留白。
                .padding(28)
            }
            // 大纲目标变化时定位到该行之前最后一个已解析块。
            .onChange(of: scrollTargetLine) { _, targetLine in
                // nil 表示当前没有主动跳转请求。
                guard let targetLine,
                    let blockID = EnhancedPreviewAnchor.blockID(
                        in: blocks.map(\.id),
                        atOrBefore: targetLine
                    )
                else { return }
                // 使用短动画保持跳转方向可感知。
                withAnimation(.easeInOut(duration: 0.18)) {
                    // 把目标块顶部对齐到预览可视区域顶部。
                    proxy.scrollTo(blockID, anchor: .top)
                }
            }
        }
    }
}

// 提供功能断言和可复核的大文档解析性能数据。
enum EnhancedMarkdownSelfCheck {
    // 保存单个体量性能检查结果。
    struct Measurement: Equatable {
        // 保存目标文档体量，便于区分 200KB 与 1MB。
        let requestedBytes: Int
        // 保存实际生成文档字节数。
        let actualBytes: Int
        // 保存解析产生的块数量，防止基准调用被无意义省略。
        let blockCount: Int
        // 保存三次完整解析耗时的中位数。
        let milliseconds: Double
        // 保存当前体量的验收阈值。
        let targetMilliseconds: Double

        // 判断实际耗时是否达到目标。
        var passed: Bool {
            // 严格小于阈值才视为通过。
            milliseconds < targetMilliseconds
        }
    }

    // 汇总块类型和两档性能检查。
    struct Report: Equatable {
        // 表示所有增强块类型是否按预期识别。
        let blockTypesValid: Bool
        // 保存 200KB 文档性能结果。
        let mediumDocument: Measurement
        // 保存 1MB 文档性能结果。
        let largeDocument: Measurement

        // 只有功能和两档性能均通过时整体通过。
        var passed: Bool {
            // 汇总三个独立检查结果。
            blockTypesValid && mediumDocument.passed && largeDocument.passed
        }
    }

    // 运行功能验证并返回或打印两档性能数据。
    @discardableResult
    static func run(printResults: Bool = true, enforcePerformanceTargets: Bool = true) -> Report {
        // 构造覆盖全部增强块类型的最小 Markdown 文档。
        let sample = """
            # 标题

            正文含 **粗体**、*斜体* 和 [链接](https://example.com)。

            - 普通项
            - [x] 已完成

            3. 第三项
            4. [ ] 待完成

            > 引用

            ```swift
            let value = true
            ```

            ---

            ![示例图](https://example.com/image.png "图片标题")

            | 名称 | 数量 |
            | :--- | ---: |
            | Markdown | 1 |
            """
        // 解析功能样例。
        let sampleBlocks = EnhancedMarkdownParser.parse(sample)
        // 验证九种块按固定顺序识别。
        let blockTypesValid = validateBlockTypes(sampleBlocks)
        // 功能模型不正确时立即报告，避免性能数据掩盖语法回归。
        precondition(blockTypesValid, "增强 Markdown 块类型自检失败")
        // 远程图片协议和确认策略必须由纯逻辑验证，不能依赖真实网络请求。
        let remoteImagePrivacyValid = validateRemoteImagePrivacy()
        // HTTP 自动请求或 HTTPS 无确认都会直接终止自检。
        precondition(remoteImagePrivacyValid, "远程图片隐私策略自检失败")
        // 编辑器纯逻辑覆盖语法 token、Unicode 格式化和大文档降级。
        let editorSupportReport = MarkdownEditorSupportSelfCheck.run()
        // 任一编辑体验断言失败都立即输出具体原因。
        precondition(
            editorSupportReport.failures.isEmpty,
            editorSupportReport.failures.joined(separator: "；")
        )
        // 大纲纯逻辑覆盖混合换行和当前章节归属。
        let outlineFailures = MarkdownOutlineSupportSelfCheck.run()
        // 大纲映射失败不能继续伪装成功。
        precondition(outlineFailures.isEmpty, outlineFailures.joined(separator: "；"))

        // 约 200KB 文档先完整预热，再测三次中位数并使用 50ms 目标。
        let medium = measureDocument(requestedBytes: 200_000, targetMilliseconds: 50)
        // 约 1MB 文档同样完整预热，再测三次中位数并使用 200ms 目标。
        let large = measureDocument(requestedBytes: 1_000_000, targetMilliseconds: 200)
        // 汇总全部功能与性能结果。
        let report = Report(blockTypesValid: blockTypesValid, mediumDocument: medium, largeDocument: large)

        // 调用方可关闭标准输出，仅消费结构化报告。
        if printResults {
            // 输出块类型验证结果。
            print("增强 Markdown 块类型：通过")
            // 输出远程图片默认不联网的隐私策略结果。
            print("远程图片隐私：HTTP 已阻止，HTTPS 需逐图确认")
            // 输出 200KB 解析耗时和目标。
            print(format(medium))
            // 输出 1MB 解析耗时和目标。
            print(format(large))
            // 输出编辑器一兆字符文档的降级扫描耗时。
            print(
                "编辑高亮：Unicode/格式撤销/大文档降级通过，局部扫描 "
                    + "\(String(format: "%.2f", editorSupportReport.largeDocumentMilliseconds))ms"
            )
            // 输出大纲映射成功标记。
            print("大纲映射：Unicode/混合换行/当前章节通过")
        }
        // 独立自检默认把性能目标作为硬性验收条件。
        if enforcePerformanceTargets {
            // 200KB 文档必须低于 50ms。
            precondition(medium.passed, "200KB 解析耗时 \(medium.milliseconds)ms，超过 50ms")
            // 1MB 文档必须低于 200ms。
            precondition(large.passed, "1MB 解析耗时 \(large.milliseconds)ms，超过 200ms")
        }
        // 返回可供应用状态栏或测试代码消费的结构化结果。
        return report
    }

    // 验证功能样例中的增强块类型和关键关联值。
    private static func validateBlockTypes(_ blocks: [EnhancedPreviewBlock]) -> Bool {
        // 功能样例必须恰好生成九个块。
        guard blocks.count == 9 else { return false }
        // 第一个块必须是一号标题。
        guard blocks[0].kind == .heading(level: 1, text: "标题") else { return false }
        // 第二个块必须保留含行内 Markdown 的段落原文。
        guard blocks[1].kind == .paragraph("正文含 **粗体**、*斜体* 和 [链接](https://example.com)。") else { return false }
        // 第三个块必须同时包含普通项和已完成任务项。
        guard
            blocks[2].kind
                == .unorderedList([
                    .init(text: "普通项", taskState: nil),
                    .init(text: "已完成", taskState: .checked),
                ])
        else { return false }
        // 第四个块必须保留起始编号和未完成任务状态。
        guard
            blocks[3].kind
                == .orderedList(
                    start: 3,
                    items: [
                        .init(text: "第三项", taskState: nil),
                        .init(text: "待完成", taskState: .unchecked),
                    ])
        else { return false }
        // 第五个块必须是引用。
        guard blocks[4].kind == .quote("引用") else { return false }
        // 第六个块必须保存语言提示和原始代码。
        guard blocks[5].kind == .code(language: "swift", text: "let value = true") else { return false }
        // 第七个块必须是分割线。
        guard blocks[6].kind == .divider else { return false }
        // 第八个块必须保存完整图片信息。
        guard
            blocks[7].kind
                == .image(
                    alt: "示例图",
                    source: "https://example.com/image.png",
                    title: "图片标题"
                )
        else { return false }
        // 第九个块必须保存表头、对齐和数据行。
        guard
            blocks[8].kind
                == .table(
                    headers: ["名称", "数量"],
                    alignments: [.leading, .trailing],
                    rows: [["Markdown", "1"]]
                )
        else { return false }
        // 所有增强块类型和关键数据均符合预期。
        return true
    }

    // 验证远程图片不会因解析或预览默认分支直接联网。
    private static func validateRemoteImagePrivacy() -> Bool {
        // 明文 HTTP 无论主机是否合法都必须永久阻止。
        let httpDecision = EnhancedImageSourceResolver.remoteImageDecision(
            for: "http://tracker.example/pixel.png?user=secret"
        )
        // 只有明确 blocked 才能证明界面不会提供加载入口。
        guard httpDecision == .blocked else { return false }
        // 解析器入口也不能把 HTTP 返回为可加载 URL。
        guard
            EnhancedImageSourceResolver.resolve(
                "http://tracker.example/pixel.png",
                documentURL: nil
            ) == nil
        else { return false }

        // HTTPS 地址必须转换成尚待确认的纯数据描述。
        let httpsDecision = EnhancedImageSourceResolver.remoteImageDecision(
            for: "https://Images.Example.com/pixel.png?token=secret"
        )
        // 提取确认请求以核对真实 URL 和脱敏主机展示。
        guard case let .requiresConfirmation(request) = httpsDecision else { return false }
        // 展示值只能保留小写主机，不能包含路径、查询或令牌。
        guard request.displayHost == "images.example.com" else { return false }
        // 请求 URL 必须仍保持 HTTPS，用户确认后才能交给 AsyncImage。
        guard request.url.scheme?.lowercased() == "https" else { return false }
        // 通用解析器不得返回未确认的 HTTPS URL，避免后续调用方绕过界面授权。
        guard
            EnhancedImageSourceResolver.resolve(
                "https://images.example.com/pixel.png",
                documentURL: nil
            ) == nil
        else { return false }
        // 完整隐私策略符合预期。
        return true
    }

    // 生成指定体量文档，完整预热后测三次并返回中位数。
    private static func measureDocument(requestedBytes: Int, targetMilliseconds: Double) -> Measurement {
        // 基准单元覆盖标题、行内语法、任务列表、引用、代码和表格。
        let unit = """
            ## 性能检查

            这是含 **粗体**、*斜体* 和 [链接](https://example.com) 的正文。

            - [x] 已完成
            - 普通项

            > 引用正文

            ```swift
            let value = true
            ```

            | 名称 | 数量 |
            | :--- | ---: |
            | Markdown | 1 |

            """
        // 按 UTF-8 字节数计算足以覆盖目标体量的重复次数。
        let repetitions = Int(ceil(Double(requestedBytes) / Double(unit.utf8.count)))
        // 一次性生成基准文档，生成耗时不计入解析数据。
        let document = String(repeating: unit, count: repetitions)
        // 先完整解析同一目标文档，预热对应体量的分配器和解析热路径。
        let expectedBlockCount = EnhancedMarkdownParser.parse(document).count
        // 非空基准必须生成真实块，防止性能调用退化成空操作。
        precondition(expectedBlockCount > 0, "性能基准未生成 Markdown 块")
        // 保存三次独立完整解析耗时供中位数消除远端 CI 瞬时抖动。
        var measurements: [Double] = []
        // 固定容量避免数组扩容噪声进入测量之间的控制路径。
        measurements.reserveCapacity(3)
        // 固定执行三次，不放宽任何体量或时间阈值。
        for _ in 0..<3 {
            // 使用系统单调时钟记录本次完整解析起点。
            let startedAt = ProcessInfo.processInfo.systemUptime
            // 执行与应用集成入口相同的完整块解析。
            let blocks = EnhancedMarkdownParser.parse(document)
            // 使用同一单调时钟换算本次毫秒耗时。
            let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            // 每次块数量必须与完整预热一致，防止不稳定结果伪装性能通过。
            precondition(
                blocks.count == expectedBlockCount,
                "性能基准块数量不一致：预期 \(expectedBlockCount)，实际 \(blocks.count)"
            )
            // 只在结果完整一致后记录本次耗时。
            measurements.append(milliseconds)
        }
        // 三个样本排序后的中间值可屏蔽一次远端 CI 调度尖峰。
        let medianMilliseconds = measurements.sorted()[1]
        // 返回包含实际字节数、块数量和阈值的结构化结果。
        return Measurement(
            requestedBytes: requestedBytes,
            actualBytes: document.utf8.count,
            blockCount: expectedBlockCount,
            milliseconds: medianMilliseconds,
            targetMilliseconds: targetMilliseconds
        )
    }

    // 把单档性能数据格式化为可复核输出。
    private static func format(_ measurement: Measurement) -> String {
        // 体量按用户更熟悉的 KB 和 MB 标签显示。
        let sizeLabel = measurement.requestedBytes >= 1_000_000 ? "1MB" : "200KB"
        // 同时输出实际字节数、块数量、耗时、阈值和结果。
        return
            "\(sizeLabel)：\(measurement.actualBytes) 字节，\(measurement.blockCount) 块，\(String(format: "%.2f", measurement.milliseconds))ms / <\(Int(measurement.targetMilliseconds))ms，\(measurement.passed ? "通过" : "未通过")"
    }
}

// 允许仅编译本文件时直接执行增强解析自检，不影响应用正式入口。
#if ENHANCED_MARKDOWN_STANDALONE
    @main
    private enum EnhancedMarkdownStandaloneCheck {
        // 独立进程只运行功能和性能检查。
        static func main() {
            // 默认打印结果并严格执行两档性能阈值。
            EnhancedMarkdownSelfCheck.run()
        }
    }
#endif
