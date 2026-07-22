import AppKit
import SwiftUI

// 把菜单和标题栏动作转交给 NSTextView 自带的查找替换栏。
@MainActor
enum NativeEditorActions {
    // 单窗口版本只需要弱引用当前正文编辑器，不延长视图生命周期。
    private static weak var textView: NSTextView?
    // 记录活动编辑器所属标签，防止过渡期动作串到后台标签。
    private static var activeDocumentID: UUID?

    // 只注册当前活动标签的原生编辑器。
    static func register(_ textView: NSTextView, documentID: UUID?, isActive: Bool) {
        // 当前实例失活时清理自己留下的弱引用。
        guard isActive else {
            if self.textView === textView {
                self.textView = nil
                activeDocumentID = nil
            }
            return
        }
        // 菜单动作始终定位到当前活动正文。
        self.textView = textView
        // 同步记录标签身份供后续动作核对。
        activeDocumentID = documentID
    }

    // 文本视图销毁时只清理精确实例，不能影响新活动标签。
    static func unregister(_ textView: NSTextView) {
        // 仅当前注册实例需要清空。
        guard self.textView === textView else { return }
        // 移除已经失效的动作目标。
        self.textView = nil
        activeDocumentID = nil
    }

    // 展示系统原生查找栏，替换模式同时展开替换控件。
    static func showFind(replacing: Bool) {
        // 编辑器尚未创建时不发送无目标动作。
        guard let textView else { return }
        // 标题栏按钮可能抢走焦点，先把第一响应者还给正文。
        textView.window?.makeFirstResponder(textView)
        // AppKit 通过菜单项 tag 区分普通查找与查找替换。
        let actionItem = NSMenuItem()
        actionItem.tag =
            replacing
            ? NSTextFinder.Action.showReplaceInterface.rawValue
            : NSTextFinder.Action.showFindInterface.rawValue
        // 原生实现自动维护查找历史、Unicode 匹配和可撤销替换。
        textView.performFindPanelAction(actionItem)
    }

    // 标签激活后把键盘第一响应者转交给对应正文。
    static func focus(documentID: UUID?) {
        // 仅当前注册标签可以获得焦点。
        guard documentID == activeDocumentID, let textView else { return }
        // 窗口进入层级后才设置第一响应者。
        textView.window?.makeFirstResponder(textView)
    }

    // 把活动编辑器跳转到零基源文件行号。
    static func jumpToLine(_ targetLine: Int, documentID: UUID? = nil) {
        // 编辑器尚未创建时不执行跳转。
        guard let textView else { return }
        // 调用方提供标签身份时必须与当前活动标签一致。
        if let documentID, documentID != activeDocumentID { return }
        // 负数统一收敛到首行。
        let safeTarget = max(0, targetLine)
        // 复用纯映射保证 emoji、CRLF 和自检路径完全一致。
        let location = MarkdownSourceLineMap.utf16Location(
            in: textView.string,
            line: safeTarget
        )
        // 把光标放到目标行开头。
        let selection = NSRange(location: location, length: 0)
        textView.setSelectedRange(selection)
        // 滚动到目标行并恢复输入焦点。
        textView.scrollRangeToVisible(selection)
        textView.window?.makeFirstResponder(textView)
    }

    // 在当前活动编辑器光标处插入一段可撤销 Markdown。
    static func insertMarkdown(_ markdown: String, documentID: UUID? = nil) {
        // 编辑器尚未创建时不执行插入。
        guard let textView else { return }
        // 明确标签身份不匹配时拒绝串写后台文档。
        if let documentID, documentID != activeDocumentID { return }
        // 原生插入 API 自动维护撤销栈并通知文本绑定。
        textView.insertText(markdown, replacementRange: textView.selectedRange())
    }

    // 对当前活动编辑器执行一项原生可撤销格式操作。
    @discardableResult
    static func applyFormatting(
        _ command: MarkdownEditorFormattingCommand,
        documentID: UUID? = nil
    ) -> Bool {
        // 编辑器尚未创建时向菜单报告未执行。
        guard let textView else { return false }
        // 调用方提供标签身份时必须与当前活动标签一致。
        if let documentID, documentID != activeDocumentID { return false }
        // 用纯逻辑生成 UTF-16 安全的单次替换计划。
        guard
            let edit = MarkdownFormattingSupport.edit(
                in: textView.string,
                selection: textView.selectedRange(),
                command: command
            )
        else { return false }
        // 格式化前结束连续输入合并，确保撤销只回退本次操作。
        textView.breakUndoCoalescing()
        // 通过 NSTextView 输入入口执行替换并通知 SwiftUI 绑定。
        textView.insertText(edit.replacement, replacementRange: edit.replacementRange)
        // 恢复命令定义的正文或占位选区。
        textView.setSelectedRange(edit.selectionAfterEdit)
        // 格式化后再次结束合并，后续输入保留独立撤销语义。
        textView.breakUndoCoalescing()
        // 滚动并聚焦当前格式化位置。
        textView.scrollRangeToVisible(edit.selectionAfterEdit)
        textView.window?.makeFirstResponder(textView)
        // 明确报告操作已经执行。
        return true
    }

