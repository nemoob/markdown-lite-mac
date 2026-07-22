import Foundation
import Testing

@testable import MarkdownLiteMac

// 验证撤销 dirty、保存后辅助索引失败、解析取消和预览锚点等可靠性边界。
@Suite("编辑模型与预览可靠性")
struct EditorModelReliabilityTests {
    // 为最近文件索引注入可识别的确定性失败。
    private enum InjectedFailure: Error {
        // 模拟正文落盘后最近文件索引无法写入。
        case recentDocumentIndex
    }

    // 撤销回到最后保存正文时必须清除输入事件先前设置的 dirty 标记。
    @Test("撤销重做后精确核对 dirty")
    @MainActor
    func testUndoRedoReconcilesDirtyAgainstSavedSnapshot() throws {
        // 建立独享存储目录，避免延迟草稿任务接触真实应用数据。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建以已保存正文为干净基线的未命名模型。
        let model = EditorModel(
            id: UUID(),
            text: "已保存正文",
            fileURL: nil,
            encoding: .utf8,
            includesByteOrderMark: false,
            dirty: false,
            savedText: "已保存正文",
            savedEncoding: .utf8,
            savedIncludesByteOrderMark: false,
            status: "已就绪",
            documentStore: DocumentSupportStore(rootDirectory: root)
        )
        // 无论断言结果如何都停止模型的延迟预览和草稿任务。
        defer { model.prepareForClose() }

        // 普通输入仍以常量时间标记 dirty。
        model.text = "修改后的正文"
        // 输入后标签必须显示未保存。
        #expect(model.isDirty)
        // 模拟撤销把正文恢复到最后保存快照。
        model.text = "已保存正文"
        // didSet 只做常量时间标记，精确核对前仍保持 dirty。
        #expect(model.isDirty)
        // 原生撤销完成后调用低频全文核对入口。
        model.reconcileDirtyAfterUndoRedo()
        // 正文和 URL 都回到保存快照时必须恢复干净状态。
        #expect(!model.isDirty)

        // 模拟重做再次采用未保存正文。
        model.text = "修改后的正文"
        // 重做完成后执行相同精确核对。
        model.reconcileDirtyAfterUndoRedo()
        // 与保存快照不同的正文必须保持 dirty。
        #expect(model.isDirty)
    }

    // 撤销到保存版本必须同时清除已经落盘和仍在途的旧草稿，关闭重开不能恢复撤销前正文。
    @Test("撤销回保存版本后旧草稿不会复活")
    @MainActor
    func testUndoToSavedTextRemovesDraftBeforeImmediateReopen() throws {
        // 建立真实文档和恢复存储共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建磁盘保存版本 A。
        let fileURL = root.appendingPathComponent("undo-draft-barrier.md")
        // 同一次原子写入取得与版本 A 严格对应的可信快照。
        let baseline = try TextFileIO.saveWithSnapshot("版本 A", to: fileURL)
        // 创建隔离草稿存储供落盘、删除屏障和重开共同使用。
        let store = DocumentSupportStore(rootDirectory: root)
        // 以磁盘版本 A 为干净基线创建编辑模型。
        let model = EditorModel(
            id: UUID(),
            text: "版本 A",
            fileURL: fileURL,
            encoding: .utf8,
            includesByteOrderMark: false,
            dirty: false,
            savedText: "版本 A",
            savedEncoding: .utf8,
            savedIncludesByteOrderMark: false,
            status: "已打开",
            documentStore: store,
            externalFileSnapshot: baseline
        )
        // 测试任何提前失败路径都停止模型的延迟任务。
        defer { model.prepareForClose() }

        // 编辑得到尚未写回文件的版本 B。
        model.text = "版本 B"
        // 模拟自动保存已经把版本 B 草稿真实落盘。
        #expect(model.ensureRecoverableDraft())
        // 先证明回归前提成立，恢复存储当前确实持有版本 B。
        #expect(try store.loadDraft(for: fileURL)?.text == "版本 B")
        // 模拟后台任务已预留旧正文、但尚未完成磁盘提交。
        let staleReservation = try store.reserveDraftWrite("版本 B", for: fileURL)

        // 模拟原生撤销把编辑器正文恢复成保存版本 A。
        model.text = "版本 A"
        // 撤销结束后触发生产路径的精确 dirty 核对和草稿清理。
        model.reconcileDirtyAfterUndoRedo()
        // 返回保存快照后标签必须立即变干净。
        #expect(!model.isDirty)
        // 已经落盘的版本 B 草稿必须在关闭前删除。
        #expect(try store.loadDraft(for: fileURL) == nil)

        // 记录撤销前已经在途的旧请求是否被删除屏障拒绝。
        var staleWriteWasSuperseded = false
        do {
            // 旧请求即使在清理完成后才提交也不能复活版本 B。
            _ = try store.commitDraftWrite(staleReservation)
        } catch DocumentSupportError.draftWriteSuperseded {
            // 明确 superseded 证明本次清理不仅删除文件，还建立了顺序屏障。
            staleWriteWasSuperseded = true
        }
        // 在途旧写入必须被阻止。
        #expect(staleWriteWasSuperseded)
        // 模拟用户撤销后立即关闭当前标签。
        model.prepareForClose()

        // 用同一标签身份模拟应用重开后的会话恢复。
        let descriptor = WorkspaceSessionDocument(id: model.id, fileURL: fileURL)
        // 恢复路径只能读取磁盘版本 A，不能再看到版本 B 草稿。
        let reopened = EditorModel.restore(descriptor, documentStore: store)
        // 测试结束后停止重开模型自己的预览任务。
        defer { reopened?.prepareForClose() }
        // 重开正文必须保持磁盘保存版本 A。
        #expect(reopened?.text == "版本 A")
        // 没有旧草稿时重开标签必须保持干净。
        #expect(reopened?.isDirty == false)
    }

