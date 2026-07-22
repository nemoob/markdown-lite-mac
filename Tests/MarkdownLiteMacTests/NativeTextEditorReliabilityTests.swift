import AppKit
import SwiftUI
import Testing

@testable import MarkdownLiteMac

// 验证原生整文同步不会保留失效撤销范围，也不会误清其他标签历史。
@Suite("原生编辑器撤销可靠性", .serialized)
@MainActor
struct NativeTextEditorReliabilityTests {
    // 更短正文整体替换后，旧撤销范围必须被移除，避免 Command-Z 越界崩溃。
    @Test("整体换文只清当前失效撤销")
    func testWholeTextReplacementClearsInvalidUndo() async throws {
        // 复用真实但不显示的窗口，获得与应用一致的撤销响应者链。
        let window = makeWindow()
        // 创建一份比目标正文更长的原生编辑器。
        let textView = makeTextView(text: "original text")
        // 文本视图进入窗口后使用正式窗口级撤销管理器。
        window.contentView?.addSubview(textView)
        // 创建与初始原生正文一致的 SwiftUI 绑定值。
        let modelText = TextBox(textView.string)
        // 通过正式协调器入口应用后续模型整体替换。
        let coordinator = makeCoordinator(text: modelText)
        // 测试结束前取消协调器创建的任何异步工作。
        defer { coordinator.tearDown() }
        // 代理连接保证测试覆盖真实文本变化桥接。
        textView.delegate = coordinator
        // 协调器记录首屏已应用正文，匹配生产 makeNSView 路径。
        coordinator.recordInitialText(modelText.value)
        // 在文末输入一个字符以建立包含旧范围的真实撤销动作。
        insert("X", into: textView, window: window)
        // 输入动作必须已经进入共享撤销管理器。
        #expect(window.undoManager?.canUndo == true)

        // 使用明显不同的短正文触发同步入口中的即时整体替换。
        coordinator.synchronizeModelText("S", to: textView)

        // 无连续存储签名时正式实现会在后台严格比较，测试等待该路径完成。
        let didApplyReplacement = await waitUntil { textView.string == "S" }
        // 整体替换未完成时立即停止，不能继续触发已知失效的旧撤销范围。
        try #require(didApplyReplacement)
        // 原生正文必须采用新的短模型内容。
        #expect(textView.string == "S")
        // 当前 textStorage 的旧撤销范围必须已经精确清理。
        try #require(window.undoManager?.canUndo == false)
        // 即使用户继续触发撤销，也必须安全保持新正文而不是越界崩溃。
        window.undoManager?.undo()
        // 无可撤销动作时正文保持整体替换结果。
        #expect(textView.string == "S")
    }