    // 返回活动编辑器当前光标所在的零基逻辑行。
    static func currentLine(documentID: UUID? = nil) -> Int? {
        // 编辑器尚未创建时没有源位置。
        guard let textView else { return nil }
        // 明确标签身份不匹配时拒绝读取后台文档位置。
        if let documentID, documentID != activeDocumentID { return nil }
        // 使用纯 UTF-16 行映射保持 emoji 和 CRLF 正确。
        return MarkdownSourceLineMap.lineNumber(
            in: textView.string,
            utf16Location: textView.selectedRange().location
        )
    }
}

// 拦截图片文件和剪贴板位图，同时保留 NSTextView 其他原生粘贴行为。
private final class MarkdownNativeTextView: NSTextView {
    // 文件型图片交给当前文档资源层处理并返回 Markdown。
    var importImageFile: ((URL) -> String?)?
    // 位图型剪贴板内容交给资源层落盘并返回 Markdown。
    var importImageData: ((Data, String) -> String?)?

    // 粘贴时优先识别图片，普通文字仍走系统行为。
    override func paste(_ sender: Any?) {
        // 读取系统通用剪贴板。
        let pasteboard = NSPasteboard.general
        // Finder 复制的图片文件优先保持原始格式和文件名。
        if insertImageFiles(from: pasteboard, replacementRange: nil) { return }
        // 截图和应用内复制的 PNG 可直接落盘。
        if let pngData = pasteboard.data(forType: .png),
            let markdown = importImageData?(pngData, "pasted-image.png")
        {
            insertMarkdown(markdown, replacementRange: nil)
            return
        }
        // TIFF 是 macOS 常见的剪贴板位图格式，统一转换为 PNG。
        if let tiffData = pasteboard.data(forType: .tiff),
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:]),
            let markdown = importImageData?(pngData, "pasted-image.png")
        {
            insertMarkdown(markdown, replacementRange: nil)
            return
        }
        // 非图片内容继续使用系统原生粘贴。
        super.paste(sender)
    }

    // 文件拖入正文时尝试转换成相对图片 Markdown。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // 把窗口坐标转换为正文坐标。
        let localPoint = convert(sender.draggingLocation, from: nil)
        // NSTextView 计算最接近拖放位置的字符插入点。
        let insertionIndex = characterIndexForInsertion(at: localPoint)
        // 拖入图片只插入，不覆盖拖放前的旧选区。
        let insertionRange = NSRange(location: insertionIndex, length: 0)
        // 只在资源层确实接收图片时拦截系统拖放。
        if insertImageFiles(from: sender.draggingPasteboard, replacementRange: insertionRange) { return true }
        // 其他拖放类型保持 NSTextView 默认语义。
        return super.performDragOperation(sender)
    }

    // 从指定粘贴板读取本地文件并插入全部成功导入的图片。
    private func insertImageFiles(
        from pasteboard: NSPasteboard,
        replacementRange: NSRange?
    ) -> Bool {
        // 只读取本地文件 URL，避免把网络地址误当作待复制资源。
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        // 没有本地 URL 时交还系统处理。
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return false
        }
        // 每个成功导入的文件得到一行 Markdown 图片语法。
        let markdownLines = urls.compactMap { importImageFile?($0) }
        // 全部文件都不受支持时不吞掉原生拖放或粘贴。
        guard !markdownLines.isEmpty else { return false }
        // 多图之间换行，保持可继续编辑的原文结构。
        insertMarkdown(markdownLines.joined(separator: "\n"), replacementRange: replacementRange)
        return true
    }

    // 通过 NSTextView 编辑 API 插入文本，完整进入撤销栈并通知绑定。
    private func insertMarkdown(_ markdown: String, replacementRange: NSRange?) {
        // 粘贴使用当前选区，拖放使用鼠标对应的精确插入点。
        let range = replacementRange ?? selectedRange()
        // 在目标范围插入或替换，遵循原生输入与撤销语义。
        insertText(markdown, replacementRange: range)
    }
}

// 用固定数量首尾字节快速识别绝大多数正文版本，不扫描整篇文档。
struct NativeTextSignature: Equatable, Sendable {
    // UTF-8 长度可以直接区分插入和删除。
    let utf8Count: Int
    // 首部最多八字节折叠成固定值。
    let prefix: UInt64
    // 尾部最多八字节折叠成固定值。
    let suffix: UInt64

    // 只在 String 已有连续 UTF-8 存储时生成，不为签名复制或扫描全文。
    init?(_ source: String) {
        // 连续存储闭包可以常量时间读取数量和首尾字节。
        guard
            let values = source.utf8.withContiguousStorageIfAvailable({ bytes in
                // 同时返回长度、首部和尾部折叠值。
                (
                    bytes.count,
                    Self.fold(bytes.prefix(8)),
                    Self.fold(bytes.suffix(8))
                )
            })
        else {
            // 桥接或非连续字符串安全退化为来源标记和后台核对。
            return nil
        }
        // 保存底层 UTF-8 字节数量。
        utf8Count = values.0
        // 保存首部采样。
        prefix = values.1
        // 保存尾部采样。
        suffix = values.2
    }

