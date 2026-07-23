import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// 表示一次后台 HTML 导出结束后可安全回传主线程的有限结果。
private enum BackgroundHTMLExportResult: Sendable {
    // 所有本地图片和 HTML 已经完整原子写入目标文件。
    case success
    // 标签关闭或下一次导出主动取消了当前任务。
    case cancelled
    // 只把可展示的错误说明带回界面，不跨 actor 传递任意错误对象。
    case failure(String)
}

// 管理一个标签自己的正文、预览、编码、草稿和保存状态。
@MainActor
final class EditorModel: ObservableObject, Identifiable {
    // 首次启动提供一份可直接修改的示例。
    static let sample = """
        # Markdown Lite

        这是一个轻量的原生 Mac Markdown 编辑器。

        - [x] 原生编辑体验
        - [x] 自动恢复草稿
        - [x] 延迟预览，不阻塞每次按键
        - [ ] 写下你的下一篇内容

        > 最小、实用、性能可测。

        | 指标 | 当前目标 |
        | :--- | ---: |
        | 200KB 解析 | < 50ms |
        | 1MB 解析 | < 200ms |
        """

    // UUID 在会话、标签和未命名草稿之间保持一致。
    let id: UUID
    // 文本变化后只更新当前标签自己的 dirty、预览和草稿任务。
    @Published var text: String {
        didSet { contentChanged() }
    }
    // 当前标签自己的增强预览块。
    @Published private(set) var previewBlocks: [EnhancedPreviewBlock] = []
    // 当前标签自己的保存或恢复反馈。
    @Published private(set) var status: String
    // 当前标签最近一次有效预览耗时。
    @Published private(set) var renderMilliseconds = 0.0
    // 自动预览暂停时保存可展示原因，手动刷新成功后恢复正常耗时展示。
    @Published private(set) var previewPauseReason: PreviewWorkPauseReason?
    // 当前标签的全文与选区统计由后台任务计算，状态栏只读取常量时间结果。
    @Published private(set) var writingStatistics = WritingStatistics(
        characterCount: 0,
        lineCount: 1,
        selectedCharacterCount: 0
    )
    // 标签标题使用真实文件名或稳定未命名标题。
    @Published private(set) var filename: String
    // dirty 只表示当前标签尚未写回真实文件。
    @Published private(set) var isDirty: Bool
    // 文件 URL 为 nil 时表示独立未命名标签。
    @Published private(set) var currentFileURL: URL?
    // 暴露按需检查得到的外部文件状态，供 UI 决定重载或明确覆盖。
    @Published private(set) var externalChangeState: ExternalDocumentChangeState
    // 每个标签独立保存预览显示偏好。
    @Published var isPreviewVisible = true
    // 只有解析结果与当前正文代次一致时，预览中的写回动作才可执行。
    var isPreviewCurrent: Bool {
        // 已应用代次落后表示界面仍展示旧正文的预览块。
        appliedPreviewGeneration == previewGeneration
    }

    // 工作区弱引用只用于兼容现有工具栏入口，不形成循环持有。
    weak var workspace: WorkspaceModel?
    // 所有标签共享同一支撑层，但草稿键由 URL 或标签 UUID 隔离。
    private let documentStore: DocumentSupportStore
    // 最近文件写入通过可注入闭包隔离，测试可以稳定复现索引失败而不破坏真实文件保存。
    private let recordRecentDocument: (URL) throws -> Void
    // 保存快照用于外部修改核对和 dirty 基线。
    private var saveState: DocumentSaveState
    // 保存与最后一次打开或保存原始字节对应的可信磁盘指纹。
    private var externalFileSnapshot: ExternalFileSnapshot?
    // 原地保存时沿用当前标签来源编码。
    private var currentEncoding: String.Encoding
    // 原地保存时沿用当前标签来源 BOM 策略。
    private var includesByteOrderMark: Bool
    // 初始化或整体替换正文时抑制输入副作用。
    private var isReplacingDocument = false
    // 每个标签持有自己的后台预览任务。
    private var previewTask: Task<Void, Never>?
    // 只有工作区活动标签允许启动自动预览和写作统计任务。
    private var isPreviewActive = true
    // 写作统计与预览分开取消，较慢的全文计数不能覆盖新正文。
    private var writingStatisticsTask: Task<Void, Never>?
    // 每次正文变化推进统计代次，保证只接受最新结果。
    private var writingStatisticsGeneration = 0
    // 每个标签独立递增版本，过期结果不会跨标签回写。
    private var previewGeneration = 0
    // 保存当前 previewBlocks 实际对应的正文代次，供交互预览拒绝旧动作。
    private var appliedPreviewGeneration = -1
    // 每个标签独立节流草稿写入。
    private var draftTimer: Timer?
    // 自动草稿完整编码和磁盘写入在后台任务执行。
    private var draftWriteTask: Task<Void, Never>?
    // HTML 图片读取、编码和原子写入使用独立后台任务，避免阻塞编辑输入。
    private var exportTask: Task<Void, Never>?
    // 双代草稿都不可用时保持独立保护，普通撤销不能把损坏证据当作旧草稿清理。
    private var hasUnresolvedDraftRecoveryFailure: Bool

    // 保留旧调用方式，实际应用由 WorkspaceModel 注入共享存储。
    convenience init() {
        // 创建默认文档支撑层。
        let store = DocumentSupportStore()
        // 兼容读取 v0.1 唯一未命名草稿。
        let legacyDraft = try? store.loadDraft(for: nil)
        // 有旧草稿就优先恢复，否则展示示例。
        let initialText = legacyDraft?.text ?? Self.sample
        // 独立创建新标签 UUID。
        let documentID = UUID()
        // 建立未命名编辑模型。
        self.init(
            id: documentID,
            text: initialText,
            fileURL: nil,
            encoding: legacyDraft?.encoding ?? .utf8,
            includesByteOrderMark: legacyDraft?.includesByteOrderMark ?? false,
            dirty: !initialText.isEmpty,
            savedText: "",
            savedEncoding: .utf8,
            savedIncludesByteOrderMark: false,
            status: legacyDraft == nil ? "已就绪" : "已恢复草稿",
            documentStore: store
        )
    }

