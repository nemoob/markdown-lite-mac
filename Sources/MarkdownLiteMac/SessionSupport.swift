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

    // 判断会话是否具备可安全尝试恢复的最小身份布局。
    var hasValidDocumentIdentityLayout: Bool {
        // 正常工作区始终至少有一个标签，空数组不能覆盖仍可能有效的上一代。
        guard !documents.isEmpty else { return false }
        // UUID 是未命名草稿的唯一入口，恢复前必须保证整组身份不重复。
        var documentIDs = Set<UUID>()
        // 逐项登记 UUID，任何重复都让本代整体失去确定恢复语义。
        for document in documents {
            // 插入失败表示两个标签会竞争同一草稿和活动标签身份。
            guard documentIDs.insert(document.id).inserted else { return false }
        }
        // 非空且 UUID 全部唯一时才允许工作区继续解析具体文档。
        return true
    }
}

// 返回会话内容以及本次是否使用上一代恢复。
struct WorkspaceSessionLoadResult: Equatable {
    // 保存已经成功解码的完整会话。
    let state: WorkspaceSessionState
    // true 表示当前代不可用且已经回退上一代。
    let recoveredFromPrevious: Bool
}

// 返回一次损坏会话归档的确定目录和逐代文件地址。
struct WorkspaceSessionArchiveResult: Equatable {
    // 每次归档使用独立目录，避免覆盖之前保留的恢复证据。
    let directoryURL: URL
    // 文件顺序与 current、previous 的检查顺序一致。
    let archivedFileURLs: [URL]
}

// 汇总归档重建入口可以稳定区分的安全拒绝原因。
enum WorkspaceSessionArchiveError: LocalizedError, Equatable {
    // 没有任何会话代时不能伪造一次损坏恢复。
    case noGenerations
    // 任一代仍可恢复时必须继续使用现有正常恢复路径。
    case recoverableGenerationExists
    // 调用方复用了相同日期和标识时不能覆盖既有归档。
    case archiveDestinationAlreadyExists
    // 归档副本与原始字节不一致时不能清理原槽位。
    case archiveVerificationFailed
    // 安装新 current 后路径又发生变化时不能用旧快照覆盖新字节。
    case generationsChangedDuringArchive

    // 返回不暴露正文或完整本机路径的可操作说明。
    var errorDescription: String? {
        // 按失败阶段提供稳定中文反馈。
        switch self {
        case .noGenerations:
            // 首次启动没有损坏证据，不需要归档重建。
            return "没有需要归档的会话恢复文件"
        case .recoverableGenerationExists:
            // 有效会话必须通过正常加载使用，不能被恢复操作移走。
            return "仍有可恢复的会话，已拒绝归档重建"
        case .archiveDestinationAlreadyExists:
            // 归档目录碰撞时要求调用方使用新标识重试。
            return "会话归档目录已存在，请使用新的恢复标识重试"
        case .archiveVerificationFailed:
            // 校验失败时原会话槽位保持不变。
            return "会话归档校验失败，原始恢复文件仍保留"
        case .generationsChangedDuringArchive:
            // Finder 或其他工具更新了 current 时保留新字节并要求用户重新检查。
            return "归档期间当前会话文件发生变化，未覆盖外部更新，请重新检查后再试"
        }
    }
}

// 用当前和上一代两个原子 JSON 文件管理工作区会话。
final class WorkspaceSessionStore {
    // 与文档草稿共用产品目录但使用独立文件。
    private static let applicationFolderName = "MarkdownLiteMac"
    // 保留 v0.7 固定文件名以兼容已经落盘的会话。
    private static let sessionFilename = "WorkspaceSession.json"
    // 上一代文件在当前文件损坏或缺失时提供一次回退。
    private static let previousSessionFilename = "WorkspaceSession.previous.json"
    // 损坏会话归档集中放在产品目录下，便于后续 Finder 入口定位。
    private static let archiveFolderName = "RecoveryArchives"

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

    // 暴露实际存储目录供恢复界面打开 Finder，不允许调用方修改内部路径。
    var storageDirectoryURL: URL {
        // 返回初始化时已经确定的产品目录。
        rootDirectory
    }

    // 返回当前真实存在的会话代，顺序固定为 current、previous。
    var existingGenerationURLs: [URL] {
        // 固定候选顺序让归档结果和测试都可预测。
        [sessionFileURL, previousSessionFileURL].filter {
            // 只返回磁盘上仍存在的精确槽位。
            fileManager.fileExists(atPath: $0.path)
        }
    }