    // 把最多八个字节稳定折叠到一个整数。
    private static func fold<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        // 从零开始按字节构造固定宽度值。
        var value: UInt64 = 0
        // 每轮只处理最多八个采样字节。
        for byte in bytes {
            // 左移后加入新字节，顺序变化也会得到不同结果。
            value = (value << 8) | UInt64(byte)
        }
        // 返回无需分配数组的轻量签名片段。
        return value
    }
}

// 集中定义轻量签名与严格正文核对的正确使用边界。
enum NativeTextComparison {
    // 只有两份签名都存在且不同才能直接证明正文变化。
    static func signaturesProveDifference(
        _ lhs: NativeTextSignature?,
        _ rhs: NativeTextSignature?
    ) -> Bool {
        // 相同或缺失签名都必须进入后台严格核对。
        guard let lhs, let rhs else { return false }
        // 不同签名可以安全跳过整文 equality。
        return lhs != rhs
    }

    // 执行可能为 O(n) 的严格正文核对，只允许后台任务调用。
    static func differsExactly(_ lhs: String, _ rhs: String) -> Bool {
        // Swift 字符串相等语义保证中部等长替换也能识别。
        lhs != rhs
    }
}

// 用原生 NSTextView 提供长文本输入、撤销和查找替换。
struct NativeTextEditor: NSViewRepresentable {
    // 与 SwiftUI 模型双向绑定正文。
    @Binding var text: String
    // 标签 UUID 供原生动作核对活动文档身份。
    var documentID: UUID? = nil
    // 只有活动标签能接收菜单查找和大纲跳转。
    var isActive = true
    // 编辑字号由设置页即时注入，默认值保持首版外观。
    var fontSize = EditorPreferenceDefaults.fontSize
    // 编辑行距由设置页即时注入，不修改 Markdown 原文。
    var lineSpacing = EditorPreferenceDefaults.lineSpacing
    // 关闭时清理所有临时语法属性并保留纯文本编辑。
    var syntaxHighlightingEnabled = EditorPreferenceDefaults.syntaxHighlightingEnabled
    // 本地图片文件导入由上层当前文档处理。
    var onImportImageFile: ((URL) -> String?)?
    // 剪贴板位图落盘由上层当前文档处理。
    var onImportImageData: ((Data, String) -> String?)?
    // 光标行变化时通知上层更新当前大纲章节。
    var onSelectionLineChanged: ((Int) -> Void)?

    // 协调器接收 AppKit 文本变化事件。
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        // 保存父视图用于回写绑定。
        var parent: NativeTextEditor
        // 记录上一轮活动状态以识别标签切换。
        var wasActive: Bool
        // 高亮任务版本用于丢弃过期后台结果。
        private var highlightGeneration = 0
        // 保存等待节流或后台扫描的高亮任务。
        private var highlightTask: Task<Void, Never>?
        // 保存真正执行纯语法扫描的 detached 任务，供新输入主动取消。
        private var highlightScanTask: Task<[MarkdownEditorSyntaxToken], Never>?
        // 光标行任务独立节流，避免按键时同步扫描大文档前缀。
        private var selectionTask: Task<Void, Never>?
        // 保存当前 NSTextView 已经采用的模型正文快照。
        private var appliedText = ""
        // 保存当前正文的可选常量时间签名。
        private var appliedTextSignature: NativeTextSignature?
        // 原生输入回写模型后，下一轮 SwiftUI 更新只消费该来源标记。
        private var pendingNativeEchoSignature: NativeTextSignature?
        // 无连续存储签名时仍用明确布尔来源标记识别下一轮回声。
        private var hasPendingNativeEcho = false
        // 模型同步版本保证异步同内容核对只接受最新结果。
        private var modelSyncGeneration = 0
        // 保存后台全文相等核对或输入法延后同步任务。
        private var modelSyncTask: Task<Void, Never>?
        // 外部模型整体替换时抑制原生 delegate 回声。
        private var isApplyingModelText = false
        // 弱引用当前原生编辑器供滚动通知刷新可见区域。
        private weak var textView: NSTextView?
        // 保存正在观察的滚动内容视图。
        private weak var observedClipView: NSClipView?
        // 记录当前是否存在临时语法属性，关闭后避免每次按键全量清理。
        private var syntaxAttributesAreActive = false
        // 保存已经真正应用到 NSTextView 的字号。
        private var appliedFontSize: Double?
        // 保存已经真正应用到 NSTextView 的行距。
        private var appliedLineSpacing: Double?
        // 输入法组合期间记住等待应用的最新字号。
        private var pendingFontSize: Double?
        // 输入法组合期间记住等待应用的最新行距。
        private var pendingLineSpacing: Double?
        // 等待 marked text 结束的偏好任务。
        private var preferenceTask: Task<Void, Never>?

        // 初始化协调器引用。
        init(parent: NativeTextEditor) {
            self.parent = parent
            // 初始状态用于后续比较活动边沿。
            wasActive = parent.isActive
        }

        // 记录 makeNSView 已经直接设置的首屏正文。
        func recordInitialText(_ source: String) {
            // 保留写时复制快照，后续相等核对不再读取 AppKit 全文。
            appliedText = source
            // 连续存储存在时保存常量时间签名。
            appliedTextSignature = NativeTextSignature(source)
            // 首屏设置不是用户输入，不产生 SwiftUI 回声。
            hasPendingNativeEcho = false
            pendingNativeEchoSignature = nil
        }