    // 两个标签共享窗口撤销管理器时，清理一个 textStorage 不能删除另一个标签动作。
    @Test("共享窗口撤销栈按标签精确清理")
    func testWholeTextReplacementPreservesOtherDocumentUndo() async throws {
        // 创建与应用单窗口多标签结构一致的窗口。
        let window = makeWindow()
        // 第一个文本视图代表发生磁盘整体重载的标签。
        let firstTextView = makeTextView(text: "A")
        // 第二个文本视图代表仍需保留撤销历史的后台标签。
        let secondTextView = makeTextView(text: "B")
        // 两个文本视图同时挂到同一窗口，确保实际共享 undoManager。
        window.contentView?.addSubview(firstTextView)
        // 第二个视图同样进入窗口响应者链。
        window.contentView?.addSubview(secondTextView)
        // 明确验证本测试确实覆盖共享窗口撤销管理器。
        #expect(firstTextView.undoManager === secondTextView.undoManager)
        // 为第一个标签建立独立输入撤销动作。
        insert("1", into: firstTextView, window: window)
        // 为第二个标签建立更新且仍需保留的输入撤销动作。
        insert("2", into: secondTextView, window: window)
        // 两个动作完成后的正文分别保持在各自标签。
        #expect(firstTextView.string == "A1")
        #expect(secondTextView.string == "B2")

        // 为第一个标签创建正式模型同步协调器。
        let firstModelText = TextBox(firstTextView.string)
        // 协调器只负责第一个标签的整体替换。
        let firstCoordinator = makeCoordinator(text: firstModelText)
        // 测试结束前取消整体换文可能安排的后台工作。
        defer { firstCoordinator.tearDown() }
        // 记录当前原生正文，使不同短目标直接进入整体替换路径。
        firstCoordinator.recordInitialText(firstModelText.value)
        // 第一个标签采用外部模型版本，并精确清理自己的旧撤销动作。
        firstCoordinator.synchronizeModelText("new A", to: firstTextView)

        // 等待签名快速路径或后台严格比较路径完成正式整体替换。
        let didApplyReplacement = await waitUntil { firstTextView.string == "new A" }
        // 未完成整体替换时停止，避免后续撤销验证错误消费第一个标签旧动作。
        try #require(didApplyReplacement)
        // 第一个标签已经采用新的整体正文。
        #expect(firstTextView.string == "new A")
        // 第二个标签的撤销动作必须仍留在共享窗口管理器中。
        try #require(window.undoManager?.canUndo == true)
        // 当前最新剩余动作属于第二个标签，执行撤销验证未被误清。
        window.undoManager?.undo()
        // 第一标签不能受到第二标签撤销影响。
        #expect(firstTextView.string == "new A")
        // 第二标签应只撤销自己的最后一次输入。
        #expect(secondTextView.string == "B")
    }

    // 只有原生撤销或重做事件需要触发模型 dirty 精确校准回调。
    @Test("撤销重做各触发一次 dirty 校准回调")
    func testUndoRedoInvokesDirtyReconciliationCallbackOncePerAction() {
        // 复用真实窗口撤销管理器验证 delegate 对 isUndoing 和 isRedoing 的识别。
        let window = makeWindow()
        // 初始正文代表已经保存的模型内容。
        let textView = makeTextView(text: "已保存")
        // 文本视图进入共享窗口响应者链。
        window.contentView?.addSubview(textView)
        // 创建可观察正文回写结果的绑定值。
        let modelText = TextBox(textView.string)
        // 记录 dirty 校准回调实际触发次数。
        var reconciliationCount = 0
        // 创建带撤销重做回调的原生编辑器描述。
        var editor = NativeTextEditor(
            text: binding(to: modelText),
            syntaxHighlightingEnabled: false
        )
        // 回调只增加计数，避免测试依赖 EditorModel 实现。
        editor.onUndoRedoTextChange = { reconciliationCount += 1 }
        // 建立正式协调器并连接 NSTextView delegate。
        let coordinator = NativeTextEditor.Coordinator(parent: editor)
        // 测试结束前停止正文变化可能安排的异步任务。
        defer { coordinator.tearDown() }
        // 原生文本变化交给正式桥接路径处理。
        textView.delegate = coordinator
        // 首屏正文已经同步到协调器。
        coordinator.recordInitialText(modelText.value)

        // 在撤销管理器空闲时直接模拟一次普通文本系统变更。
        replaceTextStorage(of: textView, with: "已保存X")
        // 普通变更只回写正文，不执行 O(n) 保存快照校准。
        #expect(reconciliationCount == 0)
        // 普通变更已经通过 delegate 回写最新模型正文。
        #expect(modelText.value == "已保存X")
        // 创建会在 UndoManager 执行期修改正文并发送正式 delegate 通知的目标。
        let mutation = UndoTextMutation(textView: textView, undoManager: window.undoManager)
        // 显式注册回到保存正文的撤销动作。
        mutation.registerUndo(replacingWith: "已保存")
        // 执行原生撤销，delegate 应在 undoManager 仍标记 isUndoing 时识别来源。
        window.undoManager?.undo()
        // 撤销后的绑定正文必须回到保存版本。
        #expect(modelText.value == "已保存")
        // 撤销完成后恰好触发一次 dirty 精确校准。
        #expect(reconciliationCount == 1)
        // 原生重做恢复刚才输入的同一字符。
        window.undoManager?.redo()
        // 重做后的绑定正文必须再次采用编辑版本。
        #expect(modelText.value == "已保存X")
        // 重做只追加一次校准回调，普通输入仍未产生额外调用。
        #expect(reconciliationCount == 2)
    }