    // 原子保存完整标签顺序和活动标签。
    func save(_ state: WorkspaceSessionState) throws {
        // 首次保存前创建产品目录。
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // 在内存完成编码，失败时不触碰已有会话。
        let data = try encoder.encode(state)
        // 只有当前代存在时才尝试晋升为上一代。
        if fileManager.fileExists(atPath: sessionFileURL.path) {
            // 预留通过验证后才能晋升的当前代原始数据。
            let currentData: Data
            do {
                // 先完整读取当前代，读取失败时视为不可用证据。
                currentData = try Data(contentsOf: sessionFileURL)
                // 完整解码确认当前代确实可以用于恢复。
                _ = try decoder.decode(WorkspaceSessionState.self, from: currentData)
            } catch {
                // 当前代不可用时必须先证明上一代仍可恢复。
                guard try hasValidPreviousSession() else {
                    // 没有有效上一代时保留损坏当前代并拒绝覆盖。
                    throw error
                }
                // 有效上一代保持不变，只原子修复当前代。
                try data.write(to: sessionFileURL, options: [.atomic])
                // 修复完成后不再执行正常轮换，避免覆盖恢复来源。
                return
            }
            // 原子保存已验证的当前代，确保回退文件始终是完整 JSON。
            try currentData.write(to: previousSessionFileURL, options: [.atomic])
        } else if fileManager.fileExists(atPath: previousSessionFileURL.path) {
            // current 缺失时必须先验证唯一 previous，避免后续轮换覆盖损坏证据。
            _ = try loadSession(at: previousSessionFileURL)
        }
        // 原子替换当前代，保证崩溃后只会留下新旧完整版本之一。
        try data.write(to: sessionFileURL, options: [.atomic])
    }

    // 优先读取当前代，损坏或缺失时回退上一代。
    func load() throws -> WorkspaceSessionState? {
        // 复用带来源结果，保持既有调用方只接收会话内容。
        try loadWithRecoverySource()?.state
    }

    // 加载会话并返回是否从上一代恢复，供工作区展示明确提示。
    func loadWithRecoverySource() throws -> WorkspaceSessionLoadResult? {
        // 暂存当前代失败，便于上一代也不存在时显式抛出原始错误。
        var currentFailure: Error?
        // 当前代存在时始终优先使用，保持正常恢复行为不变。
        if fileManager.fileExists(atPath: sessionFileURL.path) {
            do {
                // 一次读取和解码完整当前代，避免标签顺序来自不同时刻。
                let state = try loadSession(at: sessionFileURL)
                // 标记正常使用当前代，避免界面误报发生了恢复。
                return WorkspaceSessionLoadResult(state: state, recoveredFromPrevious: false)
            } catch {
                // 当前代失败不立即回退新标签，先尝试上一代。
                currentFailure = error
            }
        }
        // 当前代缺失或损坏时尝试唯一的上一代副本。
        if fileManager.fileExists(atPath: previousSessionFileURL.path) {
            // 完整读取上一代，上一次损坏时继续显式抛出。
            let state = try loadSession(at: previousSessionFileURL)
            // 标记本次来自上一代，供工作区展示恢复提示。
            return WorkspaceSessionLoadResult(state: state, recoveredFromPrevious: true)
        }
        // 当前代损坏且没有上一代时不能伪装成首次启动。
        if let currentFailure {
            // 抛出当前代原始错误供界面和日志定位。
            throw currentFailure
        }
        // 两代都不存在属于首次启动，由工作区创建首个未命名标签。
        return nil
    }

    // 单独读取上一代，供工作区在当前代可解码但无法实际恢复标签时继续回退。
    func loadPreviousGeneration() throws -> WorkspaceSessionState? {
        // 上一代不存在时由工作区决定创建首次标签或保留当前结论。
        guard fileManager.fileExists(atPath: previousSessionFileURL.path) else { return nil }
        // 仍走完整读取和解码，损坏上一代不能被误当成安全候选。
        return try loadSession(at: previousSessionFileURL)
    }

