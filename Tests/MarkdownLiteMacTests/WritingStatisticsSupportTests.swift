import Foundation
import Testing

@testable import MarkdownLiteMac

// 验证写作统计对 Unicode、换行和 AppKit UTF-16 选区保持一致语义。
@Suite("写作统计")
struct WritingStatisticsSupportTests {
    // 中文、空格和换行都应作为独立扩展字素簇计入全文。
    @Test("统计中文、空格和有效选区")
    func testChineseTextAndValidSelection() {
        // 构造包含中文、空格和单个 LF 的两行正文。
        let source = "你好 世界\n下一行"
        // 使用 NSString 生成与 NSTextView 一致的 UTF-16 选区。
        let selection = (source as NSString).range(of: "世界")

        // 一次调用取得全文和选区的完整统计。
        let statistics = WritingStatisticsSupport.calculate(
            in: source,
            selectionUTF16Range: selection
        )

        // 直接比较值对象，同时覆盖 Equatable 合成实现。
        #expect(
            statistics
                == WritingStatistics(
                    characterCount: 9,
                    lineCount: 2,
                    selectedCharacterCount: 2
                )
        )
        // 编译期约束确保结果能够安全跨并发边界传递。
        requireSendable(statistics)
    }

    // 家庭 emoji 和带组合音标的字母都必须按一个可见字符统计。
    @Test("按扩展字素簇统计 emoji 和组合字符")
    func testEmojiAndCombiningMarks() {
        // 正文包含 ASCII、ZWJ 家庭 emoji、组合字符和单个 emoji。
        let source = "A👨‍👩‍👧‍👦e\u{301}😀"
        // 选取完整家庭 emoji 的 UTF-16 范围。
        let familySelection = (source as NSString).range(of: "👨‍👩‍👧‍👦")
        // 选取由两个 Unicode 标量组成的单个组合字符。
        let combiningSelection = (source as NSString).range(of: "e\u{301}")

        // 全文统计必须保持四个用户可见字符。
        let statistics = WritingStatisticsSupport.calculate(in: source)
        // 两个复杂选区分别按一个扩展字素簇计数。
        let familyCount = WritingStatisticsSupport.selectedCharacterCount(
            in: source,
            selectionUTF16Range: familySelection
        )
        // 组合字符选区也必须保持单字符语义。
        let combiningCount = WritingStatisticsSupport.selectedCharacterCount(
            in: source,
            selectionUTF16Range: combiningSelection
        )

        // 全文包含四个 Character 且没有换行。
        #expect(statistics.characterCount == 4)
        // 无换行正文仍保留第一行。
        #expect(statistics.lineCount == 1)
        // ZWJ emoji 序列不得按多个标量拆分。
        #expect(familyCount == 1)
        // 组合音标不得与基础字母拆分。
        #expect(combiningCount == 1)
    }

    // 空正文仍应显示一行，且没有全文或选区字符。
    @Test("空文档为一行")
    func testEmptyDocument() {
        // 不传选区以覆盖界面初始状态的快速路径。
        let statistics = WritingStatisticsSupport.calculate(in: "")

        // 空正文没有任何扩展字素簇。
        #expect(statistics.characterCount == 0)
        // 编辑器中的空文档按第一空行计算。
        #expect(statistics.lineCount == 1)
        // 缺少选区时选中字符数为零。
        #expect(statistics.selectedCharacterCount == 0)
    }

    // LF、CRLF 和结尾换行应按实际逻辑行精确累计。
    @Test("统计 LF、CRLF 和尾随换行")
    func testLineEndingsAndTrailingNewline() {
        // CRLF 在 Swift 中是一个 Character，末尾 LF 创建额外空行。
        let mixedStatistics = WritingStatisticsSupport.calculate(in: "a\r\nb\n")
        // 单独验证最小尾随换行正文。
        let trailingStatistics = WritingStatisticsSupport.calculate(in: "标题\n")

        // 混合正文包含 a、CRLF、b 和 LF 四个 Character。
        #expect(mixedStatistics.characterCount == 4)
        // 两个完整换行将初始一行扩展为三行。
        #expect(mixedStatistics.lineCount == 3)
        // 两个中文字符加一个尾随 LF 共三个 Character。
        #expect(trailingStatistics.characterCount == 3)
        // 尾随 LF 必须产生第二个空白行。
        #expect(trailingStatistics.lineCount == 2)
    }

    // 完整 CRLF 选区应被视为一个 Character，而不是两个代码单元。
    @Test("完整 CRLF 选区计为一个字符")
    func testCompleteCRLFSelection() {
        // 正文中的 CRLF 占两个 UTF-16 代码单元但只占一个 Character。
        let source = "a\r\nb"
        // 使用 UTF-16 位置一和长度二完整覆盖 CRLF。
        let selection = NSRange(location: 1, length: 2)

        // 转换后的 Character 范围应只包含一个换行字符。
        let count = WritingStatisticsSupport.selectedCharacterCount(
            in: source,
            selectionUTF16Range: selection
        )

        // CRLF 不能被重复计数。
        #expect(count == 1)
    }

    // 连续选区变化可只调用独立函数，无需重新构造全文统计结果。
    @Test("独立统计连续选区变化")
    func testStandaloneSelectionCountForSelectionChanges() {
        // 固定正文模拟方向键或拖选过程中内容没有发生变化。
        let source = "前👨‍👩‍👧‍👦abc后"
        // 第一次选区完整覆盖一个复杂 emoji。
        let emojiSelection = (source as NSString).range(of: "👨‍👩‍👧‍👦")
        // 第二次选区移动到三个 ASCII 字符。
        let asciiSelection = (source as NSString).range(of: "abc")

        // 两次变化都直接走选区专用纯函数，不请求全文统计。
        let emojiCount = WritingStatisticsSupport.selectedCharacterCount(
            in: source,
            selectionUTF16Range: emojiSelection
        )
        // 同一正文可立即复用接口计算新的选区。
        let asciiCount = WritingStatisticsSupport.selectedCharacterCount(
            in: source,
            selectionUTF16Range: asciiSelection
        )

        // 复杂 emoji 应保持一个扩展字素簇。
        #expect(emojiCount == 1)
        // 移动后的 ASCII 选区应返回三个字符。
        #expect(asciiCount == 3)
    }

    // 数值非法或越界的 NSRange 必须稳定返回零而不是触发索引错误。
    @Test("拒绝非法和越界 UTF-16 选区")
    func testInvalidAndOutOfBoundsSelections() {
        // 使用包含代理项的正文覆盖 UTF-16 长度与 Character 数不同的情况。
        let source = "😀a"
        // NSNotFound 代表 AppKit 没有可用的选区位置。
        let notFound = NSRange(location: NSNotFound, length: 0)
        // 负位置不允许进入字符串索引计算。
        let negativeLocation = NSRange(location: -1, length: 1)
        // 负长度同样不是合法半开区间。
        let negativeLength = NSRange(location: 0, length: -1)
        // UTF-16 正文仅有三个代码单元，此起点已越界。
        let locationOutOfBounds = NSRange(location: 4, length: 0)
        // 合法起点搭配过长长度会让终点越界。
        let lengthOutOfBounds = NSRange(location: 2, length: 2)
        // 极大位置和长度验证实现不会先执行可能溢出的加法。
        let overflowingRange = NSRange(location: Int.max - 1, length: 10)

        // 逐个验证所有非法输入都使用统一的安全回退值。
        #expect(selectionCount(in: source, range: notFound) == 0)
        // 负起点不得被 Foundation 索引 API 接受。
        #expect(selectionCount(in: source, range: negativeLocation) == 0)
        // 负长度不得被解释为空选区。
        #expect(selectionCount(in: source, range: negativeLength) == 0)
        // 超出 UTF-16 尾端的位置必须返回零。
        #expect(selectionCount(in: source, range: locationOutOfBounds) == 0)
        // 终点超出正文时必须返回零。
        #expect(selectionCount(in: source, range: lengthOutOfBounds) == 0)
        // 极大值输入必须安全返回而不发生整数溢出。
        #expect(selectionCount(in: source, range: overflowingRange) == 0)
    }

    // 落在扩展字素簇内部的范围即使数值未越界也不是有效选区。
    @Test("拒绝半个 emoji、组合字符和 CRLF")
    func testSelectionsInsideCharacterBoundaries() {
        // emoji 的单个 UTF-16 代理项不是完整 Character。
        let emojiSource = "😀a"
        // 组合音标与基础字母共同组成一个 Character。
        let combiningSource = "e\u{301}x"
        // CR 和 LF 共同组成一个换行 Character。
        let crlfSource = "a\r\nb"

        // 只覆盖 emoji 的第一个代理项，终点落在字符内部。
        #expect(selectionCount(in: emojiSource, range: NSRange(location: 0, length: 1)) == 0)
        // 只覆盖组合字符的基础字母，终点落在组合序列内部。
        #expect(
            selectionCount(in: combiningSource, range: NSRange(location: 0, length: 1)) == 0
        )
        // 只覆盖 CR，终点落在 CRLF Character 内部。
        #expect(selectionCount(in: crlfSource, range: NSRange(location: 1, length: 1)) == 0)
        // 完整字符边界上的空选区仍是合法的零字符结果。
        #expect(selectionCount(in: emojiSource, range: NSRange(location: 2, length: 0)) == 0)
    }

    // 已取消后台任务必须在全文和选区入口都返回 nil，而不是发布部分结果。
    @Test("预取消任务停止全文和选区扫描")
    func testPreCancelledTasksStopFullAndSelectionScans() async {
        // 固定正文同时覆盖普通字符和多代码单元 emoji。
        let source = String(repeating: "a😀", count: 8_192)
        // 选区完整覆盖正文，正常路径会进入长距离 UTF-16 转换和字符循环。
        let fullSelection = NSRange(location: 0, length: (source as NSString).length)
        // 睡眠让父测试能够在统计入口执行前确定性设置取消状态。
        let fullTask = Task.detached {
            // 取消会立即结束这段等待，随后可取消入口读取同一任务状态。
            try? await Task.sleep(for: .seconds(60))
            // 全文统计不得在已取消任务中开始扫描。
            return WritingStatisticsSupport.calculateIfNotCancelled(in: source)
        }
        // 先取消任务，避免依赖正文大小或机器速度制造竞态。
        fullTask.cancel()
        // 等待任务执行取消分支并返回结果。
        let fullResult = await fullTask.value

        // 选区使用独立任务，证明两个后台入口都观察自己的取消状态。
        let selectionTask = Task.detached {
            // 同样以可取消等待建立确定性起点。
            try? await Task.sleep(for: .seconds(60))
            // 长选区统计不得在已取消任务中推进索引或字符循环。
            return WritingStatisticsSupport.selectedCharacterCountIfNotCancelled(
                in: source,
                selectionUTF16Range: fullSelection
            )
        }
        // 在选区统计入口前设置取消状态。
        selectionTask.cancel()
        // 收集选区任务的明确取消结果。
        let selectionResult = await selectionTask.value

        // 全文取消必须使用 nil 与合法零字符结果区分。
        #expect(fullResult == nil)
        // 选区取消同样不得伪装成空选区的零。
        #expect(selectionResult == nil)
    }

    // 简化重复的选区统计调用，让无效范围断言保持聚焦。
    private func selectionCount(in source: String, range: NSRange) -> Int {
        // 原样转发输入，测试不添加任何修正或兜底逻辑。
        WritingStatisticsSupport.selectedCharacterCount(
            in: source,
            selectionUTF16Range: range
        )
    }

    // 通过泛型约束在编译期验证数据类型满足 Sendable。
    private func requireSendable<Value: Sendable>(_: Value) {
        // 无需运行时逻辑；能够成功调用即证明约束成立。
    }
}