    // 直接修改 NSTextStorage 后发送 NSTextView 正式文本变化通知。
    private func replaceTextStorage(of textView: NSTextView, with text: String) {
        // NSTextStorage setter 不经过用户输入撤销注册，适合隔离测试 delegate 来源判断。
        textView.textStorage?.setAttributedString(NSAttributedString(string: text))
        // 通知 NSTextView 完成一次正文变化并回调其 delegate。
        textView.didChangeText()
    }

    // 所有串行用例共享一个不显示窗口，避免反复销毁 AppKit 响应者链造成测试进程不稳定。
    private static let sharedWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    // 重置并返回不会显示到屏幕、但具备真实响应者链的测试窗口。
    private func makeWindow() -> NSWindow {
        // 读取主 actor 隔离的共享测试窗口。
        let window = Self.sharedWindow
        // 先解除上一用例的第一响应者，避免保留旧文本输入上下文。
        window.makeFirstResponder(nil)
        // 移除上一用例添加的全部测试文本视图。
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        // 每例从空撤销栈开始，避免跨用例动作影响断言。
        window.undoManager?.removeAllActions()
        // 关闭按事件自动分组，测试通过显式分组获得确定性撤销边界。
        window.undoManager?.groupsByEvent = false
        // 返回与应用一致的窗口级撤销管理器宿主。
        return window
    }