    // 从上一代恢复后只修复 current，不把语义失效的旧 current 晋升并覆盖恢复来源。
    func saveRecoveredCurrent(_ state: WorkspaceSessionState) throws {
        // 修复前确保产品目录仍可访问。
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // 在内存完成编码，失败时 current 和 previous 都保持原样。
        let data = try encoder.encode(state)
        // previous 必须仍然完整可解码，才能作为本次修复的可信恢复来源。
        _ = try loadSession(at: previousSessionFileURL)
        // 原子替换 current，同时让 previous 字节保持不变供再次回退。
        try data.write(to: sessionFileURL, options: [.atomic])
    }

    // 归档全部不可恢复的现有代，并用调用方当前内存状态安装有效 current。
    func archiveCorruptedGenerationsAndReset(
        to state: WorkspaceSessionState,
        date: Date = Date(),
        identifier: UUID = UUID()
    ) throws -> WorkspaceSessionArchiveResult {
        // 读取一次固定顺序快照，后续操作不能因文件变化跳过某一代。
        let generationURLs = existingGenerationURLs
        // 两代都不存在属于首次启动，不能执行破坏性恢复动作。
        guard !generationURLs.isEmpty else {
            // 使用稳定错误让 UI 保持普通首次启动流程。
            throw WorkspaceSessionArchiveError.noGenerations
        }
        // 一次读入每个现有代的原始字节，归档和有效性判断必须使用同一份快照。
        let originalGenerations = try generationURLs.map { generationURL in
            // 原始 Data 必须在创建归档前完整读取成功。
            (url: generationURL, data: try Data(contentsOf: generationURL))
        }
        // 任一快照可完整解码时必须拒绝归档，继续使用既有安全回退。
        for original in originalGenerations
        where (try? decoder.decode(WorkspaceSessionState.self, from: original.data)) != nil {
            // 不允许把仍可恢复的用户会话移入故障归档。
            throw WorkspaceSessionArchiveError.recoverableGenerationExists
        }

        // 在触碰任何原文件前完成新会话编码，排除编码失败造成的半归档状态。
        let replacementData = try encoder.encode(state)
        // 立即回读编码结果，确保随后写入的数据可恢复成完全相同的状态。
        guard try decoder.decode(WorkspaceSessionState.self, from: replacementData) == state else {
            // 理论异常仍按归档验证失败保守停止。
            throw WorkspaceSessionArchiveError.archiveVerificationFailed
        }
        // 日期与调用方标识共同生成不会覆盖历史的确定目录名。
        let archiveDirectory = archiveDirectoryURL(date: date, identifier: identifier)
        // 既有同名目录可能包含上次证据，绝不能复用或覆盖。
        guard !fileManager.fileExists(atPath: archiveDirectory.path) else {
            // 调用方可以更换默认随机标识后安全重试。
            throw WorkspaceSessionArchiveError.archiveDestinationAlreadyExists
        }

        // 记录已经逐字节验证的归档文件，成功结果按相同顺序返回。
        var archivedFileURLs: [URL] = []
        do {
            // 创建本次独立目录及缺失的 RecoveryArchives 父目录。
            try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            // 每一代先复制到归档并回读验证，验证完成前不删除原槽位。
            for original in originalGenerations {
                // 保留正式文件名，便于人工区分 current 与 previous。
                let archivedURL = archiveDirectory.appendingPathComponent(
                    original.url.lastPathComponent,
                    isDirectory: false
                )
                // 原子写入归档副本，失败不会留下半个目标文件。
                try original.data.write(to: archivedURL, options: [.atomic])
                // 回读归档字节，不能只依赖 write 没有抛错。
                let archivedData = try Data(contentsOf: archivedURL)
                // 任一字节不一致都停止在原槽位尚未变化的阶段。
                guard archivedData == original.data else {
                    // 抛出稳定校验错误并进入下方清理部分目录。
                    throw WorkspaceSessionArchiveError.archiveVerificationFailed
                }
                // 本代验证成功后加入最终结果。
                archivedFileURLs.append(archivedURL)
            }
        } catch {
            // 原槽位尚未触碰，可尽力移除本次不完整归档目录避免混淆。
            try? fileManager.removeItem(at: archiveDirectory)
            // 保留原始失败原因供调用方反馈。
            throw error
        }

        // 先在归档中永久保留本次拟重建状态，外部后写 current 时仍可人工找回。
        let rebuiltSessionURL = archiveDirectory.appendingPathComponent(
            "WorkspaceSession.rebuilt.json",
            isDirectory: false
        )
        // 独立原子副本不与正式 current 共享 inode，外部原地写入也不会污染它。
        try replacementData.write(to: rebuiltSessionURL, options: [.atomic])
        // 回读确认归档中的重建状态逐字节完整。
        guard try Data(contentsOf: rebuiltSessionURL) == replacementData else {
            // 永久副本不完整时不能继续安装正式 current。
            throw WorkspaceSessionArchiveError.archiveVerificationFailed
        }
        // 再创建供系统原子安装消费的同卷临时副本。
        let replacementURL = archiveDirectory.appendingPathComponent(
            "WorkspaceSession.replacement.json",
            isDirectory: false
        )
        // 原子写保证待安装文件本身不会是半份 JSON，也不复用永久副本 inode。
        try replacementData.write(to: replacementURL, options: [.atomic])
        // 记录调用开始时是否存在 current，决定采用原子替换还是无覆盖硬链接。
        if let currentOriginal = originalGenerations.first(where: {
            // 精确比较固定 current 地址，不能按数组位置猜测。
            $0.url == sessionFileURL
        }) {
            // 唯一备份名位于会话根目录，replaceItemAt 会原子保留提交瞬间的旧 current。
            let displacedFilename =
                "WorkspaceSession.replaced-\(identifier.uuidString.lowercased()).json"
            // 计算 replaceItemAt 成功后应留下的精确备份地址。
            let displacedURL = rootDirectory.appendingPathComponent(
                displacedFilename,
                isDirectory: false
            )
            // 既有同名备份可能属于中断恢复，绝不能覆盖。
            guard !fileManager.fileExists(atPath: displacedURL.path) else {
                // 与归档目录碰撞使用同一安全拒绝语义。
                throw WorkspaceSessionArchiveError.archiveDestinationAlreadyExists
            }
            // 原子替换让 current 始终存在，并把提交瞬间被替换的精确字节放到备份路径。
            _ = try fileManager.replaceItemAt(
                sessionFileURL,
                withItemAt: replacementURL,
                backupItemName: displacedFilename,
                options: [.withoutDeletingBackupItem]
            )
            // 读取精确被替换的 current，不能假定它仍等于调用开始时的快照。
            let displacedData = try Data(contentsOf: displacedURL)
            // 提交前若有外部更新，必须把这份额外字节也移入本次归档。
            if displacedData != currentOriginal.data {
                // 使用独立文件名同时保留初始快照和提交瞬间的外部更新。
                let changedArchiveURL = archiveDirectory.appendingPathComponent(
                    "WorkspaceSession.changed-during-archive.json",
                    isDirectory: false
                )
                // 同卷移动不会复制或覆盖字节，目标在唯一归档目录内必定不存在。
                try fileManager.moveItem(at: displacedURL, to: changedArchiveURL)
                // 回读移动后的文件，确认额外证据仍逐字节完整。
                guard try Data(contentsOf: changedArchiveURL) == displacedData else {
                    // 任何不一致都保持归档目录并显式失败。
                    throw WorkspaceSessionArchiveError.archiveVerificationFailed
                }
                // 结果中加入额外变化代，Finder 和测试都能精确定位。
                archivedFileURLs.append(changedArchiveURL)
            } else {
                // 初始快照已经完整归档，相同备份只是冗余副本。
                try? fileManager.removeItem(at: displacedURL)
            }
        } else {
            // current 原本缺失时以硬链接原子创建，若外部刚创建同名文件则绝不覆盖。
            try fileManager.linkItem(at: replacementURL, to: sessionFileURL)
            // current 已拥有同一完整 inode 后，归档内的替代链接只是冗余副本。
            try? fileManager.removeItem(at: replacementURL)
        }

        // 精确比较正式 current 与本事务字节，外部后写时绝不进行破坏性回滚。
        guard try Data(contentsOf: sessionFileURL) == replacementData else {
            // 初始和提交瞬间的证据都已归档，保留外部 current 并要求重新检查。
            throw WorkspaceSessionArchiveError.generationsChangedDuringArchive
        }
        // 再走正式解码路径，确认下次启动能恢复成调用方的完整状态。
        guard try loadSession(at: sessionFileURL) == state else {
            // 字节相同却无法恢复属于稳定归档校验失败。
            throw WorkspaceSessionArchiveError.archiveVerificationFailed
        }

        // previous 不参与清理，避免任何校验到删除之间的竞态和双槽为空窗口。
        if let previousOriginal = originalGenerations.first(where: {
            // 精确匹配 previous，只有调用开始时存在才检查后续外部变化。
            $0.url == previousSessionFileURL
        }),
            let latestPreviousData = try? Data(contentsOf: previousSessionFileURL),
            latestPreviousData != previousOriginal.data
        {
            // 变化的 previous 使用独立名称追加归档，不修改仍在原槽位的新字节。
            let changedPreviousArchiveURL = archiveDirectory.appendingPathComponent(
                "WorkspaceSession.previous.changed-during-archive.json",
                isDirectory: false
            )
            // 原子复制最新可读快照，失败时原 previous 仍保持不变。
            try latestPreviousData.write(to: changedPreviousArchiveURL, options: [.atomic])
            // 回读确认额外 previous 证据完整。
            guard try Data(contentsOf: changedPreviousArchiveURL) == latestPreviousData else {
                // 归档不完整时保留原槽位并显式失败。
                throw WorkspaceSessionArchiveError.archiveVerificationFailed
            }
            // 成功结果包含这份并发变化的 previous。
            archivedFileURLs.append(changedPreviousArchiveURL)
        }

        // 成功结果提供目录和每一代的精确归档地址。
        return WorkspaceSessionArchiveResult(
            directoryURL: archiveDirectory,
            archivedFileURLs: archivedFileURLs
        )
    }

