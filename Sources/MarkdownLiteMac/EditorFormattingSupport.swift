import Dispatch
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
    // 切换当前逻辑行已有任务标记的完成状态。
    case toggleTask
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

// 为原生 Return 生成一次最小列表替换，不依赖异步预览或完整 Markdown 解析。
enum MarkdownListContinuationSupport {
    // 围栏外一次搜索两种候选字符，避免为 1MB 正文做两遍子串查找。
    private static let fenceMarkerCharacters = CharacterSet(charactersIn: "`~")

    // 保存代码围栏的字符和最短闭合长度。
    private struct Fence {
        // 反引号与波浪号必须使用相同字符闭合。
        let marker: unichar
        // 闭合围栏不能短于起始围栏。
        let length: Int
    }

    // 保存当前列表行的下一项前缀和正文范围。
    private struct ParsedListLine {
        // 新行复用缩进、标记风格和分隔空白。
        let continuationPrefix: String
        // 正文范围用于识别再次回车即可退出的空项。
        let bodyRange: NSRange
    }

    // 为纯逻辑调用方桥接 Swift String，并复用不复制 NSTextStorage 的核心入口。
    static func edit(in source: String, selection: NSRange) -> MarkdownFormattingEdit? {
        // 测试与非视图调用方使用不可变 NSString 快照。
        edit(in: source as NSString, selection: selection)
    }

