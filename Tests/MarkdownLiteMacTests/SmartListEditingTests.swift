import Foundation
import Testing

@testable import MarkdownLiteMac

// 覆盖智能 Return 的纯 UTF-16 编辑计划、围栏边界和性能上限。
@Suite("智能列表编辑")
struct SmartListEditingTests {
    // 无序列表在正文中间回车时应保留右侧 Unicode 正文。
    @Test("无序列表在 emoji 后拆行并续写")
    func testUnorderedContinuationInMiddleOfUnicodeText() throws {
        // emoji 占两个 UTF-16 单元，测试不能用字符数量代替 NSTextView 坐标。
        let source = "- 你好😀世界"
        // 光标放在 emoji 之后、剩余正文之前。
        let caret = ("- 你好😀" as NSString).length
        // 生成与真实 Return 相同的折叠选区计划。
        let edit = try #require(
            MarkdownListContinuationSupport.edit(
                in: source,
                selection: NSRange(location: caret, length: 0)
            )
        )
        // 新行继续使用原减号和单空格。
        #expect(edit.replacement == "\n- ")
        // 应用计划后右侧正文必须逐字保留。
        #expect(applying(edit, to: source) == "- 你好😀\n- 世界")
        // 光标落在下一项标记之后。
        #expect(edit.selectionAfterEdit.location == caret + ("\n- " as NSString).length)
    }

    // 三种无序标记都应按用户当前风格继续，而不是统一改成减号。
    @Test("无序列表保留减号星号和加号")
    func testAllUnorderedMarkersArePreserved() throws {
        // 逐项覆盖 Markdown Lite 解析器已经接受的全部无序标记。
        for marker in ["-", "*", "+"] {
            // 每个样本都带制表符缩进，验证行级前缀按原文保留。
            let source = "\t\(marker) 项目"
            // 文末折叠光标触发下一项续写。
            let selection = NSRange(location: (source as NSString).length, length: 0)
            // 每种标记都必须得到编辑计划。
            let edit = try #require(MarkdownListContinuationSupport.edit(in: source, selection: selection))
            // 下一项精确保留缩进、标记和一个解析器分隔空格。
            #expect(edit.replacement == "\n\t\(marker) ")
        }
    }

    // 任务识别必须与预览层跳过一个列表分隔、要求 ASCII 空格的规则一致。
    @Test("非标准任务仍按普通列表续写")
    func testNonstandardTasksRemainPlainListItems() throws {
        // 多一个列表分隔空格和任务后制表符都不是预览层任务。
        for source in ["-  [x] 正文", "- [x]\t正文"] {
            // 文末光标仍允许普通无序列表续写。
            let selection = NSRange(location: (source as NSString).length, length: 0)
            // 两种输入都应得到普通列表计划。
            let edit = try #require(MarkdownListContinuationSupport.edit(in: source, selection: selection))
            // 下一项不能凭空转换成任务。
            #expect(edit.replacement == "\n- ")
        }
    }

    // 带空格的 Markdown 分割线不能被首个减号或星号误判成列表。
    @Test("分割线回退原生 Return")
    func testSpacedDividersFallBack() {
        // 两种候选都由预览解析器识别为分割线。
        for source in ["- - -", "  *  *  *  "] {
            // 文末光标不应产生任何列表续写计划。
            #expect(
                MarkdownListContinuationSupport.edit(
                    in: source,
                    selection: NSRange(location: (source as NSString).length, length: 0)
                ) == nil
            )
        }
    }

    // 有序任务在文末回车时同时递增编号并重置完成态。
    @Test("有序任务继承 CRLF 并生成未完成下一项")
    func testOrderedTaskContinuationResetsCompletion() throws {
        // 上一行提供文末行需要继承的 CRLF 风格。
        let source = "前言\r\n\t12) [X] 已完成"
        // 文末光标模拟用户完成本项后按 Return。
        let selection = NSRange(location: (source as NSString).length, length: 0)
        // 生成下一有序任务的单次插入计划。
        let edit = try #require(MarkdownListContinuationSupport.edit(in: source, selection: selection))
        // 编号递增、右括号和缩进保留，任务状态固定为空格。
        #expect(edit.replacement == "\r\n\t13) [ ] ")
        // 原任务完成状态不能被反向修改。
        #expect(applying(edit, to: source) == source + "\r\n\t13) [ ] ")
    }

    // 当前行已有 CR 换行时必须精确复用而不是统一写成 LF。
    @Test("当前行精确保留 CR 换行")
    func testCurrentLineUsesCarriageReturn() throws {
        // 第一项使用单独 CR，后面保留下一普通行。
        let source = "- 项目\r后续"
        // 光标位于第一项正文末尾、CR 之前。
        let caret = ("- 项目" as NSString).length
        // 生成插入第二项的编辑计划。
        let edit = try #require(
            MarkdownListContinuationSupport.edit(
                in: source,
                selection: NSRange(location: caret, length: 0)
            )
        )
        // 插入换行必须保持单独 CR。
        #expect(edit.replacement == "\r- ")
        // 原有 CR 和后续正文继续保持原位。
        #expect(applying(edit, to: source) == "- 项目\r- \r后续")
    }

    // 空任务再次回车应清除整项标记并保留文档既有空行。
    @Test("空任务退出列表")
    func testEmptyTaskExitsList() throws {
        // 当前任务只有缩进、标记和尾随空白。
        let source = "前言\n\t- [ ]   \n后续"
        // 光标位于空任务行的内容终点。
        let linePrefix = "前言\n"
        // 计算空任务行末尾的 UTF-16 坐标。
        let caret = ((linePrefix + "\t- [ ]   ") as NSString).length
        // 生成移除当前列表标记的计划。
        let edit = try #require(
            MarkdownListContinuationSupport.edit(
                in: source,
                selection: NSRange(location: caret, length: 0)
            )
        )
        // 退出动作不插入第二个换行，只清空当前行内容。
        #expect(edit.replacement.isEmpty)
        // 原换行保留后得到一个普通空行。
        #expect(applying(edit, to: source) == "前言\n\n后续")
        // 光标回到该空行开头。
        #expect(edit.selectionAfterEdit.location == (linePrefix as NSString).length)
    }

    // 普通无序和有序空项应使用与任务相同的退出语义。
    @Test("普通空列表项退出结构")
    func testPlainEmptyItemsExitList() throws {
        // 两个样本分别覆盖无序和右括号有序标记。
        for source in ["  +   ", "9) "] {
            // 光标位于只有标记和空白的文末。
            let selection = NSRange(location: (source as NSString).length, length: 0)
            // 空项必须生成清除当前行的编辑计划。
            let edit = try #require(MarkdownListContinuationSupport.edit(in: source, selection: selection))
            // 替换范围覆盖完整当前行。
            #expect(edit.replacementRange == NSRange(location: 0, length: (source as NSString).length))
            // 清空标记后留下普通空行。
            #expect(edit.replacement.isEmpty)
        }
    }

    // 代码围栏中的列表样文本必须保持普通代码输入语义。
    @Test("围栏内回退且闭合后恢复智能列表")
    func testFencedCodeFallsBack() throws {
        // 闭合围栏带尾随空白，覆盖与预览解析器一致的合法形式。
        let source = "~~~ swift\n- 示例\n~~~~  \n- 正常"
        // 围栏内光标位于代码样例末尾。
        let codeCaret = ("~~~ swift\n- 示例" as NSString).length
        // 围栏内不能生成任何智能编辑计划。
        #expect(
            MarkdownListContinuationSupport.edit(
                in: source,
                selection: NSRange(location: codeCaret, length: 0)
            ) == nil
        )
        // 闭合围栏后的真实列表位于文末。
        let listCaret = (source as NSString).length
        // 围栏状态清除后应重新允许续写。
        let edit = try #require(
            MarkdownListContinuationSupport.edit(
                in: source,
                selection: NSRange(location: listCaret, length: 0)
            )
        )
        // 文档使用 LF，正常列表继续使用减号。
        #expect(edit.replacement == "\n- ")
    }

    // 非目标输入必须安全交还 NSTextView 默认行为。
    @Test("非法选区、普通正文和编号溢出均回退")
    func testUnsupportedInputsFallBack() {
        // 多字符选区由系统负责替换，helper 不做猜测。
        #expect(
            MarkdownListContinuationSupport.edit(
                in: "- 正文",
                selection: NSRange(location: 2, length: 1)
            ) == nil
        )
        // 普通段落不应被误判成列表。
        #expect(
            MarkdownListContinuationSupport.edit(
                in: "普通正文",
                selection: NSRange(location: 4, length: 0)
            ) == nil
        )
        // Int.max 无法再加一，必须避免整数溢出。
        let overflow = "\(Int.max). 项目"
        // 文末回车安全回退原生路径。
        #expect(
            MarkdownListContinuationSupport.edit(
                in: overflow,
                selection: NSRange(location: (overflow as NSString).length, length: 0)
            ) == nil
        )
        // 构造 emoji 高低代理项之间的非法 UTF-16 光标。
        let unicodeSource = "- 😀项目"
        // 减号空格后第一个代理项占用一个 UTF-16 单元。
        let splitSurrogateLocation = ("- " as NSString).length + 1
        // helper 必须拒绝会拆开 emoji 的插入位置。
        #expect(
            MarkdownListContinuationSupport.edit(
                in: unicodeSource,
                selection: NSRange(location: splitSurrogateLocation, length: 0)
            ) == nil
        )
    }

    // 1MB 文档回车只允许轻量前缀扫描，不能退化为完整 Markdown 解析。
    @Test("1MB 文档计划计算保持有界")
    func testMegabyteDocumentPlanningIsBounded() {
        // 复用应用 release 自检的固定 1MB 样本和 100 次测量口径。
        let report = MarkdownListContinuationSelfCheck.run(
            iterations: 100,
            enforcePerformanceTargets: false
        )
        // 输出精确数字供本机和 CI 失败记录复核。
        print(
            String(
                format: "智能列表 1MB：p95 %.2fms，max %.2fms",
                report.p95Milliseconds,
                report.maximumMilliseconds
            )
        )
        #if DEBUG
            // Debug 只阻止明显的全解析或平方退化，避免把优化器差异当成产品回归。
            #expect(report.p95Milliseconds < 250)
        #else
            // Release 必须达到跨本机和共享 CI 都稳定的尾延迟目标。
            #expect(report.p95Milliseconds < 10)
            // 单次最大值保留调度余量，同时限制明显算法尖峰。
            #expect(report.maximumMilliseconds < 25)
        #endif
    }

    // 把纯编辑计划应用到 NSString，模拟 NSTextView 的等价替换结果。
    private func applying(_ edit: MarkdownFormattingEdit, to source: String) -> String {
        // 可变 UTF-16 字符串与正式替换范围使用相同坐标系。
        let result = NSMutableString(string: source)
        // 单次替换验证 helper 不依赖额外状态。
        result.replaceCharacters(in: edit.replacementRange, with: edit.replacement)
        // 返回 Swift String 供逐字断言。
        return result as String
    }
}
