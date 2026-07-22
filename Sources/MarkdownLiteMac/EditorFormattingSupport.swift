import Foundation

// 定义菜单和快捷键可以调用的 Markdown 原生格式操作。
enum MarkdownEditorFormattingCommand: Equatable, Sendable {
    // 使用双星号包裹选区。
    case bold
    // 使用单星号包裹选区。
    case italic
    // 使用反引号包裹选区。
    case inlineCode
    // 把选区转换成带待填写地址的链接。
    case link
    // 把选区覆盖的逻辑行转换为指定级别标题。
    case heading(level: Int)
}

// 保存一次可交给 NSTextView 的纯文本替换计划。
struct MarkdownFormattingEdit: Equatable, Sendable {
    // 指定原文中需要被替换的 UTF-16 范围。
    let replacementRange: NSRange
    // 保存进入文本系统和撤销栈的新字符串。
    let replacement: String
    // 替换完成后需要恢复的 UTF-16 选区。
    let selectionAfterEdit: NSRange
}

// 以纯逻辑生成格式化编辑，便于覆盖 Unicode 和可逆性自检。
enum MarkdownFormattingSupport {
    // 生成一项格式操作；非法选区安全返回 nil。
    static func edit(
        in source: String,
        selection: NSRange,
        command: MarkdownEditorFormattingCommand
    ) -> MarkdownFormattingEdit? {
        // NSTextView 和 NSString 都使用 UTF-16 范围，先验证边界。
        let content = source as NSString
        // NSNotFound 或越界选区不能进入文本系统。
        guard selection.location != NSNotFound,
            selection.location <= content.length,
            selection.length <= content.length - selection.location
        else { return nil }

        // 每个行内操作复用同一套包裹与取消包裹逻辑。
        switch command {
        case .bold:
            return wrappingEdit(in: content, selection: selection, prefix: "**", suffix: "**")
        case .italic:
            return wrappingEdit(in: content, selection: selection, prefix: "*", suffix: "*")
        case .inlineCode:
            return wrappingEdit(in: content, selection: selection, prefix: "`", suffix: "`")
        case .link:
            return linkEdit(in: content, selection: selection)
        case let .heading(level):
            return headingEdit(in: content, selection: selection, level: level)
        }
    }

    // 生成可重复执行以切换开关的行内包裹编辑。
    private static func wrappingEdit(
        in content: NSString,
        selection: NSRange,
        prefix: String,
        suffix: String
    ) -> MarkdownFormattingEdit {
        // 标记长度按 UTF-16 计算，与 NSTextView 选区坐标一致。
        let prefixLength = (prefix as NSString).length
        // 后缀长度独立计算，允许未来使用不对称标记。
        let suffixLength = (suffix as NSString).length
        // 选区外侧已经存在同类标记时执行取消包裹。
        if selection.location >= prefixLength,
            NSMaxRange(selection) + suffixLength <= content.length
        {
            // 读取紧邻选区左侧的标记。
            let existingPrefix = content.substring(
                with: NSRange(
                    location: selection.location - prefixLength,
                    length: prefixLength
                ))
            // 读取紧邻选区右侧的标记。
            let existingSuffix = content.substring(
                with: NSRange(
                    location: NSMaxRange(selection),
                    length: suffixLength
                ))
            // 两侧同时匹配才可安全移除，避免误删普通字符。
            if existingPrefix == prefix, existingSuffix == suffix {
                // 读取选区可见正文。
                let selectedText = content.substring(with: selection)
                // 替换范围同时覆盖两侧标记。
                let replacementRange = NSRange(
                    location: selection.location - prefixLength,
                    length: prefixLength + selection.length + suffixLength
                )
                // 取消包裹后继续选中原有正文。
                let selectionAfterEdit = NSRange(
                    location: replacementRange.location,
                    length: selection.length
                )
                // 返回单次替换，确保撤销只需要一步。
                return MarkdownFormattingEdit(
                    replacementRange: replacementRange,
                    replacement: selectedText,
                    selectionAfterEdit: selectionAfterEdit
                )
            }
        }

        // 读取当前选区，空选区会得到空字符串。
        let selectedText = content.substring(with: selection)
        // 把正文放在配对标记中间。
        let replacement = prefix + selectedText + suffix
        // 有正文时继续选中正文，空选区时把光标放在标记中间。
        let selectionAfterEdit = NSRange(
            location: selection.location + prefixLength,
            length: selection.length
        )
        // 单次替换天然进入 NSTextView 的单步撤销记录。
        return MarkdownFormattingEdit(
            replacementRange: selection,
            replacement: replacement,
            selectionAfterEdit: selectionAfterEdit
        )
    }

