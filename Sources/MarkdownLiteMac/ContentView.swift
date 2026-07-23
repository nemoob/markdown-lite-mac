import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 统一选择状态栏可见反馈，避免会话回退提示遮住更紧急的文档风险。
enum WorkspaceStatusPresentation {
    // 按数据安全优先级组合工作区和当前文档状态。
    static func visibleStatus(workspaceStatus: String, documentStatus: String) -> String {
        // 会话持久化或恢复失败会影响全部标签，始终最高优先。
        guard !workspaceStatus.contains("失败") else { return workspaceStatus }
        // 当前文档恢复、保存失败或冲突阻止需要立即覆盖成功型会话提示。
        guard !documentStatus.contains("失败"), !documentStatus.contains("阻止") else {
            return documentStatus
        }
        // 成功从上一代会话恢复时保留全局来源，同时不隐藏当前文档状态。
        guard workspaceStatus.contains("上一代会话") else { return documentStatus }
        // 用一个状态栏同时说明会话来源和当前标签结果。
        return "\(workspaceStatus)；\(documentStatus)"
    }
}

// 保存编辑栏格式菜单的一项可测试描述和原生动作路由。
struct EditorFormattingMenuEntry: Identifiable, Equatable, Sendable {
    // 稳定标识供 SwiftUI 菜单复用对应项。
    let id: String
    // 菜单展示用户可理解的格式名称。
    let title: String
    // 快捷键只作为提示展示，实际按键仍由应用命令统一处理。
    let shortcutHint: String
    // 帮助文字同时用于 tooltip 和无障碍提示。
    let helpText: String
    // 路由复用现有原生格式命令及其撤销路径。
    let command: MarkdownEditorFormattingCommand
}

// 集中定义编辑栏格式菜单内容，避免 UI 标题与动作路由漂移。
enum EditorFormattingMenuContent {
    // 菜单入口使用明确的无障碍名称。
    static let accessibilityLabel = "Markdown 格式"
    // tooltip 简述菜单不会直接改写选区以外的内容。
    static let helpText = "为选区或当前行应用 Markdown 格式"
    // 无障碍提示列出菜单覆盖的完整能力。
    static let accessibilityHint = "打开粗体、斜体、行内代码、链接、任务状态和一到六级标题格式菜单"

    // 高频行内格式保持在一级菜单，减少日常操作层级。
    static let inlineEntries: [EditorFormattingMenuEntry] = [
        // 粗体复用双星号切换命令。
        .init(
            id: "bold",
            title: "粗体",
            shortcutHint: "⌘B",
            helpText: "用双星号包裹或取消包裹当前选区",
            command: .bold
        ),
        // 斜体复用单星号切换命令。
        .init(
            id: "italic",
            title: "斜体",
            shortcutHint: "⌘I",
            helpText: "用单星号包裹或取消包裹当前选区",
            command: .italic
        ),
        // 行内代码复用反引号切换命令。
        .init(
            id: "inline-code",
            title: "行内代码",
            shortcutHint: "⌘E",
            helpText: "用反引号包裹或取消包裹当前选区",
            command: .inlineCode
        ),
        // 链接命令继续使用现有安全占位地址。
        .init(
            id: "link",
            title: "链接",
            shortcutHint: "⌘K",
            helpText: "把当前选区转换为 Markdown 链接",
            command: .link
        ),
    ]

    // 任务切换单独列出，明确它只处理当前已有任务行。
    static let taskEntry = EditorFormattingMenuEntry(
        id: "toggle-task",
        title: "切换任务状态",
        shortcutHint: "⌘⇧X",
        helpText: "切换当前行已有 Markdown 任务的完成状态",
        command: .toggleTask
    )

    // 六级标题放入子菜单，保持编辑栏和一级菜单紧凑。
    static let headingEntries: [EditorFormattingMenuEntry] = (1...6).map { level in
        // 每一级都路由到现有标题转换命令。
        EditorFormattingMenuEntry(
            id: "heading-\(level)",
            title: "H\(level) 标题",
            shortcutHint: "⌘⌥\(level)",
            helpText: "把当前行或所选行转换为 \(level) 级标题",
            command: .heading(level: level)
        )
    }
}

// 组合多文档标签、原生编辑、相对图片、大纲和发布操作。
struct ContentView: View {
    // 工作区管理标签顺序、活动标签和会话恢复。
    @EnvironmentObject private var workspace: WorkspaceModel
    // 记住用户最近一次选择的公众号模板。
    @AppStorage("wechatExportTemplate") private var templateRawValue = WechatExportTemplate.simple.rawValue
    // 大纲默认可见，用户可在预览标题栏切换。
    @State private var isOutlineVisible = true
    // 大纲点击后同时驱动编辑器和预览滚动。
    @State private var previewTargetLine: Int?

