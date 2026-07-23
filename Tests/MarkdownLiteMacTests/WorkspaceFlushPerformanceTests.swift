import Foundation
import Testing

@testable import MarkdownLiteMac

// 扩展现有 release 端到端套件，使 Scripts/check.sh 的固定过滤器自动执行本门禁。
extension WorkspaceEndToEndPerformanceTests {
    #if DEBUG
        // Debug 全量测试只确认发现和显式跳过，不重复执行 10MB 同步 IO。
        @Test("release 10×1MB dirty 标签同步刷盘门禁", .disabled("仅由 filtered release 测试执行"))
    #else
        // Release filtered 测试执行真实同步草稿和会话写入。
        @Test("release 10×1MB dirty 标签同步刷盘门禁")
    #endif
    @MainActor
    func testReleaseDirtyWorkspaceFlushPerformance() throws {
        // 发布样本固定十个 dirty 标签。
        let documentCount = 10
        // 每个标签正文必须精确达到一百万 UTF-8 字节。
        let bytesPerDocument = 1_000_000
        // 1.5 秒为包含十次原子草稿写入和一次会话写入的保守硬上限。
        let targetMilliseconds = 1_500.0
        // 为每个标签预先生成不同的等长正文，样本构造不进入刷盘计时。
        let expectedTexts = (0..<documentCount).map {
            // 每个索引使用独立 ASCII 填充字符以检测串稿。
            makeFlushPayload(documentIndex: $0, byteCount: bytesPerDocument)
        }
        // 逐项确认按 UTF-8 字节而不是 Swift 字符数达到 1MB。
        #expect(expectedTexts.allSatisfy { $0.utf8.count == bytesPerDocument })
        // 本轮使用唯一临时根，完全隔离真实用户恢复数据。
        let rootDirectory = try makeFlushTemporaryDirectory()
        // 只删除本测试创建的精确目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 文档层显式注入临时根目录。
        let documentStore = DocumentSupportStore(rootDirectory: rootDirectory)
        // 会话层使用同一临时根保持生产布局。
        let sessionStore = WorkspaceSessionStore(rootDirectory: rootDirectory)
        // 不读取任何外部会话，以生产工作区入口创建第一个标签。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: false
        )
        // 任意断言退出时停止全部延迟预览和草稿任务。
        defer { workspace.documents.forEach { $0.prepareForClose() } }
        // 通过真实新建入口补齐十个独立未命名标签。
        while workspace.documents.count < documentCount {
            // 每次新建都会生成独立 UUID 并持久化当前顺序。
            workspace.newDocument()
        }
        // 工作区必须恰好持有目标数量，不能因入口异常产生额外标签。
        #expect(workspace.documents.count == documentCount)
        // 为每个模型设置自己的 1MB 正文并触发真实 dirty 状态。
        for (document, text) in zip(workspace.documents, expectedTexts) {
            // didSet 会安排生产预览和草稿任务，随后同步 flush 会取消等待中的草稿计时器。
            document.text = text
        }
        // 十个标签都必须在计时前处于待保护状态。
        #expect(workspace.documents.allSatisfy { $0.isDirty })
        // 单调时钟从正式同步退出刷盘入口之前开始。
        let startedAt = ProcessInfo.processInfo.systemUptime
        // 真实入口依次同步全部 dirty 草稿并原子保存最终会话。
        let flushed = workspace.flushDraftsAndSession()
        // 只记录刷盘调用本身，不把后续完整性回读计入性能门槛。
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        // 输出单行稳定数据供本地和 CI 发布日志直接复核。
        print(
            "Workspace flush performance: 10x1MB "
                + "\(String(format: "%.2f", elapsedMilliseconds))ms"
        )

        // 任一草稿或会话失败都必须先于时间门槛报告。
        #expect(flushed)
        // 单调时钟结果必须有效。
        #expect(elapsedMilliseconds >= 0)
        // 十个 1MB dirty 标签同步刷盘必须低于保守发布上限。
        #expect(elapsedMilliseconds < targetMilliseconds)

        // 刷盘后从磁盘重新解码最终会话，不能只相信 Bool 返回值。
        let savedSession = try #require(try sessionStore.load())
        // 会话必须完整保存十个标签且保持原数组顺序。
        #expect(savedSession.documents.map(\.id) == workspace.documents.map(\.id))
        // 最后新建的活动标签 UUID 必须同步保存。
        #expect(savedSession.activeDocumentID == workspace.activeDocumentID)
        // 每个会话描述都必须按自身 UUID 读取到对应的完整 1MB 草稿。
        for (index, descriptor) in savedSession.documents.enumerated() {
            // 本场景全部为未命名标签，任何文件路径都表示身份布局错误。
            #expect(descriptor.fileURL == nil)
            // 使用生产草稿加载入口读取当前代或安全上一代。
            let savedDraft = try #require(
                try documentStore.loadDraft(for: nil, untitledID: descriptor.id)
            )
            // 内嵌未命名 UUID 必须与会话描述一致，排除哈希键串写。
            #expect(savedDraft.untitledID == descriptor.id)
            // 正文逐字相等同时验证长度、顺序和内容完整性。
            #expect(savedDraft.text == expectedTexts[index])
            // 再次核对实际落盘恢复正文的 UTF-8 字节数。
            #expect(savedDraft.text.utf8.count == bytesPerDocument)
        }
    }

    // 生成一个带稳定标签前缀且精确达到目标 UTF-8 字节数的 ASCII 正文。
    private func makeFlushPayload(documentIndex: Int, byteCount: Int) -> String {
        // 短前缀让任何标签顺序或草稿键串写都能立即被逐字比较发现。
        let prefix = "tab-\(documentIndex):\n"
        // 十个标签分别使用 A 到 J，单字符始终只占一个 UTF-8 字节。
        let scalar = UnicodeScalar(65 + documentIndex)!
        // 目标固定为 1MB，前缀必然短于正文容量。
        let remainingByteCount = byteCount - prefix.utf8.count
        // 拼接前缀和单字节填充，避免多字节字符造成体量偏差。
        return prefix + String(repeating: String(Character(scalar)), count: remainingByteCount)
    }

    // 为单次 release 刷盘测量创建唯一临时目录。
    private func makeFlushTemporaryDirectory() throws -> URL {
        // UUID 防止重复运行复用旧草稿或会话代次。
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarkdownLiteMac-WorkspaceFlushPerformance-\(UUID().uuidString)",
            isDirectory: true
        )
        // 测试明确拥有此目录，后续存储不会回退默认 Application Support。
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: false
        )
        // 返回标准化路径保持各存储键一致。
        return rootDirectory.standardizedFileURL
    }
}