    // 生成 Markdown 链接编辑并选择下一步最需要填写的字段。
    private static func linkEdit(in content: NSString, selection: NSRange) -> MarkdownFormattingEdit {
        // 有选区时把选中文字作为链接标题。
        let selectedText = content.substring(with: selection)
        // 空选区提供可直接覆盖的中文占位标题。
        let label = selectedText.isEmpty ? "链接文字" : selectedText
        // 地址使用安全的可见占位，不自动猜测剪贴板内容。
        let destination = "https://"
        // 生成标准 Markdown 行内链接。
        let replacement = "[\(label)](\(destination))"
        // 空选区优先选择标题，已有标题时优先选择待填写地址。
        let selectionAfterEdit: NSRange
        if selectedText.isEmpty {
            // 左方括号占用一个 UTF-16 位置。
            selectionAfterEdit = NSRange(location: selection.location + 1, length: (label as NSString).length)
        } else {
            // 地址起点位于左方括号、标题和右括号圆括号之后。
            let destinationLocation = selection.location + 1 + selection.length + 2
            // 选择整个地址占位便于一次覆盖。
            selectionAfterEdit = NSRange(location: destinationLocation, length: (destination as NSString).length)
        }
        // 返回一项可撤销替换。
        return MarkdownFormattingEdit(
            replacementRange: selection,
            replacement: replacement,
            selectionAfterEdit: selectionAfterEdit
        )
    }

    // 把当前选区覆盖的完整逻辑行转换为统一标题级别。
    private static func headingEdit(
        in content: NSString,
        selection: NSRange,
        level: Int
    ) -> MarkdownFormattingEdit {
        // 标题级别严格限制在 Markdown 支持的一到六级。
        let safeLevel = min(6, max(1, level))
        // 新标题标记始终包含一个分隔空格。
        let marker = String(repeating: "#", count: safeLevel) + " "
        // 空文档没有可枚举行，直接插入标题标记。
        guard content.length > 0 else {
            // 光标放在标记后供用户立即输入标题。
            return MarkdownFormattingEdit(
                replacementRange: selection,
                replacement: marker,
                selectionAfterEdit: NSRange(location: (marker as NSString).length, length: 0)
            )
        }

        // 标准行范围会包含选区覆盖的换行符并保持原换行风格。
        let lineRange = content.lineRange(for: selection)
        // 以换行结尾时 EOF 代表一个真实空行，但 NSString 返回零长度行范围。
        guard lineRange.length > 0 else {
            // 在末尾空行直接插入标题标记。
            return MarkdownFormattingEdit(
                replacementRange: selection,
                replacement: marker,
                selectionAfterEdit: NSRange(
                    location: selection.location + (marker as NSString).length,
                    length: 0
                )
            )
        }
        // 预留接近原范围的结果容量。
        var replacement = String()
        replacement.reserveCapacity(lineRange.length + marker.utf8.count * 2)
        // 从首个完整逻辑行开始转换。
        var location = lineRange.location
        // 记录空选区转换后的精确光标位置。
        var caretAfterEdit: Int?

        // 每轮消费一个完整逻辑行。
        while location < NSMaxRange(lineRange) {
            // 获取内容和换行边界。
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            content.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            // 限制到本次替换范围，避免意外消费下一块内容。
            lineEnd = min(lineEnd, NSMaxRange(lineRange))
            contentsEnd = min(contentsEnd, lineEnd)
            // 读取不含换行的原行正文。
            let originalLine = content.substring(
                with: NSRange(
                    location: lineStart,
                    length: max(0, contentsEnd - lineStart)
                ))
            // 识别并移除原有一到六级标题标记。
            let oldPrefixLength = existingHeadingPrefixLength(in: originalLine)
            // 以 UTF-16 范围移除旧标记，避免 emoji 改变坐标。
            let originalLineStorage = originalLine as NSString
            // 标题正文保留原始字符和空白。
            let body = originalLineStorage.substring(from: oldPrefixLength)
            // 当前输出行在替换字符串中的 UTF-16 起点。
            let outputLineStart = (replacement as NSString).length
            // 追加新标记和正文。
            replacement += marker + body
            // 原行换行符按原样追加，兼容 LF、CRLF 和 CR。
            if lineEnd > contentsEnd {
                replacement += content.substring(
                    with: NSRange(
                        location: contentsEnd,
                        length: lineEnd - contentsEnd
                    ))
            }

            // 空选区位于当前行时计算语义等价的新光标。
            if selection.length == 0,
                selection.location >= lineStart,
                selection.location <= contentsEnd
            {
                // 原光标在标题正文中的列不能为负数。
                let bodyColumn = max(0, selection.location - lineStart - oldPrefixLength)
                // 新光标位于新标记之后的同一正文列。
                caretAfterEdit = lineRange.location + outputLineStart + (marker as NSString).length + bodyColumn
            }
            // 防御异常零长度行范围，确保循环前进。
            guard lineEnd > location else { break }
            // 继续处理下一行。
            location = lineEnd
        }

        // 空选区恢复单个光标，多行选区继续选中转换后的完整行。
        let selectionAfterEdit =
            selection.length == 0
            ? NSRange(location: caretAfterEdit ?? lineRange.location + (marker as NSString).length, length: 0)
            : NSRange(location: lineRange.location, length: (replacement as NSString).length)
        // 用一次批量替换保证多行标题也只产生一条撤销记录。
        return MarkdownFormattingEdit(
            replacementRange: lineRange,
            replacement: replacement,
            selectionAfterEdit: selectionAfterEdit
        )
    }

