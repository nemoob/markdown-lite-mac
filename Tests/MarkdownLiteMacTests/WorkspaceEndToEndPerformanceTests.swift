import Darwin
import Foundation
import Testing

@testable import MarkdownLiteMac

// 使用真实工作区、文档存储和预览任务覆盖发布配置端到端性能。
@Suite("工作区端到端性能", .serialized)
struct WorkspaceEndToEndPerformanceTests {
    // 单标签和核心多标签场景都使用真实 1MB 草稿。
    private static let oneMegabyte = 1_000_000
    // 大文件场景固定使用 50MB UTF-8 正文。
    private static let fiftyMegabytes = 50_000_000
    // 三次中位数降低临时目录 IO 和共享 CI 调度抖动。
    private static let measuredIterations = 3
    // 本机约 36ms，500ms 为较慢 CI 保留充足调度和磁盘余量。
    private static let oneTabRestoreTargetMilliseconds = 500.0
    // 本机约 51ms，十标签并发预览必须在 1.5 秒内全部可用。
    private static let tenTabRestoreTargetMilliseconds = 1_500.0
    // 本机约 6ms，一百个空标签的模型扩展不得超过半秒。
    private static let hundredTabRestoreTargetMilliseconds = 500.0
    // 本机约 22ms，50MB 文件必须在 1.5 秒内返回可编辑模型。
    private static let largeFileOpenTargetMilliseconds = 1_500.0
    // 本机约 74ms，50MB 原子保存和摘要更新不得超过三秒。
    private static let largeFileSaveTargetMilliseconds = 3_000.0
    // 本机约 0.06ms，1MB 正文连续输入同步 p95 必须保持在一帧以内。
    private static let inputP95TargetMilliseconds = 10.0
    // 单次最慢同步输入允许小量调度抖动，但不能形成可见卡顿。
    private static let inputMaximumTargetMilliseconds = 25.0
    // 本机约 172ms，包含固定 120ms 合并的预览端到端上限为 1.5 秒。
    private static let inputToPreviewTargetMilliseconds = 1_500.0
    // 本机约 454MB，隔离进程超过 1GB 表示大文件或多标签出现异常复制。
    private static let peakResidentTargetMegabytes = 1_024.0

    // 汇总本次发布门禁的全部可复核测量值。
    private struct Report {
        // 一个 1MB 标签从会话到预览追平的中位数。
        let oneTabRestoreMilliseconds: Double
        // 十个 1MB 标签从会话到全部预览追平的中位数。
        let tenTabRestoreMilliseconds: Double
        // 一百个空标签从会话到全部预览追平的中位数。
        let hundredTabRestoreMilliseconds: Double
        // 50MB 文件通过工作区入口打开的中位数。
        let largeFileOpenMilliseconds: Double
        // 50MB 文件通过编辑模型生产入口保存的中位数。
        let largeFileSaveMilliseconds: Double
        // 1MB 正文连续输入同步路径的 p95。
        let inputP95Milliseconds: Double
        // 最慢一次 1MB 正文同步输入耗时。
        let inputMaximumMilliseconds: Double
        // 最后一次输入到增强预览追平正文的端到端耗时。
        let inputToPreviewMilliseconds: Double
        // 隔离测试进程截至全部场景完成时的峰值常驻内存。
        let peakResidentMegabytes: Double
    }

