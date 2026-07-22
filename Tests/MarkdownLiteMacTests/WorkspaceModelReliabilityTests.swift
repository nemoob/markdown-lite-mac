import Foundation
import Testing

@testable import MarkdownLiteMac

// 验证工作区辅助索引失败和失效原文件关闭时仍能保住可触达正文。
@Suite("工作区恢复链可靠性")
struct WorkspaceModelReliabilityTests {
    // 为最近文件索引注入可识别的确定性失败。
    private enum InjectedFailure: Error {
        // 模拟文件已经打开后辅助索引无法写入。
        case recentDocumentIndex
    }

    // 最近文件失败不得把已经打开的标签误报为打开失败或漏存会话。
    @Test("打开成功后最近文件失败仍保留标签和会话")
    @MainActor
    func testRecentIndexFailureKeepsOpenedDocumentAndSession() throws {
        // 创建本次测试独享的真实文件和支撑数据目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建一条初始可见、随后失效的最近文件记录。
        let staleURL = root.appendingPathComponent("stale.md", isDirectory: false)
        // 创建本次需要成功打开的目标文件。
        let targetURL = root.appendingPathComponent("target.md", isDirectory: false)
        // 写入初始最近文件正文。
        try TextFileIO.save("旧文件", to: staleURL)
        // 写入目标文件正文。
        try TextFileIO.save("成功打开", to: targetURL)
        // 文档支撑层和会话层共享隔离目录。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 会话存储供测试直接读回最终标签状态。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // 预先写入一条最近文件，便于观察失败后刷新确实执行。
        try documentStore.recordRecentDocument(staleURL)
        // 注入只影响最近文件写入的工作区，真实文件打开和会话保存仍走生产实现。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: false,
            recordRecentDocument: { _ in throw InjectedFailure.recentDocumentIndex }
        )
        // 测试退出前停止所有标签的延迟预览和草稿任务。
        defer { workspace.documents.forEach { $0.prepareForClose() } }
        // 初始化刷新必须先展示预置最近文件。
        #expect(workspace.recentDocuments.map(\.fileURL) == [staleURL.standardizedFileURL])
        // 删除预置文件，让打开后的再次刷新产生可观察变化。
        try FileManager.default.removeItem(at: staleURL)

        // 通过正式工作区入口打开目标文件并触发注入失败。
        workspace.openDocument(at: targetURL)