    // 由工作区用完整恢复信息创建一个独立标签。
    init(
        id: UUID,
        text: String,
        fileURL: URL?,
        encoding: String.Encoding,
        includesByteOrderMark: Bool,
        dirty: Bool,
        savedText: String,
        savedEncoding: String.Encoding,
        savedIncludesByteOrderMark: Bool,
        status: String,
        documentStore: DocumentSupportStore,
        externalFileSnapshot: ExternalFileSnapshot? = nil,
        initialExternalChangeState: ExternalDocumentChangeState? = nil,
        unresolvedDraftRecoveryFailure: Bool = false,
        recordRecentDocument: ((URL) throws -> Void)? = nil
    ) {
        // 先保存稳定标签身份。
        self.id = id
        // 保存共享支撑层引用。
        self.documentStore = documentStore
        // 生产环境默认写入正式最近文件索引，测试可注入确定性失败闭包。
        self.recordRecentDocument =
            recordRecentDocument ?? { fileURL in
                // 默认路径保持既有存储实现和排序语义。
                try documentStore.recordRecentDocument(fileURL)
            }
        // 恢复失败保护独立于普通 dirty 快照，直到正文安全落盘或用户明确丢弃。
        hasUnresolvedDraftRecoveryFailure = unresolvedDraftRecoveryFailure
        // 初始化正文，不触发 didSet。
        self.text = text
        // 先用局部值规范化真实文件路径，避免初始化期间读取 self。
        let normalizedFileURL = fileURL?.standardizedFileURL
        // 保存规范化真实文件路径。
        currentFileURL = normalizedFileURL
        // 已命名文档只采用调用方明确注入的可信快照，恢复草稿时不能把当前磁盘误当旧基线。
        if let normalizedFileURL {
            // 保存打开、保存或草稿记录提供的可信基线；nil 必须在普通保存时保守冲突。
            self.externalFileSnapshot = externalFileSnapshot
            // 恢复路径可直接注入已经与当前磁盘比较过的状态。
            if let initialExternalChangeState {
                // 立即发布恢复时结论，避免首次普通保存前出现短暂未冲突状态。
                externalChangeState = initialExternalChangeState
            } else if externalFileSnapshot != nil {
                // 已建立内容基线时初始状态明确未变化。
                externalChangeState = .unchanged
            } else if FileManager.default.fileExists(atPath: normalizedFileURL.path) {
                // 文件存在但无法建立基线时禁止静默覆盖。
                externalChangeState = .unreadable("无法建立打开时磁盘基线")
            } else {
                // 恢复草稿但原文件缺失时明确记录删除状态。
                externalChangeState = .deleted
            }
        } else {
            // 未命名标签不参与外部文件检测。
            self.externalFileSnapshot = nil
            // UI 可据此隐藏冲突操作。
            externalChangeState = .notMonitored
        }
        // 文件名供标签栏和导出默认名使用。
        filename = fileURL?.lastPathComponent ?? "未命名.md"
        // 恢复来源编码。
        currentEncoding = encoding
        // 恢复来源 BOM 策略。
        self.includesByteOrderMark = includesByteOrderMark
        // 建立最后一次真实磁盘内容快照。
        saveState = DocumentSaveState(
            text: savedText,
            fileURL: fileURL,
            encoding: savedEncoding,
            includesByteOrderMark: savedIncludesByteOrderMark
        )
        // 恢复草稿时重新标记未保存。
        if dirty { saveState.markChanged() }
        // 同步发布 dirty 状态。
        isDirty = dirty
        // 初始化当前标签反馈。
        self.status = status
        // 首屏预览也离开主线程，避免会话恢复多个大文件时卡住窗口。
        schedulePreview(after: .zero)
        // 首屏统计同样在后台执行，初始化不能同步遍历大正文。
        scheduleWritingStatistics(after: .zero)
    }

    // 将草稿捕获时的摘要恢复成仅用于内容比较的可信磁盘基线。
    private static func draftBaselineSnapshot(
        for fileURL: URL,
        contentDigest: String?
    ) -> ExternalFileSnapshot? {
        // 旧草稿没有摘要时不能从当前磁盘反向猜测历史基线。
        guard let contentDigest else { return nil }
        // 外部变化检查只以规范化路径和摘要判定内容一致性。
        return ExternalFileSnapshot(
            fileURL: fileURL.standardizedFileURL,
            fileSize: 0,
            modificationDate: nil,
            fileIdentifier: nil,
            contentDigest: contentDigest
        )
    }

    // 比较恢复草稿的历史基线和当前磁盘，返回后续保存必须沿用的基线与状态。
    private static func trackingForRestoredDraft(
        _ draft: DocumentDraft,
        fileURL: URL,
        currentSnapshot: ExternalFileSnapshot?
    ) -> (snapshot: ExternalFileSnapshot?, state: ExternalDocumentChangeState) {
        // 先恢复草稿实际捕获时的可信摘要，不能采用启动时才读取的外部版本。
        let draftBaseline = draftBaselineSnapshot(
            for: fileURL,
            contentDigest: draft.baselineContentDigest
        )
        // 当前文件无法读取时区分删除与不可读，并保留旧基线供后续检查。
        guard let currentSnapshot else {
            // 文件仍存在表示本次无法安全读取，普通保存必须继续阻止。
            let state: ExternalDocumentChangeState =
                FileManager.default.fileExists(atPath: fileURL.path)
                ? .unreadable("无法读取当前磁盘版本")
                : .deleted
            // 返回草稿历史基线和保守状态。
            return (draftBaseline, state)
        }
        // 旧 JSON 没有历史摘要时无法证明当前磁盘仍是草稿起点。
        guard let draftBaseline else {
            // 保守报告外部修改，直到用户重载或明确覆盖。
            return (nil, .modified)
        }
        // 摘要相同证明当前磁盘仍等于草稿捕获时版本。
        guard draftBaseline.contentDigest != currentSnapshot.contentDigest else {
            // 采用当前完整快照刷新诊断元数据，同时保持安全普通保存能力。
            return (currentSnapshot, .unchanged)
        }
        // 摘要不同必须沿用历史基线并立即暴露冲突。
        return (draftBaseline, .modified)
    }

    // 创建一个真正独立的未命名标签。
    static func makeUntitled(
        id: UUID = UUID(),
        text: String = "",
        dirty: Bool = false,
        status: String = "新文档",
        documentStore: DocumentSupportStore
    ) -> EditorModel {
        // 未命名文档以空正文作为磁盘基线。
        EditorModel(
            id: id,
            text: text,
            fileURL: nil,
            encoding: .utf8,
            includesByteOrderMark: false,
            dirty: dirty,
            savedText: "",
            savedEncoding: .utf8,
            savedIncludesByteOrderMark: false,
            status: status,
            documentStore: documentStore
        )
    }

