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

    // 首尾和相邻重排必须只改变数组顺序，不重建任何编辑器对象。
    @Test("标签首尾与相邻移动保留编辑状态")
    @MainActor
    func testTabMovesPreserveEditorIdentityAndState() throws {
        // 创建本次标签顺序测试独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 用四个真实恢复标签覆盖首尾和相邻路径。
        let fixture = try makeWorkspace(documentCount: 4, activeIndex: 1, at: root)
        // 测试退出前停止全部标签的延迟任务。
        defer { fixture.workspace.documents.forEach { $0.prepareForClose() } }
        // 保留初始对象引用，后续使用身份比较防止偷换模型。
        let originalDocuments = fixture.workspace.documents
        // 给活动标签写入尚未保存的可识别正文。
        originalDocuments[1].text = "必须跟随原对象的编辑"
        // 记录重排全程必须保持的活动 UUID。
        let activeID = fixture.workspace.activeDocumentID

        // 首标签移到 count 槽位后必须成为最后一项。
        #expect(
            fixture.workspace.moveDocument(
                id: originalDocuments[0].id,
                to: originalDocuments.count
            )
        )
        // 首到尾的期望顺序只使用原 UUID。
        #expect(
            fixture.workspace.documents.map(\.id) == [
                originalDocuments[1].id,
                originalDocuments[2].id,
                originalDocuments[3].id,
                originalDocuments[0].id,
            ]
        )
        // 活动标签向右移一位必须与相邻标签换序。
        #expect(fixture.workspace.moveActiveDocument(by: 1))
        // 右移后活动标签应位于原第三个标签之后。
        #expect(
            fixture.workspace.documents.map(\.id) == [
                originalDocuments[2].id,
                originalDocuments[1].id,
                originalDocuments[3].id,
                originalDocuments[0].id,
            ]
        )
        // 活动标签再向左移一位必须恢复前一顺序。
        #expect(fixture.workspace.moveActiveDocument(by: -1))
        // 末标签移到 0 槽位必须回到首位。
        #expect(fixture.workspace.moveDocument(id: originalDocuments[0].id, to: 0))
        // 再把当前末标签移到首位，留下与初始不同的最终持久化顺序。
        #expect(fixture.workspace.moveDocument(id: originalDocuments[3].id, to: 0))

        // 最终顺序必须精确反映所有首尾和相邻操作。
        let expectedOrder = [
            originalDocuments[3].id,
            originalDocuments[0].id,
            originalDocuments[1].id,
            originalDocuments[2].id,
        ]
        // 内存标签数组必须发布最终顺序。
        #expect(fixture.workspace.documents.map(\.id) == expectedOrder)
        // 每个位置都必须仍是初始 EditorModel 实例。
        #expect(fixture.workspace.documents[0] === originalDocuments[3])
        #expect(fixture.workspace.documents[1] === originalDocuments[0])
        #expect(fixture.workspace.documents[2] === originalDocuments[1])
        #expect(fixture.workspace.documents[3] === originalDocuments[2])
        // 重排不得改变活动 UUID。
        #expect(fixture.workspace.activeDocumentID == activeID)
        // dirty 状态必须跟随原编辑器对象。
        #expect(originalDocuments[1].isDirty)
        // 未保存正文必须逐字保留。
        #expect(originalDocuments[1].text == "必须跟随原对象的编辑")
        // 成功反馈不应被旧会话状态覆盖。
        #expect(fixture.workspace.status == "标签已移动")
        // 直接读回会话证明最终顺序已落盘。
        let session = try #require(try fixture.sessionStore.load())
        // 持久化 UUID 顺序必须与内存一致。
        #expect(session.documents.map(\.id) == expectedOrder)
        // 持久化活动 UUID 也必须保持不变。
        #expect(session.activeDocumentID == activeID)
    }

    // 无效、越界和原位操作必须在会话层之前返回。
    @Test("标签无效与原位移动不落盘")
    @MainActor
    func testInvalidAndNoOpTabMovesDoNotPersist() throws {
        // 创建可直接检查会话字节的独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 活动标签固定在首位，便于覆盖左边界。
        let fixture = try makeWorkspace(documentCount: 3, activeIndex: 0, at: root)
        // 测试退出前停止全部标签延迟任务。
        defer { fixture.workspace.documents.forEach { $0.prepareForClose() } }
        // 定位必须保持的 current 会话文件。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 定位用于识别意外写入的 previous 文件。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 保存操作前 current 的精确字节。
        let currentEvidence = try Data(contentsOf: currentURL)
        // 使用无效但可精确比较的字节捕获任何意外轮换。
        let previousEvidence = Data("原位移动不得写会话".utf8)
        // 在所有无效操作前安装 previous 写入哨兵。
        try previousEvidence.write(to: previousURL, options: [.atomic])
        // 保存原标签顺序供所有分支共享核对。
        let originalOrder = fixture.workspace.documents.map(\.id)
        // 保存原工作区状态，无操作不应改写反馈。
        let originalStatus = fixture.workspace.status

        // 不存在的 UUID 必须直接失败。
        #expect(!fixture.workspace.moveDocument(id: UUID(), to: 0))
        // 负槽位必须直接失败。
        #expect(!fixture.workspace.moveDocument(id: originalOrder[0], to: -1))
        // 超过 count 的槽位必须直接失败。
        #expect(!fixture.workspace.moveDocument(id: originalOrder[0], to: originalOrder.count + 1))
        // 首标签自身前槽位是原位。
        #expect(!fixture.workspace.moveDocument(id: originalOrder[0], to: 0))
        // 首标签自身后槽位也是原位。
        #expect(!fixture.workspace.moveDocument(id: originalOrder[0], to: 1))
        // 末标签自身前槽位是原位。
        #expect(!fixture.workspace.moveDocument(id: originalOrder[2], to: 2))
        // 末标签自身后 count 槽位也是原位。
        #expect(!fixture.workspace.moveDocument(id: originalOrder[2], to: 3))
        // 活动标签零偏移必须是原位。
        #expect(!fixture.workspace.moveActiveDocument(by: 0))
        // 首标签再向左移必须拒绝越界。
        #expect(!fixture.workspace.moveActiveDocument(by: -1))
        // 极大偏移必须安全失败而不溢出。
        #expect(!fixture.workspace.moveActiveDocument(by: Int.max))

        // 所有无操作完成后标签顺序必须不变。
        #expect(fixture.workspace.documents.map(\.id) == originalOrder)
        // 工作区状态不得产生伪成功或伪失败。
        #expect(fixture.workspace.status == originalStatus)
        // current 字节不变证明没有会话写入。
        #expect(try Data(contentsOf: currentURL) == currentEvidence)
        // previous 哨兵不变证明没有发生双代轮换。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
    }

    // 百标签重排必须保存完整 UUID 顺序并能跨启动恢复。
    @Test("100 标签重排可跨启动恢复")
    @MainActor
    func testHundredTabMovePersistsAcrossRestart() throws {
        // 创建本次大标签数测试独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 使用中间活动标签验证首标签移动不改变活动 UUID。
        let fixture = try makeWorkspace(documentCount: 100, activeIndex: 50, at: root)
        // 保存移动前稳定 UUID 顺序。
        let originalOrder = fixture.workspace.documents.map(\.id)
        // 保存跨启动必须恢复的活动 UUID。
        let activeID = fixture.workspace.activeDocumentID

        // 把首标签移到第 100 个插入槽，即数组末尾。
        #expect(fixture.workspace.moveDocument(id: originalOrder[0], to: 100))
        // 构造预期顺序，仅首元素移到末尾。
        let expectedOrder = Array(originalOrder.dropFirst()) + [originalOrder[0]]
        // 内存应立即发布全部 100 个标签的新顺序。
        #expect(fixture.workspace.documents.map(\.id) == expectedOrder)
        // 活动 UUID 不应因前方标签移动而改变。
        #expect(fixture.workspace.activeDocumentID == activeID)
        // 停止原工作区任务，模拟进程退出后的静止状态。
        fixture.workspace.documents.forEach { $0.prepareForClose() }

        // 使用同一隔离目录创建全新工作区。
        let restoredWorkspace = WorkspaceModel(
            documentStore: DocumentSupportStore(rootDirectory: root),
            sessionStore: WorkspaceSessionStore(rootDirectory: root),
            restoresSession: true
        )
        // 测试结束前停止新工作区全部延迟任务。
        defer { restoredWorkspace.documents.forEach { $0.prepareForClose() } }
        // 重启后必须恢复完整 100 标签顺序。
        #expect(restoredWorkspace.documents.map(\.id) == expectedOrder)
        // 重启后活动 UUID 必须与移动前相同。
        #expect(restoredWorkspace.activeDocumentID == activeID)
    }

    // 会话不能落盘时必须保留可见顺序和编辑内容，同时明确返回失败。
    @Test("标签移动会话保存失败可见")
    @MainActor
    func testTabMoveReportsSessionPersistenceFailure() throws {
        // 创建可注入双代会话失败的独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建三个有效标签并使中间标签保持活动。
        let fixture = try makeWorkspace(documentCount: 3, activeIndex: 1, at: root)
        // 测试退出前停止全部标签延迟任务。
        defer { fixture.workspace.documents.forEach { $0.prepareForClose() } }
        // 保留原编辑器对象供失败后身份核对。
        let originalDocuments = fixture.workspace.documents
        // 给活动对象写入未保存正文，验证失败不丢编辑。
        originalDocuments[1].text = "会话失败也不能丢失"
        // 定位生产 current 会话文件。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 定位生产 previous 会话文件。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // current 使用可精确核对的损坏字节。
        let currentEvidence = Data("{标签移动-current-损坏".utf8)
        // previous 使用不同字节阻止存储层安全修复 current。
        let previousEvidence = Data("{标签移动-previous-损坏".utf8)
        // 覆盖 current 制造确定性保存失败。
        try currentEvidence.write(to: currentURL, options: [.atomic])
        // 同时覆盖 previous，确保不存在可用恢复源。
        try previousEvidence.write(to: previousURL, options: [.atomic])
        // 保存失败前的活动 UUID。
        let activeID = fixture.workspace.activeDocumentID

        // 首标签移到末尾后会话保存必须失败并返回 false。
        #expect(!fixture.workspace.moveDocument(id: originalDocuments[0].id, to: 3))

        // 内存顺序仍保留用户已看到的拖拽结果。
        #expect(
            fixture.workspace.documents.map(\.id) == [
                originalDocuments[1].id,
                originalDocuments[2].id,
                originalDocuments[0].id,
            ]
        )
        // 失败后仍必须使用原始 EditorModel 实例。
        #expect(fixture.workspace.documents[0] === originalDocuments[1])
        #expect(fixture.workspace.documents[1] === originalDocuments[2])
        #expect(fixture.workspace.documents[2] === originalDocuments[0])
        // 活动 UUID 不得因落盘失败而切换。
        #expect(fixture.workspace.activeDocumentID == activeID)
        // dirty 状态与正文必须继续留在原对象中。
        #expect(originalDocuments[1].isDirty)
        #expect(originalDocuments[1].text == "会话失败也不能丢失")
        // 工作区必须发布会话保存失败而不是移动成功。
        #expect(fixture.workspace.status.hasPrefix("会话保存失败："))
        // current 损坏证据不得被新顺序覆盖。
        #expect(try Data(contentsOf: currentURL) == currentEvidence)
        // previous 损坏证据也必须逐字节保留。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
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

    // 空 current 可解码但没有标签时必须先回退 previous。
    @Test("空当前会话回退上一代")
    @MainActor
    func testEmptyCurrentSessionFallsBackToPrevious() throws {
        // 复用完整工作区夹具，current 只提供一个明确空数组。
        try assertSemanticCurrentFallsBackToPrevious { _ in
            // 空数组不能覆盖仍可恢复的上一代未命名标签。
            WorkspaceSessionState(documents: [], activeDocumentID: nil)
        }
    }

    // 重复 UUID 会让未命名草稿归属不确定，必须整体拒绝 current。
    @Test("重复 UUID 当前会话回退上一代")
    @MainActor
    func testDuplicateCurrentSessionIDsFallBackToPrevious() throws {
        // 复用完整工作区夹具并构造两个相同标签身份。
        try assertSemanticCurrentFallsBackToPrevious { _ in
            // 使用固定重复 UUID 让失败原因与 previous 身份完全独立。
            let duplicateID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
            // 两个描述竞争同一 UUID 时不能按数组顺序猜测草稿入口。
            return WorkspaceSessionState(
                documents: [
                    WorkspaceSessionDocument(id: duplicateID, fileURL: nil),
                    WorkspaceSessionDocument(id: duplicateID, fileURL: nil),
                ],
                activeDocumentID: duplicateID
            )
        }
    }

    // current 标签全部失效且没有草稿时必须继续尝试 previous。
    @Test("无可恢复描述的当前会话回退上一代")
    @MainActor
    func testUnrestorableCurrentSessionFallsBackToPrevious() throws {
        // 复用完整工作区夹具并把失效路径放在隔离目录内。
        try assertSemanticCurrentFallsBackToPrevious { root in
            // 唯一描述指向不存在且没有草稿的本地文件。
            let missingURL = root.appendingPathComponent("missing-current.md", isDirectory: false)
            // UUID 唯一且 JSON 有效，确保本例只验证实际 descriptor 可恢复性。
            let missingID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
            // 构造身份布局有效、但工作区无法恢复任何标签的 current。
            return WorkspaceSessionState(
                documents: [WorkspaceSessionDocument(id: missingID, fileURL: missingURL)],
                activeDocumentID: missingID
            )
        }
    }

    // 正常 current 仍应保持最高优先级，不能因新增语义回退错误采用 previous。
    @Test("有效当前会话优先于上一代")
    @MainActor
    func testValidCurrentSessionRemainsPreferred() throws {
        // 创建本次优先级验证独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 会话和草稿使用同一隔离产品目录。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 会话存储用于建立 previous 与 current。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // previous 使用独立未命名标签身份。
        let previousID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        // current 使用另一个唯一身份证明优先级。
        let currentID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        // 为 previous 标签建立可恢复正文。
        _ = try documentStore.saveDraft("上一代正文", for: nil, untitledID: previousID)
        // 为 current 标签建立不同正文。
        _ = try documentStore.saveDraft("当前代正文", for: nil, untitledID: currentID)
        // 首次保存建立未来 previous。
        try sessionStore.save(
            WorkspaceSessionState(
                documents: [WorkspaceSessionDocument(id: previousID, fileURL: nil)],
                activeDocumentID: previousID
            )
        )
        // 第二次保存建立正常 current。
        try sessionStore.save(
            WorkspaceSessionState(
                documents: [WorkspaceSessionDocument(id: currentID, fileURL: nil)],
                activeDocumentID: currentID
            )
        )

        // 正式初始化必须先选择正常 current。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 测试结束前停止标签延迟任务。
        defer { workspace.documents.forEach { $0.prepareForClose() } }
        // 活动身份必须来自 current 而非 previous。
        #expect(workspace.activeDocumentID == currentID)
        // 正文必须继续由 current 的同 UUID 草稿恢复。
        #expect(workspace.activeDocument?.text == "当前代正文")
        // 工作区反馈不能误报发生了上一代回退。
        #expect(workspace.status == "已恢复 1 个标签")
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
        // 独立发布状态必须持续驱动恢复警示，不能依赖易变化的文案判断。
        #expect(workspace.hasUnrecoverableSessionFailure)
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
        // 普通持久化失败不能误清除尚未归档的恢复警示。
        #expect(workspace.hasUnrecoverableSessionFailure)
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
        // 仅剩损坏 previous 同样属于需要用户处理的不可恢复状态。
        #expect(workspace.hasUnrecoverableSessionFailure)
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
        // 多次失败后持续警示仍不能被关闭。
        #expect(workspace.hasUnrecoverableSessionFailure)
    }

    // 双代损坏完成归档和当前内存状态重建后，持续警示才可以关闭。
    @Test("双代损坏归档重建后关闭持续警示")
    @MainActor
    func testArchiveAndRebuildClearsUnrecoverableSessionFailure() throws {
        // 创建本次成功闭环独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 建立双代损坏现场并走正式工作区恢复入口。
        let fixture = try makeDoubleCorruptWorkspace(at: root)
        // 测试结束前停止内存标签的延迟任务。
        defer { fixture.workspace.documents.forEach { $0.prepareForClose() } }
        // 使用固定日期让归档目录可精确核对。
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        // 使用固定 UUID 防止同毫秒目录名不确定。
        let identifier = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        // 保存重建前当前内存标签的身份和活动状态。
        let expectedState = WorkspaceSessionState(
            documents: fixture.workspace.documents.map {
                WorkspaceSessionDocument(id: $0.id, fileURL: $0.currentFileURL)
            },
            activeDocumentID: fixture.workspace.activeDocumentID
        )
        // 按存储契约构造确定归档目录。
        let archiveDirectory =
            root
            .appendingPathComponent("RecoveryArchives", isDirectory: true)
            .appendingPathComponent(
                "WorkspaceSession-1700000000000-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                isDirectory: true
            )

        // 正式模型入口先保护草稿，再归档双代并重建 current。
        #expect(fixture.workspace.archiveCorruptedSessionAndRebuild(date: date, identifier: identifier))

        // 完整成功后持续警示必须关闭。
        #expect(!fixture.workspace.hasUnrecoverableSessionFailure)
        // 最近归档目录必须保持可达，供完成提示继续打开 Finder。
        #expect(fixture.workspace.lastSessionArchiveURL == archiveDirectory)
        // 状态反馈必须包含可供人工定位的归档目录。
        #expect(fixture.workspace.status == "损坏会话已归档并重建：\(archiveDirectory.path)")
        // 新 current 必须准确采用当时内存标签顺序和活动 UUID。
        #expect(try fixture.sessionStore.load() == expectedState)
        // 原 current 字节必须保存在归档中的同名文件。
        #expect(
            try Data(
                contentsOf: archiveDirectory.appendingPathComponent("WorkspaceSession.json")
            ) == fixture.currentEvidence
        )
        // 原 previous 字节也必须完整进入同一归档目录。
        #expect(
            try Data(
                contentsOf: archiveDirectory.appendingPathComponent("WorkspaceSession.previous.json")
            ) == fixture.previousEvidence
        )
        // 原 previous 槽位暂时保留，避免归档校验到删除之间覆盖外部更新。
        #expect(
            try Data(
                contentsOf: root.appendingPathComponent("WorkspaceSession.previous.json")
            ) == fixture.previousEvidence
        )
    }

    // 归档目标发生碰撞时必须保留警示、错误证据和既有归档内容。
    @Test("归档重建失败时保留状态与原始证据")
    @MainActor
    func testArchiveFailureKeepsUnrecoverableSessionState() throws {
        // 创建本次失败闭环独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 建立双代损坏现场并走正式工作区恢复入口。
        let fixture = try makeDoubleCorruptWorkspace(at: root)
        // 测试结束前停止内存标签的延迟任务。
        defer { fixture.workspace.documents.forEach { $0.prepareForClose() } }
        // 固定日期和 UUID 用于预先占据精确归档目标。
        let date = Date(timeIntervalSince1970: 1_700_000_001)
        // 固定标识确保生产方法命中同名目录拒绝覆盖。
        let identifier = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        // 按生产命名规则构造碰撞目录。
        let archiveDirectory =
            root
            .appendingPathComponent("RecoveryArchives", isDirectory: true)
            .appendingPathComponent(
                "WorkspaceSession-1700000001000-11111111-2222-3333-4444-555555555555",
                isDirectory: true
            )
        // 预先创建目录以模拟已有恢复归档。
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        // 写入标记文件，证明失败路径不会覆盖既有归档。
        let markerURL = archiveDirectory.appendingPathComponent("保留.txt", isDirectory: false)
        // 使用可精确读回的固定标记字节。
        let markerData = Data("既有归档".utf8)
        // 在调用模型入口前保存标记。
        try markerData.write(to: markerURL, options: [.atomic])

        // 同名归档必须失败而不是覆盖既有证据。
        #expect(!fixture.workspace.archiveCorruptedSessionAndRebuild(date: date, identifier: identifier))

        // 任一步失败后持续警示必须保持打开。
        #expect(fixture.workspace.hasUnrecoverableSessionFailure)
        // 失败不能发布一个并未完成的新归档结果。
        #expect(fixture.workspace.lastSessionArchiveURL == nil)
        // 状态必须明确重建失败并给出原始会话目录。
        #expect(fixture.workspace.status.hasPrefix("会话归档重建失败，损坏数据仍保留在 \(root.path)"))
        // current 损坏字节必须逐字节保持不变。
        #expect(try Data(contentsOf: fixture.currentURL) == fixture.currentEvidence)
        // previous 损坏字节也不能因失败而移动或覆盖。
        #expect(try Data(contentsOf: fixture.previousURL) == fixture.previousEvidence)
        // 既有归档标记必须保持原样。
        #expect(try Data(contentsOf: markerURL) == markerData)
    }

    // 成功重建后后续标签变化和草稿仍必须正常保存并可跨启动恢复。
    @Test("归档重建后可继续持久化标签和草稿")
    @MainActor
    func testPersistenceContinuesAfterArchiveRebuild() throws {
        // 创建本次跨启动验证独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 建立双代损坏现场并走正式工作区恢复入口。
        let fixture = try makeDoubleCorruptWorkspace(at: root)
        // 使用独立固定标识完成第一次安全重建。
        let identifier = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        // 重建必须成功后才继续验证普通持久化路径。
        #expect(
            fixture.workspace.archiveCorruptedSessionAndRebuild(
                date: Date(timeIntervalSince1970: 1_700_000_002),
                identifier: identifier
            )
        )
        // 新建第二个标签会立即走普通 persistSession 并轮换有效 current。
        fixture.workspace.newDocument()
        // 取得重建后的新活动标签。
        let addedDocument = try #require(fixture.workspace.activeDocument)
        // 修改正文，验证新的 UUID 草稿也能正常写入。
        addedDocument.text = "重建后新增正文"
        // 退出保护必须同时保存全部草稿和最新会话。
        #expect(fixture.workspace.flushDraftsAndSession())
        // 保存预期标签顺序供跨启动核对。
        let expectedOrder = fixture.workspace.documents.map(\.id)
        // 保存预期活动 UUID，证明普通持久化没有退回旧状态。
        let expectedActiveID = fixture.workspace.activeDocumentID
        // 停止原工作区任务，模拟进程退出后的静止磁盘状态。
        fixture.workspace.documents.forEach { $0.prepareForClose() }

        // 使用相同存储创建新工作区，走完整会话和草稿恢复链。
        let restoredWorkspace = WorkspaceModel(
            documentStore: DocumentSupportStore(rootDirectory: root),
            sessionStore: WorkspaceSessionStore(rootDirectory: root),
            restoresSession: true
        )
        // 测试结束前停止新工作区全部延迟任务。
        defer { restoredWorkspace.documents.forEach { $0.prepareForClose() } }
        // 重启后标签身份和顺序必须与重建后最新状态一致。
        #expect(restoredWorkspace.documents.map(\.id) == expectedOrder)
        // 活动标签必须恢复为后来新增的标签。
        #expect(restoredWorkspace.activeDocumentID == expectedActiveID)
        // 新增标签草稿正文必须可通过同一 UUID 恢复。
        #expect(restoredWorkspace.activeDocument?.text == "重建后新增正文")
        // 有效新会话不应再次触发不可恢复警示。
        #expect(!restoredWorkspace.hasUnrecoverableSessionFailure)
    }

    // 在隔离目录建立两份不同损坏字节，并返回正式初始化后的工作区夹具。
    @MainActor
    private func makeDoubleCorruptWorkspace(at root: URL) throws -> (
        workspace: WorkspaceModel,
        sessionStore: WorkspaceSessionStore,
        currentURL: URL,
        previousURL: URL,
        currentEvidence: Data,
        previousEvidence: Data
    ) {
        // 文档支撑层与会话层共享隔离产品目录。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 会话存储用于建立双代并供测试读回。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // 第一份有效状态将在下一次保存后成为 previous。
        let firstID = UUID()
        // 第二份有效状态建立需要随后破坏的 current。
        let secondID = UUID()
        // 首次保存建立单一 current。
        try sessionStore.save(
            WorkspaceSessionState(
                documents: [WorkspaceSessionDocument(id: firstID, fileURL: nil)],
                activeDocumentID: firstID
            )
        )
        // 第二次保存完成 current 和 previous 双代布局。
        try sessionStore.save(
            WorkspaceSessionState(
                documents: [WorkspaceSessionDocument(id: secondID, fileURL: nil)],
                activeDocumentID: secondID
            )
        )
        // 定位生产 current 固定路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 定位生产 previous 固定路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // current 使用独立可核对损坏字节。
        let currentEvidence = Data("{workspace-current-corrupt".utf8)
        // previous 使用不同字节证明归档没有混淆代次。
        let previousEvidence = Data("{workspace-previous-corrupt".utf8)
        // 原子覆盖 current 制造不可解码现场。
        try currentEvidence.write(to: currentURL, options: [.atomic])
        // 原子覆盖 previous 迫使加载完全失败。
        try previousEvidence.write(to: previousURL, options: [.atomic])
        // 使用正式恢复入口创建仍可编辑的纯内存工作区。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 夹具必须确实进入不可恢复状态，否则后续断言没有意义。
        #expect(workspace.hasUnrecoverableSessionFailure)
        // 返回测试需要的模型、存储、路径和原始证据。
        return (
            workspace,
            sessionStore,
            currentURL,
            previousURL,
            currentEvidence,
            previousEvidence
        )
    }

    // 建立有效 previous、语义失效 current 和未命名草稿，并验证完整工作区回退闭环。
    @MainActor
    private func assertSemanticCurrentFallsBackToPrevious(
        makeCurrentSession: (URL) -> WorkspaceSessionState
    ) throws {
        // 每个矩阵用例使用独立目录，避免并行测试共享任何恢复文件。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 文档存储负责提供 previous 未命名标签的正文入口。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 会话存储负责建立真实 current 与 previous 双代布局。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // 使用固定 UUID 证明回退后仍连接同一未命名草稿。
        let recoveredID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        // 为 previous 标签保存不可由新 UUID 猜测的正文。
        _ = try documentStore.saveDraft("上一代未命名正文", for: nil, untitledID: recoveredID)
        // 构造必须在所有矩阵中保持可恢复的 previous。
        let previousSession = WorkspaceSessionState(
            documents: [WorkspaceSessionDocument(id: recoveredID, fileURL: nil)],
            activeDocumentID: recoveredID
        )
        // 当前代由每个测试分别覆盖空、重复和全部失效描述。
        let currentSession = makeCurrentSession(root)
        // 首次保存建立未来 previous。
        try sessionStore.save(previousSession)
        // 第二次保存把语义失效候选放到 current。
        try sessionStore.save(currentSession)
        // 定位必须保持不变的 previous 文件。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 捕获回退前字节，验证修复 current 不轮换恢复来源。
        let previousEvidence = try Data(contentsOf: previousURL)

        // 正式工作区初始化先尝试 current，再选择可恢复 previous。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 测试结束前停止全部标签延迟任务。
        defer { workspace.documents.forEach { $0.prepareForClose() } }
        // 最终只能发布 previous 中的唯一标签。
        #expect(workspace.documents.map(\.id) == [recoveredID])
        // 活动 UUID 必须保持 previous 的未命名草稿入口。
        #expect(workspace.activeDocumentID == recoveredID)
        // 未命名正文必须通过同一 UUID 完整恢复。
        #expect(workspace.activeDocument?.text == "上一代未命名正文")
        // 工作区必须明确反馈本次采用了 previous。
        #expect(workspace.status == "已从上一代会话恢复 1 个标签")
        // 修复后的 current 必须采用最终选中的规范化 previous 状态。
        #expect(try sessionStore.load() == previousSession)
        // previous 模型仍必须保持为同一恢复来源。
        #expect(try sessionStore.loadPreviousGeneration() == previousSession)
        // previous 原始字节必须逐字节不变，防止语义失效 current 覆盖它。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
    }

    // 在隔离目录预置指定数量和活动位置的真实会话工作区。
    @MainActor
    private func makeWorkspace(
        documentCount: Int,
        activeIndex: Int,
        at root: URL
    ) throws -> (
        workspace: WorkspaceModel,
        sessionStore: WorkspaceSessionStore
    ) {
        // 测试夹具只接受至少一个标签。
        precondition(documentCount > 0)
        // 活动下标必须落在预置标签范围内。
        precondition((0..<documentCount).contains(activeIndex))
        // 文档存储与会话存储共享同一测试根目录。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 会话存储供测试直接读回标签顺序。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // 每个标签生成独立稳定 UUID。
        let documentIDs = (0..<documentCount).map { _ in UUID() }
        // 预置不依赖真实文件的未命名标签会话。
        let session = WorkspaceSessionState(
            documents: documentIDs.map {
                // 每个描述使用自己的 UUID 并保持未命名身份。
                WorkspaceSessionDocument(id: $0, fileURL: nil)
            },
            activeDocumentID: documentIDs[activeIndex]
        )
        // 先落盘真实会话，后续工作区必须走正式恢复路径。
        try sessionStore.save(session)
        // 使用生产初始化入口恢复全部标签对象。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 夹具构建必须精确恢复预置顺序。
        #expect(workspace.documents.map(\.id) == documentIDs)
        // 夹具活动 UUID 必须与预置下标一致。
        #expect(workspace.activeDocumentID == documentIDs[activeIndex])
        // 返回模型与可直接读回的会话存储。
        return (workspace, sessionStore)
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