    // 单个复合测量避免并行测试和不确定执行顺序污染端到端结果。
    #if DEBUG
        // Debug 全量测试只编译本文件，不重复执行大样本 IO 和墙钟断言。
        @Test("release 端到端性能门禁", .disabled("仅由 filtered release 测试执行"))
    #else
        // Release filtered 测试独立运行全部真实样本和硬门槛。
        @Test("release 端到端性能门禁")
    #endif
    @MainActor
    func testReleasePerformanceGate() async throws {
        // 构造一次共享的真实 Markdown 1MB 样本，准备成本不进入恢复计时。
        let largeMarkdown = Self.makeMarkdownSample(byteCount: Self.oneMegabyte)
        // 样本必须达到约定 UTF-8 体量，防止字符计数替代字节计数。
        #expect(largeMarkdown.utf8.count == Self.oneMegabyte)

        // 测量一个 1MB 草稿标签的完整恢复和首轮预览。
        let oneTabRestore = try await measureMedian(iterations: Self.measuredIterations) {
            try await measureWorkspaceRestore(tabCount: 1, draftText: largeMarkdown)
        }
        // 核心压力样本要求十个标签都携带独立 1MB 草稿。
        let tenTabRestore = try await measureMedian(iterations: Self.measuredIterations) {
            try await measureWorkspaceRestore(tabCount: 10, draftText: largeMarkdown)
        }
        // 一百标签场景独立衡量会话和模型数量扩展，不重复制造 100MB 草稿 IO。
        let hundredTabRestore = try await measureMedian(iterations: Self.measuredIterations) {
            try await measureWorkspaceRestore(tabCount: 100, draftText: nil)
        }
        // 通过工作区打开和编辑模型保存生产入口测量 50MB 文件。
        let largeFile = try measureLargeFileOpenAndSave(iterations: Self.measuredIterations)
        // 复核 1MB 连续输入的同步延迟和最终预览追平时间。
        let input = try await measureLargeDocumentInput(markdown: largeMarkdown)
        // 读取隔离测试进程的稳定峰值常驻内存。
        let peakResidentMegabytes = try peakResidentMemoryMegabytes()

        // 汇总各场景结果供统一输出和后续门槛核对。
        let report = Report(
            oneTabRestoreMilliseconds: oneTabRestore,
            tenTabRestoreMilliseconds: tenTabRestore,
            hundredTabRestoreMilliseconds: hundredTabRestore,
            largeFileOpenMilliseconds: largeFile.openMilliseconds,
            largeFileSaveMilliseconds: largeFile.saveMilliseconds,
            inputP95Milliseconds: input.p95Milliseconds,
            inputMaximumMilliseconds: input.maximumMilliseconds,
            inputToPreviewMilliseconds: input.toPreviewMilliseconds,
            peakResidentMegabytes: peakResidentMegabytes
        )
        // 输出单行结构化结果，便于本地和 CI 日志直接对照。
        print(Self.format(report))

        // 先确认所有测量都完成且没有时钟异常。
        #expect(report.oneTabRestoreMilliseconds >= 0)
        // 十标签恢复必须产生独立测量结果。
        #expect(report.tenTabRestoreMilliseconds >= 0)
        // 一百标签恢复必须产生独立测量结果。
        #expect(report.hundredTabRestoreMilliseconds >= 0)
        // 大文件打开必须完成真实读取和模型创建。
        #expect(report.largeFileOpenMilliseconds >= 0)
        // 大文件保存必须完成真实原子写入和摘要更新。
        #expect(report.largeFileSaveMilliseconds >= 0)
        // 输入 p95 必须来自有效单调时钟样本。
        #expect(report.inputP95Milliseconds >= 0)
        // 输入到预览追平必须完整完成。
        #expect(report.inputToPreviewMilliseconds >= 0)
        // 峰值内存必须由内核返回非零进程数据。
        #expect(report.peakResidentMegabytes > 0)
        // 单个 1MB 标签恢复必须低于发布硬上限。
        #expect(report.oneTabRestoreMilliseconds < Self.oneTabRestoreTargetMilliseconds)
        // 十个 1MB 标签及全部首轮预览必须低于发布硬上限。
        #expect(report.tenTabRestoreMilliseconds < Self.tenTabRestoreTargetMilliseconds)
        // 一百空标签的会话和模型恢复必须低于发布硬上限。
        #expect(report.hundredTabRestoreMilliseconds < Self.hundredTabRestoreTargetMilliseconds)
        // 50MB 打开到可编辑状态必须低于发布硬上限。
        #expect(report.largeFileOpenMilliseconds < Self.largeFileOpenTargetMilliseconds)
        // 50MB 原子保存和完整摘要更新必须低于发布硬上限。
        #expect(report.largeFileSaveMilliseconds < Self.largeFileSaveTargetMilliseconds)
        // 1MB 输入同步路径 p95 必须保持在一帧预算内。
        #expect(report.inputP95Milliseconds < Self.inputP95TargetMilliseconds)
        // 最慢一次同步输入也不能形成明显卡顿。
        #expect(report.inputMaximumMilliseconds < Self.inputMaximumTargetMilliseconds)
        // 输入合并和后台解析完成时间必须低于发布硬上限。
        #expect(report.inputToPreviewMilliseconds < Self.inputToPreviewTargetMilliseconds)
        // 大样本测试进程峰值内存必须保持在异常复制警戒线以下。
        #expect(report.peakResidentMegabytes < Self.peakResidentTargetMegabytes)
    }