    // 根据会话描述恢复一个标签，失效文件只有存在草稿时才保留。
    static func restore(
        _ descriptor: WorkspaceSessionDocument,
        documentStore: DocumentSupportStore
    ) -> EditorModel? {
        // 未命名标签按 UUID 精确恢复自己的草稿。
        guard let fileURL = descriptor.fileURL else {
            // 预留带来源的草稿结果，便于向用户说明上一代回退。
            var draftLoad: DraftLoadResult?
            // 单独记录双代恢复失败，避免把空标签误标成可安全关闭。
            var draftRecoveryFailed = false
            do {
                // 未命名草稿必须继续按标签 UUID 严格隔离。
                draftLoad = try documentStore.loadDraftWithRecoverySource(
                    for: nil,
                    untitledID: descriptor.id
                )
            } catch {
                // 存储层保留损坏证据，模型只进入受保护的空白编辑状态。
                draftRecoveryFailed = true
            }
            // 后续恢复逻辑只消费已经通过身份校验的草稿。
            let draft = draftLoad?.draft
            // 恢复状态明确区分正常、上一代回退和双代失败。
            let restoredStatus =
                draftRecoveryFailed
                ? "草稿恢复失败，损坏数据已保留"
                : draftLoad?.recoveredFromPrevious == true
                    ? "已从上一代草稿恢复"
                    : draft == nil ? "已恢复空白标签" : "已恢复草稿"
            // 草稿存在即表示尚未写入真实文件。
            return EditorModel(
                id: descriptor.id,
                text: draft?.text ?? "",
                fileURL: nil,
                encoding: draft?.encoding ?? .utf8,
                includesByteOrderMark: draft?.includesByteOrderMark ?? false,
                dirty: draft != nil || draftRecoveryFailed,
                savedText: "",
                savedEncoding: .utf8,
                savedIncludesByteOrderMark: false,
                status: restoredStatus,
                documentStore: documentStore,
                unresolvedDraftRecoveryFailure: draftRecoveryFailed
            )
        }

        // 同一次稳定读取同时获得磁盘正文和内容指纹。
        let diskRead = try? TextFileIO.readWithSnapshot(from: fileURL)
        // 后续恢复逻辑只消费无损解码正文。
        let diskContent = diskRead?.content
        // 预留带来源的已命名草稿结果，便于反馈上一代回退。
        var draftLoad: DraftLoadResult?
        // 双代都不可用时仍保留磁盘正文和损坏草稿证据。
        var draftRecoveryFailed = false
        do {
            // 已命名草稿继续按规范化路径和内嵌身份双重校验。
            draftLoad = try documentStore.loadDraftWithRecoverySource(for: fileURL)
        } catch {
            // 恢复失败不让整个会话崩溃，也不能把标签当成干净状态自动清理草稿。
            draftRecoveryFailed = true
        }
        // 后续恢复逻辑只使用已经验证的草稿。
        let draft = draftLoad?.draft
        // 文件失效且没有草稿时跳过这个标签。
        guard diskContent != nil || draft != nil || draftRecoveryFailed else { return nil }
        // 草稿与磁盘不同时优先恢复草稿，避免会话恢复阶段弹出多次警告。
        let shouldRestoreDraft = draft != nil && draft?.text != diskContent?.text
        // 选择安全的当前正文。
        let restoredText = shouldRestoreDraft ? draft?.text ?? "" : diskContent?.text ?? draft?.text ?? ""
        // 草稿恢复沿用草稿编码，否则沿用磁盘编码。
        let restoredEncoding =
            shouldRestoreDraft ? draft?.encoding ?? .utf8 : diskContent?.encoding ?? draft?.encoding ?? .utf8
        // 草稿恢复沿用草稿 BOM，否则沿用磁盘 BOM。
        let restoredBOM =
            shouldRestoreDraft ? draft?.includesByteOrderMark ?? false : diskContent?.includesByteOrderMark ?? false
        // 真实磁盘缺失时使用空基线，保存前仍会要求确认重新创建。
        let savedText = diskContent?.text ?? ""
        // 只有恢复不同草稿时才使用草稿捕获时的历史磁盘基线。
        let restoredTracking =
            shouldRestoreDraft
            ? draft.map {
                trackingForRestoredDraft(
                    $0,
                    fileURL: fileURL,
                    currentSnapshot: diskRead?.snapshot
                )
            }
            : nil
        // 必须按是否恢复草稿分支，旧草稿的 nil 历史基线不能回退成当前磁盘快照。
        let restoredSnapshot: ExternalFileSnapshot?
        // 已恢复草稿时完整采用跟踪结果，包括保守保留的 nil 基线。
        if let restoredTracking {
            // nil 表示旧 JSON 无法证明历史版本，后续普通保存必须持续冲突。
            restoredSnapshot = restoredTracking.snapshot
        } else {
            // 未恢复草稿时当前稳定读取本身就是可信基线。
            restoredSnapshot = diskRead?.snapshot
        }
        // 草稿历史摘要不同或缺失时立即进入修改状态；普通文件保持未变化。
        let restoredExternalState =
            restoredTracking?.state
            ?? (diskRead == nil ? .deleted : .unchanged)
        // 冲突恢复需要直接提示外部版本风险，不能只显示普通草稿恢复。
        let restoredStatus =
            draftRecoveryFailed
            ? diskContent == nil
                ? "原文件失效且草稿恢复失败，损坏数据已保留"
                : "草稿恢复失败，已打开磁盘文件并保留损坏数据"
            : diskContent == nil
                ? draftLoad?.recoveredFromPrevious == true
                    ? "原文件失效，已从上一代草稿恢复"
                    : "原文件失效，已恢复草稿"
                : shouldRestoreDraft && restoredExternalState == .modified
                    ? draftLoad?.recoveredFromPrevious == true
                        ? "已从上一代草稿恢复，检测到磁盘版本已在外部修改"
                        : "已恢复草稿，检测到磁盘版本已在外部修改"
                    : shouldRestoreDraft
                        ? draftLoad?.recoveredFromPrevious == true
                            ? "已从上一代草稿恢复"
                            : "已恢复草稿"
                        : draftLoad?.recoveredFromPrevious == true
                            ? "已从上一代草稿核对，磁盘文件未变化"
                            : "已恢复文件"
        // 返回完整独立标签模型。
        return EditorModel(
            id: descriptor.id,
            text: restoredText,
            fileURL: fileURL,
            encoding: restoredEncoding,
            includesByteOrderMark: restoredBOM,
            dirty: shouldRestoreDraft || diskContent == nil || draftRecoveryFailed,
            savedText: savedText,
            savedEncoding: diskContent?.encoding ?? restoredEncoding,
            savedIncludesByteOrderMark: diskContent?.includesByteOrderMark ?? restoredBOM,
            status: restoredStatus,
            documentStore: documentStore,
            externalFileSnapshot: restoredSnapshot,
            initialExternalChangeState: restoredExternalState,
            unresolvedDraftRecoveryFailure: draftRecoveryFailed
        )
    }