    // 检查当前代损坏后是否仍有可用于恢复的上一代。
    private func hasValidPreviousSession() throws -> Bool {
        // 上一代不存在时由保存调用方保留当前损坏证据并失败。
        guard fileManager.fileExists(atPath: previousSessionFileURL.path) else { return false }
        // 完整读取和解码，任何失败都阻止覆盖当前损坏证据。
        _ = try loadSession(at: previousSessionFileURL)
        // 成功解码表示可以安全修复当前代。
        return true
    }

    // 从指定代完整读取并解码一个会话。
    private func loadSession(at fileURL: URL) throws -> WorkspaceSessionState {
        // 一次读取完整 JSON，避免标签顺序来自不同时刻。
        let data = try Data(contentsOf: fileURL)
        // 解码失败显式抛出，由调用方决定是否继续回退。
        return try decoder.decode(WorkspaceSessionState.self, from: data)
    }

    // 计算一次确定归档目录，调用方 UUID 保证相同时间也不会碰撞。
    private func archiveDirectoryURL(date: Date, identifier: UUID) -> URL {
        // 毫秒时间便于按创建顺序查看，同时避免文件名包含冒号。
        let timestamp = Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
        // UUID 统一小写，保证测试和跨启动结果稳定。
        let directoryName = "WorkspaceSession-\(timestamp)-\(identifier.uuidString.lowercased())"
        // 所有会话故障归档集中在固定父目录下。
        return
            rootDirectory
            .appendingPathComponent(Self.archiveFolderName, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    // 计算固定会话文件地址。
    private var sessionFileURL: URL {
        // 会话文件不与 Drafts 子目录混放。
        rootDirectory.appendingPathComponent(Self.sessionFilename, isDirectory: false)
    }

    // 计算固定上一代会话文件地址。
    private var previousSessionFileURL: URL {
        // 上一代与当前代同目录，便于两次原子替换独立完成。
        rootDirectory.appendingPathComponent(Self.previousSessionFilename, isDirectory: false)
    }

    // 获取与文档支撑层一致的默认产品目录。
    static func defaultRootDirectory(fileManager: FileManager) -> URL {
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

// 汇总双代恢复在固定大样本上的可复核性能结果。
struct RecoverySupportSelfCheckReport: Equatable {
    // 草稿样本必须至少覆盖 1MB UTF-8 正文。
    let draftBytes: Int
    // 双代轮换包含读取校验、上一代原子写和当前代原子写。
    let draftSaveMedianMilliseconds: Double
    // 草稿回退包含损坏 current 解码失败和有效 previous 完整解码。
    let draftFallbackMedianMilliseconds: Double
    // 会话回退覆盖 100 个标签描述的双代读取。
    let sessionFallbackMedianMilliseconds: Double
}

// 在隔离临时目录验证双代恢复功能并执行发布配置性能门禁。
enum RecoverySupportSelfCheck {
    // 1MB 后台草稿轮换不应超过可感知的长任务上限。
    private static let draftSaveTargetMilliseconds = 100.0
    // 启动时读取 1MB 上一代草稿需要保持快速。
    private static let draftFallbackTargetMilliseconds = 50.0
    // 100 标签会话属于小型元数据，回退应在短时限内完成。
    private static let sessionFallbackTargetMilliseconds = 20.0

    // 默认在发布自检严格执行阈值；标准测试只核对确定性样本和行为。
    static func run(
        fileManager: FileManager = .default,
        enforcePerformanceTargets: Bool = true
    ) throws -> RecoverySupportSelfCheckReport {
        // 为本次跨存储测量创建精确唯一目录。
        let rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MarkdownLiteMac-RecoverySelfCheck-\(UUID().uuidString)", isDirectory: true)
        // 结束后只清理本次唯一目录，不接触真实用户恢复数据。
        defer { try? fileManager.removeItem(at: rootDirectory) }
        // 提前创建目录，让权限失败在任何测量开始前显式抛出。
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        // 草稿测量使用独立子目录，避免会话文件影响文件数和缓存行为。
        let draftRoot = rootDirectory.appendingPathComponent("draft", isDirectory: true)
        // 创建正式草稿存储以覆盖生产锁、编码和原子写路径。
        let draftStore = DocumentSupportStore(rootDirectory: draftRoot, fileManager: fileManager)
        // 固定一个未命名标签身份，保证连续保存形成同一双代槽位。
        let draftID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        // 使用纯 ASCII 构造精确 1MB UTF-8 正文，测量不混入字符串生成成本。
        let firstLargeDraft = String(repeating: "a", count: 1_000_000)
        // 第二份等长正文让每次轮换都写入真实不同内容。
        let secondLargeDraft = String(repeating: "b", count: 1_000_000)
        // 预热并建立首个 current，后续每次测量都执行完整双代轮换。
        _ = try draftStore.saveDraft(firstLargeDraft, for: nil, untitledID: draftID)
        // 五次中位数减少共享 CI 机器偶发调度抖动。
        let draftSaveMedian = try measureMedian(iterations: 5) { index in
            // 交替正文保证 current 和 previous 每次都代表不同有效版本。
            let text = index.isMultiple(of: 2) ? secondLargeDraft : firstLargeDraft
            // 完整走生产草稿保存路径。
            _ = try draftStore.saveDraft(text, for: nil, untitledID: draftID)
        }
        // 复用生产键算法定位 current 草稿以注入确定性损坏。
        let draftKey = try draftStore.draftKey(for: nil, untitledID: draftID)
        // current 文件继续使用兼容 v0.7 的固定地址。
        let currentDraftURL =
            draftRoot
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent("\(draftKey).json", isDirectory: false)
        // 只破坏 current，previous 保持最近一份有效 1MB 正文。
        try Data("{".utf8).write(to: currentDraftURL, options: [.atomic])
        // 重复读取同一故障布局，测量完整解码而不混入修复写入。
        let draftFallbackMedian = try measureMedian(iterations: 5) { _ in
            // 正式带来源 API 必须稳定返回 previous。
            let result = try draftStore.loadDraftWithRecoverySource(for: nil, untitledID: draftID)
            // 缺失结果或错误来源都表示功能失败，不能只报告速度。
            guard result?.recoveredFromPrevious == true,
                result?.draft.text.utf8.count == firstLargeDraft.utf8.count
            else {
                // 使用既有自检错误类型向总入口提供清晰原因。
                throw DocumentSupportError.selfCheckFailed("1MB 草稿上一代恢复")
            }
        }

        // 会话测量使用独立子目录，避免草稿大文件影响失败注入。
        let sessionRoot = rootDirectory.appendingPathComponent("session", isDirectory: true)
        // 创建正式会话存储覆盖生产 JSON 与双代路径。
        let sessionStore = WorkspaceSessionStore(rootDirectory: sessionRoot, fileManager: fileManager)
        // 构造 100 个稳定标签描述，覆盖常见多标签恢复上限之外的压力样本。
        let firstSessionDocuments = (0..<100).map { index in
            // 每个标签 UUID 由索引生成稳定末段，避免测量随机数生成。
            WorkspaceSessionDocument(
                id: UUID(uuidString: String(format: "AAAAAAAA-AAAA-AAAA-AAAA-%012X", index))!,
                fileURL: nil
            )
        }
        // 第一份会话将成为故障发生时的有效 previous。
        let firstSession = WorkspaceSessionState(
            documents: firstSessionDocuments,
            activeDocumentID: firstSessionDocuments.last?.id
        )
        // 第二份会话只改变活动标签，足以形成不同 current。
        let secondSession = WorkspaceSessionState(
            documents: firstSessionDocuments,
            activeDocumentID: firstSessionDocuments.first?.id
        )
        // 首次保存建立 current。
        try sessionStore.save(firstSession)
        // 第二次保存把第一份完整状态晋升为 previous。
        try sessionStore.save(secondSession)
        // 会话 current 使用稳定兼容文件名。
        let currentSessionURL = sessionRoot.appendingPathComponent("WorkspaceSession.json", isDirectory: false)
        // 注入无效 JSON，迫使每次加载都检查 previous。
        try Data("{".utf8).write(to: currentSessionURL, options: [.atomic])
        // 五次中位数覆盖 100 标签双代加载。
        let sessionFallbackMedian = try measureMedian(iterations: 5) { _ in
            // 正式加载必须返回完整 previous 与来源标记。
            let result = try sessionStore.loadWithRecoverySource()
            // 标签顺序、活动 UUID 和来源必须同时正确。
            guard result?.state == firstSession, result?.recoveredFromPrevious == true else {
                // 功能错误必须先于性能结果失败。
                throw DocumentSupportError.selfCheckFailed("100 标签会话上一代恢复")
            }
        }

        // 汇总可供命令行、标准测试和发布记录共同使用的结构化结果。
        let report = RecoverySupportSelfCheckReport(
            draftBytes: firstLargeDraft.utf8.count,
            draftSaveMedianMilliseconds: draftSaveMedian,
            draftFallbackMedianMilliseconds: draftFallbackMedian,
            sessionFallbackMedianMilliseconds: sessionFallbackMedian
        )
        // Debug 标准测试不执行脆弱墙钟断言，只验证同一功能和样本。
        guard enforcePerformanceTargets else { return report }
        // 1MB 双代写入超限时阻止发布，避免恢复保护拖慢后台草稿任务。
        guard report.draftSaveMedianMilliseconds < draftSaveTargetMilliseconds else {
            throw DocumentSupportError.selfCheckFailed(
                "1MB 草稿双代轮换 \(String(format: "%.2f", report.draftSaveMedianMilliseconds))ms，目标 <100ms"
            )
        }
        // 1MB 回退超限时阻止发布，避免启动恢复长时间无反馈。
        guard report.draftFallbackMedianMilliseconds < draftFallbackTargetMilliseconds else {
            throw DocumentSupportError.selfCheckFailed(
                "1MB 草稿上一代恢复 \(String(format: "%.2f", report.draftFallbackMedianMilliseconds))ms，目标 <50ms"
            )
        }
        // 100 标签会话回退超限时阻止发布。
        guard report.sessionFallbackMedianMilliseconds < sessionFallbackTargetMilliseconds else {
            throw DocumentSupportError.selfCheckFailed(
                "100 标签会话上一代恢复 \(String(format: "%.2f", report.sessionFallbackMedianMilliseconds))ms，目标 <20ms"
            )
        }
        // 所有功能与性能门禁通过后返回实测值。
        return report
    }

    // 对固定次数操作取中位数，既保留真实 IO 又降低单次调度噪声。
    private static func measureMedian(
        iterations: Int,
        operation: (Int) throws -> Void
    ) rethrows -> Double {
        // 预分配固定容量，避免测量循环中数组扩容。
        var measurements = [Double]()
        // 迭代次数由内部固定调用保证大于零。
        measurements.reserveCapacity(iterations)
        // 每次操作独立记录单调系统运行时间。
        for index in 0..<iterations {
            // systemUptime 不受系统时钟校准影响。
            let startedAt = ProcessInfo.processInfo.systemUptime
            // 调用方执行完整生产操作。
            try operation(index)
            // 转换为毫秒并记录本次耗时。
            measurements.append((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        }
        // 排序后取中间项；固定五次不会发生偶数歧义。
        let sorted = measurements.sorted()
        // 返回中位数供发布阈值和报告使用。
        return sorted[sorted.count / 2]
    }
}