    // 返回一行开头已有标题标记的 UTF-16 长度。
    private static func existingHeadingPrefixLength(in line: String) -> Int {
        // 正则只匹配最多三个缩进空格、井号和必需分隔空白。
        let pattern = #"^[ \t]{0,3}#{1,6}[ \t]+"#
        // 固定模式理论上不会失败，失败时按普通正文处理。
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        // 在完整 UTF-16 行范围内查找唯一前缀。
        let range = NSRange(location: 0, length: (line as NSString).length)
        // 没有标题标记时不移除任何字符。
        guard let match = expression.firstMatch(in: line, range: range) else { return 0 }
        // 返回匹配标记长度供正文切片和光标映射复用。
        return match.range.length
    }
}

// 定义纯语法扫描器输出的样式语义。
enum MarkdownEditorSyntaxKind: Equatable, Sendable {
    // 标题保存级别供编辑器选择字号。
    case heading(level: Int)
    // 粗体语法使用更高字重。
    case strong
    // 斜体语法使用倾斜属性。
    case emphasis
    // 行内代码使用等宽底色。
    case inlineCode
    // 围栏代码块统一使用代码配色。
    case codeBlock
    // 链接使用强调色和下划线。
    case link
    // 引用行使用次级颜色。
    case quote
}

// 保存一个 UTF-16 语法范围及其样式语义。
struct MarkdownEditorSyntaxToken: Equatable, Sendable {
    // 范围直接用于 NSLayoutManager 临时属性。
    let range: NSRange
    // 类型决定主线程应用的原生颜色和字体。
    let kind: MarkdownEditorSyntaxKind
}

// 为短文档和大文档选择不同的安全高亮范围。
enum MarkdownEditorHighlightPlanner {
    // 256K UTF-16 以内全文高亮，常规文章无需可见区补刷。
    static let fullDocumentLimit = 262_144
    // 大文档单次最多扫描 96K UTF-16，避免一次属性更新拖慢输入。
    static let maximumIncrementalLength = 98_304
    // 大文档在可见区两侧保留上下文，减少滚动时样式跳变。
    private static let contextLength = 8_192

