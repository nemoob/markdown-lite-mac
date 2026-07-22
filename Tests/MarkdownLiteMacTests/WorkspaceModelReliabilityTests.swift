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