        // 区分 SwiftUI 回声、明显外部变化和同签名待核对变化。
        func synchronizeModelText(_ incomingText: String, to textView: NSTextView) {
            // 连续字符串只采样固定首尾字节，不遍历大文档。
            let incomingSignature = NativeTextSignature(incomingText)
            // 原生输入产生的下一轮更新只消费来源标记。
            if hasPendingNativeEcho {
                // 签名都存在且不同意味着期间出现了真正外部模型变化。
                let signatureProvesExternalChange = NativeTextComparison.signaturesProveDifference(
                    pendingNativeEchoSignature,
                    incomingSignature
                )
                // 来源标记只允许消费一次。
                hasPendingNativeEcho = false
                pendingNativeEchoSignature = nil
                // 明显不同可以立即采用外部模型正文。
                if signatureProvesExternalChange {
                    requestModelTextApplication(incomingText, to: textView)
                    return
                }
                // 签名相同仍可能是中部等长替换，只能放到后台严格核对。
                scheduleExactModelVerification(incomingText, textView: textView)
                return
            }

            // 签名存在且不同可以立即确认外部模型已变化。
            if NativeTextComparison.signaturesProveDifference(
                incomingSignature,
                appliedTextSignature
            ) {
                // 明显变化无需后台全文核对。
                requestModelTextApplication(incomingText, to: textView)
                return
            }

            // 相同或缺失签名仍可能是正文中部等长变化，放到后台精确核对。
            scheduleExactModelVerification(incomingText, textView: textView)
        }

        // 在后台精确核对同签名正文，主线程不做整文 equality。
        private func scheduleExactModelVerification(
            _ incomingText: String,
            textView: NSTextView
        ) {
            // 新更新使旧核对结果失效。
            modelSyncGeneration &+= 1
            // 捕获本轮版本供回写检查。
            let generation = modelSyncGeneration
            // 取消尚未开始或等待输入法的旧同步任务。
            modelSyncTask?.cancel()
            // 捕获当前已应用快照，String 写时复制不复制正文。
            let currentText = appliedText
            // 后台执行可能为 O(n) 的严格相等判断。
            modelSyncTask = Task { [weak self, weak textView] in
                // detached 避免一兆字符中部比较阻塞主线程。
                let differs = await Task.detached(priority: .utility) {
                    NativeTextComparison.differsExactly(currentText, incomingText)
                }.value
                // 只接受最新版本且视图仍存在的结果。
                guard !Task.isCancelled,
                    differs,
                    let self,
                    self.modelSyncGeneration == generation,
                    let textView
                else { return }
                // 精确确认变化后进入统一输入法保护路径。
                self.requestModelTextApplication(incomingText, to: textView)
            }
        }

        // 立即或在输入法结束后应用外部模型正文。
        private func requestModelTextApplication(
            _ incomingText: String,
            to textView: NSTextView
        ) {
            // 新目标让旧精确核对或等待任务失效。
            modelSyncGeneration &+= 1
            // 捕获当前目标版本。
            let generation = modelSyncGeneration
            // 取消旧同步任务，但当前任务取消自身不会影响后续同步代码。
            modelSyncTask?.cancel()
            // 没有组合输入时立即整体替换。
            guard textView.hasMarkedText() else {
                applyModelText(incomingText, to: textView)
                return
            }
            // 组合输入期间等待提交或取消，不能破坏候选文本。
            modelSyncTask = Task { [weak self, weak textView] in
                // 每轮只读取输入法状态。
                while let textView, textView.hasMarkedText() {
                    // 短间隔等待组合状态结束。
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    // 新外部版本或视图销毁时停止。
                    guard !Task.isCancelled else { return }
                }
                // 只应用最新等待版本。
                guard !Task.isCancelled,
                    let self,
                    self.modelSyncGeneration == generation,
                    let textView
                else { return }
                // 输入法结束后一次性采用外部模型正文。
                self.applyModelText(incomingText, to: textView)
            }
        }

        // 以一次非用户编辑替换 NSTextView 正文并恢复安全光标。
        private func applyModelText(_ incomingText: String, to textView: NSTextView) {
            // 保存旧选区用于尽可能恢复光标。
            let selection = textView.selectedRange()
            // 抑制程序化 setter 可能产生的 delegate 回声。
            isApplyingModelText = true
            // 仅外部模型真正变化时才触发整文 setter。
            textView.string = incomingText
            // setter 已同步完成，可以恢复正常用户输入通知。
            isApplyingModelText = false
            // 将旧位置限制在新文本 UTF-16 长度内。
            let content = incomingText as NSString
            // NSNotFound 防御性回退文档末尾。
            let oldLocation = selection.location == NSNotFound ? content.length : selection.location
            // 先按新正文长度收敛位置。
            let clampedLocation = min(oldLocation, content.length)
            // 把位置进一步收敛到组合字符起点，避免落在 emoji 中间。
            let location =
                clampedLocation < content.length
                ? content.rangeOfComposedCharacterSequence(at: clampedLocation).location
                : content.length
            // 恢复安全单光标。
            textView.setSelectedRange(NSRange(location: location, length: 0))
            // 更新已应用快照供后续轻量判断。
            appliedText = incomingText
            appliedTextSignature = NativeTextSignature(incomingText)
            // 外部同步不应被下一轮误判为用户回声。
            hasPendingNativeEcho = false
            pendingNativeEchoSignature = nil
            // 外部整体换文后刷新新正文高亮。
            scheduleHighlight(
                for: textView,
                editedRange: NSRange(location: location, length: 0),
                delayNanoseconds: 0
            )
        }