    // 返回本轮需要扫描和刷新临时属性的完整行范围。
    static func targetRange(
        in source: String,
        editedRange: NSRange?,
        visibleRange: NSRange?
    ) -> NSRange {
        // 所有坐标都以 NSString 的 UTF-16 长度为准。
        let content = source as NSString
        // 空文档没有可高亮范围。
        guard content.length > 0 else { return NSRange(location: 0, length: 0) }
        // 常规文档直接返回全文，保证跨行围栏准确。
        if content.length <= fullDocumentLimit {
            return NSRange(location: 0, length: content.length)
        }

        // 优先使用当前可见区，缺失时回退最近编辑位置。
        var seed =
            validRange(visibleRange, upperBound: content.length)
            ?? validRange(editedRange, upperBound: content.length)
            ?? NSRange(location: 0, length: min(content.length, maximumIncrementalLength))
        // 当前编辑位置若与可见区接近则合并，避免光标行遗漏。
        if let edited = validRange(editedRange, upperBound: content.length) {
            // 计算合并后跨度。
            let lower = min(seed.location, edited.location)
            // 右边界同时覆盖两段范围。
            let upper = max(NSMaxRange(seed), NSMaxRange(edited))
            // 只有合并后仍处于上限内才采用。
            if upper - lower <= maximumIncrementalLength {
                seed = NSRange(location: lower, length: upper - lower)
            }
        }
        // 向前扩展有限上下文并防止负位置。
        let lower = max(0, seed.location - contextLength)
        // 向后扩展上下文并限制文档末尾。
        let upper = min(content.length, NSMaxRange(seed) + contextLength)
        // 超过单次上限时以可见区中心附近裁剪。
        let boundedUpper = min(upper, lower + maximumIncrementalLength)
        // 扩展到完整逻辑行，避免半行正则产生错误标记。
        let lineRange = content.lineRange(for: NSRange(location: lower, length: boundedUpper - lower))
        // 正常行长允许完整扩展，提升标题和围栏准确性。
        if lineRange.length <= maximumIncrementalLength {
            // NSString 可能把末行范围扩到结尾，最终再次与全文相交。
            return NSIntersectionRange(lineRange, NSRange(location: 0, length: content.length))
        }
        // 极端超长单行严格保持扫描上限，安全性优先于该行完整高亮。
        return NSRange(location: lower, length: boundedUpper - lower)
    }

    // 验证可选范围并裁剪到全文内部。
    private static func validRange(_ range: NSRange?, upperBound: Int) -> NSRange? {
        // 缺失或 NSNotFound 范围不可使用。
        guard let range, range.location != NSNotFound, range.location <= upperBound else { return nil }
        // 长度限制到剩余内容，避免整数越界。
        let length = min(range.length, upperBound - range.location)
        // 返回合法 UTF-16 范围。
        return NSRange(location: range.location, length: length)
    }
}

// 使用 Foundation 线性行扫描和少量正则生成编辑器高亮语义。
enum MarkdownEditorSyntaxHighlighter {
    // 粗体只接受单行配对双星号或双下划线。
    private static let strongExpression = try! NSRegularExpression(
        pattern: #"(\*\*[^*\n]+\*\*|__[^_\n]+__)"#
    )
    // 斜体排除双标记边界，避免与粗体重复匹配。
    private static let emphasisExpression = try! NSRegularExpression(
        pattern: #"(?<!\*)\*(?!\*)[^*\n]+\*(?!\*)|(?<!_)_(?!_)[^_\n]+_(?!_)"#
    )
    // 首版行内代码只识别单反引号配对，复杂嵌套安全退化为普通文本。
    private static let inlineCodeExpression = try! NSRegularExpression(
        pattern: #"(?<!`)`[^`\n]+`(?!`)"#
    )
    // 链接和图片共用安全的单行方括号圆括号结构。
    private static let linkExpression = try! NSRegularExpression(
        pattern: #"!?\[[^\]\n]+\]\([^\)\n]+\)"#
    )

