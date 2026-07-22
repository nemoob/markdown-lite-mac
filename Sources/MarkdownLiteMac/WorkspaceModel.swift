import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// 描述 dirty 标签关闭时允许展示的安全动作组合。
enum WorkspaceDirtyClosePolicy: Equatable {
    // 未命名标签只能先保存，取消时继续保留标签。
    case saveOnly
    // 原文件仍可作为恢复入口时允许保留路径草稿后关闭。
    case saveOrKeepDraft
    // 原文件失去恢复能力时必须另存为，取消时继续保留标签。
    case saveAsOnly

    // 根据文件身份和最新磁盘状态选择不会制造孤儿草稿的关闭策略。
    static func resolve(
        hasFileURL: Bool,
        externalState: ExternalDocumentChangeState
    ) -> WorkspaceDirtyClosePolicy {
        // 未命名标签没有稳定路径恢复入口，只允许保存或取消。
        guard hasFileURL else { return .saveOnly }
        // 已命名标签必须按最新磁盘可达性决定是否允许草稿关闭。
        switch externalState {
        case .unchanged, .modified:
            // 文件仍存在时最近文件或原路径可以重新触达恢复草稿。
            return .saveOrKeepDraft
        case .deleted, .unreadable, .notMonitored:
            // 文件缺失、不可读或状态异常时保守要求另存为。
            return .saveAsOnly
        }
    }

    // 返回关闭确认框的首要安全动作标题。
    var primaryButtonTitle: String {
        // 只有失去原路径恢复能力时明确引导另存为。
        self == .saveAsOnly ? "另存为" : "保存"
    }

    // 判断首要动作是否必须进入另存为面板。
    var usesSaveAs: Bool {
        // 仅 saveAsOnly 跳过可能被外部状态阻止的原地保存。
        self == .saveAsOnly
    }

    // 判断确认框能否提供“保留草稿并关闭”。
    var allowsDraftClose: Bool {
        // 只有原文件仍可作为恢复入口时允许关闭到路径草稿。
        self == .saveOrKeepDraft
    }
}

// 管理多标签顺序、活动标签、文件去重和会话恢复。
@MainActor
final class WorkspaceModel: ObservableObject {
    // 标签数组顺序直接对应界面标签顺序。
    @Published private(set) var documents: [EditorModel] = []
    // 活动 UUID 独立持久化，避免使用易变化的数组下标。
    @Published private(set) var activeDocumentID: UUID?
    // 最近文件由工作区统一提供给打开菜单。
    @Published private(set) var recentDocuments: [RecentDocument] = []
    // 会话或打开失败时提供非破坏性反馈。
    @Published private(set) var status = "已就绪"
    // 双代会话都无法恢复时持续发布显式状态，直到用户安全重建成功。
    @Published private(set) var hasUnrecoverableSessionFailure = false
    // 保存最近一次成功归档目录，横幅关闭后仍可由完成提示在 Finder 中定位。
    @Published private(set) var lastSessionArchiveURL: URL?

    // 所有标签共享文档 IO 和草稿存储。
    private let documentStore: DocumentSupportStore
    // 会话层只保存标签身份、顺序和活动 UUID。
    private let sessionStore: WorkspaceSessionStore
    // 最近文件写入通过闭包隔离，测试可稳定注入辅助索引失败。
    private let recordRecentDocument: (URL) throws -> Void

    // 默认恢复上次会话；测试可注入隔离存储并关闭恢复。
    init(
        documentStore: DocumentSupportStore = DocumentSupportStore(),
        sessionStore: WorkspaceSessionStore = WorkspaceSessionStore(),
        restoresSession: Bool = true,
        recordRecentDocument: ((URL) throws -> Void)? = nil
    ) {
        // 保存共享文档支撑层。
        self.documentStore = documentStore
        // 保存会话支撑层。
        self.sessionStore = sessionStore
        // 生产环境写入正式索引，测试可只替换这项辅助元数据操作。
        self.recordRecentDocument =
            recordRecentDocument ?? { fileURL in
                // 默认路径保持现有最近文件排序和持久化语义。
                try documentStore.recordRecentDocument(fileURL)
            }
        // 先刷新最近文件，标签恢复失败也不影响菜单。
        refreshRecentDocuments()
        // 按调用方配置恢复会话或创建首次标签。
        if restoresSession {
            restoreLastSession()
        } else {
            appendInitialDocument()
        }
    }

