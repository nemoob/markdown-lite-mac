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

    // 只有 current 损坏时必须逐字节归档，并把传入状态重建为可读 current。
    @Test("归档单一损坏当前代并重建")
    func testArchiveSingleCorruptCurrentAndReset() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 准备需要完整保留的任意损坏字节。
        let corruptEvidence = Data([0x00, 0xFF, 0x7B, 0x0A, 0xE4, 0xB8, 0xAD])
        // 直接写入唯一损坏代。
        try corruptEvidence.write(to: currentURL, options: [.atomic])
        // 构造归档后应成为新 current 的内存状态。
        let rebuiltState = makeState(id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        // 使用固定日期让归档位置可复验。
        let archiveDate = Date(timeIntervalSince1970: 1_725_000_000)
        // 使用固定标识避免测试依赖随机文件名。
        let archiveIdentifier = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        // 执行显式归档重建动作。
        let result = try store.archiveCorruptedGenerationsAndReset(
            to: rebuiltState,
            date: archiveDate,
            identifier: archiveIdentifier
        )

        // 存储目录应暴露初始化时传入的精确根目录。
        #expect(store.storageDirectoryURL == root)
        // 单代归档结果只能包含 current 文件。
        #expect(result.archivedFileURLs.map(\.lastPathComponent) == ["WorkspaceSession.json"])
        // 归档文件必须逐字节等于损坏现场。
        #expect(try Data(contentsOf: result.archivedFileURLs[0]) == corruptEvidence)
        // 新 current 必须可经正式加载路径完整恢复。
        #expect(try store.load() == rebuiltState)
        // 重建后只保留一个新 current，不应留下 previous。
        #expect(store.existingGenerationURLs.map(\.lastPathComponent) == ["WorkspaceSession.json"])
    }

    // 只有 previous 损坏时也必须保留其文件名，并重建为单一 current。
    @Test("归档单一损坏上一代并重建")
    func testArchiveSingleCorruptPreviousAndReset() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 取得固定上一代路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 准备需要完整保留的上一代损坏字节。
        let corruptEvidence = Data("上一代原始损坏字节".utf8)
        // 直接模拟 current 缺失而 previous 独存的现场。
        try corruptEvidence.write(to: previousURL, options: [.atomic])
        // 构造归档后应成为新 current 的内存状态。
        let rebuiltState = makeState(id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)

        // 执行显式归档重建动作。
        let result = try store.archiveCorruptedGenerationsAndReset(
            to: rebuiltState,
            date: Date(timeIntervalSince1970: 1_725_000_001),
            identifier: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        // 归档结果必须保留 previous 的原文件名。
        #expect(result.archivedFileURLs.map(\.lastPathComponent) == ["WorkspaceSession.previous.json"])
        // previous 归档副本必须逐字节等于原始现场。
        #expect(try Data(contentsOf: result.archivedFileURLs[0]) == corruptEvidence)
        // 正式加载必须返回传入的重建状态。
        #expect(try store.load() == rebuiltState)
        // previous 保留原始损坏字节，任何时刻都继续提供独立恢复证据。
        #expect(try Data(contentsOf: previousURL) == corruptEvidence)
    }

    // 双代同时损坏时必须按 current、previous 顺序完整归档两份原始字节。
    @Test("归档双代损坏并重建")
    func testArchiveBothCorruptGenerationsAndReset() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 取得固定上一代路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 准备当前代不满足 UTF-8 的原始损坏字节。
        let currentEvidence = Data([0xFF, 0x00, 0x01, 0x02])
        // 准备与当前代不同的上一代损坏字节。
        let previousEvidence = Data([0xFE, 0x10, 0x11, 0x12])
        // 写入损坏 current。
        try currentEvidence.write(to: currentURL, options: [.atomic])
        // 写入损坏 previous。
        try previousEvidence.write(to: previousURL, options: [.atomic])
        // 构造重建后的唯一会话。
        let rebuiltState = makeState(id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!)

        // 执行双代归档与重建。
        let result = try store.archiveCorruptedGenerationsAndReset(
            to: rebuiltState,
            date: Date(timeIntervalSince1970: 1_725_000_002),
            identifier: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )

        // 归档地址顺序必须与 existingGenerationURLs 的 current、previous 顺序一致。
        #expect(
            result.archivedFileURLs.map(\.lastPathComponent)
                == ["WorkspaceSession.json", "WorkspaceSession.previous.json"]
        )
        // current 归档副本必须保留原始字节。
        #expect(try Data(contentsOf: result.archivedFileURLs[0]) == currentEvidence)
        // previous 归档副本必须保留原始字节。
        #expect(try Data(contentsOf: result.archivedFileURLs[1]) == previousEvidence)
        // 归档目录必须位于固定 RecoveryArchives 父目录。
        #expect(result.directoryURL.deletingLastPathComponent().lastPathComponent == "RecoveryArchives")
        // 重建后的正式加载结果必须可读。
        #expect(try store.load() == rebuiltState)
        // previous 槽位不再删除，继续逐字节保留调用前证据。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
    }

    // 任一代仍可恢复时必须拒绝归档，且两代字节都保持不变。
    @Test("存在有效上一代时拒绝归档")
    func testArchiveRejectsWhenAnyGenerationIsRecoverable() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 构造需要保留为有效上一代的会话。
        let recoverableState = makeState(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        // 构造随后被破坏的当前代。
        let currentState = makeState(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        // 首次保存建立将来的上一代。
        try store.save(recoverableState)
        // 第二次保存完成双代布局。
        try store.save(currentState)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 取得固定上一代路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 用确定字节破坏 current，但保持 previous 可恢复。
        let currentEvidence = Data("当前损坏但上一代有效".utf8)
        // 写入损坏 current。
        try currentEvidence.write(to: currentURL, options: [.atomic])
        // 记录调用前有效 previous 的精确编码字节。
        let previousEvidence = try Data(contentsOf: previousURL)
        // 构造不得写入的新会话。
        let rejectedState = makeState(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!)

        // 任一代有效时必须抛出明确拒绝错误。
        #expect(throws: WorkspaceSessionArchiveError.recoverableGenerationExists) {
            // 尝试执行不应获准的归档重建。
            try store.archiveCorruptedGenerationsAndReset(to: rejectedState)
        }
        // 损坏 current 必须逐字节保持不变。
        #expect(try Data(contentsOf: currentURL) == currentEvidence)
        // 有效 previous 也必须逐字节保持不变。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
        // 正常恢复路径仍必须能返回有效 previous。
        #expect(try store.load() == recoverableState)
    }

    // 两代都不存在时归档动作必须显式拒绝，不能创建伪恢复目录或新会话。
    @Test("无会话代时拒绝归档")
    func testArchiveRejectsWhenNoGenerationExists() throws {
        // 创建本次测试独享的空目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建不含任何会话代的存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 构造不应被保存的替代会话。
        let rejectedState = makeState(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)

        // 没有证据可归档时必须返回稳定错误。
        #expect(throws: WorkspaceSessionArchiveError.noGenerations) {
            // 尝试执行不应获准的归档重建。
            try store.archiveCorruptedGenerationsAndReset(to: rejectedState)
        }
        // 拒绝后仍不应出现任何会话代。
        #expect(store.existingGenerationURLs.isEmpty)
        // 拒绝后也不应创建 RecoveryArchives 父目录。
        let archivesRoot = root.appendingPathComponent("RecoveryArchives", isDirectory: true)
        // 归档根目录必须继续不存在。
        #expect(!FileManager.default.fileExists(atPath: archivesRoot.path))
    }

    // 确定归档目录已存在时必须在触碰原文件前失败，并保留全部损坏字节。
    @Test("归档目录碰撞失败不破坏原代")
    func testArchiveCollisionDoesNotChangeOriginalGenerations() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 取得固定上一代路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 准备当前代损坏证据。
        let currentEvidence = Data("碰撞前当前损坏证据".utf8)
        // 准备上一代损坏证据。
        let previousEvidence = Data("碰撞前上一代损坏证据".utf8)
        // 写入损坏 current。
        try currentEvidence.write(to: currentURL, options: [.atomic])
        // 写入损坏 previous。
        try previousEvidence.write(to: previousURL, options: [.atomic])
        // 固定日期用于预先计算碰撞目录名。
        let archiveDate = Date(timeIntervalSince1970: 1_725_000_003)
        // 固定标识用于预先计算碰撞目录名。
        let archiveIdentifier = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        // 使用与生产代码一致的毫秒时间戳。
        let timestamp = Int64((archiveDate.timeIntervalSince1970 * 1_000).rounded(.down))
        // 拼出本次调用应使用的确定归档目录。
        let collisionDirectory =
            root
            .appendingPathComponent("RecoveryArchives", isDirectory: true)
            .appendingPathComponent(
                "WorkspaceSession-\(timestamp)-\(archiveIdentifier.uuidString.lowercased())",
                isDirectory: true
            )
        // 预先创建目录模拟相同恢复标识的重复调用。
        try FileManager.default.createDirectory(at: collisionDirectory, withIntermediateDirectories: true)
        // 构造不得写入的新会话。
        let rejectedState = makeState(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)

        // 同名归档目录存在时必须稳定拒绝。
        #expect(throws: WorkspaceSessionArchiveError.archiveDestinationAlreadyExists) {
            // 使用相同日期和标识触发确定碰撞。
            try store.archiveCorruptedGenerationsAndReset(
                to: rejectedState,
                date: archiveDate,
                identifier: archiveIdentifier
            )
        }
        // current 损坏证据必须逐字节保持不变。
        #expect(try Data(contentsOf: currentURL) == currentEvidence)
        // previous 损坏证据必须逐字节保持不变。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
        // 已存在的归档目录不能被失败路径删除。
        #expect(FileManager.default.fileExists(atPath: collisionDirectory.path))
    }

    // 仅有 previous 时，即使它在新 current 链接完成后消失，也不能撤销有效新会话。
    @Test("链接新当前代后上一代消失仍保留可读会话")
    func testPreviousRemovalAfterCurrentLinkKeepsReadableCurrent() throws {
        // 创建本次竞态测试独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 注入硬链接完成后的确定性外部删除。
        let fileManager = SessionArchiveRaceFileManager()
        // 创建使用竞态注入器的正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root, fileManager: fileManager)
        // 取得调用开始时缺失的 current 路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 取得唯一存在的 previous 路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 准备需要先归档的 previous 损坏字节。
        let previousEvidence = Data("链接竞态前的上一代损坏字节".utf8)
        // 建立 current 缺失、previous 独存的起始布局。
        try previousEvidence.write(to: previousURL, options: [.atomic])
        // 构造必须留在 current 的有效重建状态。
        let rebuiltState = makeState(id: UUID(uuidString: "81818181-8181-8181-8181-818181818181")!)
        // 硬链接成功后模拟 Finder 或外部工具删除旧 previous。
        fileManager.afterLinkItem = { _, destinationURL in
            // 只在正式 current 已经原子可见后注入变化。
            guard destinationURL.standardizedFileURL == currentURL.standardizedFileURL else { return }
            // 删除 previous，复现旧回滚会制造双槽同时为空的边界。
            try FileManager.default.removeItem(at: previousURL)
        }

        // 归档重建必须把已链接的新 current 作为安全提交结果保留下来。
        let result = try store.archiveCorruptedGenerationsAndReset(
            to: rebuiltState,
            date: Date(timeIntervalSince1970: 1_725_000_005),
            identifier: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        )

        // previous 外部消失后 current 仍必须存在。
        #expect(FileManager.default.fileExists(atPath: currentURL.path))
        // 正式加载路径必须返回本次有效重建状态。
        #expect(try store.load() == rebuiltState)
        // 外部删除结果不能被方法偷偷写回旧 previous。
        #expect(!FileManager.default.fileExists(atPath: previousURL.path))
        // previous 调用前字节仍必须存在于已验证归档。
        #expect(try Data(contentsOf: result.archivedFileURLs[0]) == previousEvidence)
    }

    // replace 提交前 current 被外部更新时，替换备份必须额外保存这份最新字节。
    @Test("替换前当前代变化会额外归档")
    func testCurrentChangeBeforeReplacementIsAlsoArchived() throws {
        // 创建本次竞态测试独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 注入 replace 真正执行前的确定性外部写入。
        let fileManager = SessionArchiveRaceFileManager()
        // 创建使用竞态注入器的正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root, fileManager: fileManager)
        // 取得需要走 replace 分支的 existing current。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 准备首次快照应保存的损坏字节。
        let initialEvidence = Data("替换前的最初损坏字节".utf8)
        // 准备 replace 必须通过 backup 额外捕获的新字节。
        let externalEvidence = Data("replace 调用前外部写入的新字节".utf8)
        // 建立调用开始时已存在的损坏 current。
        try initialEvidence.write(to: currentURL, options: [.atomic])
        // 构造最终必须落入 current 的有效状态。
        let rebuiltState = makeState(id: UUID(uuidString: "91919191-9191-9191-9191-919191919191")!)
        // 在 Foundation 原子替换接管旧文件前改变 current。
        fileManager.beforeReplaceItem = { originalURL, _ in
            // 只修改生产 current，不触碰归档或临时替代文件。
            guard originalURL.standardizedFileURL == currentURL.standardizedFileURL else { return }
            // 原子写入新的外部字节，要求 replace backup 精确捕获。
            try externalEvidence.write(to: currentURL, options: [.atomic])
        }

        // 正式替换应成功，并同时保留初始快照和提交前最新字节。
        let result = try store.archiveCorruptedGenerationsAndReset(
            to: rebuiltState,
            date: Date(timeIntervalSince1970: 1_725_000_006),
            identifier: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )
        // 读取结果声明的全部归档内容进行逐字节核对。
        let archivedPayloads = try result.archivedFileURLs.map { try Data(contentsOf: $0) }

        // 调用开始时的 current 快照必须继续保留。
        #expect(archivedPayloads.contains(initialEvidence))
        // replace 前出现的新 current 必须作为额外归档保留。
        #expect(archivedPayloads.contains(externalEvidence))
        // 两份不同证据必须对应至少两个归档文件，不能互相覆盖。
        #expect(result.archivedFileURLs.count >= 2)
        // 正式 current 必须可读为调用方传入的新状态。
        #expect(try store.load() == rebuiltState)
    }

    // replace 完成后 current 再被外部更新时，方法必须报变化且不能写回旧快照。
    @Test("替换后当前代变化不会被回滚覆盖")
    func testCurrentChangeAfterReplacementIsNeverRolledBack() throws {
        // 创建本次竞态测试独享目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 注入 replace 成功返回前的确定性外部写入。
        let fileManager = SessionArchiveRaceFileManager()
        // 创建使用竞态注入器的正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root, fileManager: fileManager)
        // 取得需要走 replace 分支的 existing current。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 准备调用开始时必须进入归档的损坏字节。
        let initialEvidence = Data("替换完成前的损坏字节".utf8)
        // 准备 replace 后绝不能被回滚覆盖的外部字节。
        let externalEvidence = Data("replace 完成后的外部新字节".utf8)
        // 建立调用开始时已存在的损坏 current。
        try initialEvidence.write(to: currentURL, options: [.atomic])
        // 构造事务尝试写入的有效会话。
        let rebuiltState = makeState(id: UUID(uuidString: "A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1")!)
        // Foundation replace 完成后立即用外部字节替换正式 current。
        fileManager.afterReplaceItem = { originalURL, _ in
            // 只修改刚完成提交的正式 current。
            guard originalURL.standardizedFileURL == currentURL.standardizedFileURL else { return }
            // 原子写入外部版本，要求生产代码识别所有权已经丢失。
            try externalEvidence.write(to: currentURL, options: [.atomic])
        }

        // 提交后发现 current 不再属于本事务时必须返回稳定变化错误。
        #expect(throws: WorkspaceSessionArchiveError.generationsChangedDuringArchive) {
            // 执行会命中 replace 后变化检测的正式入口。
            try store.archiveCorruptedGenerationsAndReset(
                to: rebuiltState,
                date: Date(timeIntervalSince1970: 1_725_000_007),
                identifier: UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!
            )
        }
        // 失败路径绝不能把 initial 或 replacement 字节覆盖回 current。
        #expect(try Data(contentsOf: currentURL) == externalEvidence)
        // 使用固定参数定位本次失败后仍应保留的归档目录。
        let archiveDirectory =
            root
            .appendingPathComponent("RecoveryArchives", isDirectory: true)
            .appendingPathComponent(
                "WorkspaceSession-1725000007000-abababab-abab-abab-abab-abababababab",
                isDirectory: true
            )
        // 拟重建状态使用独立文件保留，不受正式 current 的外部后写影响。
        let rebuiltSessionURL = archiveDirectory.appendingPathComponent(
            "WorkspaceSession.rebuilt.json",
            isDirectory: false
        )
        // 从归档独立解码拟重建状态，证明用户仍可人工找回本次内存工作区。
        let archivedRebuiltState = try JSONDecoder().decode(
            WorkspaceSessionState.self,
            from: Data(contentsOf: rebuiltSessionURL)
        )
        // 归档中的拟重建状态必须与调用方输入完全一致。
        #expect(archivedRebuiltState == rebuiltState)
    }

    // replace 本身失败时原双代必须保持不变，并继续保留已经验证的归档。
    @Test("替换失败保留原代和归档")
    func testArchiveReplacementFailureKeepsOriginalGenerations() throws {
        // 创建本次测试独享的会话目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理这个精确目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 注入 replace 调用前的稳定 IO 失败。
        let fileManager = SessionArchiveRaceFileManager()
        // 创建使用故障注入器的正式会话存储。
        let store = WorkspaceSessionStore(rootDirectory: root, fileManager: fileManager)
        // 取得固定当前代路径。
        let currentURL = root.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 取得固定上一代路径。
        let previousURL = root.appendingPathComponent("WorkspaceSession.previous.json", isDirectory: false)
        // 准备失败后必须保持原样的 current 字节。
        let currentEvidence = Data([0xF1, 0x00, 0x20, 0x21])
        // 准备失败后必须保持原样的 previous 字节。
        let previousEvidence = Data([0xF2, 0x00, 0x30, 0x31])
        // 写入损坏 current。
        try currentEvidence.write(to: currentURL, options: [.atomic])
        // 写入损坏 previous。
        try previousEvidence.write(to: previousURL, options: [.atomic])
        // 让 replace 在改变正式 current 前失败。
        fileManager.replacementError = CocoaError(.fileWriteNoPermission)
        // 固定日期便于失败后定位已验证归档。
        let archiveDate = Date(timeIntervalSince1970: 1_725_000_004)
        // 固定标识便于失败后定位已验证归档。
        let archiveIdentifier = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        // 构造不应在失败后写入 current 的新会话。
        let rejectedState = makeState(id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!)
        // 记录归档重建是否按预期失败。
        var didThrow = false

        do {
            // 执行会在 replace 提交前失败的归档重建。
            _ = try store.archiveCorruptedGenerationsAndReset(
                to: rejectedState,
                date: archiveDate,
                identifier: archiveIdentifier
            )
        } catch {
            // 任意底层替换错误都证明本次故障注入已经命中。
            didThrow = true
        }

        // 替换失败不能被静默吞掉。
        #expect(didThrow)
        // current 从未被替换，必须保持调用前字节。
        #expect(try Data(contentsOf: currentURL) == currentEvidence)
        // previous 不参与删除，必须保持调用前字节。
        #expect(try Data(contentsOf: previousURL) == previousEvidence)
        // 使用与生产代码一致的毫秒时间戳定位安全兜底归档。
        let timestamp = Int64((archiveDate.timeIntervalSince1970 * 1_000).rounded(.down))
        // 拼出失败后仍应存在的已验证归档目录。
        let archiveDirectory =
            root
            .appendingPathComponent("RecoveryArchives", isDirectory: true)
            .appendingPathComponent(
                "WorkspaceSession-\(timestamp)-\(archiveIdentifier.uuidString.lowercased())",
                isDirectory: true
            )
        // 读取归档 current，证明替换失败仍有独立证据兜底。
        let archivedCurrent = archiveDirectory.appendingPathComponent(
            "WorkspaceSession.json",
            isDirectory: false
        )
        // 读取归档 previous，证明双代在替换前均已验证。
        let archivedPrevious = archiveDirectory.appendingPathComponent(
            "WorkspaceSession.previous.json",
            isDirectory: false
        )
        // current 归档必须逐字节等于调用前现场。
        #expect(try Data(contentsOf: archivedCurrent) == currentEvidence)
        // previous 归档必须逐字节等于调用前现场。
        #expect(try Data(contentsOf: archivedPrevious) == previousEvidence)
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

// 在 Foundation 原子链接和替换的精确边界注入确定性外部竞态。
private final class SessionArchiveRaceFileManager: FileManager, @unchecked Sendable {
    // 链接成功后运行，覆盖 current 已可读但调用尚未返回的窗口。
    var afterLinkItem: ((URL, URL) throws -> Void)?
    // 替换接管旧 current 前运行，模拟归档快照之后出现的新字节。
    var beforeReplaceItem: ((URL, URL) throws -> Void)?
    // 替换完成后运行，模拟生产代码校验新 current 前的外部更新。
    var afterReplaceItem: ((URL, URL) throws -> Void)?
    // 非 nil 时在替换正式文件前抛出固定底层错误。
    var replacementError: Error?

    // 先完成真实硬链接，再把边界控制权交给测试闭包。
    override func linkItem(at sourceURL: URL, to destinationURL: URL) throws {
        // Foundation 先原子建立正式 current，确保注入时目标已经可读。
        try super.linkItem(at: sourceURL, to: destinationURL)
        // 测试闭包只改变显式指定的会话槽位。
        try afterLinkItem?(sourceURL, destinationURL)
    }

    // 覆盖便捷 replaceItemAt 最终动态调用的 Objective-C 开放入口。
    override func replaceItem(
        at originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions = [],
        resultingItemURL resultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        // 在真实替换前注入外部 current 更新。
        try beforeReplaceItem?(originalItemURL, newItemURL)
        // 固定失败必须发生在正式 current 被 Foundation 改变之前。
        if let replacementError {
            // 直接交回测试指定错误，证明生产实现不会误报成功。
            throw replacementError
        }
        // 复用系统安全替换和 backup 语义，不自行模拟文件操作。
        try super.replaceItem(
            at: originalItemURL,
            withItemAt: newItemURL,
            backupItemName: backupItemName,
            options: options,
            resultingItemURL: resultingURL
        )
        // 在系统替换完成后、生产调用方继续校验前注入外部更新。
        try afterReplaceItem?(originalItemURL, newItemURL)
    }
}