    // 打开一个新文件标签，并让用户明确处理与磁盘不同的旧草稿。
    static func open(
        id: UUID = UUID(),
        at fileURL: URL,
        documentStore: DocumentSupportStore
    ) throws -> EditorModel? {
        // 一次稳定读取同时获得无损正文和可信磁盘指纹。
        let diskRead = try TextFileIO.readWithSnapshot(from: fileURL)
        // 后续草稿选择逻辑消费同一份正文。
        let diskContent = diskRead.content
        // 再读取这个路径自己的恢复草稿并保留实际采用的代次。
        let draftLoad = try documentStore.loadDraftWithRecoverySource(for: fileURL)
        // 后续选择逻辑只消费已经通过身份校验的草稿。
        let draft = draftLoad?.draft
        // 默认使用磁盘内容。
        var restoredDraft: DocumentDraft?
        // 内容不同必须让用户明确选择，不能静默丢弃任一版本。
        if let draft, draft.text != diskContent.text {
            // 使用原生警告框说明恢复不会立即覆盖磁盘。
            let alert = NSAlert()
            // 明确问题标题。
            alert.messageText = "发现未合并的恢复草稿"
            // 上一代回退需要明确说明当前代不可用，同时保持不覆盖磁盘的既有语义。
            alert.informativeText =
                draftLoad?.recoveredFromPrevious == true
                ? "当前草稿不可用，已找到同一文档的上一代草稿。恢复不会立即覆盖磁盘文件。"
                : "草稿与磁盘文件内容不同。恢复草稿不会立即覆盖磁盘文件。"
            // 第一项保留草稿。
            alert.addButton(withTitle: "恢复草稿")
            // 第二项明确丢弃草稿。
            alert.addButton(withTitle: "使用磁盘版本")
            // 第三项中止打开。
            alert.addButton(withTitle: "取消")
            // 按用户选择处理当前路径草稿。
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // 草稿成为当前正文但保持 dirty。
                restoredDraft = draft
            case .alertSecondButtonReturn:
                // 用户明确选择磁盘版本后清理旧草稿。
                try documentStore.removeDraft(for: fileURL)
            default:
                // 取消时不创建半个标签。
                return nil
            }
        } else if draft != nil {
            // 完全一致的草稿没有额外恢复价值。
            try documentStore.removeDraft(for: fileURL)
        }
        // 草稿优先提供正文和格式信息。
        let currentText = restoredDraft?.text ?? diskContent.text
        // 草稿恢复沿用写入时编码。
        let currentEncoding = restoredDraft?.encoding ?? diskContent.encoding
        // 草稿恢复沿用写入时 BOM。
        let currentBOM = restoredDraft?.includesByteOrderMark ?? diskContent.includesByteOrderMark
        // 用户选择恢复草稿后继续沿用草稿捕获时基线，不采用启动时外部版本。
        let restoredTracking = restoredDraft.map {
            trackingForRestoredDraft(
                $0,
                fileURL: fileURL,
                currentSnapshot: diskRead.snapshot
            )
        }
        // 必须按是否恢复草稿分支，不能把旧草稿的 nil 基线替换成当前磁盘快照。
        let restoredSnapshot: ExternalFileSnapshot?
        // 已恢复草稿时完整采用历史跟踪结果，包括保守保留的 nil 基线。
        if let restoredTracking {
            // nil 会让后续普通保存持续阻止，直到用户明确解决。
            restoredSnapshot = restoredTracking.snapshot
        } else {
            // 没有恢复草稿时稳定读取的当前快照就是可信基线。
            restoredSnapshot = diskRead.snapshot
        }
        // 旧草稿无基线或摘要不同时立即发布外部修改状态。
        let restoredExternalState = restoredTracking?.state ?? .unchanged
        // 将保守冲突与可证明安全的草稿恢复反馈区分开。
        let restoredStatus =
            restoredDraft == nil
            ? "文件已打开"
            : restoredExternalState == .modified
                ? draftLoad?.recoveredFromPrevious == true
                    ? "已从上一代草稿恢复，检测到磁盘版本已在外部修改"
                    : "已恢复草稿，检测到磁盘版本已在外部修改"
                : draftLoad?.recoveredFromPrevious == true
                    ? "已从上一代草稿恢复，磁盘版本尚未覆盖"
                    : "已恢复草稿，磁盘版本尚未覆盖"
        // 创建独立文件标签。
        return EditorModel(
            id: id,
            text: currentText,
            fileURL: fileURL,
            encoding: currentEncoding,
            includesByteOrderMark: currentBOM,
            dirty: restoredDraft != nil,
            savedText: diskContent.text,
            savedEncoding: diskContent.encoding,
            savedIncludesByteOrderMark: diskContent.includesByteOrderMark,
            status: restoredStatus,
            documentStore: documentStore,
            externalFileSnapshot: restoredSnapshot,
            initialExternalChangeState: restoredExternalState
        )
    }

    // 兼容现有内容视图的最近文件入口，正式标签栏直接读取工作区。
    var recentDocuments: [RecentDocument] {
        // 工作区统一过滤失效记录。
        workspace?.recentDocuments ?? []
    }

    // 输入事件只安排当前标签自己的后续工作。
    private func contentChanged() {
        // 初始化整体替换时由调用方显式维护状态。
        guard !isReplacingDocument else { return }
        // 当前标签以常量时间标记未保存。
        saveState.markChanged()
        // 同步标签 dirty 圆点。
        isDirty = true
        // 当前标签停顿 120ms 后在后台解析。
        schedulePreview(after: .milliseconds(120))
        // 同一停顿窗口合并全文统计，避免逐键重复扫描。
        scheduleWritingStatistics(after: .milliseconds(120))
        // 当前标签旧草稿任务已经过期。
        draftTimer?.invalidate()
        // 取消上一轮仅用于状态回写的后台任务。
        draftWriteTask?.cancel()
        // 当前标签停顿 700ms 后保存独立草稿。
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            // 回到主 actor 只捕获写时复制快照，完整编码和 IO 转到后台。
            Task { @MainActor in self?.startBackgroundDraftWrite() }
        }
        // 当前标签状态栏提示仍在编辑。
        status = "正在编辑…"
    }

    // 原生编辑器只在撤销或重做完成后调用，用完整保存快照精确修正 dirty 状态。
    func reconcileDirtyAfterUndoRedo() {
        // 普通输入仍走常量时间 markChanged；这里仅为撤销栈回到保存内容的低频路径做全文核对。
        let reconciledDirty = saveState.reconcile(text: text, fileURL: currentFileURL)
        // 双代失败未解决前，即使正文撤销回磁盘快照也不能自动删除损坏证据。
        guard !hasUnresolvedDraftRecoveryFailure else {
            // 保持 dirty 让关闭和退出流程继续要求明确保存或丢弃。
            isDirty = true
            // 撤销后的状态栏重新展示仍未解决的数据恢复风险。
            status = "草稿恢复失败，损坏数据仍保留"
            // 不能进入普通干净路径的计时器取消和草稿删除。
            return
        }
        // 没有独立恢复风险时沿用保存快照精确修正 dirty。
        isDirty = reconciledDirty
        // 仍与保存快照不同时保留当前草稿节流和恢复能力。
        guard !isDirty else { return }
        // 回到保存快照后停止尚未触发的草稿计时器。
        draftTimer?.invalidate()
        // 清除计时器引用，避免已失效计时器被误认为当前请求。
        draftTimer = nil
        // 取消可能已经捕获旧正文的后台草稿任务。
        draftWriteTask?.cancel()
        // 清除旧任务引用，后续编辑只跟踪自己的新任务。
        draftWriteTask = nil
        // 删除已落盘旧草稿并推进同一草稿键的单调屏障，阻止更早后台写入复活。
        try? documentStore.removeDraft(
            for: currentFileURL,
            untitledID: currentFileURL == nil ? id : nil
        )
    }

    // 捕获当前状态并启动不阻塞主 actor 的自动草稿写入。
    private func startBackgroundDraftWrite() {
        // 已经撤销回保存快照时，忽略计时器先触发但稍后才进入主 actor 的旧回调。
        guard isDirty else { return }
        // 新任务开始前取消旧任务的状态回写。
        draftWriteTask?.cancel()
        // String 写时复制让主线程只获取低成本正文快照。
        let capturedText = text
        // 捕获当前文件身份，标签另存为后旧请求仍会被删除屏障拦截。
        let capturedFileURL = currentFileURL
        // 未命名草稿使用稳定标签 UUID。
        let capturedUntitledID = capturedFileURL == nil ? id : nil
        // 捕获当前来源编码。
        let capturedEncoding = currentEncoding
        // 捕获当前 BOM 策略。
        let capturedBOM = includesByteOrderMark
        // 捕获最后可信磁盘摘要，恢复后继续用它识别进程外改写。
        let capturedBaselineDigest = externalFileSnapshot?.contentDigest
        // 时间戳只作为草稿展示元数据，正确性顺序由存储层单调序号保证。
        let capturedAt = Date()
        // 捕获线程安全支撑层而不长期持有模型。
        let store = documentStore

        // Task 负责等待后台支撑层结果并只在最新状态仍有效时更新 UI。
        draftWriteTask = Task { [weak self] in
            do {
                // JSON 编码、目录创建和原子写入全部在后台执行。
                _ = try await store.saveDraftInBackground(
                    capturedText,
                    for: capturedFileURL,
                    untitledID: capturedUntitledID,
                    encoding: capturedEncoding,
                    includesByteOrderMark: capturedBOM,
                    baselineContentDigest: capturedBaselineDigest,
                    updatedAt: capturedAt
                )
                // 新输入取消后不允许旧任务覆盖状态栏。
                guard !Task.isCancelled else { return }
                // 成功写入新的有效 current 后，双代失败保护已经得到解决。
                self?.hasUnresolvedDraftRecoveryFailure = false
                // 模型仍存活时反馈草稿已经落盘。
                self?.status = "已自动保存草稿"
            } catch {
                // 新输入取消属于正常节流，不显示失败。
                guard !Task.isCancelled else { return }
                // 真正写入失败时保持明确恢复风险。
                self?.status = "草稿保存失败：\(error.localizedDescription)"
            }
        }
    }

    // 在后台解析当前标签，只接受最新一代结果。
    private func schedulePreview(
        after delay: Duration,
        trigger: PreviewWorkTrigger = .automatic
    ) {
        // 取消当前标签尚未开始的旧任务。
        previewTask?.cancel()
        // 当前标签版本号独立递增。
        previewGeneration &+= 1
        // 捕获本次版本用于回写核对。
        let generation = previewGeneration
        // 后台标签的自动请求直接结束，连正文快照和字节统计都不创建。
        if trigger == .automatic, !isPreviewActive {
            // 保存稳定原因供测试和后续激活时识别当前状态。
            previewPauseReason = .backgroundTab
            // 后台标签等待激活入口重新安排最新正文。
            return
        }
        // String 写时复制提供低成本正文快照。
        let markdown = text
        // 捕获活动状态，后台任务不得跨 actor 读取可变模型。
        let capturedIsActive = isPreviewActive
        // 新请求开始后先清除旧暂停原因，避免手动刷新期间仍显示暂停页。
        previewPauseReason = nil
        // 外层任务负责节流和最新结果回写。
        previewTask = Task { [weak self] in
            do {
                // 等待当前标签输入停顿。
                try await ContinuousClock().sleep(for: delay)
            } catch {
                // 新输入取消时不生成错误状态。
                return
            }
            // 已取消任务不再消耗解析 CPU。
            guard !Task.isCancelled else { return }
            // detached 任务先在后台统计字节并执行策略，再按需解析正文。
            let parseTask = Task.detached(priority: .userInitiated) {
                () -> (PreviewWorkPauseReason?, [EnhancedPreviewBlock], Double)? in
                // 外层任务在 detached 启动前取消时不进入解析器。
                guard !Task.isCancelled else { return nil }
                // UTF-8 计数可能遍历大正文，必须与输入主线程隔离。
                let byteCount = markdown.utf8.count
                // 统一策略决定后台、超大文档或手动请求能否继续。
                let decision = PreviewWorkPolicy.decision(
                    isActiveDocument: capturedIsActive,
                    documentByteCount: byteCount,
                    trigger: trigger
                )
                // 自动请求被暂停时不进入完整 Markdown 解析。
                if let pauseReason = decision.pauseReason {
                    // 只返回原因，不制造无意义的预览块。
                    return (pauseReason, [], 0)
                }
                // 单调时钟记录本次真实解析耗时。
                let startedAt = ProcessInfo.processInfo.systemUptime
                // 线性扫描生成增强块。
                let blocks = EnhancedMarkdownParser.parse(markdown)
                // 解析器响应取消后不把不完整结果和耗时交给界面。
                guard !Task.isCancelled else { return nil }
                // 换算成毫秒供当前标签状态栏展示。
                let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                // 一次返回无暂停标记、预览块和耗时。
                return (nil, blocks, milliseconds)
            }
            // 外层节流任务取消时显式传播给不继承取消状态的 detached 解析任务。
            let result = await withTaskCancellationHandler {
                // 正常路径等待后台解析完成。
                await parseTask.value
            } onCancel: {
                // 新输入或标签关闭会立即请求解析器停止长循环。
                parseTask.cancel()
            }
            // 解析期间取消时丢弃结果。
            guard !Task.isCancelled, let result else { return }
            // 只有同一标签最新版本可以回写。
            guard let self, self.previewGeneration == generation else { return }
            // 策略暂停时只发布原因，不能把空数组伪装成成功预览。
            if let pauseReason = result.0 {
                // 大文档提示由界面提供单次手动刷新入口。
                self.previewPauseReason = pauseReason
                // 暂停代次没有对应可交互预览。
                return
            }
            // 成功解析清除之前的大文档暂停状态。
            self.previewPauseReason = nil
            // 先标记结果所属代次，随后发布的块视图即可安全开放交互。
            self.appliedPreviewGeneration = generation
            // 更新当前标签预览块。
            self.previewBlocks = result.1
            // 更新当前标签解析耗时。
            self.renderMilliseconds = result.2
        }
    }

    // 工作区在活动标签变化后同步每个模型的后台工作资格。
    func setPreviewActive(_ isActive: Bool) {
        // 相同状态不重复取消或重建任务。
        guard isPreviewActive != isActive else { return }
        // 先保存新状态供后续自动策略读取。
        isPreviewActive = isActive
        // 标签进入后台时立即停止未完成解析。
        guard isActive else {
            // 取消当前解析及其 detached 子任务。
            previewTask?.cancel()
            // 只有尚未追平的请求需要推进代次；已完成预览可安全跨标签复用。
            if !isPreviewCurrent {
                // 推进代次，防止恰好完成的旧结果回写。
                previewGeneration &+= 1
            }
            // 后台原因不会在隐藏界面展示，但能准确描述当前策略状态。
            previewPauseReason = .backgroundTab
            // 后台标签不继续执行尚未完成的全文统计。
            writingStatisticsTask?.cancel()
            // 推进统计代次，防止取消边界上的旧结果回写。
            writingStatisticsGeneration &+= 1
            // 等待重新激活后再处理最新正文。
            return
        }
        // 正文未变化且已有当前预览时直接复用，切换标签不重复解析。
        if isPreviewCurrent {
            // 清除仅用于后台状态的暂停原因。
            previewPauseReason = nil
        } else {
            // 没有当前预览时立即为最新正文安排自动解析。
            schedulePreview(after: .zero)
        }
        // 切回活动标签时同步追平最新全文统计。
        scheduleWritingStatistics(after: .zero)
    }

    // 用户可为当前活动大文档显式执行一次不受大小限制的预览。
    func refreshPreviewManually() {
        // 后台标签没有可见预览入口，拒绝程序化误调用。
        guard isPreviewActive else { return }
        // 手动触发只放行当前请求，后续输入仍恢复自动大小限制。
        schedulePreview(after: .zero, trigger: .manualRefresh)
    }

    // 原生编辑器把后台计算好的选区字符数回写到当前标签。
    func updateSelectedCharacterCount(_ count: Int) {
        // 防御外部误调用，状态栏不接受负数。
        let safeCount = max(0, count)
        // 相同结果不触发无意义的 SwiftUI 刷新。
        guard writingStatistics.selectedCharacterCount != safeCount else { return }
        // 保留已完成的全文统计，只替换当前选区结果。
        writingStatistics = WritingStatistics(
            characterCount: writingStatistics.characterCount,
            lineCount: writingStatistics.lineCount,
            selectedCharacterCount: safeCount
        )
    }

    // 合并连续输入后在后台统计当前标签全文，只接受最新代次。
    private func scheduleWritingStatistics(after delay: Duration) {
        // 新正文或标签切换先取消旧统计等待。
        writingStatisticsTask?.cancel()
        // 每次请求推进独立代次。
        writingStatisticsGeneration &+= 1
        // 捕获代次供主线程回写前核对。
        let generation = writingStatisticsGeneration
        // 后台标签保留最近结果，激活时再为最新正文补算。
        guard isPreviewActive else { return }
        // String 写时复制只捕获当前正文，不在主线程遍历字符。
        let source = text
        // 外层任务负责节流、取消传播和最新结果回写。
        writingStatisticsTask = Task { [weak self] in
            do {
                // 等待连续输入稳定。
                try await ContinuousClock().sleep(for: delay)
            } catch {
                // 新输入或标签切换取消属于正常路径。
                return
            }
            // 取消后不再创建全文统计任务。
            guard !Task.isCancelled else { return }
            // 字符和行扫描进入 utility 后台任务，避免影响输入响应。
            let calculationTask = Task.detached(priority: .utility) {
                // 选区由原生编辑器独立计算；全文扫描在任务取消时返回 nil。
                WritingStatisticsSupport.calculateIfNotCancelled(in: source)
            }
            // 外层取消时显式传播给 detached 任务并丢弃其结果。
            let result = await withTaskCancellationHandler {
                // 正常路径等待纯统计完成。
                await calculationTask.value
            } onCancel: {
                // 将取消传给周期检查状态的全文扫描，使旧快照尽快释放。
                calculationTask.cancel()
            }
            // 仅同一标签最新代次可以更新状态栏。
            guard !Task.isCancelled,
                let self,
                let result,
                self.writingStatisticsGeneration == generation
            else { return }
            // 保留原生选区的最新结果，全文任务不能把它重置成零。
            self.writingStatistics = WritingStatistics(
                characterCount: result.characterCount,
                lineCount: result.lineCount,
                selectedCharacterCount: self.writingStatistics.selectedCharacterCount
            )
        }
    }

    // 将当前标签完整正文写入自己的恢复草稿。
    @discardableResult
    func ensureRecoverableDraft() -> Bool {
        do {
            // 已命名按路径、未命名按 UUID 保存独立草稿。
            try documentStore.saveDraft(
                text,
                for: currentFileURL,
                untitledID: currentFileURL == nil ? id : nil,
                encoding: currentEncoding,
                includesByteOrderMark: includesByteOrderMark,
                baselineContentDigest: externalFileSnapshot?.contentDigest
            )
            // 同步写入成功证明当前正文已有有效恢复入口。
            hasUnresolvedDraftRecoveryFailure = false
            // 明确反馈草稿已经安全落盘。
            status = "已自动保存草稿"
            // 调用方可以安全切换或关闭。
            return true
        } catch {
            // 失败时绝不伪装成已保存。
            status = "草稿保存失败：\(error.localizedDescription)"
            // 调用方默认阻止无提示丢失。
            return false
        }
    }

    // 应用退出前同步当前标签最后一次等待中的输入。
    @discardableResult
    func flushDraftIfNeeded() -> Bool {
        // 干净标签无需制造草稿。
        guard isDirty else { return true }
        // 取消等待中的草稿计时器。
        draftTimer?.invalidate()
        // 停止旧后台任务回写状态；存储层时间屏障会防止其覆盖同步新草稿。
        draftWriteTask?.cancel()
        // 立即保存当前标签恢复副本。
        return ensureRecoverableDraft()
    }

    // 兼容现有顶部新建按钮，实际由工作区追加标签。
    func newDocument() {
        // 工作区不存在时保持当前文档不变。
        workspace?.newDocument()
    }

    // 兼容现有顶部打开按钮，实际由工作区创建或激活标签。
    func openDocument() {
        // 文件面板由工作区统一管理多选。
        workspace?.openDocument()
    }

    // 兼容拖放和最近文件入口。
    func openDocument(at url: URL) {
        // 重复路径由工作区直接激活已有标签。
        workspace?.openDocument(at: url)
    }

    // 有真实路径时直接保存，否则进入另存为。
    func saveDocument() {
        // 忽略返回值但保留状态反馈。
        _ = saveDocumentIfPossible()
    }

    // 供工作区关闭确认判断保存是否真正完成。
    @discardableResult
    func saveDocumentIfPossible() -> Bool {
        // 未命名标签必须先选择真实文件地址。
        guard let destination = currentFileURL else {
            return saveDocumentAsIfPossible()
        }
        // 正式入口始终使用系统文件协调器。
        return saveDocument(to: destination)
    }

    // 测试可在首次预检后、协调写入复核前稳定模拟另一个编辑器保存。
    @discardableResult
    func saveDocumentIfPossible(
        beforeCoordinatedCommitForTesting hook: (() throws -> Void)?,
        usesSystemFileCoordinatorForTesting: Bool
    ) -> Bool {
        // 未命名标签必须先选择真实文件地址。
        guard let destination = currentFileURL else {
            return saveDocumentAsIfPossible()
        }
        // 测试入口把协调策略显式传给统一保存实现，生产入口不读取该参数。
        return saveDocument(
            to: destination,
            usesSystemFileCoordinator: usesSystemFileCoordinatorForTesting,
            beforeCoordinatedCommit: hook
        )
    }

    // 让用户为当前标签选择 Markdown 文件。
    func saveDocumentAs() {
        // 忽略返回值但保留状态反馈。
        _ = saveDocumentAsIfPossible()
    }

    // 返回用户是否完成另存为，供关闭流程避免误关。
    @discardableResult
    func saveDocumentAsIfPossible() -> Bool {
        // 创建系统保存面板。
        let panel = NSSavePanel()
        // 使用当前标签名作为默认文件名。
        panel.nameFieldStringValue = filename
        // 限定 Markdown 或纯文本类型。
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        // 取消时不修改标签状态。
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        // 工作区已有同一路径标签时默认阻止产生重复身份。
        guard workspace?.canAdoptFileURL(destination, for: self) ?? true else {
            // 明确说明冲突原因。
            status = "另存为取消：该文件已在其他标签打开"
            // 冲突不写磁盘。
            return false
        }
        // 执行统一原子保存。
        return saveDocument(to: destination)
    }

    // 按需检查当前已命名文档是否发生外部变化。
    @discardableResult
    func checkForExternalChanges() -> ExternalDocumentChangeState {
        // 未命名标签没有磁盘文件需要比较。
        guard let currentFileURL else {
            // 同步发布不监控状态。
            externalChangeState = .notMonitored
            // 返回当前结论供调用方分支。
            return externalChangeState
        }
        // 使用可信原始字节摘要检查当前磁盘版本。
        let inspection = ExternalChangeSupport.inspect(
            baseline: externalFileSnapshot,
            at: currentFileURL
        )
        // 发布检查结论供界面显示解决动作。
        externalChangeState = inspection.state
        // 内容未变化时采用当前快照，刷新无意义的 touch 元数据。
        if inspection.state == .unchanged, let currentSnapshot = inspection.currentSnapshot {
            // 摘要相同，因此更新快照不会改变保存语义。
            externalFileSnapshot = currentSnapshot
        }
        // 为非冲突检查保留原有编辑或保存状态文本。
        switch inspection.state {
        case .notMonitored, .unchanged:
            // 正常状态不抢占其他反馈。
            break
        case .modified:
            // dirty 与干净文档分别提示覆盖风险和安全重载路径。
            status =
                isDirty
                ? "检测到外部修改：当前编辑已保护，请重载或明确覆盖"
                : "磁盘文件已更新，可安全重新载入"
        case .deleted:
            // 删除后普通保存会被阻止，避免无提示重新创建。
            status = "磁盘文件已删除，请另存为或明确重新创建"
        case let .unreadable(reason):
            // 不可读时展示支撑层原因并保守阻止保存。
            status = "无法核对磁盘文件：\(reason)"
        }
        // 返回稳定模型状态供无 UI 测试和上层交互使用。
        return externalChangeState
    }

    // 只在当前没有未保存编辑时采用磁盘新版本。
    @discardableResult
    func reloadFromDiskIfSafe() -> Bool {
        // dirty 文档不能由后台事件静默丢弃内存正文。
        guard !isDirty else {
            // 明确说明需要用户选择冲突处理方式。
            status = "当前有未保存编辑，不能自动重载磁盘版本"
            // 返回 false 供 UI 保持冲突提示。
            return false
        }
        // 干净文档可安全采用磁盘版本。
        return reloadFromDisk(discardingChanges: false)
    }

    // 供用户明确选择“放弃当前编辑并重载”时调用。
    @discardableResult
    func reloadFromDiskDiscardingChanges() -> Bool {
        // 方法名明确表达会丢弃内存编辑，内部执行统一重载流程。
        reloadFromDisk(discardingChanges: true)
    }

    // 供用户明确选择“覆盖磁盘版本”时绕过一次普通冲突检查。
    @discardableResult
    func overwriteExternalChanges() -> Bool {
        // 正式明确覆盖仍必须进入系统文件协调器。
        overwriteExternalChanges(usesSystemFileCoordinatorForTesting: true)
    }

    // 测试可绕过受限宿主的文件协调服务，但仍执行同一覆盖写入访问器。
    @discardableResult
    func overwriteExternalChanges(
        usesSystemFileCoordinatorForTesting: Bool
    ) -> Bool {
        // 未命名文档仍应走另存为，不能绕过目标选择。
        guard let currentFileURL else {
            // 保持原有另存为行为。
            return saveDocumentAsIfPossible()
        }
        // 明确动作只跳过本次预检，成功后立即刷新可信基线。
        return saveDocument(
            to: currentFileURL,
            allowsExternalOverwrite: true,
            usesSystemFileCoordinator: usesSystemFileCoordinatorForTesting
        )
    }

    // 从当前真实路径重新读取正文、格式和精确快照。
    private func reloadFromDisk(discardingChanges: Bool) -> Bool {
        // 未命名标签没有可重载来源。
        guard let currentFileURL else {
            // 状态栏给出明确原因。
            status = "当前文档尚未保存，无法从磁盘重载"
            // 不修改正文。
            return false
        }
        // 非明确丢弃流程再次防御 dirty 竞态。
        guard discardingChanges || !isDirty else {
            // 输入可能在检查后到重载前发生，必须保守停止。
            status = "重载已取消：当前出现未保存编辑"
            // 保留内存正文。
            return false
        }

        do {
            // 同一次稳定读取获得无损正文和可信快照。
            let diskRead = try TextFileIO.readWithSnapshot(from: currentFileURL)
            // 整体替换期间抑制输入 dirty、草稿和预览副作用。
            isReplacingDocument = true
            // 采用磁盘当前正文。
            text = diskRead.content.text
            // 整体替换完成后恢复正常输入观察。
            isReplacingDocument = false
            // 后续原地保存沿用磁盘实际编码。
            currentEncoding = diskRead.content.encoding
            // 后续原地保存沿用磁盘 BOM 策略。
            includesByteOrderMark = diskRead.content.includesByteOrderMark
            // 刷新正文、路径和格式干净基线。
            saveState.markSaved(
                text: diskRead.content.text,
                fileURL: currentFileURL,
                encoding: diskRead.content.encoding,
                includesByteOrderMark: diskRead.content.includesByteOrderMark
            )
            // 用户明确采用磁盘版本后，旧草稿恢复失败不再阻止干净状态。
            hasUnresolvedDraftRecoveryFailure = false
            // 发布干净状态。
            isDirty = false
            // 采用与本次正文严格匹配的磁盘快照。
            externalFileSnapshot = diskRead.snapshot
            // 重载完成后外部状态回到未变化。
            externalChangeState = .unchanged
            // 取消可能等待写入的旧草稿定时器。
            draftTimer?.invalidate()
            // 取消旧后台草稿状态回写，删除屏障会拦截其过期落盘。
            draftWriteTask?.cancel()
            // 已明确采用磁盘版本，清理这个路径的恢复草稿。
            try? documentStore.removeDraft(for: currentFileURL)
            // 立即刷新预览，不等待下一次输入。
            schedulePreview(after: .zero)
            // 整体换文没有触发 contentChanged，先清除旧选区统计。
            updateSelectedCharacterCount(0)
            // 取消旧正文统计、推进代次并立即为磁盘新正文重新计算。
            scheduleWritingStatistics(after: .zero)
            // 告知用户磁盘版本已安全采用。
            status = discardingChanges ? "已放弃当前编辑并重载磁盘版本" : "已重新载入磁盘版本"
            // 返回重载成功。
            return true
        } catch {
            // 读取失败时保留内存正文和 dirty 状态。
            externalChangeState =
                FileManager.default.fileExists(atPath: currentFileURL.path)
                ? .unreadable(error.localizedDescription)
                : .deleted
            // 展示失败原因供用户改用另存为。
            status = "重载失败：\(error.localizedDescription)"
            // 返回失败，调用方不得假设冲突已解决。
            return false
        }
    }

    // 保存预检区分真正写入、无须写入和被冲突阻止三种结果。
    private enum SavePreflightResult {
        // 磁盘仍等于基线，可以执行原子写入。
        case proceed
        // 干净文档已采用外部新版本，本次无需再次写盘。
        case satisfiedWithoutWrite
        // 冲突或不可读状态阻止普通保存。
        case blocked
    }

    // 原地保存前按需检查外部版本并保护 dirty 草稿。
    private func prepareForRegularSave(to destination: URL) -> SavePreflightResult {
        // 另存为目标由系统面板负责覆盖确认，不复用当前文件基线。
        guard currentFileURL?.standardizedFileURL == destination.standardizedFileURL else { return .proceed }
        // 执行一次明确触发的磁盘检查，不启动持续轮询。
        let state = checkForExternalChanges()
        // 未变化时可继续原子保存。
        guard state.blocksRegularSave else { return .proceed }
        // 干净文件检测到外部修改时直接安全重载，绝不写回旧内容。
        if state == .modified, !isDirty, reloadFromDiskIfSafe() {
            // 当前内存已与磁盘一致，本次保存目标已满足。
            return .satisfiedWithoutWrite
        }
        // dirty 冲突先同步恢复草稿，避免后续解决过程丢失当前编辑。
        reportBlockedSave(for: state)
        // 普通保存不得继续写盘。
        return .blocked
    }

    // 保存预检或承诺点复核发现冲突时统一保护正文并更新可操作状态。
    @discardableResult
    private func reportBlockedSave(for state: ExternalDocumentChangeState) -> Bool {
        // 承诺点才发现冲突时也必须发布最新状态供界面显示处理入口。
        externalChangeState = state
        // dirty 冲突先同步恢复草稿，避免后续解决过程丢失当前编辑。
        let draftIsSafe = isDirty ? ensureRecoverableDraft() : true
        // 草稿结果不能掩盖外部冲突结论。
        switch state {
        case .modified:
            // 明确保留两份内容，等待用户选择重载或覆盖。
            status =
                draftIsSafe
                ? "保存已阻止：磁盘有外部修改，当前编辑已保留为草稿"
                : "保存已阻止：磁盘有外部修改，且草稿保存失败"
        case .deleted:
            // 删除后不自动重新创建，等待明确动作。
            status =
                draftIsSafe
                ? "保存已阻止：磁盘文件已删除，当前编辑已保留为草稿"
                : "保存已阻止：磁盘文件已删除，且草稿保存失败"
        case let .unreadable(reason):
            // 无法验证时默认保护磁盘现状。
            status =
                draftIsSafe
                ? "保存已阻止：无法核对磁盘文件（\(reason)），当前编辑已保留为草稿"
                : "保存已阻止：无法核对磁盘文件（\(reason)），且草稿保存失败"
        case .notMonitored, .unchanged:
            // 调用方只应传入阻止保存的状态，防御异常时仍保持不写盘。
            break
        }
        // 冲突路径统一向保存调用方报告失败。
        return false
    }

    // 将当前标签正文原子保存到指定地址。
    @discardableResult
    private func saveDocument(
        to destination: URL,
        allowsExternalOverwrite: Bool = false,
        usesSystemFileCoordinator: Bool = true,
        beforeCoordinatedCommit: (() throws -> Void)? = nil
    ) -> Bool {
        // 普通原地保存必须先通过外部版本保护。
        if !allowsExternalOverwrite {
            // 区分需要写盘、已经安全重载和被阻止三种情况。
            switch prepareForRegularSave(to: destination) {
            case .proceed:
                // 继续执行下方原子写入。
                break
            case .satisfiedWithoutWrite:
                // 干净文档已同步外部版本，可视为保存目标完成。
                return true
            case .blocked:
                // 冲突时正文、dirty 和磁盘均保持不变。
                return false
            }
        }
        // 记住保存前草稿身份。
        let previousURL = currentFileURL
        // 只有普通原地保存必须匹配当前基线；另存为已由系统面板确认目标。
        let requiresMatchingBaseline =
            !allowsExternalOverwrite
            && previousURL?.standardizedFileURL == destination.standardizedFileURL
        // 捕获本次正文，协调访问器内不再读取可变模型状态。
        let textToWrite = text
        // 捕获来源编码，确保承诺点前后使用同一保存格式。
        let encodingToWrite = currentEncoding
        // 捕获 BOM 策略，避免事务中途改变最终字节。
        let includesBOMToWrite = includesByteOrderMark
        do {
            // 系统协调写区在最终替换前重新核对同一内容基线。
            let writtenSnapshot = try ExternalChangeSupport.coordinatedWrite(
                at: destination,
                baseline: externalFileSnapshot,
                allowsOverwrite: !requiresMatchingBaseline,
                usesSystemFileCoordinator: usesSystemFileCoordinator,
                beforeCommit: beforeCoordinatedCommit
            ) { coordinatedURL in
                // 按捕获的编码和 BOM 原子写入，并获取实际字节对应的新基线。
                try TextFileIO.saveWithSnapshot(
                    textToWrite,
                    to: coordinatedURL,
                    encoding: encodingToWrite,
                    includeByteOrderMark: includesBOMToWrite
                )
            }
            // 保存成功后采用规范化真实地址。
            currentFileURL = destination.standardizedFileURL
            // 标签标题同步真实文件名。
            filename = destination.lastPathComponent
            // 刷新完整磁盘快照。
            saveState.markSaved(
                text: text,
                fileURL: destination,
                encoding: currentEncoding,
                includesByteOrderMark: includesByteOrderMark
            )
            // 正文成功写入真实文件后，旧恢复失败已经由明确保存解决。
            hasUnresolvedDraftRecoveryFailure = false
            // 磁盘已经追平当前正文。
            isDirty = false
            // 保存实际写入字节对应的指纹供下一次冲突检查使用。
            externalFileSnapshot = writtenSnapshot
            // 成功保存后磁盘与内存基线一致。
            externalChangeState = .unchanged
            // 取消尚未触发的自动草稿计时器。
            draftTimer?.invalidate()
            // 取消旧后台草稿状态回写，后续删除会建立时间屏障。
            draftWriteTask?.cancel()
            // 清理保存前精确草稿；未命名必须携带 UUID。
            try? documentStore.removeDraft(
                for: previousURL,
                untitledID: previousURL == nil ? id : nil
            )
            // 清理目标路径可能残留的同内容草稿。
            try? documentStore.removeDraft(for: destination)
            // 最近文件索引属于保存后的辅助元数据，失败不得反转已经落盘的成功结果。
            let recentDocumentWasUpdated: Bool
            // 单独隔离可能失败的索引写入，避免落入下方真实保存失败分支并重新制造草稿。
            do {
                // 使用默认存储实现或测试注入闭包更新最近文件顺序。
                try recordRecentDocument(destination)
                // 记录辅助索引已经同步完成。
                recentDocumentWasUpdated = true
            } catch {
                // 文件正文已经成功落盘，仅把辅助索引失败留给状态栏反馈。
                recentDocumentWasUpdated = false
            }
            // 通知工作区刷新会话路径和最近列表。
            workspace?.documentDidSave(self)
            // 索引失败时仍明确确认文件安全落盘，同时提示最近文件列表可能未更新。
            status = recentDocumentWasUpdated ? "文件已保存" : "文件已保存，最近文件更新失败"
            // 返回保存成功。
            return true
        } catch ExternalChangeSupportError.changedBeforeWrite(let state) {
            // 承诺点新冲突不得进入普通失败分支或覆盖外部版本。
            return reportBlockedSave(for: state)
        } catch {
            // 尽力补写恢复草稿，失败仍保留明确状态。
            let draftIsSafe = ensureRecoverableDraft()
            // 写入失败时正文和 dirty 留在内存，并保留草稿结果。
            status =
                draftIsSafe
                ? "保存失败：\(error.localizedDescription)，当前编辑已保留为草稿"
                : "保存失败：\(error.localizedDescription)，且草稿保存失败"
            // 调用方不得关闭这个 dirty 标签。
            return false
        }
    }

    // 导出当前标签为完整 HTML 文件。
    func exportHTML() {
        // 保存面板只在主线程选择目标，不执行图片读取或 Base64 编码。
        guard
            let destination = ExportSupport.chooseHTMLDestination(
                suggestedFilename: documentTitle
            )
        else {
            // 用户取消时保持原状态，不创建文件或启动后台任务。
            return
        }
        // 保存旧请求句柄，新请求必须等它完全结束后才能提交同一目标。
        let previousExportTask = exportTask
        // 新导出开始前停止同一标签尚未完成的旧请求。
        previousExportTask?.cancel()
        // String 写时复制提供本次导出的稳定正文快照。
        let capturedText = text
        // 标题和默认文件名使用用户确认时的文档名称。
        let capturedTitle = documentTitle
        // 本地图只允许相对于本次文档位置解析。
        let capturedDocumentURL = currentFileURL
        // 立即反馈当前任务已经进入后台处理。
        status = "正在导出离线 HTML…"

        // 主 actor 任务先串行化同一标签的导出，再等待后台结果并更新状态。
        exportTask = Task { [weak self] in
            // 被取消的旧请求必须完全退出，确保它不能晚于当前请求覆盖相同目标。
            if let previousExportTask {
                // 等待只发生在协作式任务上，不阻塞主线程事件循环。
                await previousExportTask.value
            }
            // 排队期间又被更新请求替换时不再创建新的后台写入。
            guard !Task.isCancelled else { return }
            // detached 任务负责全部解析、图片读取和磁盘写入。
            let writeTask = Task.detached(priority: .userInitiated) { () -> BackgroundHTMLExportResult in
                do {
                    // 纯写入 API 会验证全部本地图并在成功后原子替换目标。
                    try ExportSupport.writePortableHTML(
                        markdown: capturedText,
                        title: capturedTitle,
                        documentURL: capturedDocumentURL,
                        to: destination
                    )
                    // 只有完整写入结束才返回成功。
                    return .success
                } catch is CancellationError {
                    // 标签关闭或新请求替换当前任务时不展示错误。
                    return .cancelled
                } catch {
                    // 后台只回传可直接展示的本地化说明。
                    return .failure(error.localizedDescription)
                }
            }
            // 外层任务取消时显式传播给不继承取消状态的 detached 写入任务。
            let result = await withTaskCancellationHandler {
                // 正常路径等待后台导出结束。
                await writeTask.value
            } onCancel: {
                // 新导出或标签关闭会阻止旧请求继续写入。
                writeTask.cancel()
            }
            // 被替换的请求不能覆盖当前标签的新状态。
            guard !Task.isCancelled, let self else { return }
            // 按真实结果给出不会误导用户的数据状态。
            switch result {
            case .success:
                // 文件已经完成原子写入，可以展示实际名称。
                self.status = "已导出离线 HTML：\(destination.lastPathComponent)"
            case .cancelled:
                // 正常取消不改变当前状态栏。
                return
            case let .failure(message):
                // 导出失败不影响 Markdown 正文和恢复草稿。
                self.status = "导出失败：\(message)"
            }
        }
    }

    // 复制当前标签的公众号内联样式 HTML。
    func copyWechatHTML(template: WechatExportTemplate = .simple) {
        // 同时写入 HTML 和 Markdown 纯文本回退。
        let copied = ExportSupport.copyWechatHTML(markdown: text, template: template)
        // 明确展示当前标签复制结果。
        status = copied ? "已复制公众号格式（\(template.displayName)）" : "复制失败"
    }

    // 关闭标签前停止它自己的延迟任务。
    func prepareForClose() {
        // 停止草稿计时器，避免关闭后重复写入。
        draftTimer?.invalidate()
        // 停止后台草稿任务回写已经关闭的模型状态。
        draftWriteTask?.cancel()
        // 停止预览任务，避免无界面回写。
        previewTask?.cancel()
        // 停止全文统计任务，关闭标签后不再发布状态栏结果。
        writingStatisticsTask?.cancel()
        // 停止尚未完成的 HTML 图片读取和目标写入。
        exportTask?.cancel()
    }

    // 当前文档标题去掉扩展名供 HTML 使用。
    private var documentTitle: String {
        // URL API 正确处理包含多个点的文件名。
        let title = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        // 空标题使用稳定默认值。
        return title.isEmpty ? "未命名" : title
    }
}