    // 返回当前活动标签；异常 UUID 时安全回退首个标签。
    var activeDocument: EditorModel? {
        // 优先命中持久化活动 UUID。
        if let activeDocumentID,
            let active = documents.first(where: { $0.id == activeDocumentID })
        {
            return active
        }
        // 会话损坏时仍可显示首个有效标签。
        return documents.first
    }

    // 创建独立未命名标签并设为活动。
    func newDocument() {
        // 每次新建都生成新 UUID，不覆盖已有未命名草稿。
        let document = EditorModel.makeUntitled(documentStore: documentStore)
        // 建立弱工作区回调。
        document.workspace = self
        // 追加到标签末尾。
        documents.append(document)
        // 新标签立即成为活动标签。
        activeDocumentID = document.id
        // 只有新顺序安全落盘后才能用成功文案覆盖会话错误。
        guard persistSession() else { return }
        // 反馈新建完成。
        status = "已新建标签"
    }

    // 激活指定文档对象，不触发草稿写入或正文复制。
    @discardableResult
    func activate(_ document: EditorModel) -> Bool {
        // 只接受当前工作区实际持有的标签。
        guard documents.contains(where: { $0.id == document.id }) else { return false }
        // 更新活动 UUID。
        activeDocumentID = document.id
        // 持久化下次启动活动标签。
        return persistSession()
    }

    // 通过稳定 UUID 激活标签，便于 SwiftUI 按钮调用。
    func activate(id: UUID) {
        // 找不到 UUID 时保持当前标签不变。
        guard let document = documents.first(where: { $0.id == id }) else { return }
        // 复用对象入口保持同一持久化逻辑。
        activate(document)
    }

    // 按标签顺序循环切换，提供键盘快速浏览能力。
    func activateAdjacentDocument(reverse: Bool = false) {
        // 至少需要两个标签才有切换意义。
        guard documents.count > 1,
            let activeDocumentID,
            let currentIndex = documents.firstIndex(where: { $0.id == activeDocumentID })
        else { return }
        // 反向时向左循环，正向时向右循环。
        let offset = reverse ? documents.count - 1 : 1
        // 模运算确保首尾无缝循环。
        let nextIndex = (currentIndex + offset) % documents.count
        // 复用统一激活逻辑并持久化活动标签。
        activate(documents[nextIndex])
    }

