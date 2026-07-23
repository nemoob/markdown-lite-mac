import Foundation
import Testing

@testable import MarkdownLiteMac

// 验证草稿 current/previous 双代轮换、恢复来源和数据隔离。
@Suite("草稿双代恢复")
struct DraftGenerationRecoveryTests {
    // 为每个测试创建互不共享的临时产品目录。
    private func makeTemporaryDirectory() throws -> URL {
        // 使用随机 UUID 防止并行或上次异常退出留下的目录互相影响。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLiteMac-DraftGenerationTests-\(UUID().uuidString)", isDirectory: true)
        // 在写入草稿前创建测试根目录。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 返回只属于当前测试的目录。
        return root
    }

    // v0.7 单 current 保持可读，第二次保存后 current 和 previous 各自保持完整元数据。
    @Test("单代兼容并轮换上一代")
    func testLegacyCurrentRemainsReadableAndRotates() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建隔离草稿存储。
        let store = DocumentSupportStore(rootDirectory: root)
        // 使用稳定本地路径覆盖已命名草稿的 URL 和磁盘基线元数据。
        let fileURL = root.appendingPathComponent("legacy.md", isDirectory: false)
        // 首次保存模拟仅有 current 的 v0.7 布局。
        let first = try store.saveDraft(
            "第一代",
            for: fileURL,
            encoding: .utf16LittleEndian,
            includesByteOrderMark: true,
            baselineContentDigest: "digest-1",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        // 计算测试要核对的固定双代地址。
        let urls = try draftURLs(root: root, store: store, fileURL: fileURL, untitledID: nil)
        // 首次保存只应生成兼容旧版的 current 文件。
        #expect(FileManager.default.fileExists(atPath: urls.current.path))
        #expect(!FileManager.default.fileExists(atPath: urls.previous.path))
        // 带来源读取必须把有效 current 标记为当前代。
        let legacyLoad = try #require(
            try store.loadDraftWithRecoverySource(for: fileURL)
        )
        // v0.7 current 的正文和全部格式元数据必须保持不变。
        #expect(legacyLoad.draft == first)
        #expect(!legacyLoad.recoveredFromPrevious)