    // 建立指定标签数的真实会话，并测量模型恢复到全部预览可用。
    @MainActor
    private func measureWorkspaceRestore(tabCount: Int, draftText: String?) async throws -> Double {
        // 每轮使用唯一目录，避免系统缓存之外的应用状态串扰。
        let root = try makeTemporaryDirectory(label: "restore-\(tabCount)")
        // 结束后只删除这一轮精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 文档和会话支撑层共享生产布局。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 会话存储使用相同隔离根目录。
        let sessionStore = WorkspaceSessionStore(rootDirectory: root)
        // 使用稳定且唯一的 UUID 数组构造标签身份。
        let documentIDs = (0..<tabCount).map { _ in UUID() }

        // 只有大草稿场景预先写入每个标签的独立恢复记录。
        if let draftText {
            // 每个 UUID 都必须真实落盘，不能复用同一个草稿文件。
            for documentID in documentIDs {
                // 准备数据发生在计时之前。
                _ = try documentStore.saveDraft(
                    draftText,
                    for: nil,
                    untitledID: documentID
                )
            }
        }
        // 会话描述保持标签顺序并激活最后一个标签。
        let session = WorkspaceSessionState(
            documents: documentIDs.map { WorkspaceSessionDocument(id: $0, fileURL: nil) },
            activeDocumentID: documentIDs.last
        )
        // 准备 current 会话文件，不把测试夹具写入计入恢复耗时。
        try sessionStore.save(session)

        // 单调时钟从真实工作区构造之前开始。
        let startedAt = ProcessInfo.processInfo.systemUptime
        // 正式恢复入口读取会话、草稿、创建模型并安排首轮预览。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 无论后续断言是否通过都停止延迟预览和草稿任务。
        defer { workspace.documents.forEach { $0.prepareForClose() } }
        // 等到所有标签首轮预览都对应当前正文，才算端到端恢复完成。
        try await waitForCurrentPreviews(in: workspace, timeoutSeconds: 15)
        // 预览追平后记录完整耗时。
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000

        // 标签数量必须与会话描述完全一致。
        #expect(workspace.documents.count == tabCount)
        // 最后一个 UUID 必须继续保持活动状态。
        #expect(workspace.activeDocumentID == documentIDs.last)
        // 有草稿时每个标签都必须恢复完整 UTF-8 字节数。
        if let draftText {
            // 逐个核对可防止只恢复首个标签却伪报速度。
            #expect(workspace.documents.allSatisfy { $0.text.utf8.count == draftText.utf8.count })
        } else {
            // 百标签会话的空白模型也必须全部可用。
            #expect(workspace.documents.allSatisfy { $0.text.isEmpty })
        }
        // 返回本轮完整恢复耗时供三次中位数汇总。
        return elapsed
    }

