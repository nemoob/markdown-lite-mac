import Foundation

// 表示大纲中一条可跳转的 Markdown 标题。
struct MarkdownOutlineItem: Identifiable, Equatable, Sendable {
    // 解析块起始行作为稳定跳转标识。
    let id: Int
    // 标题层级用于视觉缩进。
    let level: Int
    // 保留标题正文供大纲展示。
    let title: String
}

// 从现有预览块生成零额外解析的大纲数据。
enum MarkdownOutlineBuilder {
    // 只提取标题块，保持原文顺序。
    static func items(from blocks: [EnhancedPreviewBlock]) -> [MarkdownOutlineItem] {
        // 单次遍历避免为长文档再次解析 Markdown。
        blocks.compactMap { block in
            // 非标题块不进入大纲。
            guard case let .heading(level, text) = block.kind else { return nil }
            // 空标题使用可见占位，确保仍能跳转。
            let visibleTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // 返回与预览块共享行号的稳定项目。
            return MarkdownOutlineItem(
                id: block.id,
                level: level,
                title: visibleTitle.isEmpty ? "未命名标题" : visibleTitle
            )
        }
    }

    // 返回目标行所属的最近上方标题，供大纲标记当前章节。
    static func currentItem(
        from items: [MarkdownOutlineItem],
        atLine targetLine: Int
    ) -> MarkdownOutlineItem? {
        // 空大纲没有当前章节。
        guard !items.isEmpty else { return nil }
        // 负行号统一视为首行。
        let safeLine = max(0, targetLine)
        // 使用半开区间二分查找最后一个不晚于目标行的标题。
        var lower = 0
        // 上界初始为元素数量。
        var upper = items.count
        // 每轮把候选范围缩小一半。
        while lower < upper {
            // 计算上中位点，确保双元素范围可以前进。
            let middle = lower + (upper - lower) / 2
            // 标题位于目标行或其上方时继续向右查找。
            if items[middle].id <= safeLine {
                lower = middle + 1
            } else {
                // 标题晚于目标行时收缩右边界。
                upper = middle
            }
        }
        // 首个标题也晚于目标行时没有所属章节。
        guard lower > 0 else { return nil }
        // 前一个元素就是最后一个不晚于目标行的标题。
        return items[lower - 1]
    }
}

// 在 Markdown 行号和 NSTextView UTF-16 光标之间建立稳定映射。
enum MarkdownSourceLineMap {
    // 返回给定 UTF-16 位置所在的零基逻辑行号。
    static func lineNumber(in source: String, utf16Location: Int) -> Int {
        // NSString 与 NSTextView 使用同一 UTF-16 坐标系。
        let content = source as NSString
        // 位置限制在全文范围，NSNotFound 回退文档末尾。
        let safeLocation =
            utf16Location == NSNotFound
            ? content.length
            : min(content.length, max(0, utf16Location))
        // 空文档和首字符都属于零行。
        guard safeLocation > 0, content.length > 0 else { return 0 }
        // 从首行开始推进到包含目标位置的行。
        var line = 0
        // 当前行 UTF-16 起点。
        var location = 0
        // 目标恰好位于下一行开头时需要返回下一行。
        while location < safeLocation, location < content.length {
            // 获取当前完整逻辑行及不含换行的正文末尾。
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            content.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            // 防御异常零长度范围。
            guard lineEnd > location else { break }
            // 没有行终止符的末行即使目标在 EOF 也仍属于当前行。
            guard lineEnd > contentsEnd else { break }
            // 目标仍位于当前行内部时停止。
            guard lineEnd <= safeLocation else { break }
            // 移动到下一行起点。
            location = lineEnd
            // 已跨过一个逻辑换行。
            line += 1
        }
        // 返回稳定零基行号。
        return line
    }

    // 返回给定零基逻辑行开头的 UTF-16 位置。
    static func utf16Location(in source: String, line targetLine: Int) -> Int {
        // NSString 保证结果可直接交给 NSTextView。
        let content = source as NSString
        // 负行号统一收敛到首行。
        let safeTarget = max(0, targetLine)
        // 从首行起点开始推进。
        var line = 0
        // 保存当前行起点。
        var location = 0
        // 每轮跳过一个完整逻辑行。
        while line < safeTarget, location < content.length {
            // 获取当前完整逻辑行范围。
            let lineRange = content.lineRange(for: NSRange(location: location, length: 0))
            // 防御异常零长度范围。
            guard NSMaxRange(lineRange) > location else { break }
            // 下一行起点是当前行范围末尾。
            location = NSMaxRange(lineRange)
            // 同步累计零基行号。
            line += 1
        }
        // 越过文档末尾的目标统一定位到 EOF。
        return min(location, content.length)
    }
}

// 验证 Unicode、混合换行和当前章节映射。
enum MarkdownOutlineSupportSelfCheck {
    // 返回全部失败项；空数组表示通过。
    static func run() -> [String] {
        // 汇总可一次定位的失败原因。
        var failures: [String] = []
        // emoji 使用两个 UTF-16 单元，同时覆盖 CRLF、LF 和 CR。
        let source = "😀 首行\r\n# 二行\n正文\r## 四行"
        // 二行起点由 NSString 精确计算。
        let secondLineLocation = MarkdownSourceLineMap.utf16Location(in: source, line: 1)
        // 反向映射必须恢复相同行号。
        if MarkdownSourceLineMap.lineNumber(in: source, utf16Location: secondLineLocation) != 1 {
            failures.append("CRLF 行号往返失败")
        }
        // 四行起点必须跨过混合换行符且保持 Unicode 边界。
        let fourthLineLocation = MarkdownSourceLineMap.utf16Location(in: source, line: 3)
        // 目标位置不能落在 UTF-16 代理对中间。
        if MarkdownSourceLineMap.lineNumber(in: source, utf16Location: fourthLineLocation) != 3 {
            failures.append("Unicode 混合换行映射失败")
        }
        // 构造按源行排序的标题列表。
        let items = [
            MarkdownOutlineItem(id: 1, level: 1, title: "二行"),
            MarkdownOutlineItem(id: 3, level: 2, title: "四行"),
        ]
        // 正文第三行仍属于上方第一个标题。
        if MarkdownOutlineBuilder.currentItem(from: items, atLine: 2)?.id != 1 {
            failures.append("当前章节向上归属失败")
        }
        // 四行及其后必须归属第二个标题。
        if MarkdownOutlineBuilder.currentItem(from: items, atLine: 3)?.id != 3 {
            failures.append("当前章节切换失败")
        }
        // 返回所有断言结果。
        return failures
    }
}