        // 成功打开必须在初始未命名标签之后保留第二个标签。
        #expect(workspace.documents.count == 2)
        // 活动标签必须是已经读取成功的目标文件。
        let openedDocument = try #require(workspace.activeDocument)
        // 目标文件身份必须保持规范化路径。
        #expect(openedDocument.currentFileURL == targetURL.standardizedFileURL)
        // 目标正文必须已经进入可编辑模型。
        #expect(openedDocument.text == "成功打开")
        // 状态必须确认打开成功并只提示辅助索引失败。
        #expect(workspace.status == "文件已打开，最近文件更新失败")
        // 失败后仍应刷新菜单并移除已经失效的旧记录。
        #expect(workspace.recentDocuments.isEmpty)
        // 直接读回落盘会话，证明索引失败没有跳过持久化。
        let session = try #require(try sessionStore.load())
        // 会话必须包含成功打开的目标路径。
        #expect(session.documents.last?.fileURL == targetURL.standardizedFileURL)
        // 活动 UUID 必须指向成功打开的标签。
        #expect(session.activeDocumentID == openedDocument.id)
    }

    // 删除和不可读原文件不能再提供会制造孤儿路径草稿的关闭按钮。
    @Test("失效原文件关闭策略只允许另存为或取消")
    func testMissingOrUnreadableFileRequiresSaveAs() {
        // 已删除文件必须进入另存为专用策略。
        let deletedPolicy = WorkspaceDirtyClosePolicy.resolve(
            hasFileURL: true,
            externalState: .deleted
        )
        // 不可读文件也必须进入同一保守策略。
        let unreadablePolicy = WorkspaceDirtyClosePolicy.resolve(
            hasFileURL: true,
            externalState: .unreadable("权限不足")
        )
        // 两种失效状态都必须明确引导另存为。
        #expect(deletedPolicy == .saveAsOnly)
        #expect(unreadablePolicy == .saveAsOnly)
        // 首要按钮文案必须与实际动作一致。
        #expect(deletedPolicy.primaryButtonTitle == "另存为")
        // 生产关闭流程必须调用另存为而不是被保护层阻止的原地保存。
        #expect(deletedPolicy.usesSaveAs)
        // 失去原路径恢复入口后绝不能提供草稿关闭按钮。
        #expect(!deletedPolicy.allowsDraftClose)
        #expect(!unreadablePolicy.allowsDraftClose)
        // 文件仍存在时保留既有可恢复草稿关闭能力。
        #expect(
            WorkspaceDirtyClosePolicy.resolve(
                hasFileURL: true,
                externalState: .unchanged
            ).allowsDraftClose
        )
        // 未命名标签继续保持只能保存或取消的既有规则。
        #expect(
            WorkspaceDirtyClosePolicy.resolve(
                hasFileURL: false,
                externalState: .notMonitored
            ) == .saveOnly
        )
    }

    // 真实删除原文件后必须识别失效状态，同时保留当前标签正文。
    @Test("原文件删除后正文仍留在工作区")
    @MainActor
    func testDeletedNamedFileKeepsReachableEditorText() throws {
        // 创建本次恢复场景独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建能够建立可信打开基线的真实 Markdown 文件。
        let fileURL = root.appendingPathComponent("deleted-after-edit.md", isDirectory: false)
        // 写入打开时磁盘版本。
        try TextFileIO.save("磁盘版本", to: fileURL)
        // 创建隔离的文档和会话存储。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 保存可供读回的隔离会话。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // 关闭会话恢复，确保测试起点确定。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: false
        )
        // 测试退出前停止全部标签延迟任务。
        defer { workspace.documents.forEach { $0.prepareForClose() } }
        // 通过正式入口打开已命名文件。
        workspace.openDocument(at: fileURL)
        // 取得刚打开的活动标签。
        let document = try #require(workspace.activeDocument)
        // 写入尚未保存且必须保护的内存正文。
        document.text = "不能丢失的当前编辑"
        // 模拟外部进程删除原文件。
        try FileManager.default.removeItem(at: fileURL)

        // 关闭前使用生产检查入口刷新真实磁盘状态。
        let state = document.checkForExternalChanges()
        // 删除必须被稳定识别，不能继续假设原路径可恢复。
        #expect(state == .deleted)
        // 将真实检查结果交给生产关闭策略。
        let policy = WorkspaceDirtyClosePolicy.resolve(
            hasFileURL: document.currentFileURL != nil,
            externalState: state
        )
        // 关闭对话框只能提供另存为或取消。
        #expect(policy == .saveAsOnly)
        #expect(!policy.allowsDraftClose)
        // 未执行另存为前标签仍必须留在工作区。
        #expect(workspace.documents.contains { $0.id == document.id })
        // 当前正文必须继续可由活动标签访问。
        #expect(workspace.activeDocument?.text == "不能丢失的当前编辑")
        // dirty 标记必须保留，避免界面误认为正文已安全写盘。
        #expect(document.isDirty)
    }

    // 工作区必须串联会话与草稿上一代恢复，并把两种来源分别反馈给用户。
    @Test("上一代会话与草稿可完整恢复")
    @MainActor
    func testPreviousSessionReconnectsPreviousUntitledDraft() throws {
        // 创建本次跨存储恢复独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 会话和草稿共享与生产一致的产品根目录。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 创建可在初始化后直接读回的会话存储。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // 上一代会话使用稳定未命名标签 UUID。
        let recoveredID = UUID()
        // 当前代会话使用不同 UUID，证明恢复确实来自 previous。
        let replacedID = UUID()
        // 第一份草稿将在下一次保存后成为上一代。
        _ = try documentStore.saveDraft("上一代未命名正文", for: nil, untitledID: recoveredID)
        // 第二份草稿建立 current/previous 双代。
        _ = try documentStore.saveDraft("即将损坏的当前正文", for: nil, untitledID: recoveredID)
        // 复用生产键定位 current 草稿。
        let draftKey = try documentStore.draftKey(for: nil, untitledID: recoveredID)
        // current 草稿保持 v0.7 兼容路径。
        let currentDraftURL =
            root
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent("\(draftKey).json", isDirectory: false)
        // 注入损坏 current，迫使标签恢复使用 previous。
        try Data("{".utf8).write(to: currentDraftURL, options: [.atomic])
        // 构造应当成为上一代的完整会话。
        let previousSession = WorkspaceSessionState(
            documents: [WorkspaceSessionDocument(id: recoveredID, fileURL: nil)],
            activeDocumentID: recoveredID
        )
        // 构造随后会被损坏的当前会话。
        let currentSession = WorkspaceSessionState(
            documents: [WorkspaceSessionDocument(id: replacedID, fileURL: nil)],
            activeDocumentID: replacedID
        )
        // 首次保存建立会话 current。
        try sessionStore.save(previousSession)
        // 第二次保存将目标会话晋升为 previous。
        try sessionStore.save(currentSession)
        // 定位会话 current 固定路径。
        let currentSessionURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 注入损坏会话 current，迫使工作区恢复 previous。
        try Data("{".utf8).write(to: currentSessionURL, options: [.atomic])

        // 使用正式初始化入口串联会话和标签草稿恢复。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 测试结束前停止全部标签的延迟任务。
        defer { workspace.documents.forEach { $0.prepareForClose() } }
        // 上一代会话只包含一个目标标签。
        #expect(workspace.documents.count == 1)
        // 标签 UUID 必须保持 previous 中的稳定身份。
        #expect(workspace.activeDocumentID == recoveredID)
        // 未命名正文必须继续由同 UUID 的上一代草稿恢复。
        #expect(workspace.activeDocument?.text == "上一代未命名正文")
        // 标签级状态必须说明草稿来源。
        #expect(workspace.activeDocument?.status == "已从上一代草稿恢复")
        // 工作区级状态必须说明会话来源。
        #expect(workspace.status == "已从上一代会话恢复 1 个标签")
        // 恢复完成后当前会话必须被原子修复为规范化 previous 状态。
        #expect(try sessionStore.load() == previousSession)
    }

    // 双代会话都损坏时只能创建内存编辑状态，不能把空会话覆盖到磁盘。
    @Test("双代会话损坏时不覆盖恢复证据")
    @MainActor
    func testCorruptSessionGenerationsRemainUntouched() throws {
        // 创建本次故障注入独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建隔离文档与会话存储。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 会话存储用于建立双代和触发真实恢复。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // 连续两份有效状态先建立双代布局。
        let firstID = UUID()
        // 第二份使用不同身份，确保两个 JSON 都真实存在。
        let secondID = UUID()
        // 首次保存只建立 current。
        try sessionStore.save(
            WorkspaceSessionState(
                documents: [WorkspaceSessionDocument(id: firstID, fileURL: nil)],
                activeDocumentID: firstID
            )
        )
        // 第二次保存完成 previous 轮换。
        try sessionStore.save(
            WorkspaceSessionState(
                documents: [WorkspaceSessionDocument(id: secondID, fileURL: nil)],
                activeDocumentID: secondID
            )
        )
        // 定位固定会话双代文件。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // previous 与 current 位于同一产品目录。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 两代使用不同损坏字节，便于精确验证没有写回。
        let currentEvidence = Data("{损坏-current-session".utf8)
        // previous 单独保存自己的损坏证据。
        let previousEvidence = Data("{损坏-previous-session".utf8)
        // 破坏当前会话。
        try currentEvidence.write(to: currentURL, options: [.atomic])
        // 同时破坏上一代会话。
        try previousEvidence.write(to: previousURL, options: [.atomic])

        // 正式初始化必须回退到纯内存可编辑状态。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 测试结束前停止内存标签的延迟任务。
        defer { workspace.documents.forEach { $0.prepareForClose() } }
        // 应用仍需保留一个可编辑标签而不是崩溃。
        #expect(workspace.documents.count == 1)
        // 工作区状态必须明确提示会话恢复失败。
        #expect(workspace.status.hasPrefix("会话恢复失败，已新建标签"))
        // current 损坏现场不得被空会话覆盖。
        #expect(try Data(contentsOf: currentURL) == currentEvidence)
        // previous 损坏现场也必须逐字节保留。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
        // 用户继续新建标签会再次尝试会话持久化。
        workspace.newDocument()
        // 失败状态不得被“已新建标签”成功文案立即覆盖。
        #expect(workspace.status.hasPrefix("会话保存失败"))
        // 重复持久化失败后 current 证据仍保持原样。
        #expect(try Data(contentsOf: currentURL) == currentEvidence)
        // previous 证据也不能因继续操作被轮换覆盖。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
        // 退出保护必须把会话失败反馈给应用生命周期。
        #expect(!workspace.flushDraftsAndSession())
        // flush 之后全局失败状态仍必须可见。
        #expect(workspace.status.hasPrefix("会话保存失败"))
    }

    // current 缺失且唯一 previous 损坏时，工作区任何保存都必须保留证据并阻止退出。
    @Test("仅剩损坏上一代会话时持续阻止覆盖")
    @MainActor
    func testPreviousOnlyCorruptSessionBlocksWorkspacePersistence() throws {
        // 创建本次 previous-only 故障独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建隔离文档与会话存储。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 正式会话存储用于建立双代和重复持久化。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // 两个不同 UUID 建立真实 current/previous 布局。
        let firstID = UUID()
        // 第二个 UUID 只负责触发轮换。
        let secondID = UUID()
        // 首次保存建立 current。
        try sessionStore.save(
            WorkspaceSessionState(
                documents: [WorkspaceSessionDocument(id: firstID, fileURL: nil)],
                activeDocumentID: firstID
            )
        )
        // 第二次保存建立 previous。
        try sessionStore.save(
            WorkspaceSessionState(
                documents: [WorkspaceSessionDocument(id: secondID, fileURL: nil)],
                activeDocumentID: secondID
            )
        )
        // 定位固定会话双代地址。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // previous 是本测试唯一需要保留的恢复证据。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 删除 current 模拟原子替换之外的中断状态。
        try FileManager.default.removeItem(at: currentURL)
        // 注入可精确核对的唯一 previous 损坏字节。
        let previousEvidence = Data("{唯一损坏-previous-session".utf8)
        // 破坏唯一上一代。
        try previousEvidence.write(to: previousURL, options: [.atomic])

        // 正式初始化会因 previous 无法解码而进入纯内存安全状态。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 测试结束前停止全部标签延迟任务。
        defer { workspace.documents.forEach { $0.prepareForClose() } }
        // 应用仍提供一个可编辑标签。
        #expect(workspace.documents.count == 1)
        // 初始化必须明确提示会话恢复失败。
        #expect(workspace.status.hasPrefix("会话恢复失败，已新建标签"))
        // 初始化不能补写新 current。
        #expect(!FileManager.default.fileExists(atPath: currentURL.path))
        // previous 原始证据必须保持不变。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)

        // 新建标签再次触发正式 persistSession。
        workspace.newDocument()
        // 成功文案不得覆盖上一代验证失败。
        #expect(workspace.status.hasPrefix("会话保存失败"))
        // current 仍不得被创建。
        #expect(!FileManager.default.fileExists(atPath: currentURL.path))
        // previous 仍必须逐字节保留。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
        // 应用退出同步也必须失败，阻止 UUID 草稿失去会话映射。
        #expect(!workspace.flushDraftsAndSession())
        // flush 后不能改变 previous 证据。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
    }

    // 为每个测试创建唯一目录，避免并行执行时互相覆盖。
    private func makeTemporaryDirectory() throws -> URL {
        // 使用系统临时目录和随机 UUID 构造明确范围。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLite-WorkspaceReliability-\(UUID().uuidString)", isDirectory: true)
        // 创建目录供真实文件、草稿、最近索引和会话共同使用。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 返回调用方独占目录。
        return root
    }
}