    // 连续测量 50MB 文件生产打开和保存路径并分别返回中位数。
    @MainActor
    private func measureLargeFileOpenAndSave(
        iterations: Int
    ) throws -> (openMilliseconds: Double, saveMilliseconds: Double) {
        // 预分配固定数量的打开样本。
        var openMeasurements: [Double] = []
        // 预分配固定数量的保存样本。
        var saveMeasurements: [Double] = []
        // 避免测量循环内数组扩容。
        openMeasurements.reserveCapacity(iterations)
        // 保存数组使用相同固定容量。
        saveMeasurements.reserveCapacity(iterations)
        // 单份 50MB 字符串可被各轮夹具以写时复制方式复用。
        let fileText = String(repeating: "x", count: Self.fiftyMegabytes)
        // 样本必须是真实 50MB UTF-8 数据。
        #expect(fileText.utf8.count == Self.fiftyMegabytes)

        // 每轮创建独立文件和工作区，避免路径去重或已有快照形成捷径。
        for _ in 0..<iterations {
            // 创建这一轮唯一目录。
            let root = try makeTemporaryDirectory(label: "large-file")
            // 本轮结束后删除精确目录。
            defer { try? FileManager.default.removeItem(at: root) }
            // 创建 50MB Markdown 文件地址。
            let fileURL = root.appendingPathComponent("large.md", isDirectory: false)
            // 准备文件发生在打开计时之外。
            try TextFileIO.save(fileText, to: fileURL)
            // 创建真实共享文档存储。
            let documentStore = DocumentSupportStore(rootDirectory: root)
            // 创建真实会话存储。
            let sessionStore = WorkspaceSessionStore(rootDirectory: root)
            // 不恢复旧会话，得到确定的初始工作区。
            let workspace = WorkspaceModel(
                documentStore: documentStore,
                sessionStore: sessionStore,
                restoresSession: false
            )
            // 本轮结束时取消初始标签和大文件标签的全部延迟任务。
            defer { workspace.documents.forEach { $0.prepareForClose() } }

            // 从生产工作区打开入口之前开始计时。
            let openStartedAt = ProcessInfo.processInfo.systemUptime
            // 打开包含稳定读取、摘要、编辑模型、最近文件和会话更新。
            workspace.openDocument(at: fileURL)
            // 工作区返回即可编辑时结束打开计时，后台预览不阻塞可交互时间。
            openMeasurements.append((ProcessInfo.processInfo.systemUptime - openStartedAt) * 1_000)
            // 取得刚打开的活动大文件标签。
            let document = try #require(workspace.activeDocument)
            // 打开必须完整保留 50MB 正文。
            #expect(document.text.utf8.count == Self.fiftyMegabytes)
            // 打开计时完成后取消大文件后台预览，避免无界解析干扰独立保存和 RSS 口径。
            document.prepareForClose()
            // 在计时外追加一个字节，保证保存执行真实不同内容写入。
            document.text.append("y")

            // 从生产保存入口之前开始计时。
            let saveStartedAt = ProcessInfo.processInfo.systemUptime
            // 原地保存覆盖系统文件协调、原子写、摘要、草稿清理和元数据更新。
            let didSave = document.saveDocumentIfPossible()
            // 保存入口返回时记录完整提交耗时。
            saveMeasurements.append((ProcessInfo.processInfo.systemUptime - saveStartedAt) * 1_000)
            // 保存必须明确成功且清除 dirty。
            #expect(didSave && !document.isDirty)
            // 读取文件属性核对真实落盘字节数，不额外解码 50MB 正文。
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            // 文件应包含原始 50MB 加最后输入的一个 ASCII 字节。
            #expect((attributes[.size] as? NSNumber)?.intValue == Self.fiftyMegabytes + 1)
        }

        // 对打开样本排序并取稳定中位数。
        let openMedian = median(openMeasurements)
        // 对保存样本独立排序并取稳定中位数。
        let saveMedian = median(saveMeasurements)
        // 返回两个生产路径的独立结果。
        return (openMedian, saveMedian)
    }