    // 创建允许撤销的纯文本 NSTextView。
    private func makeTextView(text: String) -> NSTextView {
        // 使用独立 textStorage 确保每个标签可以按目标精确清理。
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 140))
        // 开启 NSTextView 原生输入撤销注册。
        textView.allowsUndo = true
        // 写入不进入撤销栈的测试初始正文。
        textView.string = text
        // 返回可挂到共享窗口的原生编辑器。
        return textView
    }

    // 在单个明确撤销组内向指定文本视图末尾插入正文。
    private func insert(_ text: String, into textView: NSTextView, window: NSWindow) {
        // 当前标签先成为第一响应者，匹配用户真实输入目标。
        window.makeFirstResponder(textView)
        // 光标移动到当前正文 UTF-16 末尾。
        let end = (textView.string as NSString).length
        // 设置零长度选区供 insertText 追加正文。
        textView.setSelectedRange(NSRange(location: end, length: 0))
        // 取得两个标签共享的窗口撤销管理器。
        guard let undoManager = window.undoManager else {
            // 测试环境缺少撤销管理器属于不可继续的基础失败。
            Issue.record("测试窗口缺少 undoManager")
            // 保持正文不变并终止本次辅助操作。
            return
        }
        // 显式开始一组，避免无事件循环测试依赖 AppKit 自动分组。
        undoManager.beginUndoGrouping()
        // 走与真实编辑器一致的原生输入入口。
        textView.insertText(text, replacementRange: textView.selectedRange())
        // 结束连续输入合并，保证本轮形成单独动作。
        textView.breakUndoCoalescing()
        // 关闭显式撤销组，使后续 undo 可以立即执行。
        undoManager.endUndoGrouping()
    }

    // 等待主 actor 上的异步模型严格比较与整体换文完成。
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        // 最多等待一秒，足够覆盖测试短文本的后台 equality 与主 actor 回写。
        for _ in 0..<100 {
            // 条件满足后立即结束，不引入固定测试延迟。
            if condition() { return true }
            // 短暂让出主 actor，允许协调器异步任务完成并回写 NSTextView。
            try? await Task.sleep(for: .milliseconds(10))
        }
        // 超时后返回最终状态供 #require 记录明确失败并停止危险后续动作。
        return condition()
    }

    // 用引用语义安全承载会被 Binding 逃逸闭包读写的测试正文。
    private final class TextBox {
        // 保存原生编辑器与模型之间的最新正文。
        var value: String

        // 使用明确初始正文创建盒子。
        init(_ value: String) {
            // 保存初始值供绑定 getter 读取。
            self.value = value
        }
    }

    // 在 UndoManager 的 undo/redo 执行窗口内制造确定性的 NSTextView 正文变化。
    @MainActor
    private final class UndoTextMutation {
        // 弱引用测试文本视图，避免撤销栈与视图形成持有环。
        private weak var textView: NSTextView?
        // 弱引用共享撤销管理器，窗口释放后不继续注册动作。
        private weak var undoManager: UndoManager?

        // 保存本测试需要联动的文本视图和撤销管理器。
        init(textView: NSTextView, undoManager: UndoManager?) {
            // 保存待修改视图。
            self.textView = textView
            // 保存动作注册目标管理器。
            self.undoManager = undoManager
        }

        // 注册下一次撤销时采用的正文。
        func registerUndo(replacingWith replacement: String) {
            // 管理器不存在时测试前置条件无法成立。
            guard let undoManager else { return }
            // 无事件循环测试需要显式建立初始撤销分组。
            undoManager.beginUndoGrouping()
            // 以当前辅助对象为目标，确保动作闭包生命周期稳定。
            undoManager.registerUndo(withTarget: self) { target in
                // UndoManager 闭包签名未声明 actor，但本测试只在主线程同步调用 undo/redo。
                MainActor.assumeIsolated {
                    // 在已核对的主 actor 上执行可自动注册反向 redo 的统一替换。
                    target.replace(with: replacement)
                }
            }
            // 完成初始动作分组，后续 undo 可以立即执行。
            undoManager.endUndoGrouping()
        }

        // 替换正文并为相反方向注册恢复动作。
        private func replace(with replacement: String) {
            // 视图或管理器已经释放时保持安全空操作。
            guard let textView, let undoManager else { return }
            // 捕获替换前正文供自动 redo 或再次 undo 使用。
            let previousText = textView.string
            // UndoManager 在 undo/redo 期间会把新注册动作放入相反方向栈。
            undoManager.registerUndo(withTarget: self) { target in
                // UndoManager 同步回调发生在本测试明确调用 undo/redo 的主 actor。
                MainActor.assumeIsolated {
                    // 反向动作复用同一替换和通知路径。
                    target.replace(with: previousText)
                }
            }
            // 直接替换存储，避免辅助动作再次创建 NSTextView 输入撤销。
            textView.textStorage?.setAttributedString(NSAttributedString(string: replacement))
            // 在 undoManager 仍处于 isUndoing 或 isRedoing 时发送 delegate 通知。
            textView.didChangeText()
        }
    }

    // 创建读写引用盒子的 SwiftUI 绑定。
    private func binding(to text: TextBox) -> Binding<String> {
        // getter 和 setter 共享稳定引用，不依赖局部 inout 生命周期。
        Binding(
            get: { text.value },
            // setter 保存原生编辑器回写后的最新正文。
            set: { text.value = $0 }
        )
    }

    // 创建使用正式正文同步路径的协调器。
    private func makeCoordinator(text: TextBox) -> NativeTextEditor.Coordinator {
        // 构造连接局部模型正文的编辑器描述，并关闭与本测试无关的异步高亮。
        let editor = NativeTextEditor(
            text: binding(to: text),
            syntaxHighlightingEnabled: false
        )
        // 返回可直接调用内部同步入口的正式协调器。
        return NativeTextEditor.Coordinator(parent: editor)
    }
}