    // 最近文件索引属于辅助元数据，失败不能把已经成功的正文保存报告为失败。
    @Test("最近文件索引失败不反转保存成功")
    @MainActor
    func testRecentIndexFailureKeepsSuccessfulSave() throws {
        // 建立真实文档和恢复存储共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建本次保存使用的真实 Markdown 地址。
        let fileURL = root.appendingPathComponent("recent-index-failure.md")
        // 写入打开时版本并取得与正文严格对应的可信快照。
        let baseline = try TextFileIO.saveWithSnapshot("保存前", to: fileURL)
        // 创建隔离草稿和最近文件存储。
        let store = DocumentSupportStore(rootDirectory: root)
        // 注入只让最近文件索引失败的模型，正文写入仍走正式支撑层。
        let model = EditorModel(
            id: UUID(),
            text: "保存前",
            fileURL: fileURL,
            encoding: .utf8,
            includesByteOrderMark: false,
            dirty: false,
            savedText: "保存前",
            savedEncoding: .utf8,
            savedIncludesByteOrderMark: false,
            status: "已打开",
            documentStore: store,
            externalFileSnapshot: baseline,
            recordRecentDocument: { _ in throw InjectedFailure.recentDocumentIndex }
        )
        // 无论断言结果如何都停止模型的延迟任务。
        defer { model.prepareForClose() }

        // 制造需要写回磁盘的新正文。
        model.text = "已经成功落盘"
        // 绕过测试宿主文件协调服务，但保留同一原子写入和基线复核路径。
        let saved = model.saveDocumentIfPossible(
            beforeCoordinatedCommitForTesting: nil,
            usesSystemFileCoordinatorForTesting: false
        )

        // 辅助索引失败不能反转保存返回值。
        #expect(saved)
        // 真实文件必须包含本次新正文。
        #expect(try TextFileIO.read(from: fileURL).text == "已经成功落盘")
        // 成功落盘后模型必须清除 dirty。
        #expect(!model.isDirty)
        // 状态必须准确区分正文成功和最近文件索引失败。
        #expect(model.status == "文件已保存，最近文件更新失败")
        // 保存后没有进入通用失败分支重新制造恢复草稿。
        #expect(try store.loadDraft(for: fileURL) == nil)
    }

    // 滚动锚点必须保留在目标行之前，不能因下一块绝对距离更近而提前跳转。
    @Test("预览锚点选择目标之前最后一块")
    func testPreviewAnchorUsesPreviousBlock() {
        // 复现目标 90 更接近下一块 101、但语义上仍属于首块的边界。
        let blockID = EnhancedPreviewAnchor.blockID(in: [0, 101], atOrBefore: 90)
        // 目标之前最后一个块必须是 0，而不是绝对距离更近的 101。
        #expect(blockID == 0)
        // 目标到达第二块起始行时应正常采用第二块。
        #expect(EnhancedPreviewAnchor.blockID(in: [0, 101], atOrBefore: 101) == 101)
        // 空预览没有可滚动锚点。
        #expect(EnhancedPreviewAnchor.blockID(in: [], atOrBefore: 90) == nil)
    }

    // 已取消解析任务必须在进入长文档主扫描前返回空结果。
    @Test("解析器响应任务取消")
    func testParserStopsWhenTaskIsCancelled() async {
        // 生成足以暴露无效 CPU 扫描的长列表输入。
        let markdown = String(repeating: "- 待取消的长列表项目\n", count: 20_000)
        // 在同一 detached 任务内先设置取消标记，得到无竞态的可复现检查。
        let blocks = await Task.detached {
            // 当前任务主动取消自身，模拟外层预览 cancellation handler 的传播结果。
            withUnsafeCurrentTask { currentTask in
                // 设置持久取消标记供同步解析器读取。
                currentTask?.cancel()
            }
            // 解析器必须读取当前任务取消状态并立即返回。
            return EnhancedMarkdownParser.parse(markdown)
        }.value
        // 已取消任务不得生成或发布任何部分块。
        #expect(blocks.isEmpty)
    }

    // 为每个测试创建唯一目录，避免并行执行时互相覆盖。
    private func makeTemporaryDirectory() throws -> URL {
        // 使用系统临时目录和随机 UUID 构造明确范围。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLite-EditorReliability-\(UUID().uuidString)", isDirectory: true)
        // 创建目录供真实原子读写和草稿索引使用。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 返回调用方独占目录。
        return root
    }
}
