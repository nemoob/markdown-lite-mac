import Foundation
import Testing

@testable import MarkdownLiteMac

// 验证会话当前代与上一代在兼容、损坏和缺失场景下的恢复规则。
@Suite("会话双代恢复")
struct SessionSupportRecoveryTests {
    // v0.7 只有当前代文件时必须直接加载，并在首次新保存时成为上一代。
    @Test("兼容 v0.7 单代会话")
    func testLegacyCurrentSessionLoadsAndRotatesOnSave() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 构造旧版已经落盘的会话。
        let legacyState = makeState(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        // 构造 v0.8 即将保存的新会话。
        let currentState = makeState(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        // 取得兼容 v0.7 的固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 使用标准编码器模拟旧版本单文件写入。
        let legacyData = try JSONEncoder().encode(legacyState)
        // 只写当前代，不预先创建上一代文件。
        try legacyData.write(to: currentURL, options: [.atomic])
        // 创建正式会话存储读取旧版文件。
        let store = WorkspaceSessionStore(rootDirectory: root)

        // 旧版单代会话必须不经过迁移即可加载。
        #expect(try store.load() == legacyState)
        // 带来源接口必须返回相同旧版会话。
        let legacyLoad = try #require(try store.loadWithRecoverySource())
        // 旧版固定主文件仍属于正常当前代读取。
        #expect(legacyLoad.state == legacyState)
        // 正常读取当前代时不得误报上一代恢复。
        #expect(!legacyLoad.recoveredFromPrevious)
        // 首次 v0.8 保存会把旧版当前代晋升为上一代。
        try store.save(currentState)

        // 正常加载必须返回刚保存的新当前代。
        #expect(try store.load() == currentState)
        // 取得新增的固定上一代路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 直接读取上一代，证明旧版会话被完整保留。
        let previousData = try Data(contentsOf: previousURL)
        // 使用相同结构解码上一代文件。
        let previousState = try JSONDecoder().decode(WorkspaceSessionState.self, from: previousData)
        // 上一代必须等于保存前的旧版会话。
        #expect(previousState == legacyState)
    }

    // 当前代损坏时必须自动恢复最近一个有效上一代。
    @Test("当前代损坏时回退上一代")
    func testCorruptCurrentSessionFallsBackToPrevious() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 构造即将成为上一代的第一份会话。
        let previousState = makeState(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        // 构造正常情况下应作为当前代的第二份会话。
        let currentState = makeState(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        // 首次保存建立当前代。
        try store.save(previousState)
        // 第二次保存把第一份晋升为上一代。
        try store.save(currentState)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 用无效 JSON 模拟进程外损坏当前代。
        try Data("损坏".utf8).write(to: currentURL, options: [.atomic])

        // 加载必须跳过损坏当前代并返回有效上一代。
        #expect(try store.load() == previousState)
        // 带来源接口必须明确标记本次使用了上一代。
        let recovery = try #require(try store.loadWithRecoverySource())
        // 集成层应取得与旧接口相同的会话内容。
        #expect(recovery.state == previousState)
        // 集成层必须能够展示上一代恢复提示。
        #expect(recovery.recoveredFromPrevious)
    }

    // 当前代缺失时仍必须使用已经存在的上一代。
    @Test("当前代缺失时回退上一代")
    func testMissingCurrentSessionFallsBackToPrevious() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 构造即将成为上一代的第一份会话。
        let previousState = makeState(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        // 构造用于触发轮换的第二份会话。
        let currentState = makeState(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        // 首次保存建立当前代。
        try store.save(previousState)
        // 第二次保存建立上一代。
        try store.save(currentState)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 删除当前代模拟原子替换之外的外部缺失。
        try FileManager.default.removeItem(at: currentURL)

        // 加载必须在当前代缺失时返回上一代。
        #expect(try store.load() == previousState)
    }

    // 损坏的当前代不得在后续保存时覆盖唯一有效上一代。
    @Test("损坏当前代不会污染上一代")
    func testSavePreservesPreviousWhenCurrentIsCorrupt() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 构造需要始终保留的有效上一代。
        let previousState = makeState(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        // 构造随后会被破坏的当前代。
        let replacedState = makeState(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        // 构造损坏后由内存重新保存的新当前代。
        let repairedState = makeState(id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        // 首次保存建立当前代。
        try store.save(previousState)
        // 第二次保存让第一份成为上一代。
        try store.save(replacedState)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 第一次损坏当前代，模拟恢复前发现坏文件。
        try Data("损坏一".utf8).write(to: currentURL, options: [.atomic])
        // 保存内存中的有效状态时必须跳过损坏代的晋升。
        try store.save(repairedState)
        // 新当前代必须立即可正常读取。
        #expect(try store.load() == repairedState)
        // 再次损坏新当前代以检查上一代是否仍未被污染。
        try Data("损坏二".utf8).write(to: currentURL, options: [.atomic])

        // 回退结果仍必须是最初的有效上一代。
        #expect(try store.load() == previousState)
    }

    // 当前代是唯一损坏证据时必须拒绝用新会话覆盖它。
    @Test("唯一当前代损坏时拒绝保存")
    func testSaveRejectsCorruptCurrentWithoutPrevious() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 构造唯一当前代的有效初始内容。
        let initialState = makeState(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        // 构造不得覆盖现场的新会话。
        let replacementState = makeState(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        // 首次保存只建立当前代，不产生上一代。
        try store.save(initialState)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 写入可在保存后精确比较的损坏证据。
        let corruptEvidence = Data("唯一损坏证据".utf8)
        // 破坏唯一当前代。
        try corruptEvidence.write(to: currentURL, options: [.atomic])

        // 没有有效上一代时保存必须显式失败。
        #expect(throws: DecodingError.self) {
            // 模拟恢复失败后创建新标签触发的保存。
            try store.save(replacementState)
        }
        // 重新读取当前代原始字节。
        let retainedEvidence = try Data(contentsOf: currentURL)
        // 保存失败后必须完整保留损坏证据。
        #expect(retainedEvidence == corruptEvidence)
        // 失败路径不能凭空创建上一代文件。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 上一代缺失状态必须保持不变。
        #expect(!FileManager.default.fileExists(atPath: previousURL.path))
    }

    // current 缺失且唯一 previous 损坏时必须拒绝保存，不能在第二次轮换时抹掉证据。
    @Test("仅剩损坏上一代时拒绝保存")
    func testSaveRejectsCorruptPreviousWithoutCurrent() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 连续两次保存先建立 current 和 previous。
        let firstState = makeState(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        // 第二份状态只用于触发上一代轮换。
        let secondState = makeState(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        // 构造不得覆盖损坏现场的新状态。
        let replacementState = makeState(id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        // 首次保存建立 current。
        try store.save(firstState)
        // 第二次保存建立 previous。
        try store.save(secondState)
        // 取得固定 current 路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 取得固定 previous 路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 删除 current，模拟只剩上一代的中断布局。
        try FileManager.default.removeItem(at: currentURL)
        // 写入可精确核对的 previous 损坏证据。
        let previousEvidence = Data("唯一损坏上一代".utf8)
        // 破坏唯一剩余会话代。
        try previousEvidence.write(to: previousURL, options: [.atomic])

        // 第一次保存就必须拒绝，不能先创建新 current 再等待下一次覆盖 previous。
        #expect(throws: DecodingError.self) {
            // 模拟用户继续操作触发会话持久化。
            try store.save(replacementState)
        }
        // current 必须继续缺失，证明没有写入半修复状态。
        #expect(!FileManager.default.fileExists(atPath: currentURL.path))
        // previous 损坏证据必须逐字节保留。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
        // 重复保存也必须稳定失败，不能因第一次调用改变布局。
        #expect(throws: DecodingError.self) {
            // 第二次调用覆盖潜在的重复 persist/flush 路径。
            try store.save(replacementState)
        }
        // 重复失败后唯一证据仍不得变化。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
    }

    // 当前代和上一代都损坏时保存也必须失败并保留两份现场。
    @Test("双代损坏时拒绝保存")
    func testSaveRejectsWhenBothGenerationsAreCorrupt() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 构造第一代有效会话。
        let firstState = makeState(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        // 构造第二代有效会话。
        let secondState = makeState(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        // 构造不得覆盖现场的新会话。
        let replacementState = makeState(id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        // 首次保存建立当前代。
        try store.save(firstState)
        // 第二次保存建立当前代和上一代。
        try store.save(secondState)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 取得固定上一代路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 记录当前代损坏现场。
        let currentEvidence = Data("当前损坏证据".utf8)
        // 记录上一代损坏现场。
        let previousEvidence = Data("上一代损坏证据".utf8)
        // 破坏当前代。
        try currentEvidence.write(to: currentURL, options: [.atomic])
        // 破坏上一代。
        try previousEvidence.write(to: previousURL, options: [.atomic])

        // 上一代无法解码时保存必须显式失败。
        #expect(throws: DecodingError.self) {
            // 模拟双代恢复失败后创建新标签触发的保存。
            try store.save(replacementState)
        }
        // 当前代损坏证据必须保持原样。
        #expect(try Data(contentsOf: currentURL) == currentEvidence)
        // 上一代损坏证据也必须保持原样。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
    }

    // 当前代与上一代同时损坏时必须抛错，不能伪装成首次启动。
    @Test("双代损坏时显式失败")
    func testBothCorruptSessionsThrow() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 构造第一代有效会话。
        let firstState = makeState(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        // 构造第二代有效会话。
        let secondState = makeState(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        // 连续保存两次以建立当前和上一代。
        try store.save(firstState)
        // 第二次保存完成双代布局。
        try store.save(secondState)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 取得固定上一代路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 破坏当前代 JSON。
        try Data("当前损坏".utf8).write(to: currentURL, options: [.atomic])
        // 同时破坏上一代 JSON。
        try Data("上一代损坏".utf8).write(to: previousURL, options: [.atomic])

        // 两次解码都失败时必须把错误交给工作区安全回退。
        #expect(throws: DecodingError.self) {
            // 执行正式双代加载路径。
            try store.load()
        }
    }

    // 两代都不存在时仍保持既有首次启动语义。
    @Test("双代都不存在时返回空会话")
    func testNoSessionGenerationReturnsNil() throws {
        // 创建本次测试独享的空目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建不含任何会话文件的正式存储。
        let store = WorkspaceSessionStore(rootDirectory: root)

        // 首次启动必须继续返回 nil，而不是抛出错误。
        #expect(try store.load() == nil)
    }

    // 构造只含一个未命名标签的确定性会话。
    private func makeState(id: UUID) -> WorkspaceSessionState {
        // 使用同一 UUID 同时表示标签身份和活动标签。
        WorkspaceSessionState(
            documents: [WorkspaceSessionDocument(id: id, fileURL: nil)],
            activeDocumentID: id
        )
    }

    // 为每个测试创建唯一目录，避免并行执行时互相覆盖。
    private func makeTemporaryDirectory() throws -> URL {
        // 使用系统临时目录和随机 UUID 构造明确范围。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLite-SessionRecovery-\(UUID().uuidString)", isDirectory: true)
        // 创建目录供当前代和上一代会话共同使用。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 返回调用方独占目录。
        return root
    }
}
