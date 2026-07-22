import Foundation

// 持久化一个标签的稳定身份和可选文件地址，不重复保存正文。
struct WorkspaceSessionDocument: Codable, Equatable, Identifiable {
    // UUID 同时定位未命名草稿和活动标签。
    let id: UUID
    // 已命名标签保存规范化本地地址，未命名标签保持 nil。
    let fileURL: URL?
}

// 保存上次退出时的标签顺序和活动标签。
struct WorkspaceSessionState: Codable, Equatable {
    // 数组顺序就是标签栏顺序。
    let documents: [WorkspaceSessionDocument]
    // 活动 UUID 不存在时恢复首个有效标签。
    let activeDocumentID: UUID?
}

// 用单个原子 JSON 文件管理工作区会话。
final class WorkspaceSessionStore {
    // 与文档草稿共用产品目录但使用独立文件。
    private static let applicationFolderName = "MarkdownLiteMac"
    // 固定文件名避免产生多份互相冲突的会话。
    private static let sessionFilename = "WorkspaceSession.json"

    // 保留注入的文件管理器，便于隔离自检。
    private let fileManager: FileManager
    // 保存会话文件的产品目录。
    private let rootDirectory: URL
    // JSON 编码器集中输出可读格式。
    private let encoder: JSONEncoder
    // JSON 解码器恢复同一结构。
    private let decoder: JSONDecoder

    // 默认写入 Application Support，也允许测试注入临时目录。
    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        // 后续路径检查和写入统一使用同一个文件管理器。
        self.fileManager = fileManager
        // 测试目录优先，正式运行使用稳定产品目录。
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        // 创建确定性 JSON 编码器。
        encoder = JSONEncoder()
        // 排序键便于人工排查损坏会话。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 创建配套解码器。
        decoder = JSONDecoder()
    }

    // 原子保存完整标签顺序和活动标签。
    func save(_ state: WorkspaceSessionState) throws {
        // 首次保存前创建产品目录。
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // 在内存完成编码，失败时不触碰已有会话。
        let data = try encoder.encode(state)
        // 原子替换保证崩溃后只会留下新旧完整版本之一。
        try data.write(to: sessionFileURL, options: [.atomic])
    }

    // 读取上次会话；首次启动没有文件属于正常状态。
    func load() throws -> WorkspaceSessionState? {
        // 文件不存在时让工作区创建首个未命名标签。
        guard fileManager.fileExists(atPath: sessionFileURL.path) else { return nil }
        // 一次读取完整 JSON，避免标签顺序来自不同时刻。
        let data = try Data(contentsOf: sessionFileURL)
        // 解码失败显式抛出，由工作区安全回退新会话。
        return try decoder.decode(WorkspaceSessionState.self, from: data)
    }

    // 计算固定会话文件地址。
    private var sessionFileURL: URL {
        // 会话文件不与 Drafts 子目录混放。
        rootDirectory.appendingPathComponent(Self.sessionFilename, isDirectory: false)
    }

    // 获取与文档支撑层一致的默认产品目录。
    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        // 优先使用系统用户级 Application Support。
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        // 极端环境没有系统目录时回退到用户 Library 标准路径。
        let baseDirectory =
            applicationSupport
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        // 固定产品名确保调试包和正式包恢复同一会话。
        return baseDirectory.appendingPathComponent(applicationFolderName, isDirectory: true)
    }
}

// 验证会话顺序和活动标签可以跨进程往返恢复。
enum SessionSupportSelfCheck {
    // 在独立临时目录运行，不读取或修改真实用户会话。
    static func run(fileManager: FileManager = .default) throws -> String {
        // 为本次自检生成精确唯一目录。
        let rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MarkdownLiteMac-SessionSelfCheck-\(UUID().uuidString)", isDirectory: true)
        // 结束后只清理本次唯一目录。
        defer { try? fileManager.removeItem(at: rootDirectory) }
        // 注入临时目录创建会话存储。
        let store = WorkspaceSessionStore(rootDirectory: rootDirectory, fileManager: fileManager)
        // 使用固定 UUID 让失败结果可重复定位。
        let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let secondID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        // 同时覆盖未命名和已命名标签描述。
        let expected = WorkspaceSessionState(
            documents: [
                WorkspaceSessionDocument(id: firstID, fileURL: nil),
                WorkspaceSessionDocument(
                    id: secondID,
                    fileURL: rootDirectory.appendingPathComponent("文章.md").standardizedFileURL
                ),
            ],
            activeDocumentID: secondID
        )
        // 走正式原子保存路径。
        try store.save(expected)
        // 从磁盘重新读取而非复用内存对象。
        let restored = try store.load()
        // 顺序、地址和活动 UUID 必须完全一致。
        guard restored == expected else {
            throw DocumentSupportError.selfCheckFailed("工作区会话往返")
        }
        // 输出紧凑通过标记供总自检展示。
        return "SessionSupportSelfCheck：标签顺序与活动标签恢复通过"
    }
}