        // 只在值真正变化时应用编辑器字号和行距。
        func applyEditorPreferencesIfNeeded(to textView: NSTextView) {
            // 设置页范围外的直接调用也限制在可读字号。
            let desiredFontSize = min(24, max(12, parent.fontSize))
            // 行距限制到设置页公开范围。
            let desiredLineSpacing = min(12, max(0, parent.lineSpacing))
            // 已应用值完全一致时保持常量时间返回。
            if appliedFontSize == desiredFontSize,
                appliedLineSpacing == desiredLineSpacing
            {
                // 相同目标不再需要旧等待任务。
                preferenceTask?.cancel()
                preferenceTask = nil
                pendingFontSize = nil
                pendingLineSpacing = nil
                return
            }
            // 已有相同待应用目标时不因每次按键重启等待。
            if pendingFontSize == desiredFontSize,
                pendingLineSpacing == desiredLineSpacing,
                preferenceTask != nil
            {
                return
            }
            // 新设置使旧等待目标过期。
            preferenceTask?.cancel()
            // 记录最新目标，组合输入结束后只应用这一版。
            pendingFontSize = desiredFontSize
            pendingLineSpacing = desiredLineSpacing

            // 没有组合输入时立即应用一次。
            guard textView.hasMarkedText() else {
                applyEditorPreferences(
                    fontSize: desiredFontSize,
                    lineSpacing: desiredLineSpacing,
                    to: textView
                )
                return
            }

            // marked text 存在时等待输入法提交或取消组合文本。
            preferenceTask = Task { [weak self, weak textView] in
                // 每轮只做一次轻量状态检查，不触碰正文属性。
                while let textView, textView.hasMarkedText() {
                    // 以短间隔等待输入法状态变化。
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    // 设置再次变化或视图销毁时停止旧任务。
                    guard !Task.isCancelled else { return }
                }
                // 视图或协调器已经释放时不再应用。
                guard !Task.isCancelled,
                    let self,
                    let textView,
                    self.pendingFontSize == desiredFontSize,
                    self.pendingLineSpacing == desiredLineSpacing
                else { return }
                // 输入法结束后一次性应用最新偏好。
                self.applyEditorPreferences(
                    fontSize: desiredFontSize,
                    lineSpacing: desiredLineSpacing,
                    to: textView
                )
                // 活动标签补刷临时语法字体；后台标签激活时再刷新。
                self.scheduleHighlight(
                    for: textView,
                    editedRange: textView.selectedRange(),
                    delayNanoseconds: 0
                )
            }
        }

        // 把已规范化偏好应用到纯文本视图并更新缓存。
        private func applyEditorPreferences(
            fontSize: Double,
            lineSpacing: Double,
            to textView: NSTextView
        ) {
            // 纯文本编辑器统一采用稳定等宽字体。
            let font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
            // 创建不会修改 Markdown 字符串的默认段落样式。
            let paragraphStyle = NSMutableParagraphStyle()
            // 仅改变视觉行距。
            paragraphStyle.lineSpacing = CGFloat(lineSpacing)
            // 更新现有纯文本的基础字体。
            textView.font = font
            // 默认段落样式负责现有正文布局。
            textView.defaultParagraphStyle = paragraphStyle
            // 新输入沿用相同字体，避免关闭高亮后样式跳变。
            textView.typingAttributes[.font] = font
            // 新输入沿用当前行距。
            textView.typingAttributes[.paragraphStyle] = paragraphStyle
            // 记录真实应用值供后续按键快速比较。
            appliedFontSize = fontSize
            appliedLineSpacing = lineSpacing
            // 当前等待目标已经完成。
            pendingFontSize = nil
            pendingLineSpacing = nil
            preferenceTask = nil
        }

        // 用户输入后同步最新正文。
        func textDidChange(_ notification: Notification) {
            // 确认通知来自 NSTextView。
            guard let textView = notification.object as? NSTextView else { return }
            // 程序化整体换文不能再反向写回模型。
            guard !isApplyingModelText else { return }
            // 新用户输入使尚未应用的旧外部模型结果失效。
            modelSyncGeneration &+= 1
            // 取消等待严格核对或输入法结束的旧同步任务。
            modelSyncTask?.cancel()
            // 原生输入只读取一次最新正文。
            let changedText = textView.string
            // 当前 NSTextView 与这份正文已经一致。
            appliedText = changedText
            // 保存轻量签名供下一轮 SwiftUI 回声识别。
            let signature = NativeTextSignature(changedText)
            appliedTextSignature = signature
            pendingNativeEchoSignature = signature
            // 明确标记下一次模型更新来自当前原生编辑器。
            hasPendingNativeEcho = true
            // 回写 SwiftUI 状态。
            parent.text = changedText
            // 只刷新光标附近和可见区，大文档自动限制扫描体量。
            scheduleHighlight(
                for: textView,
                editedRange: textView.selectedRange(),
                delayNanoseconds: 80_000_000
            )
        }