    // 构建工作区主窗口。
    var body: some View {
        Group {
            // 工作区保证至少一个标签，仍对异常恢复状态做安全兜底。
            if let activeDocument = workspace.activeDocument {
                WorkspaceEditorView(
                    workspace: workspace,
                    document: activeDocument,
                    templateRawValue: $templateRawValue,
                    isOutlineVisible: $isOutlineVisible,
                    previewTargetLine: $previewTargetLine
                )
            } else {
                // 极端恢复失败时保留可理解的窗口内容。
                ContentUnavailableView("正在恢复工作区", systemImage: "doc.text")
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        // Finder 双击 Markdown 后追加或激活对应标签。
        .onOpenURL { url in
            workspace.openDocument(at: url)
        }
        // 窗口级拖放支持批量打开文档，也允许把图片放到当前光标。
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
        }
        // 切换标签后清除上一文档的大纲滚动目标。
        .onChange(of: workspace.activeDocumentID) { _, _ in
            previewTargetLine = nil
        }
    }

    // 区分图片资源与可编辑文档后执行窗口级拖放。
    private func handleDroppedURLs(_ urls: [URL]) -> Bool {
        // 本地图片交给当前文档 assets 流程。
        let imageURLs = urls.filter {
            AssetSupport.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        // Markdown 与纯文本文件追加为标签。
        let documentURLs = urls.filter {
            ["md", "markdown", "txt"].contains($0.pathExtension.lowercased())
        }
        // 有活动标签时把窗口级图片拖放插入当前光标。
        if let document = workspace.activeDocument, !imageURLs.isEmpty {
            // 每张成功复制的图片产生一行 Markdown。
            let markdown = imageURLs.compactMap {
                ImageImportUI.importFile($0, into: document)
            }.joined(separator: "\n")
            // 至少一张成功时通过原生编辑器插入并进入撤销栈。
            if !markdown.isEmpty {
                NativeEditorActions.insertMarkdown(markdown, documentID: document.id)
            }
        }
        // 文档 URL 走统一去重和会话持久化入口。
        if !documentURLs.isEmpty {
            workspace.openDocuments(at: documentURLs)
        }
        // 只有确实识别到受支持类型时才声明处理成功。
        return !imageURLs.isEmpty || !documentURLs.isEmpty
    }
}

// 观察活动文档并组合主工具栏、标签栏和编辑区域。
private struct WorkspaceEditorView: View {
    // 工作区变化驱动标签栏和活动身份刷新。
    @ObservedObject var workspace: WorkspaceModel
    // 活动文档变化驱动预览、状态栏和当前文件信息刷新。
    @ObservedObject var document: EditorModel
    // 公众号模板持久化原始值由外层统一保存。
    @Binding var templateRawValue: String
    // 控制预览侧大纲宽度是否占用空间。
    @Binding var isOutlineVisible: Bool
    // 保存当前大纲跳转行号。
    @Binding var previewTargetLine: Int?
    // 保存活动编辑器光标所在逻辑行，驱动大纲和预览跟随。
    @State private var editorLine = 0
    // 预览跟随使用独立任务合并连续方向键和跨行输入。
    @State private var previewFollowTask: Task<Void, Never>?

    // 无效持久化值回退到兼容首版的简洁模板。
    private var selectedTemplate: WechatExportTemplate {
        WechatExportTemplate(rawValue: templateRawValue) ?? .simple
    }

    // 工作区失败和上一代会话恢复优先展示，其他时间显示当前标签状态。
    private var visibleStatus: String {
        // 复用可测试的安全优先级，确保文档失败不会被成功型会话提示遮住。
        WorkspaceStatusPresentation.visibleStatus(
            workspaceStatus: workspace.status,
            documentStatus: document.status
        )
    }

    // 组合日常写作所需的所有区域。
    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            // 双代会话都损坏时持续展示可执行恢复入口，状态栏文案变化不会把它隐藏。
            if workspace.hasUnrecoverableSessionFailure {
                Divider()
                sessionRecoveryWarning
            }
            Divider()
            DocumentTabBar(workspace: workspace)
            Divider()
            // 分栏结构始终保留编辑器父节点，显隐预览不会销毁撤销栈。
            HSplitView {
                editorPane
                    .frame(minWidth: 360)
                // 专注模式只移除预览子视图。
                if document.isPreviewVisible {
                    previewPane
                        .frame(minWidth: 320)
                }
            }
            Divider()
            statusBar
        }
        // 切换标签时清除上一文档的光标章节状态。
        .onChange(of: document.id) { _, _ in
            // 取消上一标签尚未执行的预览跟随。
            previewFollowTask?.cancel()
            editorLine = 0
        }
        // 初次进入或切回标签时恢复该 NSTextView 自己保留的真实光标行。
        .task(id: document.id) {
            // 等待活动编辑器完成注册和第一响应者切换。
            try? await Task.sleep(for: .milliseconds(20))
            // 标签再次变化时不采用过期行号。
            guard !Task.isCancelled,
                let line = NativeEditorActions.currentLine(documentID: document.id)
            else { return }
            // 复用同一入口更新当前章节并节流预览跟随。
            updateEditorLine(line)
        }
        // 视图离开层级时停止未完成任务。
        .onDisappear {
            previewFollowTask?.cancel()
        }
    }