    // 关闭指定标签；dirty 标签必须保存或安全落草稿。
    func close(_ document: EditorModel) {
        // 只处理当前数组中的精确对象。
        guard let closingIndex = documents.firstIndex(where: { $0.id == document.id }) else { return }
        // dirty 标签必须让用户明确选择。
        if document.isDirty {
            // 已命名标签在关闭前重新检查磁盘，避免把删除或不可读文件当作恢复入口。
            let externalState =
                document.currentFileURL == nil
                ? ExternalDocumentChangeState.notMonitored
                : document.checkForExternalChanges()
            // 将磁盘可达性转换成可单测的安全动作组合。
            let closePolicy = WorkspaceDirtyClosePolicy.resolve(
                hasFileURL: document.currentFileURL != nil,
                externalState: externalState
            )
            // 创建原生关闭确认框。
            let alert = NSAlert()
            // 标签名明确指出受影响对象。
            alert.messageText = "关闭“\(document.filename)”？"
            // 未命名标签没有可重新打开的文件身份，因此只能保存或取消。
            alert.informativeText =
                closePolicy == .saveOnly
                ? "未命名文档必须先保存到文件，关闭后才能可靠找回。"
                : closePolicy == .saveAsOnly
                    ? "原文件已删除或无法读取。请另存为到可访问位置；取消将继续保留标签。"
                    : "文档尚未保存。可以保存到文件，或保留恢复草稿后关闭标签。"
            // 第一项按原文件可达性保存或引导安全另存为。
            alert.addButton(withTitle: closePolicy.primaryButtonTitle)
            // 默认安全取消。
            alert.addButton(withTitle: "取消")
            // 只有原文件仍可作为恢复入口时才允许关闭到路径草稿。
            if closePolicy.allowsDraftClose {
                alert.addButton(withTitle: "保留草稿并关闭")
            }
            // 根据用户明确选择处理。
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // 缺失或不可读的原路径必须改用另存为，避免普通保存被冲突保护阻止后误关。
                let didSave =
                    closePolicy.usesSaveAs
                    ? document.saveDocumentAsIfPossible()
                    : document.saveDocumentIfPossible()
                // 保存失败或另存为取消时保持正文和标签可触达。
                guard didSave else { return }
            case .alertThirdButtonReturn:
                // 草稿失败时默认阻止关闭，避免无提示丢失。
                guard document.ensureRecoverableDraft() else {
                    // 创建单按钮失败提示。
                    let failureAlert = NSAlert()
                    // 明确关闭已被阻止。
                    failureAlert.messageText = "无法安全关闭标签"
                    // 让用户回到编辑器另行保存。
                    failureAlert.informativeText = "恢复草稿写入失败，标签仍保持打开。请另存为后重试。"
                    // 唯一动作返回编辑。
                    failureAlert.addButton(withTitle: "返回编辑")
                    // 展示失败提示后结束关闭流程。
                    failureAlert.runModal()
                    return
                }
            default:
                // 取消时不修改数组、活动标签或草稿。
                return
            }
        } else {
            // 干净标签清理自己的精确旧草稿。
            try? documentStore.removeDraft(
                for: document.currentFileURL,
                untitledID: document.currentFileURL == nil ? document.id : nil
            )
        }