        // 原生选区变化时异步计算当前逻辑行。
        func textViewDidChangeSelection(_ notification: Notification) {
            // 没有上层消费者时不产生任何行扫描成本。
            guard parent.isActive,
                parent.onSelectionLineChanged != nil,
                let textView = notification.object as? NSTextView
            else { return }
            // 捕获不可变正文和 UTF-16 光标位置供后台计算。
            let source = textView.string
            // 主选区起点代表当前光标章节。
            let location = textView.selectedRange().location
            // 新选区使旧行号结果过期。
            selectionTask?.cancel()
            // 短节流合并连续方向键和输入法选区事件。
            selectionTask = Task { [weak self] in
                // 等待选区稳定。
                try? await Task.sleep(nanoseconds: 50_000_000)
                // 取消任务不能继续回写旧章节。
                guard !Task.isCancelled else { return }
                // 行扫描离开主线程，避免文档末尾光标卡顿。
                let line = await Task.detached(priority: .utility) {
                    MarkdownSourceLineMap.lineNumber(in: source, utf16Location: location)
                }.value
                // 再次确认任务仍是最新结果。
                guard !Task.isCancelled, self?.parent.isActive == true else { return }
                // 使用协调器最新回调通知当前活动视图。
                self?.parent.onSelectionLineChanged?(line)
            }
        }

        // 注册滚动通知并安排首次高亮。
        func configureHighlighting(textView: NSTextView, scrollView: NSScrollView) {
            // 保存弱引用供滚动回调使用。
            self.textView = textView
            // 切换观察对象前移除旧通知。
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            // 滚动内容视图需要主动发布边界变化。
            scrollView.contentView.postsBoundsChangedNotifications = true
            // 保存新的精确观察对象。
            observedClipView = scrollView.contentView
            // 使用 selector 避免异步闭包持有 AppKit 视图。
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            // 只有活动标签需要立即生成可见区域样式。
            if parent.isActive {
                scheduleHighlight(for: textView, editedRange: nil, delayNanoseconds: 0)
            }
        }

        // 滚动到大文档新区域时补充局部高亮。
        @objc private func visibleBoundsDidChange(_ notification: Notification) {
            // 视图已经销毁时忽略迟到通知。
            guard let textView else { return }
            // 滚动事件使用更短节流保持样式跟随。
            scheduleHighlight(for: textView, editedRange: nil, delayNanoseconds: 40_000_000)
        }

        // 根据当前偏好安排一轮后台语法扫描。
        func scheduleHighlight(
            for textView: NSTextView,
            editedRange: NSRange?,
            delayNanoseconds: UInt64
        ) {
            // 后台标签只保留既有样式，不继续消耗扫描资源。
            guard parent.isActive else { return }
            // 关闭高亮时取消任务并清理既有临时属性。
            guard parent.syntaxHighlightingEnabled else {
                highlightTask?.cancel()
                highlightScanTask?.cancel()
                clearSyntaxAttributes(in: textView)
                return
            }
            // 新请求递增版本并取消等待中的旧请求。
            highlightGeneration &+= 1
            // 捕获本轮版本供回写核对。
            let generation = highlightGeneration
            // 旧任务不再需要继续等待或扫描。
            highlightTask?.cancel()
            highlightScanTask?.cancel()
            // String 写时复制提供低成本不可变快照。
            let source = textView.string
            // 读取当前可见字符范围供大文档降级。
            let visibleRange = visibleCharacterRange(in: textView)
            // 纯规划器决定全文或有限局部范围。
            let targetRange = MarkdownEditorHighlightPlanner.targetRange(
                in: source,
                editedRange: editedRange,
                visibleRange: visibleRange
            )
            // 捕获当前设置字号供主线程应用样式。
            let configuredFontSize = parent.fontSize
            // 节流后在后台执行纯语法扫描。
            highlightTask = Task { [weak self, weak textView] in
                // 非零延迟合并连续输入或滚动事件。
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                // 取消任务不再启动扫描。
                guard !Task.isCancelled else { return }
                // 为本轮正则与行扫描创建可独立取消的后台任务。
                let scanTask = Task.detached(priority: .userInitiated) {
                    MarkdownEditorSyntaxHighlighter.tokens(in: source, range: targetRange)
                }
                // 保存句柄，新输入可以真正终止已经开始的扫描。
                self?.highlightScanTask = scanTask
                // 外层取消时同步取消纯扫描任务。
                let tokens = await withTaskCancellationHandler {
                    await scanTask.value
                } onCancel: {
                    scanTask.cancel()
                }
                // 过期扫描结果不能覆盖新文本样式。
                guard !Task.isCancelled,
                    let self,
                    self.highlightGeneration == generation,
                    let textView
                else { return }
                // 当前句柄已经完成，不再保留。
                self.highlightScanTask = nil
                // 输入法仍有标记文本时延后属性变化，避免破坏组合输入。
                guard !textView.hasMarkedText() else {
                    self.scheduleHighlight(
                        for: textView,
                        editedRange: editedRange,
                        delayNanoseconds: 120_000_000
                    )
                    return
                }
                // 只对本轮覆盖范围应用临时属性，不触碰字符串和撤销栈。
                self.apply(
                    tokens: tokens,
                    coveredRange: targetRange,
                    fontSize: configuredFontSize,
                    to: textView
                )
            }
        }

