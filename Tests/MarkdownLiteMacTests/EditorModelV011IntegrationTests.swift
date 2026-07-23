import Foundation
import Testing

@testable import MarkdownLiteMac

// 验证 v0.11 统计和预览策略已经接入真实编辑模型，而不只停留在纯策略函数。
@Suite("v0.11 编辑模型集成", .serialized)
struct EditorModelV011IntegrationTests {
    // 后台全文统计必须发布当前正文结果并保留独立选区数量。
    @Test("写作统计后台追平最新正文")
    @MainActor
    func testWritingStatisticsTrackLatestText() async throws {
        // 每轮使用隔离草稿目录，自动保存不能接触真实用户数据。
        let root = try makeTemporaryDirectory(label: "statistics")
        // 测试结束后只删除精确临时目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 建立使用隔离目录的真实文档支撑层。
        let store = DocumentSupportStore(rootDirectory: root)
        // 初始正文混合 ASCII、emoji 和尾随换行。
        let document = EditorModel.makeUntitled(
            text: "a😀\n",
            dirty: false,
            documentStore: store
        )
        // 结束时取消统计、预览和草稿任务。
        defer { document.prepareForClose() }

        // 等待首次后台统计发布。
        let initialCompleted = await waitUntil {
            document.writingStatistics.characterCount == 3
                && document.writingStatistics.lineCount == 2
        }
        // 初始结果必须按扩展字素簇和尾随空行计算。
        #expect(initialCompleted)

        // 连续替换两次正文，第一轮后台结果必须被取消。
        document.text = "旧结果"
        // 最新正文包含中文、组合字符和两个逻辑换行。
        document.text = "中文\ne\u{301}\n"
        // 等待最新代次覆盖旧统计。
        let latestCompleted = await waitUntil {
            document.writingStatistics.characterCount == 5
                && document.writingStatistics.lineCount == 3
        }
        // 过期结果不得在等待结束后重新覆盖当前正文。
        #expect(latestCompleted)

        // 模拟原生编辑器发布合法选区字符数。
        document.updateSelectedCharacterCount(2)
        // 选区更新必须保留刚完成的全文统计。
        #expect(
            document.writingStatistics
                == WritingStatistics(characterCount: 5, lineCount: 3, selectedCharacterCount: 2)
        )
    }

    // 整体采用磁盘新正文时必须取消旧统计并立即安排新一代结果。
    @Test("磁盘重载后写作统计追平新正文")
    @MainActor
    func testReloadFromDiskRefreshesWritingStatistics() async throws {
        // 使用隔离目录保存本次真实磁盘文件和恢复数据。
        let root = try makeTemporaryDirectory(label: "reload-statistics")
        // 测试结束后只删除本次精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建具备稳定短正文的 Markdown 文件。
        let fileURL = root.appendingPathComponent("reload-statistics.md", isDirectory: false)
        // 首次内容只有一个字符和一行，便于识别旧统计。
        try TextFileIO.save("旧", to: fileURL)
        // 文档支撑层和被测模型共享隔离目录。
        let store = DocumentSupportStore(rootDirectory: root)
        // 通过真实打开入口建立磁盘快照和初始后台统计。
        let document = try #require(try EditorModel.open(at: fileURL, documentStore: store))
        // 结束时取消预览、统计和草稿任务。
        defer { document.prepareForClose() }

        // 等待初始正文统计发布，确保后续能识别是否仍显示旧值。
        let initialCompleted = await waitUntil {
            document.writingStatistics.characterCount == 1
                && document.writingStatistics.lineCount == 1
        }
        // 初始统计必须真实完成。
        #expect(initialCompleted)
        // 模拟重载前原生编辑器仍有一个选中字符。
        document.updateSelectedCharacterCount(1)
        // 外部进程写入字符数和行数都不同的新正文。
        try TextFileIO.save("新的\n磁盘\n正文", to: fileURL)

        // 用户明确采用磁盘版本，整体换文路径不会触发普通 didSet 副作用。
        #expect(document.reloadFromDiskDiscardingChanges())
        // 重载成功必须立即清除旧正文的选区数量。
        #expect(document.writingStatistics.selectedCharacterCount == 0)
        // 等待零延迟后台任务发布磁盘新正文的完整统计。
        let reloadedCompleted = await waitUntil {
            document.writingStatistics.characterCount == 8
                && document.writingStatistics.lineCount == 3
                && document.writingStatistics.selectedCharacterCount == 0
        }

        // 新统计必须在没有额外编辑或标签切换的情况下主动追平。
        #expect(reloadedCompleted)
        // 模型正文必须与统计所依据的磁盘版本完全一致。
        #expect(document.text == "新的\n磁盘\n正文")
    }

    // 后台标签不得解析，重新激活后必须为最新正文补齐预览。
    @Test("后台标签停止预览并在激活后追平")
    @MainActor
    func testBackgroundDocumentDefersPreviewUntilActivation() async throws {
        // 使用独立临时目录隔离自动草稿。
        let root = try makeTemporaryDirectory(label: "background-preview")
        // 测试结束后删除精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建真实文档支撑层。
        let store = DocumentSupportStore(rootDirectory: root)
        // 创建足以产生预览块的小文档。
        let document = EditorModel.makeUntitled(
            text: "# 后台标题\n\n正文",
            dirty: false,
            documentStore: store
        )
        // 立即模拟工作区把标签移入后台，初始化任务尚未获得执行机会。
        document.setPreviewActive(false)
        // 结束时取消残留任务。
        defer { document.prepareForClose() }

        // 后台策略必须立即发布稳定原因。
        #expect(document.previewPauseReason == .backgroundTab)
        // 推进后的正文代次没有可交互预览。
        #expect(!document.isPreviewCurrent)

        // 模拟用户切回这个标签。
        document.setPreviewActive(true)
        // 等待活动标签后台解析完成。
        let previewCompleted = await waitUntil {
            document.isPreviewCurrent && !document.previewBlocks.isEmpty
        }
        // 激活后必须恢复正常预览且清除后台原因。
        #expect(previewCompleted)
        #expect(document.previewPauseReason == nil)

        // 已追平预览再次进入后台时可以安全保留，不应被无条件判为过期。
        document.setPreviewActive(false)
        // 后台原因与预览代次独立，现有块仍对应同一份正文。
        #expect(document.previewPauseReason == .backgroundTab)
        #expect(document.isPreviewCurrent)
        // 再次激活应直接复用现有块并清除后台原因。
        document.setPreviewActive(true)
        #expect(document.previewPauseReason == nil)
        #expect(document.isPreviewCurrent)
    }

    // 超过五 MiB 的正文必须自动暂停，同时保留显式单次刷新能力。
    @Test("大文档自动暂停并允许单次手动预览")
    @MainActor
    func testLargeDocumentRequiresManualPreviewRefresh() async throws {
        // 使用独立临时目录隔离自动草稿。
        let root = try makeTemporaryDirectory(label: "large-preview")
        // 测试结束后删除精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建真实文档支撑层。
        let store = DocumentSupportStore(rootDirectory: root)
        // ASCII 字符让字符数与 UTF-8 字节数精确一致。
        let largeText = String(
            repeating: "x",
            count: PreviewWorkPolicy.automaticPreviewByteLimit + 1
        )
        // 通过生产初始化入口安排首轮自动预览。
        let document = EditorModel.makeUntitled(
            text: largeText,
            dirty: false,
            documentStore: store
        )
        // 结束时取消预览和后台统计。
        defer { document.prepareForClose() }

        // 等待后台字节统计选择大文档暂停策略。
        let automaticPaused = await waitUntil(timeoutSeconds: 5) {
            document.previewPauseReason == .documentTooLarge
        }
        // 自动路径不得解析超过上限的正文。
        #expect(automaticPaused)
        #expect(!document.isPreviewCurrent)

        // 用户明确请求本次大文档预览。
        document.refreshPreviewManually()
        // 等待单次手动解析完成并成为当前代次。
        let manualCompleted = await waitUntil(timeoutSeconds: 15) {
            document.isPreviewCurrent && document.previewPauseReason == nil
        }
        // 手动请求必须放行且清除暂停原因。
        #expect(manualCompleted)
    }

    // 创建当前测试唯一的临时目录。
    private func makeTemporaryDirectory(label: String) throws -> URL {
        // UUID 保证串行重跑也不会碰撞旧夹具。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MarkdownLiteMac-v011-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        // 显式创建根目录，让权限失败进入测试结果。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 返回只属于本用例的目录。
        return root
    }

    // 轮询主 actor 状态直到条件成立或超时。
    @MainActor
    private func waitUntil(
        timeoutSeconds: Double = 3,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        // 使用单调时钟避免系统时间调整影响测试。
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        // 条件未满足时短暂让出主 actor 给后台结果回写。
        while !condition() {
            // 超时返回 false，由调用点给出语义明确的断言。
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            // 十毫秒轮询不会忙等，也远小于发布性能门槛。
            try? await Task.sleep(for: .milliseconds(10))
        }
        // 条件已满足。
        return true
    }
}