    // 顶部只保留高频文件和发布动作。
    private var topToolbar: some View {
        HStack(spacing: 10) {
            Text("Markdown Lite")
                .font(.headline)
            // 橙点明确当前活动标签尚未写回真实文件。
            Circle()
                .fill(document.isDirty ? Color.orange : Color.clear)
                .frame(width: 7, height: 7)
                .accessibilityLabel(document.isDirty ? "有未保存修改" : "已保存")
            Text(document.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: workspace.newDocument) {
                Label("新建", systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            // 打开菜单同时提供多选面板和最近文件。
            Menu {
                Button("选择文件…", action: workspace.openDocument)
                    .keyboardShortcut("o", modifiers: .command)
                if !workspace.recentDocuments.isEmpty {
                    Divider()
                    ForEach(workspace.recentDocuments) { recent in
                        Button(recent.fileURL.lastPathComponent) {
                            workspace.openDocument(at: recent.fileURL)
                        }
                        .help(recent.fileURL.path)
                    }
                }
            } label: {
                Label("打开", systemImage: "folder")
            }
            Button(action: workspace.saveDocument) {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            publishingMenu
            // 单击切换专注编辑或左右预览。
            Button {
                document.isPreviewVisible.toggle()
            } label: {
                Image(
                    systemName: document.isPreviewVisible
                        ? "rectangle.righthalf.inset.filled"
                        : "rectangle.split.2x1"
                )
            }
            .help(document.isPreviewVisible ? "隐藏预览" : "显示预览")
            .accessibilityLabel(document.isPreviewVisible ? "隐藏预览" : "显示预览")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    // 用紧凑醒目的横幅解释风险，并提供查看证据和安全重建两个动作。
    private var sessionRecoveryWarning: some View {
        HStack(spacing: 10) {
            // 橙色警告图标建立高于普通状态栏的视觉优先级。
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            // 两行文字同时说明现状和下一步，不挤占主要编辑区域。
            VStack(alignment: .leading, spacing: 1) {
                // 标题明确当前会话无法自动恢复。
                Text("会话恢复失败")
                    .font(.caption.weight(.semibold))
                // 说明当前标签尚在内存，提醒用户及时完成闭环。
                Text("当前标签仅保存在内存中；可先查看损坏文件，再归档并重建会话。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // 让动作保持靠右且不压缩风险说明到不可读。
            Spacer(minLength: 8)
            // Finder 动作只展示证据，不改变任何会话文件。
            Button("在 Finder 中显示", action: workspace.revealSessionRecoveryData)
                .controlSize(.small)
                .accessibilityLabel("在 Finder 中显示损坏的会话数据")
                .accessibilityHint("显示现存的会话恢复文件，不修改任何数据")
            // 重建动作必须经过二次确认后才归档原始文件并创建新会话。
            Button("归档并重建", action: confirmSessionArchiveAndRebuild)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
                .accessibilityLabel("归档损坏会话并重建")
                .accessibilityHint("确认后保留损坏文件副本，并用当前打开标签重建会话")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("会话恢复失败，当前标签仅保存在内存中")
    }

    // 二次确认会归档原始证据，但不会尝试从损坏 JSON 猜测内容。
    private func confirmSessionArchiveAndRebuild() {
        // 使用原生警告框提供明确默认取消动作。
        let alert = NSAlert()
        // 标题说明即将执行的两个阶段。
        alert.messageText = "归档损坏的会话数据并重建？"
        // 明确新会话只采用当前可见标签，现存损坏代会移入独立归档目录。
        alert.informativeText = "现存的损坏会话恢复文件将保留到独立归档目录；新会话会采用目前打开的标签顺序和活动标签。"
        // 第一按钮保持安全取消，防止回车直接改变磁盘布局。
        alert.addButton(withTitle: "取消")
        // 第二按钮与横幅动作同名，降低确认歧义。
        alert.addButton(withTitle: "归档并重建")
        // 只有用户明确选择第二项才执行模型层原子恢复流程。
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        // 模型统一负责草稿保护、归档、重建和最终状态发布。
        guard workspace.archiveCorruptedSessionAndRebuild() else {
            // 原生警告框让键盘和 VoiceOver 用户都能立即获知失败，而非只依赖状态栏。
            let failureAlert = NSAlert()
            // 标题保持简短，详细原因继续来自模型的确定状态。
            failureAlert.messageText = "会话归档重建失败"
            // 展示原会话目录和底层错误，便于用户保留证据后重试。
            failureAlert.informativeText = workspace.status
            // 单按钮只关闭提示，不提供绕过数据保护的危险动作。
            failureAlert.addButton(withTitle: "好")
            // 同步展示确保恢复横幅仍在时用户已明确收到失败反馈。
            failureAlert.runModal()
            // 失败后不进入成功提示和 Finder 归档流程。
            return
        }
        // 成功后立即展示归档位置，避免横幅关闭让用户失去结果反馈。
        let completionAlert = NSAlert()
        // 标题确认会话已经重新具备持久化能力。
        completionAlert.messageText = "会话已安全重建"
        // 精确目录仅在本机展示，便于用户备份原始损坏文件。
        completionAlert.informativeText = "原始会话恢复文件已保存在：\n\n\(workspace.lastSessionArchiveURL?.path ?? "恢复归档目录")"
        // 第一按钮结束流程，不默认打开其他应用。
        completionAlert.addButton(withTitle: "完成")
        // 第二按钮提供归档完成后的持续可达入口。
        completionAlert.addButton(withTitle: "在 Finder 中显示归档")
        // 用户明确选择第二项时定位本次精确归档目录。
        if completionAlert.runModal() == .alertSecondButtonReturn {
            // Finder 动作不修改任何归档或新会话数据。
            workspace.revealLastSessionArchive()
        }
    }

    // 导出菜单同时暴露完整 HTML 和两套公众号模板。
    private var publishingMenu: some View {
        Menu {
            Button("导出 HTML…", action: document.exportHTML)
            Divider()
            ForEach(WechatExportTemplate.allCases) { template in
                Button {
                    // 记住本次选择供下次快速复制。
                    templateRawValue = template.rawValue
                    // 按明确模板写入 HTML 与纯文本剪贴板类型。
                    document.copyWechatHTML(template: template)
                } label: {
                    Text("\(selectedTemplate == template ? "✓ " : "")复制公众号 · \(template.displayName)")
                }
            }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
    }

    // 编辑栏保留所有标签各自的 NSTextView，切换时不丢光标和撤销栈。
    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // 紧凑菜单让已有格式能力在编辑区可发现。
                formattingMenu
                Button {
                    ImageImportUI.chooseImages(for: document)
                } label: {
                    Label("图片", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .help("复制图片到 assets 并插入相对路径")
                Button("⌘F 查找") {
                    NativeEditorActions.showFind(replacing: false)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("查找正文")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            Divider()
            // ZStack 让后台标签视图留在层级中并保留自己的撤销与滚动状态。
            ZStack {
                ForEach(workspace.documents) { candidate in
                    PersistentDocumentEditor(
                        document: candidate,
                        isActive: candidate.id == workspace.activeDocumentID,
                        onSelectionLineChanged: candidate.id == workspace.activeDocumentID
                            ? updateEditorLine
                            : nil,
                        onSelectedCharacterCountChanged: { count in
                            // 协调器只从活动 NSTextView 回调，精确写回所属标签统计。
                            candidate.updateSelectedCharacterCount(count)
                        }
                    )
                    .opacity(candidate.id == workspace.activeDocumentID ? 1 : 0)
                    .allowsHitTesting(candidate.id == workspace.activeDocumentID)
                    .accessibilityHidden(candidate.id != workspace.activeDocumentID)
                    .zIndex(candidate.id == workspace.activeDocumentID ? 1 : 0)
                }
            }
        }
    }

    // 用单一入口展示行内格式和六级标题，不占用多枚工具栏按钮。
    private var formattingMenu: some View {
        Menu {
            // 高频行内操作直接展示，并携带可见快捷键提示。
            ForEach(EditorFormattingMenuContent.inlineEntries) { entry in
                formattingButton(for: entry)
            }
            Divider()
            // 任务状态复用原生单字符替换和撤销路径。
            formattingButton(for: EditorFormattingMenuContent.taskEntry)
            Divider()
            // 标题级别放入子菜单，避免一级菜单过长。
            Menu("标题") {
                // 一到六级标题全部复用现有转换命令。
                ForEach(EditorFormattingMenuContent.headingEntries) { entry in
                    formattingButton(for: entry)
                }
            }
            .accessibilityLabel("标题格式")
            .accessibilityHint("选择一到六级 Markdown 标题")
        } label: {
            // 文字和系统图标共同保证入口清晰可辨。
            Label("格式", systemImage: "textformat")
        }
        // 使用原生无边框菜单样式融入紧凑编辑栏。
        .menuStyle(.borderlessButton)
        // 固定内容宽度避免挤压文件和预览区域。
        .fixedSize()
        // 与相邻图片和查找动作保持同一字号层级。
        .font(.caption2)
        // 鼠标停留时说明菜单用途。
        .help(EditorFormattingMenuContent.helpText)
        // VoiceOver 使用比可见短标题更明确的名称。
        .accessibilityLabel(EditorFormattingMenuContent.accessibilityLabel)
        // VoiceOver 说明完整可用格式范围。
        .accessibilityHint(EditorFormattingMenuContent.accessibilityHint)
    }

    // 把一项菜单描述连接到当前活动文档的现有格式动作。
    private func formattingButton(for entry: EditorFormattingMenuEntry) -> some View {
        Button {
            // 原生编辑器继续负责 UTF-16 选区、撤销和输入焦点。
            NativeEditorActions.applyFormatting(entry.command, documentID: document.id)
        } label: {
            // 两列布局同时呈现动作名称和现有快捷键。
            HStack {
                // 左侧展示格式名称。
                Text(entry.title)
                Spacer()
                // 右侧弱化快捷键提示，避免与动作名称争夺视觉焦点。
                Text(entry.shortcutHint)
                    .foregroundStyle(.secondary)
            }
        }
        // 每项都提供对应 Markdown 行为说明。
        .help(entry.helpText)
        // VoiceOver 直接朗读动作名称。
        .accessibilityLabel(entry.title)
        // 无障碍提示同时说明结果和可用快捷键。
        .accessibilityHint("\(entry.helpText)，快捷键 \(entry.shortcutHint)")
    }

    // 预览侧可切换大纲，并接收大纲滚动目标和当前文档图片基址。
    private var previewPane: some View {
        // 一次视图计算只从预览块提取一遍标题。
        let items = MarkdownOutlineBuilder.items(from: document.previewBlocks)
        return VStack(spacing: 0) {
            HStack {
                Text("预览")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isOutlineVisible.toggle()
                } label: {
                    Label("大纲", systemImage: "list.bullet.indent")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .help(isOutlineVisible ? "隐藏大纲" : "显示大纲")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            Divider()
            // 超大文档自动暂停时以明确说明替代旧预览，避免误看过期内容。
            if document.previewPauseReason == .documentTooLarge {
                largeDocumentPreviewPauseView
            } else {
                HStack(spacing: 0) {
                    if isOutlineVisible {
                        MarkdownOutlineView(
                            items: items,
                            currentItemID: MarkdownOutlineBuilder.currentItem(
                                from: items,
                                atLine: editorLine
                            )?.id
                        ) { item in
                            jump(to: item)
                        }
                        .frame(width: 190)
                        Divider()
                    }
                    EnhancedMarkdownPreview(
                        blocks: document.previewBlocks,
                        documentURL: document.currentFileURL,
                        scrollTargetLine: previewTargetLine,
                        onToggleTask: { sourceLine, expectedText, expectedChecked in
                            // 正文已变化但新预览尚未完成时拒绝旧复选框操作。
                            guard document.isPreviewCurrent else { return }
                            // 原生编辑器继续核对标签、源行、正文和旧状态后执行可撤销替换。
                            NativeEditorActions.toggleTask(
                                atLine: sourceLine,
                                expectedSource: document.text,
                                expectedText: expectedText,
                                expectedChecked: expectedChecked,
                                documentID: document.id
                            )
                        }
                    )
                    // 文档切换时重建预览树，避免远程图片确认状态跨标签复用。
                    .id(document.id)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }

    // 大文档默认停止自动解析，用户仍可明确承担一次预览成本。
    private var largeDocumentPreviewPauseView: some View {
        VStack(spacing: 12) {
            // 系统图标提供不带警告色的性能保护提示。
            Image(systemName: "pause.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            // 文案直接复用模型策略，避免阈值在两处漂移。
            Text(PreviewWorkPauseReason.documentTooLarge.displayMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            // 手动刷新只放行当前正文一次，后续输入重新应用五 MiB 上限。
            Button("仍要生成一次预览") {
                document.refreshPreviewManually()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("本次可能消耗较多内存和处理时间")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // 状态栏只展示可行动反馈和真实后台解析耗时，避免长文输入时逐键遍历全部字符。
    private var statusBar: some View {
        HStack {
            Text(visibleStatus)
                .lineLimit(1)
            Spacer()
            // 外部修改只在模型确认冲突后展示显式解决入口。
            if document.externalChangeState.blocksRegularSave {
                externalConflictMenu
            }
            // 成功归档后保留紧凑入口，同时让正文保存状态继续正常更新。
            if workspace.lastSessionArchiveURL != nil {
                // Finder 动作只定位最近归档，不修改恢复文件或当前会话。
                Button(action: workspace.revealLastSessionArchive) {
                    // 文件夹图标和短标签在状态栏内保持可识别且不过度占宽。
                    Label("恢复归档", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .help("在 Finder 中显示最近一次会话恢复归档")
                .accessibilityLabel("在 Finder 中显示最近一次会话恢复归档")
            }
            // 状态栏只读取后台已发布的整数，不在 SwiftUI body 内扫描正文。
            Text(writingStatisticsText)
                .lineLimit(1)
                .accessibilityLabel(writingStatisticsAccessibilityLabel)
            // 大文档暂停时不把上一次解析耗时误认为当前正文结果。
            if document.previewPauseReason == .documentTooLarge {
                Text("预览已暂停")
            } else {
                Text("预览 \(document.renderMilliseconds, specifier: "%.1f") ms")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    // 组合紧凑可见统计；空选区不占用额外状态栏宽度。
    private var writingStatisticsText: String {
        // 读取当前标签后台结果，标签切换不会短暂复用上一标签数据。
        let statistics = document.writingStatistics
        // 非空选区追加用户当前最关心的局部数量。
        if statistics.selectedCharacterCount > 0 {
            return
                "字符 \(statistics.characterCount) · 行 \(statistics.lineCount)"
                + " · 已选 \(statistics.selectedCharacterCount)"
        }
        // 普通光标状态只展示全文字符和行数。
        return "字符 \(statistics.characterCount) · 行 \(statistics.lineCount)"
    }

    // VoiceOver 使用自然中文朗读完整统计，但不注册高频实时播报区域。
    private var writingStatisticsAccessibilityLabel: String {
        // 读取当前标签最新已发布结果。
        let statistics = document.writingStatistics
        // 非空选区包含选中数量。
        if statistics.selectedCharacterCount > 0 {
            return
                "全文 \(statistics.characterCount) 个字符，\(statistics.lineCount) 行，"
                + "已选择 \(statistics.selectedCharacterCount) 个字符"
        }
        // 空选区只朗读全文结果。
        return "全文 \(statistics.characterCount) 个字符，\(statistics.lineCount) 行"
    }

    // 把可能丢弃或覆盖内容的动作集中在醒目的冲突菜单中。
    private var externalConflictMenu: some View {
        Menu {
            // 干净文档直接重载，dirty 文档必须再次明确确认。
            Button("重新载入磁盘版本", action: reloadExternalVersion)
            // 另存为保留两份内容，是最安全的默认解决方式。
            Button("将当前版本另存为…", action: workspace.saveDocumentAs)
            Divider()
            // 覆盖必须经过二次确认，不能由普通保存隐式触发。
            Button("用当前版本覆盖磁盘…", action: overwriteExternalVersion)
        } label: {
            Label("处理冲突", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // 处理采用磁盘版本，并保护仍在内存中的 dirty 正文。
    private func reloadExternalVersion() {
        // 干净文档没有内容丢失风险，可直接采用磁盘版本。
        guard document.isDirty else {
            document.reloadFromDiskIfSafe()
            return
        }
        // dirty 文档需要明确说明当前编辑会被放弃。
        let alert = NSAlert()
        alert.messageText = "放弃当前未保存编辑？"
        alert.informativeText = "重新载入会采用磁盘版本，并永久删除当前未保存编辑及其恢复草稿。若要保留两份，请先取消并选择“将当前版本另存为…”。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "永久放弃并重载")
        // 只有第二个明确按钮允许丢弃内存正文。
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        // 模型层执行无损编码读取并刷新可信磁盘基线。
        document.reloadFromDiskDiscardingChanges()
    }

    // 处理用户明确选择保留当前正文并覆盖外部版本。
    private func overwriteExternalVersion() {
        // 覆盖或重新创建文件具有不可逆语义，必须再次确认。
        let alert = NSAlert()
        alert.messageText = "覆盖磁盘上的外部版本？"
        alert.informativeText = "磁盘中的外部修改将被当前编辑替换。建议优先另存为，以同时保留两个版本。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "覆盖磁盘")
        // 默认按钮保持取消，避免回车误覆盖。
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        // 仅显式入口调用绕过一次冲突预检的模型方法。
        document.overwriteExternalChanges()
    }

    // 大纲点击同时定位源文件和预览块。
    private func jump(to item: MarkdownOutlineItem) {
        // 先清空旧值，重复点击同一标题也能再次触发预览滚动。
        previewTargetLine = nil
        // 原生编辑器按 UTF-16 安全行边界移动光标。
        NativeEditorActions.jumpToLine(item.id, documentID: document.id)
        // 下一轮主线程更新写入新目标供 ScrollViewReader 响应。
        Task { @MainActor in
            previewTargetLine = item.id
        }
    }

    // 光标跨行时立即标记当前章节，并节流预览滚动。
    private func updateEditorLine(_ line: Int) {
        // 先把异常值收敛到首行。
        let safeLine = max(0, line)
        // 同一逻辑行内输入不重复计算章节或安排动画。
        guard editorLine != safeLine else { return }
        // 保存非负行号供当前章节二分查找。
        editorLine = safeLine
        // 新跨行动作取消旧动画目标，避免长按方向键持续重启动画。
        previewFollowTask?.cancel()
        // 光标稳定 180ms 后再让预览跟随最近解析块。
        previewFollowTask = Task { @MainActor in
            // 等待短暂停顿以合并连续行移动。
            try? await Task.sleep(for: .milliseconds(180))
            // 被新行号替代的任务不能回写旧目标。
            guard !Task.isCancelled else { return }
            // 提交稳定目标；大纲高亮此前已经即时更新。
            previewTargetLine = safeLine
        }
    }
}

// 自定义进程内类型避免把普通文本拖放误认为标签重排。
private extension UTType {
    // 该载荷只携带文档 UUID，不包含文档路径或正文。
    static let markdownLiteDocumentTab = UTType(exportedAs: "com.nemoob.markdown-lite.document-tab")
}

// 区分目标标签左右两个插入槽位。
private enum DocumentTabInsertionEdge: Equatable {
    // 目标数组下标就是目标标签之前的插入槽。
    case before
    // 目标数组下标加一是目标标签之后的插入槽。
    case after
}

// 保存当前悬停的目标标签和确切插入边。
private struct DocumentTabDropTarget: Equatable {
    // 稳定 UUID 让数组重排时不依赖可变文件名。
    let documentID: UUID
    // 左右边决定屏幕反馈和最终槽位。
    let edge: DocumentTabInsertionEdge
}

// 用原生 DropDelegate 连续跟踪指针在标签左右半区的位置。
private struct DocumentTabDropDelegate: DropDelegate {
    // 当前视图代表的目标文档。
    let documentID: UUID
    // 实际标签宽度用于计算前后半区。
    let targetWidth: CGFloat
    // 共享悬停状态保证同时只显示一条插入线。
    @Binding var dropTarget: DocumentTabDropTarget?
    // 落点解析后只向工作区提交 UUID 和槽位语义。
    let onMove: (UUID, DocumentTabDropTarget) -> Void

    // 只接受本应用定义的标签载荷。
    func validateDrop(info: DropInfo) -> Bool {
        // 其他文件、图片和文本拖放继续交给原有入口。
        info.hasItemsConforming(to: [.markdownLiteDocumentTab])
    }

    // 首次进入标签时立即显示离指针最近的插入边。
    func dropEntered(info: DropInfo) {
        // 使用当前局部坐标计算前后槽位。
        dropTarget = resolvedTarget(at: info.location.x)
    }

    // 指针在同一标签内跨过中线时刷新插入反馈。
    func dropUpdated(info: DropInfo) -> DropProposal? {
        // 左右半区每次更新都映射到确切边。
        dropTarget = resolvedTarget(at: info.location.x)
        // 用系统移动光标说明源标签不会被复制。
        return DropProposal(operation: .move)
    }

    // 拖出当前目标后清除它的插入线。
    func dropExited(info: DropInfo) {
        // 只清理仍属于当前标签的状态，不覆盖新目标。
        guard dropTarget?.documentID == documentID else { return }
        // 拖出标签栏时没有模型调用，顺序保持不变。
        dropTarget = nil
    }

    // 落下时异步读取进程内 UUID，再回主线程调用模型。
    func performDrop(info: DropInfo) -> Bool {
        // 以最终指针位置为准，不依赖上一次 hover 回调。
        let finalTarget = resolvedTarget(at: info.location.x)
        // 提交后立即清除视觉插入线。
        dropTarget = nil
        // 只取第一个本应用标签载荷。
        guard let provider = info.itemProviders(for: [.markdownLiteDocumentTab]).first else {
            // 没有有效载荷时声明未处理。
            return false
        }
        // 从自定义 UTType 读取不含路径的 UUID 字节。
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.markdownLiteDocumentTab.identifier) {
            data,
            _ in
            // 缺失或非 UUID 载荷不修改任何标签状态。
            guard let data,
                let sourceID = UUID(uuidString: String(decoding: data, as: UTF8.self)),
                sourceID != documentID
            else { return }
            // NSItemProvider 回调可在后台线程，工作区模型必须回主 actor 更新。
            Task { @MainActor in
                // 模型统一处理数组重排、原位 no-op 和会话持久化。
                onMove(sourceID, finalTarget)
            }
        }
        // 已接收合法的本应用拖放，具体重排结果由模型决定。
        return true
    }

    // 用标签中线把局部横坐标转换成插入边。
    private func resolvedTarget(at horizontalLocation: CGFloat) -> DocumentTabDropTarget {
        // 左半区是 before，中线及右半区是 after。
        let edge: DocumentTabInsertionEdge = horizontalLocation < targetWidth / 2 ? .before : .after
        // 返回绑定当前稳定 UUID 的插入目标。
        return DocumentTabDropTarget(documentID: documentID, edge: edge)
    }
}

// 标签栏观察每个文档的 dirty 和文件名变化。
private struct DocumentTabBar: View {
    // 工作区提供顺序、活动身份和关闭动作。
    @ObservedObject var workspace: WorkspaceModel
    // 共享当前悬停槽位，确保标签之间只显示一个插入反馈。
    @State private var dropTarget: DocumentTabDropTarget?

    // 使用横向滚动容纳多个日常文档标签。
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 4) {
                ForEach(workspace.documents) { document in
                    // 当前下标只用于 VoiceOver 序号和落点槽位计算。
                    let position = workspace.documents.firstIndex(where: { $0.id == document.id }) ?? 0
                    DocumentTabItem(
                        document: document,
                        isActive: document.id == workspace.activeDocumentID,
                        position: position,
                        documentCount: workspace.documents.count,
                        insertionEdge: dropTarget?.documentID == document.id ? dropTarget?.edge : nil,
                        dropTarget: $dropTarget,
                        onActivate: {
                            workspace.activate(document)
                            NativeEditorActions.focus(documentID: document.id)
                        },
                        onClose: { workspace.close(document) },
                        onMove: moveDocument
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // 把目标标签的前后边转换为模型定义的“移除前插入槽”。
    private func moveDocument(_ sourceID: UUID, to target: DocumentTabDropTarget) {
        // 重排期间目标已消失时不修改当前顺序。
        guard let targetIndex = workspace.documents.firstIndex(where: { $0.id == target.documentID }) else {
            return
        }
        // before 直接使用目标下标，after 使用其后一个插入槽。
        let destinationIndex = target.edge == .before ? targetIndex : targetIndex + 1
        // 模型层负责前移校正、原位 no-op 和会话持久化。
        workspace.moveDocument(id: sourceID, to: destinationIndex)
    }
}

// 单个标签把激活和关闭拆成两个明确点击目标。
private struct DocumentTabItem: View {
    // 观察标签名和 dirty 变化。
    @ObservedObject var document: EditorModel
    // 活动标签使用更清晰的系统背景。
    let isActive: Bool
    // 从零开始的当前位置供 VoiceOver 朗读。
    let position: Int
    // 总数帮助非视觉用户理解标签相对位置。
    let documentCount: Int
    // 当前标签只在成为落点时显示左或右插入线。
    let insertionEdge: DocumentTabInsertionEdge?
    // DropDelegate 写入标签栏共享的唯一悬停目标。
    @Binding var dropTarget: DocumentTabDropTarget?
    // 实际布局宽度让拖放左右半区随文件名长度变化。
    @State private var tabWidth: CGFloat = 1
    // 主区域点击激活标签。
    let onActivate: () -> Void
    // 关闭按钮执行带数据保护的工作区流程。
    let onClose: () -> Void
    // 有效落点把源 UUID 和目标槽位交回标签栏。
    let onMove: (UUID, DocumentTabDropTarget) -> Void

    // 预先组合 VoiceOver 文案，避免复杂视图表达式反复推断字符串类型。
    private var accessibilityDescription: String {
        // 活动标签增加“当前”前缀，其他标签保持简洁。
        let activeDescription = isActive ? "当前" : ""
        // 保存状态使用与 dirty 指示点一致的语义。
        let saveDescription = document.isDirty ? "有未保存修改" : "已保存"
        // 合并文件名、位置和状态供一次连续朗读。
        return "\(activeDescription)标签 \(document.filename)，第 \(position + 1) 个，共 \(documentCount) 个，\(saveDescription)"
    }

    // 构建紧凑原生标签外观。
    var body: some View {
        HStack(spacing: 4) {
            Button(action: onActivate) {
                HStack(spacing: 6) {
                    // dirty 小点只表示当前标签有未写回内容。
                    Circle()
                        .fill(document.isDirty ? Color.orange : Color.clear)
                        .frame(width: 6, height: 6)
                    Text(document.filename)
                        .lineLimit(1)
                        .frame(maxWidth: 150)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // VoiceOver 同时读出标签位置、活动状态和 dirty 状态。
            .accessibilityLabel(accessibilityDescription)
            // 提示非鼠标用户可通过原生菜单重排，不必使用拖放。
            .accessibilityHint("按下以激活；可使用“标签”菜单向左或向右移动")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("关闭标签")
            // 关闭按钮单独读出文件名，避免与激活按钮混淆。
            .accessibilityLabel("关闭标签 \(document.filename)")
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.07))
        )
        // 背景测量不参与点击命中，只为 DropDelegate 提供实际宽度。
        .background {
            GeometryReader { geometry in
                Color.clear
                    // 首次布局完成后保存真实宽度。
                    .onAppear {
                        tabWidth = geometry.size.width
                    }
                    // 文件名变化时同步新宽度，保持中线准确。
                    .onChange(of: geometry.size.width) { _, newWidth in
                        tabWidth = newWidth
                    }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        }
        // 悬停在左半或右半时显示对应的原生强调色插入线。
        .overlay(alignment: insertionEdge == .before ? .leading : .trailing) {
            if insertionEdge != nil {
                // 细线不遮挡标签文字，但能明确区分插入前后。
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .accessibilityHidden(true)
            }
        }
        // 拖起时只提供进程内 UUID 载荷，不暴露路径或正文。
        .onDrag(makeDragProvider)
        // 每个标签在自己的局部坐标中计算前后落点。
        .onDrop(
            of: [.markdownLiteDocumentTab],
            delegate: DocumentTabDropDelegate(
                documentID: document.id,
                targetWidth: tabWidth,
                dropTarget: $dropTarget,
                onMove: onMove
            )
        )
        // 鼠标用户可发现拖放，同时指向可替代的菜单路径。
        .help("拖动以重新排列；也可使用“标签”菜单移动")
    }

    // 构建只在本应用进程内可见的标签拖放载荷。
    private func makeDragProvider() -> NSItemProvider {
        // UUID 编码为 UTF-8，载荷不包含用户数据。
        let payload = Data(document.id.uuidString.utf8)
        // 使用系统项目提供器参与标准拖放会话。
        let provider = NSItemProvider()
        // ownProcess 阻止其他应用把内部 UUID 当成可交换数据。
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.markdownLiteDocumentTab.identifier,
            visibility: .ownProcess
        ) { completion in
            // 载荷已在主线程生成，提供器只返回不可变 Data。
            completion(payload, nil)
            // 小型内存载荷无需额外 Progress 对象。
            return nil
        }
        // 返回已注册自定义类型的提供器。
        return provider
    }
}

// 每个标签永久持有自己的 NSTextView，后台标签只隐藏不销毁。
private struct PersistentDocumentEditor: View {
    // 当前标签正文变化通过独立 ObservableObject 驱动。
    @ObservedObject var document: EditorModel
    // 活动身份决定焦点、查找和交互权限。
    let isActive: Bool
    // 活动编辑器光标跨行时通知预览和大纲。
    let onSelectionLineChanged: ((Int) -> Void)?
    // 活动编辑器选区变化时更新当前标签统计。
    let onSelectedCharacterCountChanged: ((Int) -> Void)?
    // 字号设置跨启动持久化并即时传给原生编辑器。
    @AppStorage("editorFontSize") private var fontSize = EditorPreferenceDefaults.fontSize
    // 行距设置只改变显示，不写入 Markdown 原文。
    @AppStorage("editorLineSpacing") private var lineSpacing = EditorPreferenceDefaults.lineSpacing
    // 用户可关闭语法高亮，编辑器内部负责清理临时属性。
    @AppStorage("syntaxHighlightingEnabled") private var syntaxHighlightingEnabled =
        EditorPreferenceDefaults.syntaxHighlightingEnabled

    // 连接原生编辑器与安全资源导入层。
    var body: some View {
        NativeTextEditor(
            text: $document.text,
            documentID: document.id,
            isActive: isActive,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            syntaxHighlightingEnabled: syntaxHighlightingEnabled,
            onImportImageFile: { url in
                ImageImportUI.importFile(url, into: document)
            },
            onImportImageData: { data, filename in
                ImageImportUI.storeImageData(data, filename: filename, into: document)
            },
            onUndoRedoTextChange: {
                // 只在原生撤销或重做后按保存快照精确校准当前标签 dirty 状态。
                document.reconcileDirtyAfterUndoRedo()
            },
            onSelectionLineChanged: onSelectionLineChanged,
            onSelectedCharacterCountChanged: onSelectedCharacterCountChanged
        )
    }
}

// 把资源层错误转换为最小原生提示，并集中处理图片选择。
@MainActor
private enum ImageImportUI {
    // 复制单个本地图片并生成 Markdown。
    static func importFile(_ url: URL, into document: EditorModel) -> String? {
        do {
            // 使用去掉扩展名的文件名作为可读替代文字。
            let alt = url.deletingPathExtension().lastPathComponent
            // 资源层负责安全复制、重名和相对路径编码。
            return try AssetSupport.importImage(
                from: url,
                documentURL: document.currentFileURL
            ).markdown(alt: alt)
        } catch {
            // 导入失败不改正文并给出明确下一步。
            show(error)
            return nil
        }
    }

    // 保存剪贴板位图并生成 Markdown。
    static func storeImageData(
        _ data: Data,
        filename: String,
        into document: EditorModel
    ) -> String? {
        do {
            // 位图数据经 ImageIO 验证后原子写入 assets。
            return try AssetSupport.storeImageData(
                data,
                preferredFilename: filename,
                documentURL: document.currentFileURL
            ).markdown(alt: "图片")
        } catch {
            // 写入失败时保持剪贴板和正文原状。
            show(error)
            return nil
        }
    }

    // 使用系统面板选择一张或多张图片并插入当前光标。
    static func chooseImages(for document: EditorModel) {
        // 未命名文档必须先建立稳定资源目录。
        guard document.currentFileURL != nil else {
            show(AssetSupportError.documentMustBeSaved)
            return
        }
        // 系统面板只允许选择图片，不接受目录。
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        // 取消时不修改资源目录和正文。
        guard panel.runModal() == .OK else { return }
        // 按选择顺序复制并生成多行 Markdown。
        let markdown = panel.urls.compactMap {
            importFile($0, into: document)
        }.joined(separator: "\n")
        // 至少一张成功时插入活动标签当前光标。
        if !markdown.isEmpty {
            NativeEditorActions.insertMarkdown(markdown, documentID: document.id)
        }
    }

    // 使用单按钮警告框展示本地资源错误。
    private static func show(_ error: Error) {
        // 系统警告框与保存/关闭确认保持一致体验。
        let alert = NSAlert()
        alert.messageText = "无法添加图片"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