        // 标签进入后台时取消只对前台有意义的异步工作。
        func pauseBackgroundWork() {
            // 递增版本确保已经进入 detached 的结果也无法回写。
            highlightGeneration &+= 1
            // 取消等待中的高亮和光标行任务。
            highlightTask?.cancel()
            highlightScanTask?.cancel()
            selectionTask?.cancel()
        }

        // 清理协调器持有的通知和异步任务。
        func tearDown() {
            // 停止所有尚未回写的任务。
            highlightTask?.cancel()
            highlightScanTask?.cancel()
            selectionTask?.cancel()
            preferenceTask?.cancel()
            modelSyncTask?.cancel()
            // 移除精确滚动观察对象。
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
            // 解除弱引用便于文本视图释放。
            textView = nil
            observedClipView = nil
        }

        // 返回当前可见矩形对应的 UTF-16 字符范围。
        private func visibleCharacterRange(in textView: NSTextView) -> NSRange? {
            // 布局管理器和文本容器缺失时由规划器回退安全范围。
            guard let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return nil }
            // 计算可见矩形覆盖的字形范围。
            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: textView.visibleRect,
                in: textContainer
            )
            // 字形范围转换为 NSString 使用的字符范围。
            return layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
        }

        // 移除可能由语法高亮设置的全部临时属性。
        private func clearSyntaxAttributes(in textView: NSTextView) {
            // 已经处于纯文本状态时保持常量时间返回。
            guard syntaxAttributesAreActive else { return }
            // 没有布局管理器时无需清理。
            guard let layoutManager = textView.layoutManager else { return }
            // 使用当前全文范围，关闭开关后立即恢复纯文本外观。
            let range = NSRange(location: 0, length: (textView.string as NSString).length)
            // 先更新状态，空文档也视为已经清理完成。
            syntaxAttributesAreActive = false
            // 空文档避免无意义属性调用。
            guard range.length > 0 else { return }
            // 逐项移除本模块使用的临时属性。
            for key in syntaxAttributeKeys {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: range)
            }
        }

        // 把后台 token 映射为 NSLayoutManager 临时属性。
        private func apply(
            tokens: [MarkdownEditorSyntaxToken],
            coveredRange: NSRange,
            fontSize: Double,
            to textView: NSTextView
        ) {
            // 没有布局管理器时保持普通文本显示。
            guard let layoutManager = textView.layoutManager else { return }
            // 新文本长度可能因极短竞态变化，先限制清理范围。
            let contentLength = (textView.string as NSString).length
            // 起点已经越界时整轮结果失效。
            guard coveredRange.location <= contentLength else { return }
            // 清理范围限制到当前文本末尾。
            let safeRange = NSRange(
                location: coveredRange.location,
                length: min(coveredRange.length, contentLength - coveredRange.location)
            )
            // 先清理旧语法属性，删除标记后不会残留颜色。
            for key in syntaxAttributeKeys {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: safeRange)
            }
            // 逐 token 应用有限原生属性。
            for token in tokens {
                // 迟到 token 越过当前正文时安全跳过。
                guard token.range.location != NSNotFound,
                    NSMaxRange(token.range) <= contentLength
                else { continue }
                // 生成当前类型的原生属性。
                let attributes = syntaxAttributes(for: token.kind, fontSize: fontSize)
                // 临时属性不改变 textStorage、选区或撤销内容。
                layoutManager.addTemporaryAttributes(attributes, forCharacterRange: token.range)
            }
            // 即使本轮没有 token，已覆盖区外仍可能保留语法属性。
            syntaxAttributesAreActive = true
        }

        // 返回语法类型对应的原生临时属性。
        private func syntaxAttributes(
            for kind: MarkdownEditorSyntaxKind,
            fontSize: Double
        ) -> [NSAttributedString.Key: Any] {
            // 字号限制到设置页允许范围，防御直接调用传入异常值。
            let baseSize = CGFloat(min(24, max(12, fontSize)))
            // 不同语法只设置必要属性，允许链接和强调叠加。
            switch kind {
            case let .heading(level):
                // 高级标题获得更明显字号，六级保持基础字号。
                let increment = CGFloat(max(0, 6 - min(6, max(1, level))))
                // 标题统一使用等宽粗体以保持编辑坐标稳定。
                return [
                    .font: NSFont.monospacedSystemFont(ofSize: baseSize + increment, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                ]
            case .strong:
                // 粗体只提高字重。
                return [.font: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .semibold)]
            case .emphasis:
                // 倾斜属性不覆盖标题或粗体字号。
                return [.obliqueness: 0.18]
            case .inlineCode:
                // 行内代码使用轻底色和强调色。
                return [
                    .font: NSFont.monospacedSystemFont(ofSize: max(11, baseSize - 1), weight: .medium),
                    .foregroundColor: NSColor.systemPink,
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10),
                ]
            case .codeBlock:
                // 围栏代码整块使用稳定等宽配色。
                return [
                    .font: NSFont.monospacedSystemFont(ofSize: max(11, baseSize - 1), weight: .regular),
                    .foregroundColor: NSColor.systemPurple,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.10),
                ]
            case .link:
                // 链接使用系统链接色并保留可识别下划线。
                return [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            case .quote:
                // 引用弱化为次级文字颜色。
                return [.foregroundColor: NSColor.secondaryLabelColor]
            }
        }

        // 统一列出清理时需要移除的临时属性键。
        private var syntaxAttributeKeys: [NSAttributedString.Key] {
            // 必须覆盖 syntaxAttributes 可能产生的每一种属性。
            [.font, .foregroundColor, .backgroundColor, .underlineStyle, .obliqueness]
        }
    }

    // 创建协调器。
    func makeCoordinator() -> Coordinator {
        // 每个编辑器只需要一个代理对象。
        Coordinator(parent: self)
    }

    // 创建带滚动和查找能力的原生编辑器。
    func makeNSView(context: Context) -> NSScrollView {
        // 滚动容器负责长文档导航。
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        // NSTextView 提供原生输入法、撤销、查找和选择行为。
        let textView = MarkdownNativeTextView()
        textView.delegate = context.coordinator
        textView.string = text
        // 首屏正文已经同步，后续更新不再做整文 equality。
        context.coordinator.recordInitialText(text)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 18, height: 18)
        // 首次创建即应用设置页字号和行距。
        context.coordinator.applyEditorPreferencesIfNeeded(to: textView)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        // 合并文件 URL 类型而不覆盖 NSTextView 已注册的原生文本拖放类型。
        var draggedTypes = textView.registeredDraggedTypes
        if !draggedTypes.contains(.fileURL) { draggedTypes.append(.fileURL) }
        textView.registerForDraggedTypes(draggedTypes)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // 中文与英文正文保留系统拼写提示。
        textView.isContinuousSpellCheckingEnabled = true
        // 容器宽度跟随编辑区，保持自然换行。
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        // 将文本视图放入滚动容器。
        scrollView.documentView = textView
        // 文件图片回调通过协调器读取最新 SwiftUI 参数。
        textView.importImageFile = { [weak coordinator = context.coordinator] url in
            coordinator?.parent.onImportImageFile?(url)
        }
        // 剪贴板位图回调同样保持最新文档身份。
        textView.importImageData = { [weak coordinator = context.coordinator] data, filename in
            coordinator?.parent.onImportImageData?(data, filename)
        }
        // 监听滚动并安排首次增量语法高亮。
        context.coordinator.configureHighlighting(textView: textView, scrollView: scrollView)
        // 注册活动编辑器供标题栏、菜单和大纲使用。
        NativeEditorActions.register(textView, documentID: documentID, isActive: isActive)
        // 新建标签的视图进入窗口后自动接收键盘输入。
        if isActive {
            DispatchQueue.main.async {
                NativeEditorActions.focus(documentID: documentID)
            }
        }
        // 返回完整编辑器。
        return scrollView
    }

    // 外部打开或新建文档时同步 NSTextView。
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // 获取内部文本视图。
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 先比较旧状态，识别后台标签刚被激活的边沿。
        let becameActive = isActive && !context.coordinator.wasActive
        // 比较旧偏好，决定是否需要重算临时语法字体。
        let highlightingPreferencesChanged =
            context.coordinator.parent.fontSize != fontSize || context.coordinator.parent.lineSpacing != lineSpacing
            || context.coordinator.parent.syntaxHighlightingEnabled != syntaxHighlightingEnabled
        // 保存本轮状态供下一次切换判断。
        context.coordinator.wasActive = isActive
        // 协调器必须持有最新绑定、活动状态和图片回调。
        context.coordinator.parent = self
        // 常量时间比较偏好；只有真实变化才触发布局更新。
        context.coordinator.applyEditorPreferencesIfNeeded(to: textView)
        // SwiftUI 更新后只让活动标签接管原生动作。
        NativeEditorActions.register(textView, documentID: documentID, isActive: isActive)
        // 点击标签后在下一轮事件循环把焦点从按钮转交给新正文。
        if becameActive {
            DispatchQueue.main.async {
                NativeEditorActions.focus(documentID: documentID)
            }
        }
        // 标签进入后台后立即停止未完成的高亮和章节计算。
        if !isActive {
            context.coordinator.pauseBackgroundWork()
        }
        // 新活动标签补刷自己的可见区，后台标签不会提前消耗性能。
        if becameActive {
            context.coordinator.scheduleHighlight(
                for: textView,
                editedRange: textView.selectedRange(),
                delayNanoseconds: 0
            )
        }
        // 字号、行距或开关变化时立即刷新当前高亮范围。
        if highlightingPreferencesChanged {
            context.coordinator.scheduleHighlight(
                for: textView,
                editedRange: textView.selectedRange(),
                delayNanoseconds: 0
            )
        }
        // 来源标记和轻量签名决定是否需要采用外部模型正文。
        context.coordinator.synchronizeModelText(text, to: textView)
    }

    // 标签关闭或视图销毁时清理精确原生动作目标。
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // 只有真正的内部文本视图需要注销。
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 停止滚动观察和后台高亮任务。
        coordinator.tearDown()
        // 清理弱引用，防止后续菜单动作访问已销毁视图。
        NativeEditorActions.unregister(textView)
    }
}