        // 停止这个标签自己的延迟任务。
        document.prepareForClose()
        // 从工作区删除精确标签。
        documents.remove(at: closingIndex)
        // 删除活动标签时选择原位置右侧或最后一个左侧标签。
        if activeDocumentID == document.id {
            // 剩余为空时先清空活动 UUID。
            activeDocumentID = documents.isEmpty ? nil : documents[min(closingIndex, documents.count - 1)].id
        }
        // 主窗口始终保留一个可编辑标签。
        if documents.isEmpty {
            // 创建空白标签但延后到统一持久化。
            let replacement = EditorModel.makeUntitled(documentStore: documentStore)
            // 建立工作区回调。
            replacement.workspace = self
            // 放入唯一标签位置。
            documents = [replacement]
            // 新空白标签成为活动。
            activeDocumentID = replacement.id
        }
        // 只有关闭后的顺序安全落盘后才能展示成功文案。
        guard persistSession() else { return }
        // 反馈关闭完成。
        status = "标签已关闭"
    }

    // 关闭当前活动标签。
    func closeActiveDocument() {
        // 没有活动标签时保持幂等。
        guard let activeDocument else { return }
        // 复用完整确认流程。
        close(activeDocument)
    }

    // 使用系统面板一次选择一个或多个 Markdown 文件。
    func openDocument() {
        // 创建本地文件选择面板。
        let panel = NSOpenPanel()
        // 多选可以一次追加多个标签。
        panel.allowsMultipleSelection = true
        // 禁止把目录当正文读取。
        panel.canChooseDirectories = false
        // Markdown UTI 不可用时回退纯文本。
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        // 同时接受 Markdown 和普通文本。
        panel.allowedContentTypes = [markdownType, .plainText]
        // 取消时不改变工作区。
        guard panel.runModal() == .OK else { return }
        // 按面板顺序依次打开，保持可预测标签顺序。
        openDocuments(at: panel.urls)
    }

    // 打开单个拖入、双击或最近文件 URL。
    func openDocument(at url: URL) {
        // 复用批量入口保证去重规则一致。
        openDocuments(at: [url])
    }

    // 批量打开文件；重复路径只激活已有标签。
    func openDocuments(at urls: [URL]) {
        // 依次处理，单个失败不阻断其他文件。
        for rawURL in urls {
            // 只接受本地文件 URL。
            guard rawURL.isFileURL else {
                // 记录最近一次失败原因。
                status = "打开失败：仅支持本地文件"
                // 继续处理其他 URL。
                continue
            }
            // 标准化路径用于跨入口去重。
            let url = rawURL.standardizedFileURL
            // 相同路径已打开时只激活已有标签。
            if let existing = documents.first(where: { $0.currentFileURL == url }) {
                // 保留原对象、正文、撤销关联和预览任务。
                guard activate(existing) else {
                    // 会话失败状态由 activate 内部 persistSession 保留。
                    continue
                }
                // 最近访问顺序仍应更新。
                try? recordRecentDocument(url)
                // 刷新菜单。
                refreshRecentDocuments()
                // 明确反馈没有产生重复标签。
                status = "已切换到打开的标签"
                // 继续处理下一 URL。
                continue
            }
            // 将真实文件打开与后续辅助元数据更新隔离，后者失败不能反转已打开结果。
            let document: EditorModel
            do {
                // 创建独立标签并处理这个路径的恢复草稿。
                guard let openedDocument = try EditorModel.open(at: url, documentStore: documentStore) else {
                    // 用户取消草稿选择时继续处理其他 URL。
                    continue
                }
                // 保存已经成功创建的标签对象供后续主流程使用。
                document = openedDocument
            } catch {
                // 单文件失败不破坏已有标签。
                status = "打开失败：\(error.localizedDescription)"
                // 继续处理下一 URL。
                continue
            }
            // 建立工作区回调。
            document.workspace = self
            // 新文件追加到标签末尾。
            documents.append(document)
            // 最近成功打开的文件成为活动标签。
            activeDocumentID = document.id
            // 默认辅助索引尚未更新成功。
            var recentDocumentWasUpdated = false
            do {
                // 最近文件索引失败只能影响菜单顺序，不能回滚内存标签。
                try recordRecentDocument(url)
                // 记录辅助索引已经同步。
                recentDocumentWasUpdated = true
            } catch {
                // 保留 false，交由最终状态准确提示辅助更新失败。
            }
            // 无论索引写入是否成功都重新读取菜单状态。
            refreshRecentDocuments()
            // 只有新增标签身份安全落盘后才能用打开成功文案覆盖会话错误。
            guard persistSession() else { continue }
            // 明确区分完整成功与最近文件辅助索引失败。
            status = recentDocumentWasUpdated ? "文件已打开" : "文件已打开，最近文件更新失败"
        }
    }

    // 保存当前活动标签。
    func saveDocument() {
        // 没有活动标签时保持幂等。
        guard let activeDocument else { return }
        // 走标签自身编码和冲突检查。
        activeDocument.saveDocument()
        // 另存为成功可能改变会话 URL。
        persistSession()
    }

    // 另存当前活动标签。
    func saveDocumentAs() {
        // 没有活动标签时保持幂等。
        guard let activeDocument else { return }
        // 打开系统保存面板。
        activeDocument.saveDocumentAs()
        // 成功时持久化新路径，取消时写回相同状态无副作用。
        persistSession()
    }

    // 导出当前活动标签 HTML。
    func exportHTML() {
        // 没有活动标签时保持幂等。
        activeDocument?.exportHTML()
    }

    // 复制当前活动标签公众号格式。
    func copyWechatHTML(template: WechatExportTemplate = .simple) {
        // 没有活动标签时保持幂等。
        activeDocument?.copyWechatHTML(template: template)
    }

    // 应用退出前同步全部 dirty 标签草稿并保存会话。
    @discardableResult
    func flushDraftsAndSession() -> Bool {
        // 默认所有标签都已安全落盘。
        var allDraftsSaved = true
        // 每个标签独立执行草稿保存，单个失败不跳过其他标签。
        for document in documents where !document.flushDraftIfNeeded() {
            // 任一失败都向调用方返回 false。
            allDraftsSaved = false
        }
        // 无论草稿结果如何都尝试保留可恢复的标签顺序。
        let sessionSaved = persistSession()
        // 草稿和会话必须同时成功，退出流程才能确认安全。
        return allDraftsSaved && sessionSaved
    }

    // 在 Finder 中定位仍保留的损坏会话代，便于用户先备份或人工检查。
    func revealSessionRecoveryData() {
        // 优先选择实际存在的 current 和 previous 文件，让证据直接可见。
        let generationURLs = sessionStore.existingGenerationURLs
        // 两代文件都不存在时退回显示会话目录，避免按钮无响应。
        let revealedURLs = generationURLs.isEmpty ? [sessionStore.storageDirectoryURL] : generationURLs
        // 使用系统 Finder 同时选择全部可用恢复入口。
        NSWorkspace.shared.activateFileViewerSelecting(revealedURLs)
    }

    // 在 Finder 中定位最近一次成功归档，供完成提示继续提供可达入口。
    func revealLastSessionArchive() {
        // 没有成功归档时保持幂等，不能误打开普通会话目录。
        guard let lastSessionArchiveURL else { return }
        // 选择精确归档目录，便于用户立即备份或检查原始文件。
        NSWorkspace.shared.activateFileViewerSelecting([lastSessionArchiveURL])
    }

    // 归档损坏双代并用当前内存标签顺序重建可继续持久化的会话。
    @discardableResult
    func archiveCorruptedSessionAndRebuild(
        date: Date = Date(),
        identifier: UUID = UUID()
    ) -> Bool {
        // 只有启动恢复已确认不可恢复时才允许执行破坏性重建入口。
        guard hasUnrecoverableSessionFailure else { return false }
        // 新尝试开始前清除旧结果，失败时不能把上一次路径误当成本次成功。
        lastSessionArchiveURL = nil
        // 重建会话前先保存每个 dirty 标签正文，避免 UUID 映射落盘但内容仍只在内存。
        for document in documents where !document.flushDraftIfNeeded() {
            // 草稿失败时保留警示和原始损坏代，禁止制造不可恢复的新会话。
            status = "会话归档重建失败，损坏数据仍保留在 \(sessionStore.storageDirectoryURL.path)：草稿保存失败"
            // 明确返回失败供测试和后续生命周期保护使用。
            return false
        }
        do {
            // 原子归档双代后用当前内存标签身份、顺序和活动 UUID 建立新 current。
            let result = try sessionStore.archiveCorruptedGenerationsAndReset(
                to: currentSessionState,
                date: date,
                identifier: identifier
            )
            // 只有归档与新会话都成功后才关闭持续警示。
            hasUnrecoverableSessionFailure = false
            // 保留本次精确归档目录供完成提示和 Finder 动作使用。
            lastSessionArchiveURL = result.directoryURL
            // 把归档目录写入状态栏，便于用户稍后精确找回原始证据。
            status = "损坏会话已归档并重建：\(result.directoryURL.path)"
            // 明确返回成功供界面和测试确认闭环。
            return true
        } catch {
            // 任一步失败都保留警示，不把部分操作误报为已经恢复。
            hasUnrecoverableSessionFailure = true
            // 同时给出原会话目录和底层原因，保证失败后证据仍可定位。
            status = "会话归档重建失败，损坏数据仍保留在 \(sessionStore.storageDirectoryURL.path)：\(error.localizedDescription)"
            // 让调用方继续阻止无提示退出。
            return false
        }
    }

    // 判断另存为路径是否会与其他打开标签冲突。
    func canAdoptFileURL(_ rawURL: URL, for document: EditorModel) -> Bool {
        // 非文件 URL 不允许成为本地文档身份。
        guard rawURL.isFileURL else { return false }
        // 规范化目标路径用于精确比较。
        let url = rawURL.standardizedFileURL
        // 只有另一个标签已占用同一路径时拒绝。
        return !documents.contains { $0.id != document.id && $0.currentFileURL == url }
    }

    // 标签保存成功后刷新最近文件和会话路径。
    func documentDidSave(_ document: EditorModel) {
        // 只响应当前工作区实际持有的对象。
        guard documents.contains(where: { $0.id == document.id }) else { return }
        // 更新最近文件菜单。
        refreshRecentDocuments()
        // 保存另存为后的新 URL。
        persistSession()
    }

    // 恢复上次标签顺序和活动标签。
    private func restoreLastSession() {
        do {
            // 读取完整会话及实际代次；首次启动返回 nil。
            guard let sessionLoad = try sessionStore.loadWithRecoverySource() else {
                // 首次启动迁移旧版草稿或展示示例。
                appendInitialDocument()
                return
            }
            // 后续标签恢复只消费已经完整解码的会话状态。
            let session = sessionLoad.state
            // 防止损坏会话中的重复路径产生多个标签。
            var restoredFileURLs = Set<URL>()
            // 按持久化顺序逐个恢复有效标签。
            for descriptor in session.documents {
                // 网络 URL 或重复文件路径直接跳过。
                if let fileURL = descriptor.fileURL {
                    // 统一标准化路径。
                    let normalizedURL = fileURL.standardizedFileURL
                    // 非本地或已经恢复的路径无效。
                    guard fileURL.isFileURL, !restoredFileURLs.contains(normalizedURL) else { continue }
                    // 先登记路径，防止后续重复项。
                    restoredFileURLs.insert(normalizedURL)
                }
                // 文件失效无草稿时返回 nil，不影响其他标签。
                guard let document = EditorModel.restore(descriptor, documentStore: documentStore) else {
                    continue
                }
                // 建立工作区回调。
                document.workspace = self
                // 保持原始标签顺序。
                documents.append(document)
            }
            // 全部描述失效时回退新标签。
            guard !documents.isEmpty else {
                // 创建安全可编辑状态。
                appendInitialDocument()
                // 上一代没有任何有效描述时也要说明本次确实发生了回退。
                if sessionLoad.recoveredFromPrevious, !status.contains("失败") {
                    // 当前新标签已经安全持久化，可以展示上一代失效边界。
                    status = "上一代会话没有可恢复标签，已新建标签"
                }
                return
            }
            // 活动 UUID 有效时恢复，否则回退首个标签。
            activeDocumentID =
                documents.contains(where: { $0.id == session.activeDocumentID })
                ? session.activeDocumentID
                : documents.first?.id
            // 清理失效描述并修复当前代会话；失败状态由 persistSession 保留。
            guard persistSession() else { return }
            // 上一代回退必须在界面明确可见，避免用户误以为当前代仍然完好。
            status =
                sessionLoad.recoveredFromPrevious
                ? "已从上一代会话恢复 \(documents.count) 个标签"
                : "已恢复 \(documents.count) 个标签"
        } catch {
            // 会话 JSON 损坏时回退新标签，不崩溃也不覆盖草稿。
            status = "会话恢复失败，已新建标签：\(error.localizedDescription)"
            // 发布持续恢复警示，普通状态文案变化也不能隐藏未解决的数据风险。
            hasUnrecoverableSessionFailure = true
            // 创建安全可编辑状态，但不迁移草稿或保存空会话覆盖损坏证据。
            appendInitialDocument(allowsPersistence: false)
        }
    }

    // 首次启动迁移 v0.1 草稿或创建示例标签。
    private func appendInitialDocument(allowsPersistence: Bool = true) {
        // 会话损坏路径不得读取后再迁移任何旧草稿，避免制造无法持久化的新映射。
        let legacyLoad = allowsPersistence ? try? documentStore.loadDraftWithRecoverySource(for: nil) : nil
        // 后续初始化只使用已经通过身份校验的旧草稿。
        let legacyDraft = legacyLoad?.draft
        // 为 v0.2 标签生成新 UUID。
        let documentID = UUID()
        // 旧草稿存在时保留正文和格式，否则展示示例。
        let document = EditorModel(
            id: documentID,
            text: legacyDraft?.text ?? EditorModel.sample,
            fileURL: nil,
            encoding: legacyDraft?.encoding ?? .utf8,
            includesByteOrderMark: legacyDraft?.includesByteOrderMark ?? false,
            dirty: true,
            savedText: "",
            savedEncoding: .utf8,
            savedIncludesByteOrderMark: false,
            status: legacyDraft == nil
                ? "已就绪"
                : legacyLoad?.recoveredFromPrevious == true
                    ? "已从上一代恢复并迁移旧版草稿"
                    : "已迁移旧版草稿",
            documentStore: documentStore
        )
        // 建立工作区回调。
        document.workspace = self
        // 作为首个唯一标签。
        documents = [document]
        // 设为活动标签。
        activeDocumentID = document.id
        // 旧草稿先复制到新 UUID 键，成功后才删除旧键。
        if allowsPersistence,
            let legacyDraft,
            (try? documentStore.saveDraft(
                legacyDraft.text,
                for: nil,
                untitledID: documentID,
                encoding: legacyDraft.encoding,
                includesByteOrderMark: legacyDraft.includesByteOrderMark
            )) != nil
        {
            // 新草稿确认落盘后清理旧版唯一键。
            try? documentStore.removeDraft(for: nil)
        }
        // 会话损坏时停止在纯内存安全状态，不能覆盖唯一恢复证据。
        guard allowsPersistence else { return }
        // 保存首次 v0.2 会话。
        persistSession()
    }

    // 原子保存当前标签顺序和活动 UUID。
    @discardableResult
    private func persistSession() -> Bool {
        do {
            // 原子写入单个会话文件。
            try sessionStore.save(currentSessionState)
            // 外部人工修复后若普通保存恢复成功，同样关闭已经解决的持续警示。
            hasUnrecoverableSessionFailure = false
            // 明确返回本轮会话已安全落盘。
            return true
        } catch {
            // 会话失败不改变内存标签，但明确反馈。
            status = "会话保存失败：\(error.localizedDescription)"
            // 让退出保护阻止无提示丢失标签顺序。
            return false
        }
    }

    // 从当前内存标签构建唯一会话描述，供普通保存和归档重建共享。
    private var currentSessionState: WorkspaceSessionState {
        // 只保存身份和路径，正文继续由独立草稿管理。
        WorkspaceSessionState(
            documents: documents.map {
                WorkspaceSessionDocument(id: $0.id, fileURL: $0.currentFileURL)
            },
            activeDocumentID: activeDocumentID
        )
    }

    // 刷新仍存在于磁盘的最近文件。
    private func refreshRecentDocuments() {
        do {
            // 失效记录不进入菜单，但不改写原索引。
            recentDocuments = try documentStore.recentDocuments().filter {
                FileManager.default.fileExists(atPath: $0.fileURL.path)
            }
        } catch {
            // 索引损坏不影响编辑主流程。
            recentDocuments = []
        }
    }
}

