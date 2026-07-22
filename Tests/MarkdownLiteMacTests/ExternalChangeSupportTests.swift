import Foundation
import Testing

@testable import MarkdownLiteMac

// 验证原始字节快照和编辑模型不会静默覆盖外部修改。
@Suite("外部文件修改保护")
struct ExternalChangeSupportTests {
    // 同大小且恢复原修改时间的外部改写仍必须被摘要识别。
    @Test("同大小同时间变化仍由摘要识别")
    func testDigestDetectsSameSizeChangeWithRestoredModificationDate() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建真实 Markdown 文件地址。
        let fileURL = root.appendingPathComponent("same-size.md")
        // 写入三字节初始版本。
        try TextFileIO.save("one", to: fileURL)
        // 捕获打开时可信原始字节快照。
        let baseline = try ExternalChangeSupport.capture(at: fileURL)
        // 写入相同字节数但不同内容。
        try TextFileIO.save("two", to: fileURL)
        // 恢复旧修改时间，证明检测不只依赖属性。
        if let modificationDate = baseline.modificationDate {
            // 文件属性伪装不能绕过 SHA-256 内容比较。
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: fileURL.path
            )
        }
        // 对比当前磁盘版本和旧基线。
        let inspection = ExternalChangeSupport.inspect(baseline: baseline, at: fileURL)
        // 内容摘要不同必须报告外部修改。
        #expect(inspection.state == .modified)
    }

    // 相同原始字节即使被原子重写也不应制造无意义冲突。
    @Test("相同字节重写不制造冲突")
    func testIdenticalRewriteRemainsUnchanged() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建真实 Markdown 文件地址。
        let fileURL = root.appendingPathComponent("identical.md")
        // 写入初始正文。
        try TextFileIO.save("相同内容", to: fileURL)
        // 捕获可信基线。
        let baseline = try ExternalChangeSupport.capture(at: fileURL)
        // 再次原子写入完全相同的字节。
        try TextFileIO.save("相同内容", to: fileURL)
        // 检查新文件身份和旧基线。
        let inspection = ExternalChangeSupport.inspect(baseline: baseline, at: fileURL)
        // 内容相同无需阻止保存。
        #expect(inspection.state == .unchanged)
        // 可读文件应返回可供刷新元数据的新快照。
        #expect(inspection.currentSnapshot != nil)
    }

    // 文件删除必须与普通读取失败明确区分。
    @Test("删除状态单独报告")
    func testDeletionIsReported() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建真实 Markdown 文件地址。
        let fileURL = root.appendingPathComponent("deleted.md")
        // 写入初始正文。
        try TextFileIO.save("将被删除", to: fileURL)
        // 捕获删除前基线。
        let baseline = try ExternalChangeSupport.capture(at: fileURL)
        // 删除精确测试文件。
        try FileManager.default.removeItem(at: fileURL)
        // 检查不存在的原路径。
        let inspection = ExternalChangeSupport.inspect(baseline: baseline, at: fileURL)
        // 模型需要 deleted 状态提供另存为或重新创建动作。
        #expect(inspection.state == .deleted)
        // 删除状态没有当前磁盘快照。
        #expect(inspection.currentSnapshot == nil)
    }

    // 无损正文和磁盘摘要必须来自同一次原始数据读取。
    @Test("正文与快照来自同一次读取")
    func testReadWithSnapshotMatchesCapturedBytes() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建带中文和 emoji 的真实文件地址。
        let fileURL = root.appendingPathComponent("snapshot.md")
        // 使用正式原子写入并直接取得保存基线。
        let savedSnapshot = try TextFileIO.saveWithSnapshot("中文 🚀", to: fileURL)
        // 使用打开入口同时读取正文和快照。
        let diskRead = try TextFileIO.readWithSnapshot(from: fileURL)
        // 无损正文必须完整一致。
        #expect(diskRead.content.text == "中文 🚀")
        // 保存摘要、读取摘要和实际文件摘要必须完全一致。
        #expect(diskRead.snapshot.contentDigest == savedSnapshot.contentDigest)
    }

    // 逆序完成时必须由请求单调序号决定最终正文，而不是 Date 大小。
    @Test("草稿逆序完成使用单调序号")
    func testOutOfOrderCompletionUsesMonotonicGeneration() throws {
        // 建立草稿存储隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建线程安全草稿支撑层。
        let store = DocumentSupportStore(rootDirectory: root)
        // 固定未命名标签身份便于命中同一草稿键。
        let documentID = UUID()
        // 先预留旧正文，并故意给它未来墙上时间。
        let olderReservation = try store.reserveDraftWrite(
            "旧正文",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        // 后预留的新正文模拟系统时间回拨到更早时刻。
        let newerReservation = try store.reserveDraftWrite(
            "新正文",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        // 让更新请求先完成，模拟后台任务逆序结束。
        _ = try store.commitDraftWrite(newerReservation)
        // 记录旧请求是否得到明确 superseded 结果。
        var olderWasSuperseded = false
        do {
            // 更早 generation 即使 Date 更晚也不能覆盖新正文。
            _ = try store.commitDraftWrite(olderReservation)
        } catch DocumentSupportError.draftWriteSuperseded {
            // 明确错误证明调用方不会误报旧内容保存成功。
            olderWasSuperseded = true
        }
        // 旧提交必须准确报告被取代。
        #expect(olderWasSuperseded)
        // 最终磁盘只保留调用顺序更晚的新正文。
        let loadedDraft = try store.loadDraft(for: nil, untitledID: documentID)
        // 墙上时间允许回拨并仅作为显示元数据保留。
        #expect(loadedDraft?.text == "新正文")
        #expect(loadedDraft?.updatedAt == Date(timeIntervalSince1970: 100))
    }

    // 同步 flush 的后调用不能因墙上时间回拨而被静默跳过。
    @Test("同步草稿保存不受时间回拨影响")
    func testSynchronousSaveSurvivesClockRollback() throws {
        // 建立草稿存储隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建线程安全草稿支撑层。
        let store = DocumentSupportStore(rootDirectory: root)
        // 固定未命名标签身份便于命中同一草稿键。
        let documentID = UUID()
        // 第一次保存使用较晚墙上时间。
        _ = try store.saveDraft(
            "时间回拨前",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        // 后一次同步 flush 故意使用更早墙上时间。
        _ = try store.saveDraft(
            "时间回拨后的最新正文",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        // 后调用必须真实落盘且返回内容可恢复。
        let loadedDraft = try store.loadDraft(for: nil, untitledID: documentID)
        // Date 更早不能导致最新正文被旧规则跳过。
        #expect(loadedDraft?.text == "时间回拨后的最新正文")
        #expect(loadedDraft?.updatedAt == Date(timeIntervalSince1970: 100))
    }

    // 保存或重载后的删除序号必须阻止已预留旧草稿重新出现。
    @Test("删除序号阻止旧草稿复活")
    func testReservedDraftCannotReappearAfterRemoval() throws {
        // 建立草稿存储隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建线程安全草稿支撑层。
        let store = DocumentSupportStore(rootDirectory: root)
        // 固定未命名标签身份便于命中同一草稿键。
        let documentID = UUID()
        // 模拟删除前已捕获但尚未完成的旧后台正文。
        let staleReservation = try store.reserveDraftWrite(
            "过期正文",
            for: nil,
            untitledID: documentID
        )
        // 保存或重载清理草稿时分配更晚删除序号。
        try store.removeDraft(for: nil, untitledID: documentID)
        // 记录旧请求是否得到明确 superseded 结果。
        var staleWasSuperseded = false
        do {
            // 删除后才完成的旧请求必须被屏障拒绝。
            _ = try store.commitDraftWrite(staleReservation)
        } catch DocumentSupportError.draftWriteSuperseded {
            // 明确错误证明删除不会被旧任务反转。
            staleWasSuperseded = true
        }
        // 旧后台请求必须报告被取代。
        #expect(staleWasSuperseded)
        // 删除后的草稿文件不得重新出现。
        #expect(try store.loadDraft(for: nil, untitledID: documentID) == nil)
    }

    // dirty 编辑遇到外部修改时普通保存必须失败并保留两份内容。
    @Test("dirty 冲突阻止覆盖并保留草稿")
    @MainActor
    func testDirtyEditorBlocksExternalOverwriteAndKeepsDraft() throws {
        // 建立文档和草稿共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建被编辑的真实文件。
        let fileURL = root.appendingPathComponent("conflict.md")
        // 写入打开时版本。
        try TextFileIO.save("磁盘初始", to: fileURL)
        // 草稿存储注入隔离目录。
        let store = DocumentSupportStore(rootDirectory: root)
        // 打开无旧草稿的编辑模型。
        let optionalModel = try EditorModel.open(at: fileURL, documentStore: store)
        // 文件存在时模型必须成功创建。
        let model = try #require(optionalModel)
        // 模拟当前应用内未保存编辑。
        model.text = "本地编辑"
        // 模拟其他应用写入不同内容。
        try TextFileIO.save("外部编辑", to: fileURL)
        // 普通保存必须被冲突保护阻止。
        #expect(!model.saveDocumentIfPossible())
        // 外部版本不得被静默覆盖。
        #expect(try TextFileIO.read(from: fileURL).text == "外部编辑")
        // 本地正文和 dirty 状态必须保持。
        #expect(model.text == "本地编辑")
        #expect(model.isDirty)
        // 模型层必须暴露可处理的修改状态。
        #expect(model.externalChangeState == .modified)
        // 当前编辑必须同步保留到独立草稿。
        #expect(try store.loadDraft(for: fileURL)?.text == "本地编辑")
        // 停止该模型等待中的预览和草稿任务。
        model.prepareForClose()
    }

    // 首次预检通过后发生的外部保存必须在协调写入承诺点再次被识别。
    @Test("承诺点竞态阻止静默覆盖")
    @MainActor
    func testCoordinatedCommitRejectsChangeAfterInitialInspection() throws {
        // 建立文档和草稿共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建真实 Markdown 文件地址。
        let fileURL = root.appendingPathComponent("commit-race.md")
        // 写入模型打开时的可信版本。
        try TextFileIO.save("打开版本", to: fileURL)
        // 草稿存储注入隔离目录。
        let store = DocumentSupportStore(rootDirectory: root)
        // 打开后保留初始内容摘要作为普通保存基线。
        let model = try #require(try EditorModel.open(at: fileURL, documentStore: store))
        // 模拟应用内尚未写回磁盘的正文。
        model.text = "本地待保存版本"
        // 记录确定性钩子确实进入了首次预检后的承诺区。
        var commitHookRan = false
        // 在协调访问器内、最终基线复核前模拟另一个编辑器完成保存。
        let saved = model.saveDocumentIfPossible(
            beforeCoordinatedCommitForTesting: {
                // 标记钩子已经执行，避免测试因未进入目标窗口而假通过。
                commitHookRan = true
                // 外部版本只在首次预检通过后才写入。
                try TextFileIO.save("承诺点外部版本", to: fileURL)
            },
            usesSystemFileCoordinatorForTesting: false
        )
        // 普通保存必须执行承诺点复核并报告失败。
        #expect(commitHookRan)
        #expect(!saved)
        // 外部版本不得被随后发生的本地原子写入覆盖。
        #expect(try TextFileIO.read(from: fileURL).text == "承诺点外部版本")
        // 本地正文、dirty 和冲突状态必须保持可处理。
        #expect(model.text == "本地待保存版本")
        #expect(model.isDirty)
        #expect(model.externalChangeState == .modified)
        // 承诺点冲突同样必须同步留下可恢复草稿。
        #expect(try store.loadDraft(for: fileURL)?.text == "本地待保存版本")
        // 用户随后明确覆盖时允许进入同一协调写区但跳过基线匹配。
        #expect(model.overwriteExternalChanges(usesSystemFileCoordinatorForTesting: false))
        // 明确覆盖后磁盘采用用户选择保留的本地版本。
        #expect(try TextFileIO.read(from: fileURL).text == "本地待保存版本")
        // 停止该模型等待中的预览和草稿任务。
        model.prepareForClose()
    }

    // 干净编辑器遇到外部修改时保存动作应安全采用磁盘版本。
    @Test("干净文档安全重载外部版本")
    @MainActor
    func testCleanEditorReloadsExternalVersionWithoutWriting() throws {
        // 建立文档和草稿共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建被编辑的真实文件。
        let fileURL = root.appendingPathComponent("clean-reload.md")
        // 写入打开时版本。
        try TextFileIO.save("打开版本", to: fileURL)
        // 创建隔离支撑层。
        let store = DocumentSupportStore(rootDirectory: root)
        // 打开干净编辑模型。
        let model = try #require(try EditorModel.open(at: fileURL, documentStore: store))
        // 模拟其他应用保存新版本。
        try TextFileIO.save("外部新版本", to: fileURL)
        // 用户按保存时应安全重载而不是写回旧正文。
        #expect(model.saveDocumentIfPossible())
        // 内存正文必须采用磁盘新版本。
        #expect(model.text == "外部新版本")
        // 重载后恢复干净状态和新基线。
        #expect(!model.isDirty)
        #expect(model.externalChangeState == .unchanged)
        // 磁盘外部版本必须保持不变。
        #expect(try TextFileIO.read(from: fileURL).text == "外部新版本")
        // 停止该模型等待中的预览任务。
        model.prepareForClose()
    }

    // 明确丢弃重载采用磁盘正文，并永久清理同路径恢复草稿。
    @Test("明确丢弃重载删除恢复草稿")
    @MainActor
    func testDiscardingReloadAdoptsDiskAndDeletesDraft() throws {
        // 建立文档和草稿共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建真实 Markdown 文件地址。
        let fileURL = root.appendingPathComponent("discard-reload.md")
        // 写入模型打开时版本。
        try TextFileIO.save("打开版本", to: fileURL)
        // 创建隔离草稿支撑层并打开文档。
        let store = DocumentSupportStore(rootDirectory: root)
        let model = try #require(try EditorModel.open(at: fileURL, documentStore: store))
        // 模拟当前应用内未保存编辑。
        model.text = "将永久丢弃的本地版本"
        // 在用户确认前确保恢复草稿确实存在。
        #expect(model.ensureRecoverableDraft())
        #expect(try store.loadDraft(for: fileURL)?.text == "将永久丢弃的本地版本")
        // 模拟磁盘出现用户决定采用的新版本。
        try TextFileIO.save("用户采用的磁盘版本", to: fileURL)
        // 模型层明确丢弃入口必须成功采用磁盘版本。
        #expect(model.reloadFromDiskDiscardingChanges())
        // 重载后正文与磁盘一致且不再标记 dirty。
        #expect(model.text == "用户采用的磁盘版本")
        #expect(!model.isDirty)
        #expect(model.externalChangeState == .unchanged)
        // 永久丢弃语义要求同路径恢复草稿被删除。
        #expect(try store.loadDraft(for: fileURL) == nil)
        // 停止该模型等待中的预览任务。
        model.prepareForClose()
    }

    // 用户明确覆盖后应写入本地版本并刷新冲突基线。
    @Test("明确覆盖后刷新冲突基线")
    @MainActor
    func testExplicitOverwriteResolvesConflict() throws {
        // 建立文档和草稿共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建被编辑的真实文件。
        let fileURL = root.appendingPathComponent("explicit-overwrite.md")
        // 写入打开时版本。
        try TextFileIO.save("打开版本", to: fileURL)
        // 创建隔离支撑层并打开文件。
        let store = DocumentSupportStore(rootDirectory: root)
        let model = try #require(try EditorModel.open(at: fileURL, documentStore: store))
        // 模拟应用内编辑和外部修改同时发生。
        model.text = "用户选择保留的版本"
        try TextFileIO.save("外部版本", to: fileURL)
        // 首次普通保存必须先报告冲突。
        #expect(!model.saveDocumentIfPossible())
        // 明确覆盖 API 才允许替换外部版本。
        #expect(model.overwriteExternalChanges(usesSystemFileCoordinatorForTesting: false))
        // 磁盘采用用户明确选择的当前正文。
        #expect(try TextFileIO.read(from: fileURL).text == "用户选择保留的版本")
        // 成功覆盖后 dirty 和冲突状态都应清除。
        #expect(!model.isDirty)
        #expect(model.externalChangeState == .unchanged)
        // 停止该模型等待中的预览任务。
        model.prepareForClose()
    }

    // 草稿必须把编辑起点的磁盘摘要带过进程重启，不能采用重启时外部版本作为新基线。
    @Test("重启恢复草稿仍阻止外部覆盖")
    @MainActor
    func testRestartedDraftBlocksExternalOverwriteUntilExplicitOverride() throws {
        // 建立文档和草稿共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建真实 Markdown 文件地址。
        let fileURL = root.appendingPathComponent("restart-conflict.md")
        // 写入首次打开时可信磁盘版本。
        try TextFileIO.save("磁盘初始", to: fileURL)
        // 创建跨模型实例复用的隔离草稿存储。
        let store = DocumentSupportStore(rootDirectory: root)
        // 第一个模型模拟应用退出前的编辑会话。
        let firstModel = try #require(try EditorModel.open(at: fileURL, documentStore: store))
        // 生成尚未写回真实文件的本地正文。
        firstModel.text = "本地恢复草稿"
        // 退出前同步落盘草稿及其可信磁盘摘要。
        #expect(firstModel.ensureRecoverableDraft())
        // 读取持久化结果证明草稿确实携带打开时基线。
        let persistedDraft = try #require(try store.loadDraft(for: fileURL))
        // 已命名草稿必须保存可跨重启比较的摘要。
        #expect(persistedDraft.baselineContentDigest != nil)
        // 停止第一个模型的延迟任务，模拟应用进程退出。
        firstModel.prepareForClose()
        // 应用关闭期间由其他编辑器写入不同磁盘版本。
        try TextFileIO.save("进程外磁盘版本", to: fileURL)
        // 新模型实例按会话描述恢复同一路径草稿。
        let descriptor = WorkspaceSessionDocument(id: firstModel.id, fileURL: fileURL)
        let restoredModel = try #require(EditorModel.restore(descriptor, documentStore: store))
        // 恢复必须保留本地草稿正文和未保存状态。
        #expect(restoredModel.text == "本地恢复草稿")
        #expect(restoredModel.isDirty)
        // 草稿历史摘要与当前磁盘不同时应在首次保存前立即暴露冲突。
        #expect(restoredModel.externalChangeState == .modified)
        // 测试宿主绕过系统协调服务，但仍执行生产保存的两次基线核对逻辑。
        let regularSaveSucceeded = restoredModel.saveDocumentIfPossible(
            beforeCoordinatedCommitForTesting: nil,
            usesSystemFileCoordinatorForTesting: false
        )
        // 普通保存必须被草稿历史基线阻止。
        #expect(!regularSaveSucceeded)
        // 被阻止后进程外磁盘版本必须原样保留。
        #expect(try TextFileIO.read(from: fileURL).text == "进程外磁盘版本")
        // 只有用户明确覆盖时才允许跳过本次基线匹配。
        #expect(restoredModel.overwriteExternalChanges(usesSystemFileCoordinatorForTesting: false))
        // 明确覆盖后磁盘采用用户选择保留的本地草稿。
        #expect(try TextFileIO.read(from: fileURL).text == "本地恢复草稿")
        // 覆盖成功刷新新基线并清除 dirty。
        #expect(!restoredModel.isDirty)
        #expect(restoredModel.externalChangeState == .unchanged)
        // 停止恢复模型的延迟任务。
        restoredModel.prepareForClose()
    }

    // 当前磁盘仍等于草稿捕获基线时，重启恢复后的普通保存应保持可用。
    @Test("重启恢复草稿基线相同可普通保存")
    @MainActor
    func testRestartedDraftAllowsSaveWhenBaselineStillMatches() throws {
        // 建立文档和草稿共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建真实 Markdown 文件地址。
        let fileURL = root.appendingPathComponent("restart-unchanged.md")
        // 写入首次打开时磁盘版本。
        try TextFileIO.save("磁盘初始", to: fileURL)
        // 创建跨模型实例复用的隔离草稿存储。
        let store = DocumentSupportStore(rootDirectory: root)
        // 第一个模型产生本地未保存编辑。
        let firstModel = try #require(try EditorModel.open(at: fileURL, documentStore: store))
        firstModel.text = "可安全保存的草稿"
        // 同步保存草稿及其打开时摘要。
        #expect(firstModel.ensureRecoverableDraft())
        // 停止第一个模型的延迟任务，模拟重启。
        firstModel.prepareForClose()
        // 磁盘在应用关闭期间保持原样。
        let descriptor = WorkspaceSessionDocument(id: firstModel.id, fileURL: fileURL)
        let restoredModel = try #require(EditorModel.restore(descriptor, documentStore: store))
        // 摘要相同可以证明草稿仍基于当前磁盘版本。
        #expect(restoredModel.externalChangeState == .unchanged)
        // 使用测试协调注入执行普通保存，不触发明确覆盖路径。
        let regularSaveSucceeded = restoredModel.saveDocumentIfPossible(
            beforeCoordinatedCommitForTesting: nil,
            usesSystemFileCoordinatorForTesting: false
        )
        // 普通保存应成功写入恢复草稿。
        #expect(regularSaveSucceeded)
        #expect(try TextFileIO.read(from: fileURL).text == "可安全保存的草稿")
        // 停止恢复模型的延迟任务。
        restoredModel.prepareForClose()
    }

    // 旧版 JSON 没有历史摘要时仍应成功解码，并在恢复不同正文时保守进入冲突。
    @Test("旧草稿无基线向后兼容且保守冲突")
    @MainActor
    func testLegacyDraftWithoutBaselineDecodesAndConflictsConservatively() throws {
        // 建立文档和草稿共用的隔离目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建旧草稿对应的真实文件地址。
        let fileURL = root.appendingPathComponent("legacy-draft.md")
        // 当前磁盘保留一个与旧草稿不同的版本。
        try TextFileIO.save("当前磁盘版本", to: fileURL)
        // 手工构造没有 baselineContentDigest 的旧版可编码记录。
        let legacyDraft = DocumentDraft(
            text: "旧版本地草稿",
            fileURL: fileURL.standardizedFileURL,
            encoding: .utf8,
            includesByteOrderMark: false,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        // 使用与正式存储一致的日期策略编码旧结构。
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // nil 可选字段应从 JSON 中省略，模拟升级前真实文件。
        let legacyData = try encoder.encode(legacyDraft)
        let legacyObject = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(legacyObject["baselineContentDigest"] == nil)
        // 使用与正式存储一致的日期策略验证缺字段仍能解码。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedDraft = try decoder.decode(DocumentDraft.self, from: legacyData)
        #expect(decodedDraft.baselineContentDigest == nil)
        // 正式存储默认 nil 同样生成可由恢复路径读取的旧式草稿。
        let store = DocumentSupportStore(rootDirectory: root)
        _ = try store.saveDraft(
            decodedDraft.text,
            for: fileURL,
            encoding: decodedDraft.encoding,
            includesByteOrderMark: decodedDraft.includesByteOrderMark,
            updatedAt: decodedDraft.updatedAt
        )
        // 新模型恢复旧草稿时不能把当前磁盘猜成历史基线。
        let descriptor = WorkspaceSessionDocument(id: UUID(), fileURL: fileURL)
        let restoredModel = try #require(EditorModel.restore(descriptor, documentStore: store))
        // 不同正文且无法证明磁盘未变时保守报告修改。
        #expect(restoredModel.text == "旧版本地草稿")
        #expect(restoredModel.externalChangeState == .modified)
        // 普通保存使用测试协调注入并必须被阻止。
        #expect(
            !restoredModel.saveDocumentIfPossible(
                beforeCoordinatedCommitForTesting: nil,
                usesSystemFileCoordinatorForTesting: false
            )
        )
        // 当前磁盘版本不得被旧草稿静默覆盖。
        #expect(try TextFileIO.read(from: fileURL).text == "当前磁盘版本")
        // 停止恢复模型的延迟任务。
        restoredModel.prepareForClose()
    }

    // 建立一个调用方负责清理的唯一临时目录。
    private func makeTemporaryDirectory() throws -> URL {
        // UUID 避免并行测试互相覆盖。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLiteMac-XCTest-\(UUID().uuidString)", isDirectory: true)
        // 一次创建完整隔离目录。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 返回真实目录地址。
        return root
    }
}
