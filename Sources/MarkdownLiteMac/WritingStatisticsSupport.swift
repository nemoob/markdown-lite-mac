import Foundation

// 保存一次纯文本统计结果，便于界面跨并发边界安全传递和直接比较。
struct WritingStatistics: Equatable, Sendable {
    // 按 Swift 扩展字素簇统计全文字符，空格和换行同样计入。
    let characterCount: Int
    // 空文档从一行起算，每个完整换行字符增加一行。
    let lineCount: Int
    // 仅在 UTF-16 选区完整合法时返回选中的扩展字素簇数量。
    let selectedCharacterCount: Int
}

// 集中提供无状态的写作统计函数，避免界面层重复处理 Unicode 边界。
struct WritingStatisticsSupport: Equatable, Sendable {
    // 同时计算全文字符数、行数和可选选区字符数。
    static func calculate(
        in source: String,
        selectionUTF16Range: NSRange? = nil
    ) -> WritingStatistics {
        // 既有同步入口必须始终返回完整结果，不受调用任务既有取消状态影响。
        calculate(
            in: source,
            selectionUTF16Range: selectionUTF16Range,
            stopsWhenCancelled: false
        )!
    }

    // 后台任务使用可取消入口；取消时返回 nil，调用方不得发布部分统计。
    static func calculateIfNotCancelled(
        in source: String,
        selectionUTF16Range: NSRange? = nil
    ) -> WritingStatistics? {
        // 后台路径周期性读取当前任务取消状态。
        calculate(
            in: source,
            selectionUTF16Range: selectionUTF16Range,
            stopsWhenCancelled: true
        )
    }

    // 共享完整统计实现，并按调用入口选择是否响应任务取消。
    private static func calculate(
        in source: String,
        selectionUTF16Range: NSRange?,
        stopsWhenCancelled: Bool
    ) -> WritingStatistics? {
        // 已取消后台任务在读取正文前立即停止。
        guard !cancellationRequested(whenEnabled: stopsWhenCancelled) else { return nil }
        // 全文字符数从零开始，后续按扩展字素簇逐个累加。
        var characterCount = 0
        // 即使正文为空也存在第一行。
        var lineCount = 1

        // 单次遍历同时完成字符和换行统计，避免为行数再次扫描正文。
        for character in source {
            // 每四千零九十六个字符检查一次，兼顾快速取消和正常统计吞吐量。
            if characterCount & 0xFFF == 0,
                cancellationRequested(whenEnabled: stopsWhenCancelled)
            {
                // 取消后丢弃部分计数，不能把不完整结果发布到界面。
                return nil
            }
            // 每个 Swift Character 代表一个用户可见的扩展字素簇。
            characterCount += 1

            // Swift 将 CRLF 识别为一个换行 Character，因此只增加一行。
            if character.isNewline {
                // 末尾换行同样创建一个空白尾行。
                lineCount += 1
            }
        }

        // 空文档或最后一个检查批次也必须观察扫描期间发生的取消。
        guard !cancellationRequested(whenEnabled: stopsWhenCancelled) else { return nil }

        // 未提供选区时使用零，避免无意义地遍历 UTF-16 视图。
        let selectedCharacterCount: Int
        // 只有调用方提供选区时才进入独立的可取消范围转换和计数。
        if let selectionUTF16Range {
            // NSTextView 提供 UTF-16 NSRange，由共享实现完成安全转换和计数。
            guard
                let count = Self.selectedCharacterCount(
                    in: source,
                    selectionUTF16Range: selectionUTF16Range,
                    stopsWhenCancelled: stopsWhenCancelled
                )
            else {
                // nil 只表示后台任务已取消，非法范围仍稳定返回零。
                return nil
            }
            // 保存完整选区字符数。
            selectedCharacterCount = count
        } else {
            // 没有选区消费者时保持零成本默认值。
            selectedCharacterCount = 0
        }

        // 返回不可变值，调用方无需了解底层 Unicode 转换细节。
        return WritingStatistics(
            characterCount: characterCount,
            lineCount: lineCount,
            selectedCharacterCount: selectedCharacterCount
        )
    }

    // 将合法 UTF-16 选区转换为完整字符范围后统计扩展字素簇。
    static func selectedCharacterCount(
        in source: String,
        selectionUTF16Range: NSRange
    ) -> Int {
        // 既有同步入口保持稳定返回值和非法范围回退语义。
        selectedCharacterCount(
            in: source,
            selectionUTF16Range: selectionUTF16Range,
            stopsWhenCancelled: false
        )!
    }

    // 后台选区扫描在任务取消时返回 nil，不发布部分字符数。
    static func selectedCharacterCountIfNotCancelled(
        in source: String,
        selectionUTF16Range: NSRange
    ) -> Int? {
        // 原生编辑器通过此入口获得可协作取消的长选区统计。
        selectedCharacterCount(
            in: source,
            selectionUTF16Range: selectionUTF16Range,
            stopsWhenCancelled: true
        )
    }