    // 扫描指定完整行范围并返回不修改原文的高亮 token。
    static func tokens(in source: String, range requestedRange: NSRange) -> [MarkdownEditorSyntaxToken] {
        // 已取消任务在触碰正文前立即结束。
        guard !Task.isCancelled else { return [] }
        // NSString 保证所有 token 坐标可直接交给 AppKit。
        let content = source as NSString
        // 空范围或非法起点不产生 token。
        guard content.length > 0,
            requestedRange.location != NSNotFound,
            requestedRange.location < content.length
        else { return [] }
        // 把调用方范围限制到全文。
        let safeLength = min(requestedRange.length, content.length - requestedRange.location)
        // 常规文本扩展到完整行保证标题、引用和围栏识别稳定。
        let expandedLineRange = NSIntersectionRange(
            content.lineRange(for: NSRange(location: requestedRange.location, length: safeLength)),
            NSRange(location: 0, length: content.length)
        )
        // 极端超长行不能突破大文档单次扫描上限。
        let scanRange =
            expandedLineRange.length <= MarkdownEditorHighlightPlanner.maximumIncrementalLength
            ? expandedLineRange
            : NSRange(location: requestedRange.location, length: safeLength)
        // 保存所有块级 token。
        var tokens: [MarkdownEditorSyntaxToken] = []
        // 保存代码块范围以阻止内部行内语法被重复高亮。
        var codeRanges: [NSRange] = []
        // 保存尚未闭合的围栏类型、长度和起点。
        var openFence: (marker: Character, length: Int, location: Int)?
        // 从目标区域首行开始扫描。
        var location = scanRange.location

        // 每轮消费一个 NSString 逻辑行。
        while location < NSMaxRange(scanRange) {
            // 新输入取消扫描后不再继续遍历旧正文。
            guard !Task.isCancelled else { return [] }
            // 获取完整行和正文边界。
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            content.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            // 局部扫描可能从极端超长行中部开始，不能向前越过安全范围。
            lineStart = max(lineStart, scanRange.location)
            // 范围末尾不能越过本次降级扫描区域。
            lineEnd = min(lineEnd, NSMaxRange(scanRange))
            contentsEnd = min(contentsEnd, lineEnd)
            // 读取当前可见行正文。
            let line = content.substring(
                with: NSRange(
                    location: lineStart,
                    length: max(0, contentsEnd - lineStart)
                ))
            // 提取可能的围栏标记。
            let fence = fenceMarker(in: line)

            // 已在代码块内时只寻找匹配闭合围栏。
            if let opening = openFence {
                // 同类且长度足够、尾部仅空白的标记关闭代码块。
                if let fence,
                    fence.marker == opening.marker,
                    fence.length >= opening.length,
                    fence.trailingText.isEmpty
                {
                    // 代码范围包含闭合行和换行符。
                    let codeRange = NSRange(
                        location: opening.location,
                        length: lineEnd - opening.location
                    )
                    // 保存代码范围供块样式和行内排除复用。
                    codeRanges.append(codeRange)
                    // 当前围栏已经闭合。
                    openFence = nil
                }
            } else if let fence {
                // 不在代码块时任何合法标记都开启新围栏。
                openFence = (fence.marker, fence.length, lineStart)
            } else {
                // 普通行优先识别 ATX 标题。
                if let level = headingLevel(in: line) {
                    // 标题 token 不包含换行符。
                    tokens.append(
                        .init(
                            range: NSRange(location: lineStart, length: contentsEnd - lineStart),
                            kind: .heading(level: level)
                        ))
                }
                // 引用整行使用次级颜色，内部仍允许行内样式叠加。
                if isQuoteLine(line) {
                    // 引用 token 不包含换行符。
                    tokens.append(
                        .init(
                            range: NSRange(location: lineStart, length: contentsEnd - lineStart),
                            kind: .quote
                        ))
                }
            }

            // 防御异常零长度行范围。
            guard lineEnd > location else { break }
            // 移动到下一逻辑行。
            location = lineEnd
        }

        // 扫描区域内未闭合围栏安全高亮到区域末尾。
        if let opening = openFence {
            // 只影响当前有限扫描范围，不扩张到整个大文档。
            codeRanges.append(
                NSRange(
                    location: opening.location,
                    length: NSMaxRange(scanRange) - opening.location
                ))
        }
        // 把每个代码范围转换为高优先级 token。
        tokens.append(contentsOf: codeRanges.map { .init(range: $0, kind: .codeBlock) })
        // 行内四类语法分别扫描，规则数量固定。
        appendMatches(
            expression: strongExpression,
            kind: .strong,
            source: source,
            scanRange: scanRange,
            blockedRanges: codeRanges,
            to: &tokens
        )
        // 每类正则之间检查取消，单次不可中断区间限制在一个 96K 规则内。
        guard !Task.isCancelled else { return [] }
        appendMatches(
            expression: emphasisExpression,
            kind: .emphasis,
            source: source,
            scanRange: scanRange,
            blockedRanges: codeRanges,
            to: &tokens
        )
        // 斜体扫描完成后再次响应新输入取消。
        guard !Task.isCancelled else { return [] }
        appendMatches(
            expression: inlineCodeExpression,
            kind: .inlineCode,
            source: source,
            scanRange: scanRange,
            blockedRanges: codeRanges,
            to: &tokens
        )
        // 行内代码扫描完成后再次响应新输入取消。
        guard !Task.isCancelled else { return [] }
        appendMatches(
            expression: linkExpression,
            kind: .link,
            source: source,
            scanRange: scanRange,
            blockedRanges: codeRanges,
            to: &tokens
        )
        // 最终排序前丢弃已经过期的整轮结果。
        guard !Task.isCancelled else { return [] }
        // 按样式优先级和位置稳定排序，保证标题字号不被内部粗体覆盖。
        return tokens.sorted { lhs, rhs in
            // 先比较叠加优先级。
            let lhsPriority = stylePriority(lhs.kind)
            // 保存右侧优先级避免重复计算。
            let rhsPriority = stylePriority(rhs.kind)
            // 不同优先级先应用基础块色，再应用更具体的样式。
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            // 同类样式按原文先后排列。
            return lhs.range.location < rhs.range.location
        }
    }

