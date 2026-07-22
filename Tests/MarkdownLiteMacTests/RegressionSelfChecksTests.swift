import Foundation
import Testing

@testable import MarkdownLiteMac

// 将既有无界面自检纳入标准 Swift Testing 发现和报告流程。
@Suite("既有模块标准回归")
struct RegressionSelfChecksTests {
    // 文档读写、编码、草稿、最近文件和 dirty 快照必须全部通过。
    @Test("文档支撑层")
    func testDocumentSupportSelfCheck() throws {
        // 复用正式隔离自检实现。
        let report = try DocumentSupportSelfCheck.run()
        // 当前至少覆盖六条持久化主路径。
        #expect(report.passedChecks.count >= 6)
    }

    // 会话顺序和活动标签必须可跨启动往返。
    @Test("会话持久化")
    func testSessionSupportSelfCheck() throws {
        // 运行隔离会话持久化自检。
        let result = try SessionSupportSelfCheck.run()
        // 稳定通过标记应说明恢复成功。
        #expect(result.contains("恢复通过"))
    }

    // 多标签、独立草稿和失效文件回退必须通过。
    @Test("多标签工作区")
    @MainActor
    func testWorkspaceModelSelfCheck() throws {
        // 工作区模型属于主 actor，测试在相同隔离域执行。
        let result = try WorkspaceModelSelfCheck.run()
        // 稳定通过标记应包含多标签核心能力。
        #expect(result.contains("多标签去重"))
    }

    // 图片相对路径、重名、类型和穿越保护必须通过。
    @Test("图片资源安全")
    func testAssetSupportSelfCheck() {
        // 关闭标准输出，只消费结构化通过数量。
        let passedChecks = AssetSupportSelfCheck.run(printResults: false)
        // 当前图片模块包含十条安全和兼容性检查。
        #expect(passedChecks >= 10)
    }

    // HTML 与公众号两套模板必须保持安全输出。
    @Test("导出安全")
    func testExportSupportSelfCheck() {
        // 导出自检返回所有失败原因。
        let failures = ExportSupportSelfCheck.run()
        // 空数组表示所有安全与模板断言通过。
        #expect(failures.isEmpty)
    }

    // Markdown 结构和两档完整基准样本必须进入标准测试报告。
    @Test("Markdown 结构与基准样本")
    func testMarkdownStructureAndBenchmarkSamples() {
        // Debug 测试进程只验证结构与样本完整性，发布性能由随后独立 release 自检门禁。
        let report = EnhancedMarkdownSelfCheck.run(
            printResults: false,
            enforcePerformanceTargets: false
        )
        // 增强块类型样例必须保持完整识别。
        #expect(report.blockTypesValid)
        // 中档样本必须完整覆盖至少 200KB、真实块输出和既定 50ms 门槛。
        #expect(report.mediumDocument.actualBytes >= 200_000)
        #expect(report.mediumDocument.blockCount > 0)
        #expect(report.mediumDocument.targetMilliseconds == 50)
        // 大档样本必须完整覆盖至少 1MB、真实块输出和既定 200ms 门槛。
        #expect(report.largeDocument.actualBytes >= 1_000_000)
        #expect(report.largeDocument.blockCount > report.mediumDocument.blockCount)
        #expect(report.largeDocument.targetMilliseconds == 200)
    }

    // 文档末尾空行必须可以通过标题快捷键直接开始新标题。
    @Test("EOF 空行标题格式")
    func testHeadingFormattingAtTrailingEmptyLine() {
        // 构造以换行结尾的常见回车后编辑场景。
        let source = "正文\n"
        // 光标位于换行后的零长度末行。
        let selection = NSRange(location: (source as NSString).length, length: 0)
        // 生成二级标题格式编辑。
        let edit = MarkdownFormattingSupport.edit(
            in: source,
            selection: selection,
            command: .heading(level: 2)
        )
        // 格式支持必须返回可执行编辑。
        #expect(edit != nil)
        // 生成失败时停止后续解包，前一断言会报告原因。
        guard let edit else { return }
        // 末行零长度范围必须被标题标记替换。
        #expect(edit.replacementRange == selection)
        // 二级标题标记包含两个井号和一个空格。
        #expect(edit.replacement == "## ")
        // 应用与 NSTextView 相同的单次替换。
        let result = NSMutableString(string: source)
        // 把格式编辑写入末尾空行。
        result.replaceCharacters(in: edit.replacementRange, with: edit.replacement)
        // 最终正文必须保留原换行并追加标题标记。
        #expect(result as String == "正文\n## ")
        // 光标应落在标题标记之后供用户立即输入。
        #expect(edit.selectionAfterEdit == NSRange(location: selection.location + 3, length: 0))
    }

    // 编辑栏格式菜单必须完整描述并路由现有原生格式命令。
    @Test("编辑栏格式菜单路由")
    func testEditorFormattingMenuContent() {
        // 读取一级菜单的四项高频行内格式。
        let inlineEntries = EditorFormattingMenuContent.inlineEntries
        // 一级菜单命令顺序应匹配用户最常用的格式顺序。
        #expect(inlineEntries.map(\.command) == [.bold, .italic, .inlineCode, .link])
        // 快捷键提示必须与应用命令保持一致。
        #expect(inlineEntries.map(\.shortcutHint) == ["⌘B", "⌘I", "⌘E", "⌘K"])

        // 读取标题子菜单的全部级别。
        let headingEntries = EditorFormattingMenuContent.headingEntries
        // 标题子菜单必须完整覆盖 H1 到 H6。
        #expect(headingEntries.map(\.title) == (1...6).map { "H\($0) 标题" })
        // 每一级标题必须路由到对应的现有格式命令。
        #expect(headingEntries.map(\.command) == (1...6).map { .heading(level: $0) })
        // 标题快捷键提示必须完整覆盖 Command-Option-1 到 6。
        #expect(headingEntries.map(\.shortcutHint) == (1...6).map { "⌘⌥\($0)" })

        // 任务状态作为独立块级动作复用同一原生格式路由。
        let taskEntry = EditorFormattingMenuContent.taskEntry
        // 菜单必须把任务项连接到纯逻辑切换命令。
        #expect(taskEntry.command == .toggleTask)
        // 可见快捷键必须与应用菜单注册的 Command-Shift-X 一致。
        #expect(taskEntry.shortcutHint == "⌘⇧X")

        // 合并所有菜单项便于统一检查可发现性描述。
        let allEntries = inlineEntries + [taskEntry] + headingEntries
        // 每项稳定标识必须唯一，避免 SwiftUI 复用错误动作。
        #expect(Set(allEntries.map(\.id)).count == allEntries.count)
        // 所有动作都必须提供非空标题、快捷键和帮助说明。
        #expect(
            allEntries.allSatisfy {
                !$0.title.isEmpty && !$0.shortcutHint.isEmpty && !$0.helpText.isEmpty
            })
        // 菜单入口本身也必须提供 tooltip 和无障碍描述。
        #expect(!EditorFormattingMenuContent.helpText.isEmpty)
        #expect(!EditorFormattingMenuContent.accessibilityLabel.isEmpty)
        #expect(!EditorFormattingMenuContent.accessibilityHint.isEmpty)
    }
}
