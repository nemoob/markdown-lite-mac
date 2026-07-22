import Foundation
import Testing

@testable import MarkdownLiteMac

// 验证任务清单点击和菜单共享的纯逻辑只修改准确源行状态。
@Suite("任务清单交互")
struct TaskListInteractionTests {
    // 无序任务切换必须保留缩进、Unicode 正文和 CRLF。
    @Test("无序任务保留原文与 CRLF")
    func testUncheckedTaskTogglePreservesSource() throws {
        // 第二行包含缩进、星号和中文正文，覆盖常见跨平台文档。
        let source = "标题\r\n\t* [ ] 写完 😀\r\n结尾"
        // 当前编辑选区留在首行，预览点击不应移动写作光标。
        let selection = NSRange(location: 1, length: 0)
        // 使用解析时正文和状态生成带过期校验的编辑计划。
        let edit = MarkdownTaskToggleSupport.edit(
            in: source,
            line: 1,
            expectedText: "写完 😀",
            expectedChecked: false,
            preserving: selection
        )
        // 合法任务必须生成一次单字符替换。
        let requiredEdit = try #require(edit)
        // 未完成状态统一替换为小写 x。
        #expect(requiredEdit.replacement == "x")
        // 预览点击后仍保留原始写作选区。
        #expect(requiredEdit.selectionAfterEdit == selection)
        // 按 NSTextView 的 UTF-16 方式应用计划。
        let result = NSMutableString(string: source)
        // 只替换方括号中的状态字符。
        result.replaceCharacters(in: requiredEdit.replacementRange, with: requiredEdit.replacement)
        // 缩进、列表标记、正文和 CRLF 必须逐字节语义保持。
        #expect(result as String == "标题\r\n\t* [x] 写完 😀\r\n结尾")
    }

    // 有序任务和大写完成标记都应切回未完成且保留真实编号。
    @Test("有序任务保留编号并兼容大写 X")
    func testCheckedOrderedTaskToggle() throws {
        // 右括号编号和大写 X 均由现有解析器支持。
        let source = "  12) [X] 已完成\n下一行"
        // 光标位于任务正文中，菜单切换后位置应保持。
        let selection = NSRange(location: 12, length: 2)
        // 当前行菜单无需提供预期快照，但仍走同一纯逻辑。
        let edit = MarkdownTaskToggleSupport.edit(
            in: source,
            line: 0,
            preserving: selection
        )
        // 已识别任务必须返回可应用计划。
        let requiredEdit = try #require(edit)
        // 完成状态只替换为空格。
        #expect(requiredEdit.replacement == " ")
        // 应用替换验证编号和正文完全不变。
        let result = NSMutableString(string: source)
        // 模拟原生文本系统的一次等长替换。
        result.replaceCharacters(in: requiredEdit.replacementRange, with: requiredEdit.replacement)
        // 输出只改变任务状态字符。
        #expect(result as String == "  12) [ ] 已完成\n下一行")
        // 等长替换不得移动原选区。
        #expect(requiredEdit.selectionAfterEdit == selection)
    }

    // 旧预览的正文、状态或行号任一不匹配都必须停止写回。
    @Test("过期预览安全空操作")
    func testStalePreviewIsRejected() {
        // 当前源文件已经从旧预览的未完成状态变成完成状态。
        let source = "- [x] 新正文"
        // 旧状态不匹配时拒绝重复切换。
        #expect(
            MarkdownTaskToggleSupport.edit(
                in: source,
                line: 0,
                expectedText: "新正文",
                expectedChecked: false,
                preserving: NSRange(location: 0, length: 0)
            ) == nil
        )
        // 旧正文不匹配时不能修改同一行后来出现的新任务。
        #expect(
            MarkdownTaskToggleSupport.edit(
                in: source,
                line: 0,
                expectedText: "旧正文",
                expectedChecked: true,
                preserving: NSRange(location: 0, length: 0)
            ) == nil
        )
        // 越过文末的旧行号不能因映射到 EOF 而误改最后一行。
        #expect(
            MarkdownTaskToggleSupport.edit(
                in: source,
                line: 8,
                expectedText: "新正文",
                expectedChecked: true,
                preserving: NSRange(location: 0, length: 0)
            ) == nil
        )
        // 解析器无法装入 Int 的超长有序编号不能被切换逻辑单独当作任务。
        let oversizedNumber = String(repeating: "9", count: 80) + ". [ ] 正文"
        // 菜单与预览必须和解析器保持相同语法边界。
        #expect(
            MarkdownTaskToggleSupport.edit(
                in: oversizedNumber,
                line: 0,
                preserving: NSRange(location: 0, length: 0)
            ) == nil
        )
    }

    // 格式菜单命令必须以当前选区所在行切换任务并拒绝普通列表。
    @Test("格式菜单路由当前任务行")
    func testFormattingCommandRoutesCurrentLine() throws {
        // 第二行是任务，首行和末行用于验证行定位边界。
        let source = "普通行\n- [ ] 当前任务\n- 普通列表"
        // 把光标放在第二行任务正文中。
        let taskLocation = ("普通行\n- [ ] 当" as NSString).length
        // 通过正式格式命令入口生成任务切换。
        let edit = MarkdownFormattingSupport.edit(
            in: source,
            selection: NSRange(location: taskLocation, length: 0),
            command: .toggleTask
        )
        // 当前任务行必须可切换。
        let requiredEdit = try #require(edit)
        // 正式命令同样只写入一个 x。
        #expect(requiredEdit.replacement == "x")

        // 把光标移动到没有任务标记的第三行。
        let plainListLocation = ("普通行\n- [ ] 当前任务\n" as NSString).length
        // 普通列表不能被菜单隐式转换为任务。
        #expect(
            MarkdownFormattingSupport.edit(
                in: source,
                selection: NSRange(location: plainListLocation, length: 0),
                command: .toggleTask
            ) == nil
        )
    }
}