    // 测量 1MB 文本连续输入的同步工作和最后一轮预览追平。
    @MainActor
    private func measureLargeDocumentInput(
        markdown: String
    ) async throws -> (p95Milliseconds: Double, maximumMilliseconds: Double, toPreviewMilliseconds: Double) {
        // 输入模型使用独立目录，自动草稿不会污染其他场景。
        let root = try makeTemporaryDirectory(label: "input")
        // 完成后删除精确测试目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 建立真实文档支撑层。
        let documentStore = DocumentSupportStore(rootDirectory: root)
        // 创建一个携带完整 1MB 正文的未命名标签。
        let document = EditorModel.makeUntitled(
            text: markdown,
            dirty: false,
            documentStore: documentStore
        )
        // 结束时取消最后一次预览和草稿计时器。
        defer { document.prepareForClose() }
        // 先等待初始化预览完成，避免它与输入测量交叠。
        try await waitForCurrentPreview(in: document, timeoutSeconds: 5)
        // 固定三十次连续输入足够计算 p95，同时保持测试耗时有限。
        let inputCount = 30
        // 预分配同步输入耗时数组。
        var inputMeasurements: [Double] = []
        // 避免输入循环内数组扩容。
        inputMeasurements.reserveCapacity(inputCount)

        // 前二十九次输入模拟快速键入和旧任务取消。
        for _ in 0..<(inputCount - 1) {
            // 单调时钟只覆盖正文赋值及同步副作用。
            let startedAt = ProcessInfo.processInfo.systemUptime
            // 追加单个 ASCII 字符触发正式 contentChanged 路径。
            document.text.append("x")
            // 立即记录用户输入同步返回耗时。
            inputMeasurements.append((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        }
        // 最后一次输入同时作为预览端到端起点。
        let previewStartedAt = ProcessInfo.processInfo.systemUptime
        // 最后一字节继续触发相同生产输入路径。
        document.text.append("x")
        // 记录最后一次同步输入耗时。
        inputMeasurements.append((ProcessInfo.processInfo.systemUptime - previewStartedAt) * 1_000)
        // 等待 120ms 合并和后台解析都完成。
        try await waitForCurrentPreview(in: document, timeoutSeconds: 5)
        // 计算最后输入到最新预览可用的完整延迟。
        let toPreview = (ProcessInfo.processInfo.systemUptime - previewStartedAt) * 1_000
        // 排序后读取 p95 和最大值，避免平均值掩盖长尾。
        let sortedMeasurements = inputMeasurements.sorted()
        // 三十次样本的向上取整百分位索引稳定落在第二十九项。
        let p95Index = max(0, Int(ceil(Double(sortedMeasurements.count) * 0.95)) - 1)
        // 返回同步长尾和异步预览完整结果。
        return (sortedMeasurements[p95Index], sortedMeasurements.last ?? 0, toPreview)
    }

    // 对固定次数异步操作取中位数，减少单次 IO 与调度噪声。
    @MainActor
    private func measureMedian(
        iterations: Int,
        operation: @MainActor () async throws -> Double
    ) async throws -> Double {
        // 预分配固定容量。
        var measurements: [Double] = []
        // 避免测量循环内扩容。
        measurements.reserveCapacity(iterations)
        // 每轮调用都创建自己的隔离生产布局。
        for _ in 0..<iterations {
            // 记录这一轮已经完成的端到端耗时。
            measurements.append(try await operation())
        }
        // 奇数次数直接取排序后的中间项。
        return median(measurements)
    }

    // 等待工作区所有标签预览与当前正文代次一致。
    @MainActor
    private func waitForCurrentPreviews(
        in workspace: WorkspaceModel,
        timeoutSeconds: Double
    ) async throws {
        // 复用单文档轮询条件并使用同一个绝对截止时间。
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        // 任何标签仍未追平时继续短暂让出主 actor。
        while !workspace.documents.allSatisfy(\.isPreviewCurrent) {
            // 超时明确失败，避免性能回归让 CI 永久挂起。
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw PerformanceTestError.previewTimeout
            }
            // 两毫秒轮询远小于性能门槛且不会忙等占满主线程。
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // 等待单标签最新预览追平正文。
    @MainActor
    private func waitForCurrentPreview(
        in document: EditorModel,
        timeoutSeconds: Double
    ) async throws {
        // 使用单调系统运行时间建立截止点。
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        // 当前预览落后时持续短暂让出主 actor。
        while !document.isPreviewCurrent {
            // 超过截止点时抛出确定错误而非继续等待。
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw PerformanceTestError.previewTimeout
            }
            // 两毫秒间隔兼顾响应速度和调度稳定性。
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // 构造精确 UTF-8 字节数且包含多段 Markdown 的固定样本。
    private static func makeMarkdownSample(byteCount: Int) -> String {
        // 每个约 4KB 段落同时覆盖标题和长正文解析。
        let chunk = "# Benchmark\n" + String(repeating: "a", count: 4_070) + "\n\n"
        // ASCII 字符数与 UTF-8 字节数相同，可安全按字符截取。
        let repeated = String(repeating: chunk, count: byteCount / chunk.count + 1)
        // 截取精确目标字符数并生成独立字符串。
        return String(repeated.prefix(byteCount))
    }

    // 创建当前测量唯一的临时目录。
    private func makeTemporaryDirectory(label: String) throws -> URL {
        // 标签只用于日志和失败定位，UUID 防止并发碰撞。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MarkdownLiteMac-Performance-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        // 显式创建根目录，让 IO 失败立即进入测试报告。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 返回仅属于本轮测量的地址。
        return root
    }

    // 返回奇数个测量样本的中位数。
    private func median(_ measurements: [Double]) -> Double {
        // 内部调用始终提供三次样本，防御异常时返回零并由功能断言报告。
        guard !measurements.isEmpty else { return 0 }
        // 排序后读取中央项。
        let sorted = measurements.sorted()
        // 三次固定样本不会出现偶数中位数歧义。
        return sorted[sorted.count / 2]
    }

    // 从内核读取当前隔离测试进程自启动以来的峰值常驻内存。
    private func peakResidentMemoryMegabytes() throws -> Double {
        // 初始化内核 rusage 输出结构。
        var usage = rusage()
        // 查询当前进程的累计资源使用量。
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw PerformanceTestError.resourceUsageUnavailable
        }
        // macOS 的 ru_maxrss 单位为字节，转换成二进制 MB 便于日志阅读。
        return Double(usage.ru_maxrss) / 1_048_576
    }

    // 生成稳定单行结果供 CI 日志保存。
    private static func format(_ report: Report) -> String {
        // 固定字段名和两位小数，版本间可直接比较。
        String(
            format:
                "端到端性能：restore[1x1MB=%.2fms,10x1MB=%.2fms,100x0=%.2fms] "
                + "50MB[open=%.2fms,save=%.2fms] input1MB[p95=%.2fms,max=%.2fms,preview=%.2fms] peakRSS=%.2fMB "
                + "targets[restore<%.0f/%.0f/%.0fms,50MB<%.0f/%.0fms,input<%.0f/%.0f/%.0fms,RSS<%.0fMB]",
            report.oneTabRestoreMilliseconds,
            report.tenTabRestoreMilliseconds,
            report.hundredTabRestoreMilliseconds,
            report.largeFileOpenMilliseconds,
            report.largeFileSaveMilliseconds,
            report.inputP95Milliseconds,
            report.inputMaximumMilliseconds,
            report.inputToPreviewMilliseconds,
            report.peakResidentMegabytes,
            oneTabRestoreTargetMilliseconds,
            tenTabRestoreTargetMilliseconds,
            hundredTabRestoreTargetMilliseconds,
            largeFileOpenTargetMilliseconds,
            largeFileSaveTargetMilliseconds,
            inputP95TargetMilliseconds,
            inputMaximumTargetMilliseconds,
            inputToPreviewTargetMilliseconds,
            peakResidentTargetMegabytes
        )
    }

    // 为不可继续的测量环境提供明确错误。
    private enum PerformanceTestError: Error {
        // 后台预览未在保护时限内追平。
        case previewTimeout
        // 内核未能提供当前进程资源数据。
        case resourceUsageUnavailable
    }
}