    // 从一行提取围栏字符、长度和尾部信息。
    private static func fenceMarker(in line: String) -> (marker: Character, length: Int, trailingText: String)? {
        // Markdown 最多允许三个前导普通空格或制表符。
        let leadingCount = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        // 更深缩进视为代码正文而不是围栏。
        guard leadingCount <= 3 else { return nil }
        // 去掉允许的前导空白。
        let trimmed = line.dropFirst(leadingCount)
        // 围栏只能使用反引号或波浪号。
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        // 统计连续同类标记数量。
        let markerLength = trimmed.prefix(while: { $0 == marker }).count
        // 少于三个标记不是围栏。
        guard markerLength >= 3 else { return nil }
        // 尾部文本去掉普通空白供闭合判断。
        let trailing = trimmed.dropFirst(markerLength).trimmingCharacters(in: .whitespaces)
        // 返回完整围栏信息。
        return (marker, markerLength, trailing)
    }

    // 识别一到六级 ATX 标题。
    private static func headingLevel(in line: String) -> Int? {
        // 标题同样只允许最多三个前导空白。
        let leadingCount = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        // 深缩进不解释为标题。
        guard leadingCount <= 3 else { return nil }
        // 去掉允许的缩进。
        let trimmed = line.dropFirst(leadingCount)
        // 统计井号数量。
        let level = trimmed.prefix(while: { $0 == "#" }).count
        // 级别必须在一到六之间。
        guard (1...6).contains(level) else { return nil }
        // 井号后必须存在空白分隔符。
        let separatorIndex = trimmed.index(trimmed.startIndex, offsetBy: level)
        guard separatorIndex < trimmed.endIndex, trimmed[separatorIndex].isWhitespace else { return nil }
        // 返回合法标题级别。
        return level
    }

    // 判断一行是否以合法引用标记开头。
    private static func isQuoteLine(_ line: String) -> Bool {
        // 引用最多允许三个前导空白。
        let leadingCount = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        // 深缩进不视为引用。
        guard leadingCount <= 3 else { return false }
        // 去掉允许的缩进后匹配大于号。
        return line.dropFirst(leadingCount).first == ">"
    }

    // 把一项正则的非代码匹配追加为 token。
    private static func appendMatches(
        expression: NSRegularExpression,
        kind: MarkdownEditorSyntaxKind,
        source: String,
        scanRange: NSRange,
        blockedRanges: [NSRange],
        to tokens: inout [MarkdownEditorSyntaxToken]
    ) {
        // 一次获取当前规则全部匹配。
        let matches = expression.matches(in: source, range: scanRange)
        // 逐个过滤代码块内部结果。
        for match in matches {
            // 新输入到来时停止处理旧正则结果。
            guard !Task.isCancelled else { return }
            // 与任一代码范围相交时不能解释为行内语法。
            guard !overlapsSortedRanges(match.range, blockedRanges) else { continue }
            // 保存安全的完整匹配范围。
            tokens.append(.init(range: match.range, kind: kind))
        }
    }