        // 第二次保存触发一次双代轮换。
        let second = try store.saveDraft(
            "第二代",
            for: fileURL,
            encoding: .utf8,
            includesByteOrderMark: false,
            baselineContentDigest: "digest-2",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        // 正常读取必须优先采用最新 current。
        let currentLoad = try #require(
            try store.loadDraftWithRecoverySource(for: fileURL)
        )
        // current 必须精确等于第二次保存结果。
        #expect(currentLoad.draft == second)
        #expect(!currentLoad.recoveredFromPrevious)
        // 人为损坏 current，验证 previous 保存的是原始第一代。
        try Data("{".utf8).write(to: urls.current)
        // current 解码失败后必须回退到 previous。
        let fallback = try #require(
            try store.loadDraftWithRecoverySource(for: fileURL)
        )
        // previous 的正文、编码、BOM、URL、基线和时间必须全部精确恢复。
        #expect(fallback.draft == first)
        #expect(fallback.recoveredFromPrevious)
        // 既有无来源 API 也必须透明返回同一 fallback，保证 EditorModel 无需迁移即可恢复。
        #expect(try store.loadDraft(for: fileURL) == first)
    }

    // current 损坏但 previous 有效时，新保存不得把坏数据轮换进上一代。
    @Test("回退后新保存保留有效上一代")
    func testSaveAfterFallbackPreservesValidPrevious() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建隔离草稿存储。
        let store = DocumentSupportStore(rootDirectory: root)
        // 使用稳定标签 UUID 命中同一草稿键。
        let documentID = UUID()
        // 第一代将在下一次保存后成为 previous。
        let first = try store.saveDraft(
            "可恢复上一代",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        // 第二次保存创建 current/previous 双代。
        _ = try store.saveDraft(
            "即将损坏的当前代",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        // 计算双代文件地址供故障注入和原始字节比较。
        let urls = try draftURLs(root: root, store: store, fileURL: nil, untitledID: documentID)
        // 捕获有效 previous 原始字节。
        let previousBeforeSave = try Data(contentsOf: urls.previous)
        // 模拟 current 截断损坏。
        try Data("{broken-current".utf8).write(to: urls.current)

        // previous 有效时允许把新的内存正文写成 current。
        let newest = try store.saveDraft(
            "新的当前代",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        // current 损坏路径不得改写 last-known-good previous。
        #expect(try Data(contentsOf: urls.previous) == previousBeforeSave)
        // 正常读取应采用刚保存的新 current。
        let current = try #require(
            try store.loadDraftWithRecoverySource(for: nil, untitledID: documentID)
        )
        // 新 current 必须完整且不带回退标记。
        #expect(current.draft == newest)
        #expect(!current.recoveredFromPrevious)
        // 再次损坏 current，确认 previous 仍可重复恢复。
        try Data("{".utf8).write(to: urls.current)
        // 第二次回退仍必须得到原第一代。
        let fallback = try #require(
            try store.loadDraftWithRecoverySource(for: nil, untitledID: documentID)
        )
        // previous 未被坏 current 或新保存污染。
        #expect(fallback.draft == first)
        #expect(fallback.recoveredFromPrevious)
    }

    // 两代都损坏时必须拒绝用新正文覆盖仅存证据。
    @Test("双代损坏阻止覆盖")
    func testBothCorruptGenerationsBlockReplacement() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建隔离草稿存储和稳定文档身份。
        let store = DocumentSupportStore(rootDirectory: root)
        let documentID = UUID()
        // 连续两次保存生成 current 和 previous。
        _ = try store.saveDraft("上一代", for: nil, untitledID: documentID)
        _ = try store.saveDraft("当前代", for: nil, untitledID: documentID)
        // 计算双代地址并注入不同损坏字节。
        let urls = try draftURLs(root: root, store: store, fileURL: nil, untitledID: documentID)
        try Data("{bad-current".utf8).write(to: urls.current)
        try Data("{bad-previous".utf8).write(to: urls.previous)
        // 捕获保存尝试前的两份唯一证据。
        let currentEvidence = try Data(contentsOf: urls.current)
        let previousEvidence = try Data(contentsOf: urls.previous)
        // 记录新保存是否按故障保护要求失败。
        var replacementWasBlocked = false
        do {
            // 没有有效备份时不得覆盖损坏 current。
            _ = try store.saveDraft("不能覆盖证据", for: nil, untitledID: documentID)
        } catch {
            // 任一明确错误都表示存储层拒绝了不安全替换。
            replacementWasBlocked = true
        }
        // 新保存必须失败而不是伪报草稿安全。
        #expect(replacementWasBlocked)
        // current 和 previous 原始证据必须逐字节保留。
        #expect(try Data(contentsOf: urls.current) == currentEvidence)
        #expect(try Data(contentsOf: urls.previous) == previousEvidence)
    }

    // current 身份错配可读取匹配 previous，但任何新写入仍必须拒绝覆盖错配证据。
    @Test("身份错配只允许严格回退")
    func testMismatchedCurrentFallsBackButBlocksWrite() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建隔离草稿存储和目标标签身份。
        let store = DocumentSupportStore(rootDirectory: root)
        let expectedID = UUID()
        // 第一代将在下一次保存后成为匹配目标的 previous。
        let expectedPrevious = try store.saveDraft(
            "目标上一代",
            for: nil,
            untitledID: expectedID,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        // 第二次保存生成双代文件。
        _ = try store.saveDraft(
            "目标当前代",
            for: nil,
            untitledID: expectedID,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        // 计算目标稳定键对应的双代地址。
        let urls = try draftURLs(root: root, store: store, fileURL: nil, untitledID: expectedID)
        // 构造可解码但属于其他标签的 current。
        let mismatchedDraft = DocumentDraft(
            text: "其他标签正文",
            fileURL: nil,
            untitledID: UUID(),
            encoding: .utf8,
            includesByteOrderMark: false,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        // 用正式日期策略编码身份错配 JSON。
        try encodedDraft(mismatchedDraft).write(to: urls.current)
        // 读取允许越过错配 current，但 previous 仍必须匹配目标 UUID。
        let fallback = try #require(
            try store.loadDraftWithRecoverySource(for: nil, untitledID: expectedID)
        )
        // 返回内容必须来自匹配目标的 previous。
        #expect(fallback.draft == expectedPrevious)
        #expect(fallback.recoveredFromPrevious)
        // 保存前记录两份原始证据。
        let currentEvidence = try Data(contentsOf: urls.current)
        let previousEvidence = try Data(contentsOf: urls.previous)
        // 记录写入是否以身份错配明确失败。
        var writeRejectedIdentity = false
        do {
            // 写入不能像读取一样越过错配 current，否则会覆盖其他文档证据。
            _ = try store.saveDraft("不得覆盖", for: nil, untitledID: expectedID)
        } catch DocumentSupportError.draftIdentityMismatch {
            // 精确错误证明失败原因是身份隔离而非偶然 IO。
            writeRejectedIdentity = true
        }
        // 写入必须被身份隔离拒绝。
        #expect(writeRejectedIdentity)
        // 两代内容必须保持原样。
        #expect(try Data(contentsOf: urls.current) == currentEvidence)
        #expect(try Data(contentsOf: urls.previous) == previousEvidence)

        // 再把 previous 换成另一个可解码但错配的标签草稿。
        let mismatchedPreviousEvidence = try encodedDraft(mismatchedDraft)
        // 写入后保留精确字节供删除失败断言复用。
        try mismatchedPreviousEvidence.write(to: urls.previous)
        // 记录两代都错配时读取是否显式失败。
        var loadRejectedIdentity = false
        do {
            // 两代都不属于目标时绝不能返回任意一份正文。
            _ = try store.loadDraftWithRecoverySource(for: nil, untitledID: expectedID)
        } catch DocumentSupportError.draftIdentityMismatch {
            // previous 严格校验必须保留身份错误。
            loadRejectedIdentity = true
        }
        // 双错配读取必须失败。
        #expect(loadRejectedIdentity)
        // 删除也必须执行相同身份校验，不能用目标哈希键直接删除其他文档记录。
        var removalRejectedIdentity = false
        do {
            // 模拟成功保存、明确丢弃或干净关闭触发的双代清理。
            try store.removeDraft(for: nil, untitledID: expectedID)
        } catch DocumentSupportError.draftIdentityMismatch {
            // 精确错误证明删除路径同样执行身份隔离。
            removalRejectedIdentity = true
        }
        // 错配记录必须拒绝删除。
        #expect(removalRejectedIdentity)
        // current 错配正文必须仍在原位。
        #expect(try Data(contentsOf: urls.current) == currentEvidence)
        // previous 已更新为另一份错配记录，也必须继续存在。
        #expect(try Data(contentsOf: urls.previous) == mismatchedPreviousEvidence)
    }

    // current 有效时应优先读取，并可在下一次轮换中修复损坏 previous。
    @Test("有效当前代修复损坏上一代")
    func testValidCurrentRepairsCorruptPrevious() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建隔离草稿存储和稳定标签身份。
        let store = DocumentSupportStore(rootDirectory: root)
        let documentID = UUID()
        // 生成第一代和当前第二代。
        _ = try store.saveDraft(
            "第一代",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let second = try store.saveDraft(
            "有效第二代",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        // 计算双代地址并只损坏 previous。
        let urls = try draftURLs(root: root, store: store, fileURL: nil, untitledID: documentID)
        try Data("{bad-previous".utf8).write(to: urls.previous)
        // current 有效时读取不得被坏 previous 干扰。
        let current = try #require(
            try store.loadDraftWithRecoverySource(for: nil, untitledID: documentID)
        )
        // 读取必须返回第二代 current。
        #expect(current.draft == second)
        #expect(!current.recoveredFromPrevious)

        // 第三次保存应使用已验证 current 修复 previous。
        _ = try store.saveDraft(
            "第三代",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        // 损坏第三代 current 以强制验证 repaired previous。
        try Data("{".utf8).write(to: urls.current)
        // repaired previous 必须可以正常回退。
        let repairedFallback = try #require(
            try store.loadDraftWithRecoverySource(for: nil, untitledID: documentID)
        )
        // 修复后的 previous 应精确等于保存前的有效第二代。
        #expect(repairedFallback.draft == second)
        #expect(repairedFallback.recoveredFromPrevious)
    }

    // 删除必须覆盖 current/previous 两代，并继续阻止已经预留的旧后台请求复活。
    @Test("删除双代并阻止旧请求复活")
    func testRemovalDeletesBothGenerationsAndKeepsBarrier() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建隔离草稿存储和稳定标签身份。
        let store = DocumentSupportStore(rootDirectory: root)
        let documentID = UUID()
        // 连续两次保存生成 current 和 previous。
        _ = try store.saveDraft("第一代", for: nil, untitledID: documentID)
        _ = try store.saveDraft("第二代", for: nil, untitledID: documentID)
        // 删除前预留一个尚未提交的旧后台写入。
        let staleReservation = try store.reserveDraftWrite(
            "过期第三代",
            for: nil,
            untitledID: documentID
        )
        // 计算双代地址并确认前置条件成立。
        let urls = try draftURLs(root: root, store: store, fileURL: nil, untitledID: documentID)
        #expect(FileManager.default.fileExists(atPath: urls.current.path))
        #expect(FileManager.default.fileExists(atPath: urls.previous.path))

        // 正式清理必须在同一 generation 序列中删除两代。
        try store.removeDraft(for: nil, untitledID: documentID)
        // current 和 previous 都不得残留。
        #expect(!FileManager.default.fileExists(atPath: urls.current.path))
        #expect(!FileManager.default.fileExists(atPath: urls.previous.path))
        // 记录旧 reservation 是否被删除屏障明确拒绝。
        var staleWasSuperseded = false
        do {
            // 删除前预留、删除后完成的任务不得重新创建任一代。
            _ = try store.commitDraftWrite(staleReservation)
        } catch DocumentSupportError.draftWriteSuperseded {
            // 精确错误证明双代删除仍复用原单调序号屏障。
            staleWasSuperseded = true
        }
        // 旧后台请求必须失败且文件不能复活。
        #expect(staleWasSuperseded)
        #expect(!FileManager.default.fileExists(atPath: urls.current.path))
        #expect(!FileManager.default.fileExists(atPath: urls.previous.path))
    }

    // current 缺失时仍应恢复独立有效 previous，保证原子替换边缘状态可达。
    @Test("当前代缺失时恢复上一代")
    func testMissingCurrentLoadsPrevious() throws {
        // 建立本测试独享临时目录。
        let root = try makeTemporaryDirectory()
        // 测试结束后只清理本次唯一目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 创建隔离草稿存储和稳定标签身份。
        let store = DocumentSupportStore(rootDirectory: root)
        let documentID = UUID()
        // 生成可作为 previous 的第一代。
        let first = try store.saveDraft(
            "独立上一代",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        // 第二次保存形成双代布局。
        _ = try store.saveDraft(
            "将被移除的当前代",
            for: nil,
            untitledID: documentID,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        // 计算双代地址并只移除 current。
        let urls = try draftURLs(root: root, store: store, fileURL: nil, untitledID: documentID)
        try FileManager.default.removeItem(at: urls.current)
        // 加载应直接尝试仍存在的 previous。
        let fallback = try #require(
            try store.loadDraftWithRecoverySource(for: nil, untitledID: documentID)
        )
        // previous 必须恢复原第一代并报告来源。
        #expect(fallback.draft == first)
        #expect(fallback.recoveredFromPrevious)
    }

    // 计算生产代码稳定键对应的 current 和 previous 测试地址。
    private func draftURLs(
        root: URL,
        store: DocumentSupportStore,
        fileURL: URL?,
        untitledID: UUID?
    ) throws -> (current: URL, previous: URL) {
        // 复用生产键算法，避免测试复制哈希实现。
        let key = try store.draftKey(for: fileURL, untitledID: untitledID)
        // 草稿统一位于产品根目录下的 Drafts 子目录。
        let draftsDirectory = root.appendingPathComponent("Drafts", isDirectory: true)
        // current 保持 v0.7 的原文件名。
        let current = draftsDirectory.appendingPathComponent("\(key).json", isDirectory: false)
        // previous 使用固定双扩展名且不改变文档键。
        let previous = draftsDirectory.appendingPathComponent("\(key).previous.json", isDirectory: false)
        // 一次返回两代精确地址。
        return (current, previous)
    }

    // 使用生产草稿日期策略编码故障注入记录。
    private func encodedDraft(_ draft: DocumentDraft) throws -> Data {
        // 测试编码器必须与生产 ISO 8601 日期格式一致。
        let encoder = JSONEncoder()
        // 设置稳定日期格式，确保错配 JSON 本身完全可解码。
        encoder.dateEncodingStrategy = .iso8601
        // 返回完整草稿 JSON。
        return try encoder.encode(draft)
    }
}