// 用真实文件和隔离存储验证多标签去重、草稿与会话恢复。
@MainActor
enum WorkspaceModelSelfCheck {
    // 自检不显示文件面板或修改真实用户数据。
    static func run(fileManager: FileManager = .default) throws -> String {
        // 为本次测试创建唯一根目录。
        let rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MarkdownLiteMac-WorkspaceSelfCheck-\(UUID().uuidString)", isDirectory: true)
        // 测试完成后只清理这个精确目录。
        defer { try? fileManager.removeItem(at: rootDirectory) }
        // 先创建真实文件父目录。
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // 创建可重复打开的 Markdown 文件。
        let fileURL = rootDirectory.appendingPathComponent("已命名.md", isDirectory: false)
        // 通过正式 IO 保存测试正文。
        try TextFileIO.save("# 已命名\n", to: fileURL)
        // 文档和会话存储共享同一个隔离产品目录。
        let documentStore = DocumentSupportStore(rootDirectory: rootDirectory, fileManager: fileManager)
        // 会话存储使用相同隔离目录。
        let sessionStore = WorkspaceSessionStore(rootDirectory: rootDirectory, fileManager: fileManager)
        // 关闭恢复创建一个全新工作区。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: false
        )
        // 获取首个未命名标签。
        guard let firstUntitled = workspace.activeDocument else {
            throw DocumentSupportError.selfCheckFailed("首个未命名标签")
        }
        // 修改首个标签以触发独立草稿。
        firstUntitled.text = "未命名一"
        // 新建第二个未命名标签。
        workspace.newDocument()
        // 获取第二个活动标签。
        guard let secondUntitled = workspace.activeDocument else {
            throw DocumentSupportError.selfCheckFailed("第二个未命名标签")
        }
        // 修改第二个标签以触发另一份草稿。
        secondUntitled.text = "未命名二"
        // 第一次打开真实文件应追加标签。
        workspace.openDocument(at: fileURL)
        // 记录已命名标签 UUID。
        guard let namedID = workspace.activeDocument?.id, workspace.documents.count == 3 else {
            throw DocumentSupportError.selfCheckFailed("追加已命名标签")
        }
        // 第二次打开同一路径必须只激活已有标签。
        workspace.openDocument(at: fileURL)
        // 数量和 UUID 都必须保持不变。
        guard workspace.documents.count == 3, workspace.activeDocument?.id == namedID else {
            throw DocumentSupportError.selfCheckFailed("同路径标签去重")
        }
        // 将首个标签设为活动以验证活动 UUID 恢复。
        workspace.activate(firstUntitled)
        // 应用退出路径必须保存两个独立未命名草稿。
        guard workspace.flushDraftsAndSession() else {
            throw DocumentSupportError.selfCheckFailed("全部标签草稿保存")
        }
        // 保存预期标签顺序。
        let expectedOrder = workspace.documents.map(\.id)
        // 用同一隔离存储模拟重新启动。
        let restoredWorkspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 顺序、活动标签和正文都必须跨启动保留。
        guard restoredWorkspace.documents.map(\.id) == expectedOrder,
            restoredWorkspace.activeDocument?.id == firstUntitled.id,
            restoredWorkspace.documents.first(where: { $0.id == firstUntitled.id })?.text == "未命名一",
            restoredWorkspace.documents.first(where: { $0.id == secondUntitled.id })?.text == "未命名二"
        else {
            throw DocumentSupportError.selfCheckFailed("多标签会话恢复")
        }
        // 构造仅含失效文件的会话，验证恢复不会崩溃。
        let missingID = UUID()
        // 保存一个不存在且没有草稿的路径。
        try sessionStore.save(
            WorkspaceSessionState(
                documents: [
                    WorkspaceSessionDocument(
                        id: missingID,
                        fileURL: rootDirectory.appendingPathComponent("已删除.md")
                    )
                ],
                activeDocumentID: missingID
            )
        )
        // 恢复会跳过失效描述并创建安全新标签。
        let fallbackWorkspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 安全回退必须留下一个可编辑标签。
        guard fallbackWorkspace.documents.count == 1,
            fallbackWorkspace.activeDocument != nil,
            fallbackWorkspace.activeDocument?.id != missingID
        else {
            throw DocumentSupportError.selfCheckFailed("失效文件安全回退")
        }
        // 用普通文件占据会话根目录，稳定制造会话写入失败。
        let blockedSessionRoot = rootDirectory.appendingPathComponent("blocked-session-root")
        // 写入普通文件后，SessionStore 无法在同一路径创建目录。
        try Data("blocked".utf8).write(to: blockedSessionRoot, options: .atomic)
        // 草稿使用独立有效目录，保证失败只来自会话落盘。
        let validDraftRoot = rootDirectory.appendingPathComponent("valid-draft-root", isDirectory: true)
        // 创建隔离工作区以验证退出保护返回失败。
        let blockedWorkspace = WorkspaceModel(
            documentStore: DocumentSupportStore(rootDirectory: validDraftRoot, fileManager: fileManager),
            sessionStore: WorkspaceSessionStore(rootDirectory: blockedSessionRoot, fileManager: fileManager),
            restoresSession: false
        )
        // 草稿成功但会话失败时，退出流程仍必须被阻止。
        guard !blockedWorkspace.flushDraftsAndSession() else {
            throw DocumentSupportError.selfCheckFailed("会话失败阻止退出")
        }
        // 返回可复核的综合通过标记。
        return "WorkspaceModelSelfCheck：多标签去重、独立草稿、顺序、活动标签、失效文件与退出保护通过"
    }
}