    // 使用二分搜索判断 token 是否与已排序代码范围相交。
    private static func overlapsSortedRanges(_ range: NSRange, _ blockedRanges: [NSRange]) -> Bool {
        // 没有代码块时可以立即返回。
        guard !blockedRanges.isEmpty else { return false }
        // 二分查找第一个结束位置晚于 token 起点的代码块。
        var lower = 0
        // 上界采用数组数量的半开区间。
        var upper = blockedRanges.count
        // 收缩到可能相交的首个范围。
        while lower < upper {
            // 计算中点避免线性扫描大量代码块。
            let middle = lower + (upper - lower) / 2
            // 完全位于 token 左侧的范围可以跳过。
            if NSMaxRange(blockedRanges[middle]) <= range.location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        // 所有代码块都在左侧时不存在交集。
        guard lower < blockedRanges.count else { return false }
        // 首个候选起点早于 token 末尾即表示相交。
        return blockedRanges[lower].location < NSMaxRange(range)
    }

    // 返回临时属性叠加顺序。
    private static func stylePriority(_ kind: MarkdownEditorSyntaxKind) -> Int {
        // 块级字体最后应用，避免行内粗体把标题字号覆盖。
        switch kind {
        case .quote: return 0
        case .strong, .emphasis: return 1
        case .heading: return 2
        case .link: return 3
        case .inlineCode: return 4
        case .codeBlock: return 5
        }
    }
}

// 为格式化、Unicode 范围和大文档降级提供无界面自检。
enum MarkdownEditorSupportSelfCheck {
    // 保存自检失败项和大文档局部扫描耗时。
    struct Report: Equatable, Sendable {
        // 空数组表示所有功能断言通过。
        let failures: [String]
        // 记录一兆字符文档的局部高亮扫描耗时。
        let largeDocumentMilliseconds: Double
    }