    // 共享选区实现，区分稳定同步调用和可取消后台调用。
    private static func selectedCharacterCount(
        in source: String,
        selectionUTF16Range: NSRange,
        stopsWhenCancelled: Bool
    ) -> Int? {
        // 已取消后台任务不再转换任何 UTF-16 索引。
        guard !cancellationRequested(whenEnabled: stopsWhenCancelled) else { return nil }
        // 任一边界无效、越界或落在字符内部时均按未选中处理。
        guard
            let characterRange = characterRange(
                in: source,
                utf16Range: selectionUTF16Range,
                stopsWhenCancelled: stopsWhenCancelled
            )
        else {
            // 范围转换期间被取消时必须与普通非法范围区分。
            guard !cancellationRequested(whenEnabled: stopsWhenCancelled) else { return nil }
            // 返回零可让调用方安全接收暂态或损坏的 AppKit 选区。
            return 0
        }

        // 从零开始逐个统计完整扩展字素簇，允许长选区及时响应取消。
        var count = 0
        // 只遍历已经验证边界的选区切片。
        for _ in source[characterRange] {
            // 使用与全文相同的有界检查间隔。
            if count & 0xFFF == 0,
                cancellationRequested(whenEnabled: stopsWhenCancelled)
            {
                // 取消后不返回部分选区数量。
                return nil
            }
            // 当前完整 Character 计入选区结果。
            count += 1
        }
        // 空选区或最后一个批次之后再次观察取消。
        guard !cancellationRequested(whenEnabled: stopsWhenCancelled) else { return nil }
        // 返回完整且未取消的选区字符数。
        return count
    }

    // 校验 NSRange 数值和 Unicode 边界，并返回可安全切片的字符范围。
    private static func characterRange(
        in source: String,
        utf16Range: NSRange,
        stopsWhenCancelled: Bool
    ) -> Range<String.Index>? {
        // NSNotFound、负位置和负长度都不是可转换的文本选区。
        guard
            utf16Range.location != NSNotFound,
            utf16Range.location >= 0,
            utf16Range.length >= 0
        else {
            // 非法数值不参与任何索引运算，避免溢出或运行时错误。
            return nil
        }

        // AppKit 的 NSRange 使用 UTF-16 代码单元，因此在同一视图中推进索引。
        let utf16 = source.utf16
        // 分批推进到选区起点，越界或取消都会安全返回 nil。
        guard
            let lowerUTF16Index = utf16Index(
                in: utf16,
                from: utf16.startIndex,
                offsetBy: utf16Range.location,
                stopsWhenCancelled: stopsWhenCancelled
            )
        else { return nil }
        // 从已验证起点分批推进选区长度，避免整数加法溢出。
        guard
            let upperUTF16Index = utf16Index(
                in: utf16,
                from: lowerUTF16Index,
                offsetBy: utf16Range.length,
                stopsWhenCancelled: stopsWhenCancelled
            )
        else { return nil }

        // 仅接受落在完整 Character 边界上的起止位置。
        guard
            let lowerBound = String.Index(lowerUTF16Index, within: source),
            let upperBound = String.Index(upperUTF16Index, within: source)
        else {
            // 半个代理项、组合字符或 CRLF 的内部边界均安全返回空结果。
            return nil
        }

        // 两个已验证的 String.Index 可组成不会破坏 Unicode 的半开区间。
        return lowerBound..<upperBound
    }

    // 以固定批次推进 UTF-16 索引，使长距离转换也能响应任务取消。
    private static func utf16Index(
        in utf16: String.UTF16View,
        from startIndex: String.UTF16View.Index,
        offsetBy offset: Int,
        stopsWhenCancelled: Bool
    ) -> String.UTF16View.Index? {
        // 调用方已经拒绝负数，这里继续防御独立误用。
        guard offset >= 0 else { return nil }
        // 从已验证起点开始推进。
        var index = startIndex
        // 剩余距离不做起点加长度运算，因此不会整数溢出。
        var remaining = offset
        // 每次最多前进四千零九十六个 UTF-16 代码单元。
        while remaining > 0 {
            // 每个批次前观察后台任务取消状态。
            guard !cancellationRequested(whenEnabled: stopsWhenCancelled) else { return nil }
            // 有界步长兼顾取消响应和索引推进效率。
            let step = min(remaining, 4_096)
            // limitedBy 阻止无效或极大 NSRange 越过正文末尾。
            guard
                let nextIndex = utf16.index(
                    index,
                    offsetBy: step,
                    limitedBy: utf16.endIndex
                )
            else {
                // 到达正文末尾前仍有剩余距离表示输入范围越界。
                return nil
            }
            // 保存本批次终点供下一轮继续。
            index = nextIndex
            // 只减去已经安全推进的距离。
            remaining -= step
        }
        // 零长度或完整推进后也必须观察最后时刻的取消。
        guard !cancellationRequested(whenEnabled: stopsWhenCancelled) else { return nil }
        // 返回未越界且未取消的 UTF-16 索引。
        return index
    }

    // 只有可取消后台入口才读取当前任务状态。
    private static func cancellationRequested(whenEnabled isEnabled: Bool) -> Bool {
        // 既有同步 API 传入 false，因此即使位于已取消任务中也保持完整结果。
        isEnabled && Task.isCancelled
    }
}