    // 在单一折叠选区上直接读取原生字符串并生成续写或退出列表计划。
    static func edit(in content: NSString, selection: NSRange) -> MarkdownFormattingEdit? {
        // 智能 Return 只接管一个有效光标，多字符选区保持系统替换行为。
        guard selection.location != NSNotFound,
            selection.length == 0,
            selection.location <= content.length,
            content.length > 0
        else { return nil }
        // 光标落在 UTF-16 代理项中间不是 NSTextView 可安全替换的字符边界。
        guard !splitsSurrogatePair(in: content, at: selection.location) else { return nil }

        // 取得光标所在逻辑行的内容边界和原始换行边界。
        var lineStart = 0
        // 完整行终点包含 LF、CRLF 或 CR。
        var lineEnd = 0
        // 内容终点排除原始换行符。
        var contentsEnd = 0
        // Foundation 负责处理混合换行与 UTF-16 光标坐标。
        content.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: selection.location, length: 0)
        )
        // 位于换行符内部的异常光标不应触发自定义替换。
        guard selection.location >= lineStart, selection.location <= contentsEnd else { return nil }
        // 围栏内的列表样例属于代码，必须保持普通 Return。
        guard !isInsideFence(in: content, before: lineStart) else { return nil }
        // 只解析当前行前缀，不运行全文块解析器。
        guard
            let parsed = parsedListLine(
                in: content,
                lineRange: NSRange(location: lineStart, length: contentsEnd - lineStart)
            )
        else { return nil }
        // 光标必须已经越过列表或任务标记，避免在标记内部拆行。
        guard selection.location >= parsed.bodyRange.location else { return nil }

        // 整个列表正文为空白时移除当前标记，让本行退出列表结构。
        if containsOnlyHorizontalSpace(in: content, range: parsed.bodyRange) {
            // 一次替换移除缩进、标记和尾随空白，但保留既有换行符。
            return MarkdownFormattingEdit(
                replacementRange: NSRange(location: lineStart, length: contentsEnd - lineStart),
                replacement: "",
                selectionAfterEdit: NSRange(location: lineStart, length: 0)
            )
        }

        // 优先复用当前行换行，文末则继承上一行风格并最终回退 LF。
        let lineBreak = preferredLineBreak(
            in: content,
            lineStart: lineStart,
            lineEnd: lineEnd,
            contentsEnd: contentsEnd
        )
        // 换行与下一项标记在一次输入中完成，保证单步撤销。
        let replacement = lineBreak + parsed.continuationPrefix
        // 新光标落在下一项正文起点，行中 Return 会把右侧正文自然移到这里。
        let selectionAfterEdit = NSRange(
            location: selection.location + (replacement as NSString).length,
            length: 0
        )
        // 只在原光标插入，不改动前后列表编号或其他行。
        return MarkdownFormattingEdit(
            replacementRange: selection,
            replacement: replacement,
            selectionAfterEdit: selectionAfterEdit
        )
    }

    // 解析无序、有序及其任务变体，并生成下一项前缀。
    private static func parsedListLine(in content: NSString, lineRange: NSRange) -> ParsedListLine? {
        // 空行不包含可续写的列表标记。
        guard lineRange.length > 0 else { return nil }
        // `- - -` 与 `* * *` 属于预览分割线，不能按列表续写。
        guard !isDivider(in: content, range: lineRange) else { return nil }
        // 行终点用于所有字符访问的统一上界。
        let lineLimit = NSMaxRange(lineRange)
        // 从行首开始保留全部空格和制表符缩进。
        var cursor = lineRange.location
        // 列表解析器与预览层一致地接受常见横向缩进。
        while cursor < lineLimit, isHorizontalSpace(content.character(at: cursor)) {
            // 每轮只消费一个 UTF-16 ASCII 空白单元。
            cursor += 1
        }
        // 只有缩进而没有标记时回退普通 Return。
        guard cursor < lineLimit else { return nil }
        // 保存缩进终点，供有序列表替换新编号时复用。
        let markerStart = cursor
        // 读取首个标记字符区分无序和有序列表。
        let first = content.character(at: cursor)

        // 无序列表只接受 Markdown Lite 已支持的三种标记。
        if first == 45 || first == 42 || first == 43 {
            // 跳过单字符无序标记。
            cursor += 1
            // 标记后至少需要一个空格或制表符。
            guard cursor < lineLimit, isHorizontalSpace(content.character(at: cursor)) else { return nil }
            // 预览解析器只消费一个分隔字符，其余空白属于真实正文。
            cursor += 1
            // 无序续行复用缩进、标记和第一个原始分隔字符。
            let basePrefix = content.substring(
                with: NSRange(location: lineRange.location, length: cursor - lineRange.location)
            )
            // 统一解析可选任务标记，并把已完成状态重置为未完成。
            return taskAwareLine(
                in: content,
                basePrefix: basePrefix,
                bodyStart: cursor,
                lineLimit: lineLimit
            )
        }

        // 有序列表必须从一个或多个 ASCII 数字开始。
        guard isASCIIDigit(first) else { return nil }
        // 扫描连续数字并保留原分隔符风格。
        while cursor < lineLimit, isASCIIDigit(content.character(at: cursor)) {
            // 每次只前进一个 ASCII 数字。
            cursor += 1
        }
        // 数字后必须存在点号或右括号。
        guard cursor < lineLimit else { return nil }
        // 保存真实结束符，下一项继续使用同一风格。
        let delimiter = content.character(at: cursor)
        // 其他字符不能构成有序列表标记。
        guard delimiter == 46 || delimiter == 41 else { return nil }
        // 把原编号转换为 Int，超大数字安全回退系统行为。
        let numberText = content.substring(
            with: NSRange(location: markerStart, length: cursor - markerStart)
        )
        // Int.max 无法生成下一项，必须拒绝溢出。
        guard let number = Int(numberText), number < Int.max else { return nil }
        // 跳过点号或右括号。
        cursor += 1
        // 结束符后至少需要一个空格或制表符。
        guard cursor < lineLimit, isHorizontalSpace(content.character(at: cursor)) else { return nil }
        // 记录编号后分隔空白起点。
        let gapStart = cursor
        // 预览解析器只消费第一个分隔字符。
        cursor += 1
        // 原缩进不随新编号位数变化。
        let indentation = content.substring(
            with: NSRange(location: lineRange.location, length: markerStart - lineRange.location)
        )
        // 点号或右括号按原样复用。
        let delimiterText = content.substring(with: NSRange(location: gapStart - 1, length: 1))
        // 编号后的第一个空白按原样复用。
        let gap = content.substring(with: NSRange(location: gapStart, length: 1))
        // 只计算当前下一项，不重写前后编号。
        let basePrefix = indentation + String(number + 1) + delimiterText + gap
        // 有序任务同样把下一项固定为未完成。
        return taskAwareLine(
            in: content,
            basePrefix: basePrefix,
            bodyStart: cursor,
            lineLimit: lineLimit
        )
    }

    // 在列表正文起点识别可选任务标记，并保留任务后的分隔空白。
    private static func taskAwareLine(
        in content: NSString,
        basePrefix: String,
        bodyStart: Int,
        lineLimit: Int
    ) -> ParsedListLine {
        // 任务标记至少需要左括号、状态、右括号和一个 ASCII 空格。
        guard bodyStart + 3 < lineLimit,
            content.character(at: bodyStart) == 91,
            isTaskState(content.character(at: bodyStart + 1)),
            content.character(at: bodyStart + 2) == 93,
            content.character(at: bodyStart + 3) == 32
        else {
            // 普通列表正文直接使用标记后的当前位置。
            return ParsedListLine(
                continuationPrefix: basePrefix,
                bodyRange: NSRange(location: bodyStart, length: lineLimit - bodyStart)
            )
        }
        // 与预览解析器一致地只跳过右括号后的一个 ASCII 空格。
        let cursor = bodyStart + 4
        // 下一项无论当前 x 大小写或完成状态都固定为未完成。
        let continuationPrefix = basePrefix + "[ ] "
        // 返回真实任务正文范围供空项退出判断。
        return ParsedListLine(
            continuationPrefix: continuationPrefix,
            bodyRange: NSRange(location: cursor, length: lineLimit - cursor)
        )
    }

    // 按 MarkdownEngine 同口径识别允许空白分隔的分割线。
    private static func isDivider(in content: NSString, range: NSRange) -> Bool {
        // 去掉行首横向空白后定位首个标记。
        var cursor = skippingHorizontalSpace(in: content, from: range.location, limit: NSMaxRange(range))
        // 只有空白的行不是分割线。
        guard cursor < NSMaxRange(range) else { return false }
        // 保存整行必须统一使用的标记字符。
        let marker = content.character(at: cursor)
        // Markdown 分割线只接受减号、星号或下划线。
        guard marker == 45 || marker == 42 || marker == 95 else { return false }
        // 统计忽略空白后的真实标记数量。
        var markerCount = 0
        // 扫描当前逻辑行全部内容。
        while cursor < NSMaxRange(range) {
            // 读取一个 ASCII 标记或横向空白。
            let character = content.character(at: cursor)
            // 相同标记计入分割线长度。
            if character == marker {
                // 累加真实标记数量。
                markerCount += 1
            } else if !isHorizontalSpace(character) {
                // 任一其他字符都证明这是普通列表正文。
                return false
            }
            // 继续检查下一 UTF-16 单元。
            cursor += 1
        }
        // 标准分割线至少需要三个相同标记。
        return markerCount >= 3
    }

    // 扫描当前行之前的围栏状态，避免在代码示例内改写 Return。
    private static func isInsideFence(in content: NSString, before lineStart: Int) -> Bool {
        // 文首之前不可能已经进入代码围栏。
        guard lineStart > 0 else { return false }
        // nil 表示当前扫描位置位于普通 Markdown。
        var activeFence: Fence?
        // 从文首候选围栏推进，普通正文通过 NSString 原生搜索一次跳过。
        var cursor = 0
        // 当前行本身不参与判断，避免列表正文被误当成围栏声明。
        while cursor < lineStart {
            // 围栏外同时寻找两种标记，围栏内只寻找可能闭合的同类标记。
            guard
                let candidate = nextFenceCandidate(
                    in: content,
                    from: cursor,
                    before: lineStart,
                    marker: activeFence?.marker
                )
            else {
                // 没有更多候选时，现有活动状态就是当前行所属上下文。
                return activeFence != nil
            }
            // 取得候选所在行的真实起点。
            var scannedLineStart = 0
            // 取得候选所在行的完整行终点。
            var scannedLineEnd = 0
            // 内容终点排除本行换行符。
            var scannedContentsEnd = 0
            // 每个围栏候选最多调用一次 Foundation 行边界识别。
            content.getLineStart(
                &scannedLineStart,
                end: &scannedLineEnd,
                contentsEnd: &scannedContentsEnd,
                for: NSRange(location: candidate, length: 0)
            )
            // 防御异常范围越过目标当前行。
            let boundedContentsEnd = min(scannedContentsEnd, lineStart)
            // 保存本次不含换行的扫描范围。
            let scannedRange = NSRange(
                location: scannedLineStart,
                length: max(0, boundedContentsEnd - scannedLineStart)
            )
            // 已进入围栏时只接受匹配字符且足够长的纯围栏闭合行。
            if let fence = activeFence {
                // 匹配闭合后恢复普通 Markdown 状态。
                if isClosingFence(in: content, range: scannedRange, opening: fence) {
                    // 清除活动围栏供后续行重新识别。
                    activeFence = nil
                }
            } else if let opening = openingFence(in: content, range: scannedRange) {
                // 普通状态遇到合法起始行后保存围栏约束。
                activeFence = opening
            }
            // 异常零长度行至少越过本次候选，避免搜索停留在原位置。
            let nextCursor = max(candidate + 3, scannedLineEnd)
            // 最多推进到当前目标行起点。
            cursor = min(nextCursor, lineStart)
        }
        // 仍有活动围栏表示当前列表样文本属于代码内容。
        return activeFence != nil
    }

    // 用 NSString 原生子串搜索定位下一个可能改变围栏状态的位置。
    private static func nextFenceCandidate(
        in content: NSString,
        from start: Int,
        before limit: Int,
        marker: unichar?
    ) -> Int? {
        // 空搜索范围没有任何候选。
        guard start < limit else { return nil }
        // 所有搜索都限制在当前列表行之前。
        let searchRange = NSRange(location: start, length: limit - start)
        // 已进入围栏时其他字符不可能闭合当前块。
        if let marker {
            // 根据活动字符选择固定三字符搜索令牌。
            let token = marker == 96 ? "```" : "~~~"
            // Foundation 在 UTF-16 范围内使用优化后的原生查找。
            let match = content.range(of: token, options: [.literal], range: searchRange)
            // NSNotFound 明确表示直到当前行都没有闭合候选。
            return match.location == NSNotFound ? nil : match.location
        }
        // 普通 Markdown 一次寻找任意反引号或波浪号字符。
        let match = content.rangeOfCharacter(
            from: fenceMarkerCharacters,
            options: [],
            range: searchRange
        )
        // 找不到候选时无需逐行扫描全文。
        return match.location == NSNotFound ? nil : match.location
    }

    // 解析一行开头的反引号或波浪号围栏。
    private static func openingFence(in content: NSString, range: NSRange) -> Fence? {
        // 去掉允许存在的前导横向空白。
        var cursor = skippingHorizontalSpace(in: content, from: range.location, limit: NSMaxRange(range))
        // 空行不能开启代码围栏。
        guard cursor < NSMaxRange(range) else { return nil }
        // 只接受反引号或波浪号。
        let marker = content.character(at: cursor)
        // 其他首字符保持普通 Markdown 状态。
        guard marker == 96 || marker == 126 else { return nil }
        // 统计连续相同围栏字符。
        let markerStart = cursor
        // 起始信息串不影响围栏长度。
        while cursor < NSMaxRange(range), content.character(at: cursor) == marker {
            // 每轮消费一个围栏字符。
            cursor += 1
        }
        // GFM 风格围栏至少需要三个字符。
        let length = cursor - markerStart
        // 过短标记按普通正文处理。
        guard length >= 3 else { return nil }
        // 返回闭合时需要匹配的字符与长度。
        return Fence(marker: marker, length: length)
    }

    // 判断一行是否为当前围栏的合法闭合行。
    private static func isClosingFence(
        in content: NSString,
        range: NSRange,
        opening: Fence
    ) -> Bool {
        // 闭合围栏同样允许前导横向空白。
        var cursor = skippingHorizontalSpace(in: content, from: range.location, limit: NSMaxRange(range))
        // 首字符必须与起始围栏一致。
        guard cursor < NSMaxRange(range), content.character(at: cursor) == opening.marker else { return false }
        // 保存闭合围栏字符起点。
        let markerStart = cursor
        // 统计连续相同字符。
        while cursor < NSMaxRange(range), content.character(at: cursor) == opening.marker {
            // 每轮消费一个闭合字符。
            cursor += 1
        }
        // 闭合长度不能短于起始围栏。
        guard cursor - markerStart >= opening.length else { return false }
        // 闭合围栏后只允许空格或制表符。
        return skippingHorizontalSpace(in: content, from: cursor, limit: NSMaxRange(range))
            == NSMaxRange(range)
    }

    // 根据当前或上一行选择不改变文档风格的换行符。
    private static func preferredLineBreak(
        in content: NSString,
        lineStart: Int,
        lineEnd: Int,
        contentsEnd: Int
    ) -> String {
        // 当前行已有换行时精确复用其 LF、CRLF 或 CR 字节语义。
        if lineEnd > contentsEnd {
            // 直接读取 Foundation 已识别的换行范围。
            return content.substring(
                with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd)
            )
        }
        // 文末行没有换行时优先检查上一行终止字符。
        if lineStart > 0 {
            // 上一 UTF-16 单元是 LF 时可能属于 CRLF。
            if content.character(at: lineStart - 1) == 10 {
                // 同时存在 CR 时保持双字符换行。
                if lineStart > 1, content.character(at: lineStart - 2) == 13 {
                    // 返回原文使用的 CRLF。
                    return "\r\n"
                }
                // 单独 LF 保持 Unix 换行。
                return "\n"
            }
            // 单独 CR 保持旧式换行风格。
            if content.character(at: lineStart - 1) == 13 {
                // 返回原文使用的 CR。
                return "\r"
            }
        }
        // 全文第一行且没有现有换行时采用平台通用 LF。
        return "\n"
    }

    // 跳过指定范围开头的空格和制表符。
    private static func skippingHorizontalSpace(in content: NSString, from start: Int, limit: Int) -> Int {
        // 从调用方提供的安全起点开始。
        var cursor = start
        // 逐个跳过 ASCII 横向空白。
        while cursor < limit, isHorizontalSpace(content.character(at: cursor)) {
            // 推进到首个非空白字符或范围末尾。
            cursor += 1
        }
        // 返回首个未消费位置。
        return cursor
    }

    // 判断范围是否只含空格或制表符。
    private static func containsOnlyHorizontalSpace(in content: NSString, range: NSRange) -> Bool {
        // 从正文范围起点开始扫描。
        var cursor = range.location
        // 任一非横向空白都表示列表项已有正文。
        while cursor < NSMaxRange(range) {
            // 非空白字符立即结束判断。
            if !isHorizontalSpace(content.character(at: cursor)) { return false }
            // 继续检查下一 UTF-16 单元。
            cursor += 1
        }
        // 空范围或全空白范围都属于可退出列表的空项。
        return true
    }

    // 判断 UTF-16 光标是否错误地位于一对代理项之间。
    private static func splitsSurrogatePair(in content: NSString, at location: Int) -> Bool {
        // 文首和文末都是合法边界，不读取范围外字符。
        guard location > 0, location < content.length else { return false }
        // 读取光标左侧 UTF-16 单元。
        let previous = content.character(at: location - 1)
        // 读取光标右侧 UTF-16 单元。
        let next = content.character(at: location)
        // 高代理项后紧跟低代理项时，二者中间不是 Unicode 字符边界。
        return previous >= 0xD800 && previous <= 0xDBFF
            && next >= 0xDC00 && next <= 0xDFFF
    }

    // 只把 ASCII 空格和制表符视为 Markdown 标记分隔。
    private static func isHorizontalSpace(_ character: unichar) -> Bool {
        // 数值判断避免为单字符创建临时 String。
        character == 32 || character == 9
    }

    // 有序列表编号严格限制为 ASCII 0 到 9。
    private static func isASCIIDigit(_ character: unichar) -> Bool {
        // 连续码点范围可以常量时间判断。
        character >= 48 && character <= 57
    }

    // 任务状态只接受空格、小写 x 或大写 X。
    private static func isTaskState(_ character: unichar) -> Bool {
        // 与预览任务解析规则保持一致。
        character == 32 || character == 120 || character == 88
    }
}