    // 执行纯逻辑检查，不读取剪贴板或真实文档。
    static func run() -> Report {
        // 汇总所有失败原因便于一次定位。
        var failures: [String] = []
        // 构造长度和首尾八字节相同、仅中部不同的外部替换。
        let originalEchoText = "12345678-原始中部-ABCDEFGH"
        // 替换文本保持中部 UTF-8 字节长度一致，专门制造轻量签名碰撞。
        let externalMiddleReplacement = "12345678-替换中部-ABCDEFGH"
        // 连续字符串应生成可比较签名。
        let originalSignature = NativeTextSignature(originalEchoText)
        // 外部替换也生成同规则签名。
        let replacementSignature = NativeTextSignature(externalMiddleReplacement)
        // 轻量签名不能把中部等长替换证明为相同正文。
        if NativeTextComparison.signaturesProveDifference(originalSignature, replacementSignature) {
            failures.append("轻量签名错误证明中部替换")
        }
        // 后台严格核对必须识别这次真实外部变化。
        if !NativeTextComparison.differsExactly(originalEchoText, externalMiddleReplacement) {
            failures.append("同签名外部替换未被严格核对识别")
        }
        // 样例在语法前放置 emoji，验证 UTF-16 坐标不按 Character 错算。
        let sample = "😀 前缀\n# 标题\n> 引用 **粗体** *斜体* `代码` [链接](https://example.com)\n```swift\n**代码内不高亮**\n```\n"
        // 扫描完整样例。
        let sampleRange = NSRange(location: 0, length: (sample as NSString).length)
        // 获取所有语法 token。
        let tokens = MarkdownEditorSyntaxHighlighter.tokens(in: sample, range: sampleRange)
        // 关键语法类型必须全部出现。
        let kinds = tokens.map(\.kind)
        // 标题层级必须保留。
        if !kinds.contains(.heading(level: 1)) { failures.append("标题高亮缺失") }
        // 引用必须识别。
        if !kinds.contains(.quote) { failures.append("引用高亮缺失") }
        // 四种行内样式必须识别。
        if !kinds.contains(.strong) || !kinds.contains(.emphasis) || !kinds.contains(.inlineCode)
            || !kinds.contains(.link)
        {
            failures.append("行内语法高亮缺失")
        }
        // 围栏代码必须形成独立块。
        if !kinds.contains(.codeBlock) { failures.append("围栏代码高亮缺失") }
        // 代码块内部的粗体字面量不能产生额外 token。
        let strongCount = kinds.filter { $0 == .strong }.count
        if strongCount != 1 { failures.append("代码块内部语法未隔离") }
        // 每个 token 都必须落在合法 UTF-16 范围。
        let sampleLength = (sample as NSString).length
        if tokens.contains(where: { $0.range.location == NSNotFound || NSMaxRange($0.range) > sampleLength }) {
            failures.append("Unicode token 范围越界")
        }

        // 选择 emoji 后的中文正文验证格式化范围。
        let boldSource = "😀中文"
        // 中文两个字符从 UTF-16 位置二开始。
        let boldSelection = NSRange(location: 2, length: 2)
        // 生成粗体编辑。
        if let edit = MarkdownFormattingSupport.edit(in: boldSource, selection: boldSelection, command: .bold) {
            // 应用编辑后的字符串必须保持 emoji 完整。
            let mutable = NSMutableString(string: boldSource)
            // 保存被替换原文用于模拟撤销。
            let replaced = mutable.substring(with: edit.replacementRange)
            // 应用与 NSTextView 相同的单次替换。
            mutable.replaceCharacters(in: edit.replacementRange, with: edit.replacement)
            // 粗体结果必须符合 Markdown。
            if mutable as String != "😀**中文**" { failures.append("Unicode 粗体编辑错误") }
            // 用单次逆替换模拟撤销管理器恢复原文。
            mutable.replaceCharacters(
                in: NSRange(location: edit.replacementRange.location, length: (edit.replacement as NSString).length),
                with: replaced
            )
            // 逆替换必须精确恢复原字符串。
            if mutable as String != boldSource { failures.append("格式化编辑不可逆") }
        } else {
            failures.append("Unicode 粗体编辑未生成")
        }

        // 一兆字符文档验证只扫描可见区而不是全文。
        let largeDocument = String(repeating: "普通正文 **粗体** 与 [链接](https://example.com)\n", count: 24_000)
        // 可见区放在文档中部，覆盖实际滚动场景。
        let largeLength = (largeDocument as NSString).length
        // 使用约四千 UTF-16 的可见范围。
        let visibleRange = NSRange(location: largeLength / 2, length: min(4_096, largeLength / 2))
        // 规划大文档安全降级范围。
        let targetRange = MarkdownEditorHighlightPlanner.targetRange(
            in: largeDocument,
            editedRange: visibleRange,
            visibleRange: visibleRange
        )
        // 单次范围不得超过上限加一个末行容差。
        if targetRange.length > MarkdownEditorHighlightPlanner.maximumIncrementalLength + 512 {
            failures.append("大文档高亮未降级")
        }
        // 记录局部扫描起点。
        let startedAt = ProcessInfo.processInfo.systemUptime
        // 执行与编辑器相同的纯语法扫描。
        _ = MarkdownEditorSyntaxHighlighter.tokens(in: largeDocument, range: targetRange)
        // 换算毫秒供命令行输出。
        let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        // 局部扫描不设置过紧机器相关阈值，只阻止明显全文退化。
        if milliseconds >= 100 { failures.append("大文档局部高亮超过 100ms") }
        // 构造一兆字符单行，覆盖 lineRange 可能扩张全文的极端输入。
        let longLine = String(repeating: "**x**", count: 200_000)
        // 只请求超长行中部的可见范围。
        let longLineLength = (longLine as NSString).length
        // 规划器必须继续遵守局部上限。
        let longLineTarget = MarkdownEditorHighlightPlanner.targetRange(
            in: longLine,
            editedRange: nil,
            visibleRange: NSRange(location: longLineLength / 2, length: 2_048)
        )
        // 超长行目标不能扩张为全文。
        if longLineTarget.length > MarkdownEditorHighlightPlanner.maximumIncrementalLength {
            failures.append("超长单行高亮未降级")
        }
        // 扫描器也必须把 token 限制在规划范围内。
        let longLineTokens = MarkdownEditorSyntaxHighlighter.tokens(in: longLine, range: longLineTarget)
        // 任一 token 越界都说明扫描器重新扩张了整行。
        if longLineTokens.contains(where: {
            $0.range.location < longLineTarget.location || NSMaxRange($0.range) > NSMaxRange(longLineTarget)
        }) {
            failures.append("超长单行 token 越过降级范围")
        }
        // 返回完整可复核结果。
        return Report(failures: failures, largeDocumentMilliseconds: milliseconds)
    }
}
