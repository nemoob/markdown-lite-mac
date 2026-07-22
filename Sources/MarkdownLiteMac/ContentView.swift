import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    // 打开失败优先展示工作区反馈，其他时间展示当前标签状态。
    private var visibleStatus: String {
        workspace.status.contains("失败") ? workspace.status : document.status
    }

    // 组合日常写作所需的所有区域。
    var body: some View {
        VStack(spacing: 0) {
            topToolbar
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
                            : nil
                    )
                    .opacity(candidate.id == workspace.activeDocumentID ? 1 : 0)
                    .allowsHitTesting(candidate.id == workspace.activeDocumentID)
                    .accessibilityHidden(candidate.id != workspace.activeDocumentID)
                    .zIndex(candidate.id == workspace.activeDocumentID ? 1 : 0)
                }
            }
        }
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
                    scrollTargetLine: previewTargetLine
                )
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
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
            Text("预览 \(document.renderMilliseconds, specifier: "%.1f") ms")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
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

// 标签栏观察每个文档的 dirty 和文件名变化。
private struct DocumentTabBar: View {
    // 工作区提供顺序、活动身份和关闭动作。
    @ObservedObject var workspace: WorkspaceModel

    // 使用横向滚动容纳多个日常文档标签。
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 4) {
                ForEach(workspace.documents) { document in
                    DocumentTabItem(
                        document: document,
                        isActive: document.id == workspace.activeDocumentID,
                        onActivate: {
                            workspace.activate(document)
                            NativeEditorActions.focus(documentID: document.id)
                        },
                        onClose: { workspace.close(document) }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// 单个标签把激活和关闭拆成两个明确点击目标。
private struct DocumentTabItem: View {
    // 观察标签名和 dirty 变化。
    @ObservedObject var document: EditorModel
    // 活动标签使用更清晰的系统背景。
    let isActive: Bool
    // 主区域点击激活标签。
    let onActivate: () -> Void
    // 关闭按钮执行带数据保护的工作区流程。
    let onClose: () -> Void

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
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("关闭标签")
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.07))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        }
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
            onSelectionLineChanged: onSelectionLineChanged
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