// 在 release 自检中复核 1MB 文档智能 Return 的真实计划耗时。
enum MarkdownListContinuationSelfCheck {
    // 保存可在日志和 CI 中直接复核的分位数与最慢值。
    struct Report: Sendable {
        // 第 95 百分位反映连续回车的稳定延迟。
        let p95Milliseconds: Double
        // 最慢一次用于捕捉明显调度或算法尖峰。
        let maximumMilliseconds: Double
    }

    // 执行固定 1MB 样本并可选择严格应用性能门槛。
    static func run(iterations: Int = 100, enforcePerformanceTargets: Bool = true) -> Report {
        // 至少执行一次，避免空数组无法计算分位数。
        let safeIterations = max(1, iterations)
        // 长普通块与少量行内标记共同覆盖快速搜索和候选排除分支。
        let ordinaryLine = "普通正文 0123456789\n"
        // 每约 16KB 插入一次非围栏反引号与波浪号，贴近日常技术文档。
        let unit = String(repeating: ordinaryLine, count: 512) + "行内 `code` 与 ~ 符号\n"
        // 按 UTF-8 字节数构造不小于 1MB 的稳定样本。
        let repetitions = 1_048_576 / unit.utf8.count + 1
        // 文末真实无序项是每轮需要生成编辑计划的目标。
        let source = String(repeating: unit, count: repetitions) + "- 最后一项"
        // 自检计时直接复用不可变 NSString，排除无关桥接分配。
        let nativeContent = source as NSString
        // 文末 UTF-16 光标与正式 NSTextView 坐标一致。
        let selection = NSRange(location: nativeContent.length, length: 0)
        // 首次调用预热 Foundation 行边界和代码路径。
        let warmup = MarkdownListContinuationSupport.edit(in: nativeContent, selection: selection)
        // 功能结果错误时性能数字没有意义，立即终止自检。
        precondition(warmup?.replacement == "\n- ", "智能列表 1MB 预热结果错误")
        // 预分配固定次数，避免计时循环中的数组扩容噪声。
        var measurements = [Double]()
        // 提前保留全部测量容量。
        measurements.reserveCapacity(safeIterations)

        // 每轮独立测量同一纯计划，结果不修改样本文本。
        for _ in 0..<safeIterations {
            // 单调纳秒时钟不受系统时间调整影响。
            let start = DispatchTime.now().uptimeNanoseconds
            // 正式计算必须始终返回同一下一项前缀。
            let edit = MarkdownListContinuationSupport.edit(in: nativeContent, selection: selection)
            // 在结果产生后立即截取终点，避免断言和数组操作进入计时。
            let end = DispatchTime.now().uptimeNanoseconds
            // 任一轮功能退化都应让自检失败。
            precondition(edit?.replacement == "\n- ", "智能列表 1MB 计划结果错误")
            // 将纳秒差转换为便于阅读的毫秒。
            measurements.append(Double(end - start) / 1_000_000)
        }

        // 排序后用固定索引计算可复核的第 95 百分位。
        let sorted = measurements.sorted()
        // 向上取整确保小样本也不会低估尾部延迟。
        let p95Index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        // 保存本轮稳定分位数与真实最慢值。
        let report = Report(
            p95Milliseconds: sorted[p95Index],
            maximumMilliseconds: sorted[sorted.count - 1]
        )
        // 严格 release 自检执行跨本机与共享 CI 都稳定的尾延迟门槛。
        if enforcePerformanceTargets {
            // 任一门槛失败时输出精确实测值方便定位回归。
            precondition(
                report.p95Milliseconds < 10 && report.maximumMilliseconds < 25,
                String(
                    format: "智能列表 1MB 性能未达标：p95 %.2fms，max %.2fms",
                    report.p95Milliseconds,
                    report.maximumMilliseconds
                )
            )
        }
        // 返回报告供命令行自检输出。
        return report
    }
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
        case .toggleTask:
            // 当前行任务切换复用带原文校验的纯逻辑入口。
            return MarkdownTaskToggleSupport.edit(
                in: source,
                line: MarkdownSourceLineMap.lineNumber(
                    in: source,
                    utf16Location: selection.location
                ),
                preserving: selection
            )
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

// 生成只替换任务勾选字符的安全编辑计划，供菜单和预览共同复用。
enum MarkdownTaskToggleSupport {
    // 模式严格匹配解析器已经接受的无序或有序任务行，并捕获状态和正文。
    private static let taskLineExpression = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:[-+*]|([0-9]+)[.)])[ \t]\[([ xX])\] (.*)$"#
    )

    // 定位零基逻辑行并在预期内容仍匹配时生成等长状态替换。
    static func edit(
        in source: String,
        line targetLine: Int,
        expectedText: String? = nil,
        expectedChecked: Bool? = nil,
        preserving selection: NSRange
    ) -> MarkdownFormattingEdit? {
        // 负行号不代表任何真实预览条目。
        guard targetLine >= 0 else { return nil }
        // NSTextView 与 NSString 使用相同 UTF-16 坐标。
        let content = source as NSString
        // 目标行起点复用经过混合换行验证的映射逻辑。
        let lineLocation = MarkdownSourceLineMap.utf16Location(in: source, line: targetLine)
        // 越过文末的行号会被映射到 EOF，必须通过反向行号核对拒绝。
        guard MarkdownSourceLineMap.lineNumber(in: source, utf16Location: lineLocation) == targetLine else {
            return nil
        }
        // 取得完整逻辑行边界，同时把 CRLF 等换行符排除在匹配范围外。
        var lineStart = 0
        var contentsEnd = 0
        content.getLineStart(
            &lineStart,
            end: nil,
            contentsEnd: &contentsEnd,
            for: NSRange(location: lineLocation, length: 0)
        )
        // 空行和异常反向范围都不可能包含任务标记。
        guard contentsEnd >= lineStart else { return nil }
        // 只读取当前行正文，保证替换不会触碰原换行风格。
        let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        // 在原始全文坐标中匹配，捕获范围可直接交给 NSTextView。
        guard
            let match = taskLineExpression.firstMatch(in: source, range: lineRange),
            match.range == lineRange,
            match.numberOfRanges == 4
        else { return nil }
        // 第一捕获组仅在有序列表中保存原始十进制编号。
        let orderedNumberRange = match.range(at: 1)
        // 第二捕获组是方括号中的单个空格、x 或 X。
        let stateRange = match.range(at: 2)
        // 第三捕获组是解析器展示的完整任务正文。
        let textRange = match.range(at: 3)
        // 防御正则引擎返回缺失捕获组。
        guard stateRange.location != NSNotFound, textRange.location != NSNotFound else { return nil }
        // 有序编号必须与解析器一样可以装入 Int，超长数字继续按普通正文处理。
        if orderedNumberRange.location != NSNotFound,
            Int(content.substring(with: orderedNumberRange)) == nil
        {
            return nil
        }
        // 读取当前勾选字符以统一大小写完成状态。
        let stateMarker = content.substring(with: stateRange)
        // 空格表示未完成，大小写 x 都表示已完成。
        let isChecked = stateMarker.lowercased() == "x"
        // 预览动作必须确认当前状态仍等于解析时状态，双击旧视图会安全停止。
        if let expectedChecked, expectedChecked != isChecked { return nil }
        // 读取当前任务正文供过期预览和行移动校验。
        let taskText = content.substring(with: textRange)
        // 预览展示内容变化后不能把旧点击应用到新正文。
        if let expectedText, expectedText != taskText { return nil }
        // 等长单字符替换不会改变任何既有 UTF-16 选区坐标。
        let safeSelection = normalizedSelection(selection, contentLength: content.length)
        // 已完成任务切回空格，未完成任务统一写为小写 x。
        let replacement = isChecked ? " " : "x"
        // 返回一次最小替换，保留缩进、编号、正文和换行符。
        return MarkdownFormattingEdit(
            replacementRange: stateRange,
            replacement: replacement,
            selectionAfterEdit: safeSelection
        )
    }

    // 把可能来自失效视图的选区限制在当前正文边界内。
    private static func normalizedSelection(_ selection: NSRange, contentLength: Int) -> NSRange {
        // NSNotFound 无法交给 NSTextView，回退到文末光标。
        guard selection.location != NSNotFound else {
            return NSRange(location: contentLength, length: 0)
        }
        // 起点限制在零到文末之间。
        let location = min(contentLength, max(0, selection.location))
        // 长度不能越过当前正文末尾。
        let length = min(max(0, selection.length), contentLength - location)
        // 返回可直接恢复的 UTF-16 选区。
        return NSRange(location: location, length: length)
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
        // NFC 单码位和 NFD 组合标记视觉相同但原始 UTF-8 字节不同。
        let normalizedNFC = "é"
        // 显式组合重音覆盖 Swift 字符串规范等价语义。
        let normalizedNFD = "e\u{301}"
        // 数据保护核对必须保留两种原始编码序列的差异。
        if !NativeTextComparison.differsExactly(normalizedNFC, normalizedNFD) {
            failures.append("Unicode 规范等价正文未按原始字节区分")
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
