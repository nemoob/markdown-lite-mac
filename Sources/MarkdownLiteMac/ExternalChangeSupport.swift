import CryptoKit
import Foundation

// 保存一次与磁盘原始字节严格对应的文件版本指纹。
struct ExternalFileSnapshot: Equatable, Sendable {
    // 规范化文件地址用于阻止把基线误用到其他文档。
    let fileURL: URL
    // 原始字节数用于诊断和快速展示。
    let fileSize: Int
    // 修改时间仅作诊断；最终一致性由内容摘要判断。
    let modificationDate: Date?
    // 系统文件身份帮助识别原子替换，但不把同内容替换误报为冲突。
    let fileIdentifier: String?
    // SHA-256 摘要可靠识别同大小、同修改时间的内容变化。
    let contentDigest: String
}

// 表示模型层当前观察到的外部文件状态。
enum ExternalDocumentChangeState: Equatable, Sendable {
    // 未命名文档没有磁盘文件需要监控。
    case notMonitored
    // 磁盘原始字节仍与可信基线一致。
    case unchanged
    // 磁盘内容与打开或保存时的可信基线不同。
    case modified
    // 原文件已经从磁盘消失。
    case deleted
    // 文件存在但当前无法可靠读取或建立快照。
    case unreadable(String)

    // 判断当前状态是否必须阻止普通原地保存。
    var blocksRegularSave: Bool {
        // 只有明确不冲突的两种状态允许普通流程继续。
        switch self {
        case .notMonitored, .unchanged:
            // 未命名会走另存为，未变化文件可原地保存。
            return false
        case .modified, .deleted, .unreadable:
            // 其余状态都需要重载或用户明确覆盖。
            return true
        }
    }
}

// 返回一次外部变化检查及可供模型采用的新快照。
struct ExternalChangeInspection: Equatable, Sendable {
    // 保存本次检查结论。
    let state: ExternalDocumentChangeState
    // 文件可读时携带当前版本快照，便于刷新无变化元数据。
    let currentSnapshot: ExternalFileSnapshot?
}

// 将快照读取失败转换为稳定且可展示的原因。
enum ExternalChangeSupportError: LocalizedError, Equatable {
    // 外部变化支撑层只处理本地文件。
    case invalidFileURL
    // 目标不存在或已在检查期间删除。
    case fileMissing
    // 目录和其他特殊节点不能作为 Markdown 文档。
    case notRegularFile
    // 两次元数据检查都显示读取期间仍在变化。
    case changedDuringRead
    // 普通保存进入协调写区后发现磁盘已不再等于原基线。
    case changedBeforeWrite(ExternalDocumentChangeState)
    // 系统协调器既未返回错误也未执行写入访问器。
    case coordinatedWriteDidNotRun

    // 返回不暴露正文内容的中文说明。
    var errorDescription: String? {
        // 按具体原因给出简洁状态。
        switch self {
        case .invalidFileURL:
            // 网络地址不能参与本地冲突保护。
            return "外部修改检测仅支持本地文件"
        case .fileMissing:
            // 文件消失需要用户决定是否重新创建。
            return "磁盘文件不存在"
        case .notRegularFile:
            // 特殊节点不能安全执行原子替换。
            return "目标不是普通文件"
        case .changedDuringRead:
            // 快速连续写入时保守停止，避免建立错误基线。
            return "文件在读取期间持续变化"
        case .changedBeforeWrite:
            // 承诺点变化由模型转换为可操作的冲突状态。
            return "磁盘文件在保存承诺前再次变化"
        case .coordinatedWriteDidNotRun:
            // 未获得系统协调写入机会时不得退化为普通覆盖。
            return "系统未执行协调写入"
        }
    }
}

// 保存同一批原始字节及其磁盘快照，避免解码和指纹之间发生竞态。
struct ExternalFileRead: Sendable {
    // 原始数据交给 TextFileIO 执行无损编码识别。
    let data: Data
    // 快照摘要严格由同一份 data 生成。
    let snapshot: ExternalFileSnapshot
}

// 按需读取文件并比较可信内容指纹，不启动持续轮询。
enum ExternalChangeSupport {
    // 读取一个稳定文件版本，并让原始数据与摘要来自同一次读取。
    static func readFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> ExternalFileRead {
        // 网络地址不能交给本地冲突保护。
        guard url.isFileURL else { throw ExternalChangeSupportError.invalidFileURL }
        // 统一点路径段，确保快照身份稳定。
        let normalizedURL = url.standardizedFileURL

        // 文件在一次读取附近可能被原子替换，因此最多重试一次。
        for _ in 0..<2 {
            // 读取数据前记录元数据版本。
            let metadataBefore = try metadata(at: normalizedURL, fileManager: fileManager)
            // 映射大文件可降低额外内存复制，摘要仍遍历全部字节。
            let data: Data
            do {
                // 同步读取只由打开、保存或显式检查触发，不进入持续轮询。
                data = try Data(contentsOf: normalizedURL, options: [.mappedIfSafe])
            } catch {
                // 文件在读取前消失时返回稳定缺失错误。
                if !fileManager.fileExists(atPath: normalizedURL.path) {
                    // 调用方可据此进入 deleted 状态。
                    throw ExternalChangeSupportError.fileMissing
                }
                // 权限和其他系统错误保留给模型状态说明。
                throw error
            }
            // 读取后再次记录元数据，防止把跨版本数据当作基线。
            let metadataAfter = try metadata(at: normalizedURL, fileManager: fileManager)
            // 身份、长度和修改时间均稳定时接受本次读取。
            if metadataBefore == metadataAfter, data.count == metadataAfter.fileSize {
                // 摘要直接由本次解码所用原始数据生成。
                let snapshot = makeSnapshot(
                    data: data,
                    url: normalizedURL,
                    metadata: metadataAfter
                )
                // 一次返回原始数据和严格匹配快照。
                return ExternalFileRead(data: data, snapshot: snapshot)
            }
        }
        // 连续两次变化时保守停止，避免主线程无限等待。
        throw ExternalChangeSupportError.changedDuringRead
    }

    // 读取当前文件并仅返回可信快照。
    static func capture(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> ExternalFileSnapshot {
        // 复用稳定读取入口，确保所有快照使用同一算法。
        try readFile(at: url, fileManager: fileManager).snapshot
    }

    // 为已经原子写入的已知字节建立保存基线。
    static func snapshotForKnownData(
        _ data: Data,
        at url: URL,
        fileManager: FileManager = .default
    ) -> ExternalFileSnapshot {
        // 写入已经成功，即使元数据查询失败也能使用内容摘要保护下一次保存。
        let metadata = try? metadata(at: url.standardizedFileURL, fileManager: fileManager)
        // 缺少元数据时使用已知字节数并保留可选诊断字段为空。
        let stableMetadata =
            metadata
            ?? FileMetadata(
                fileSize: data.count,
                modificationDate: nil,
                fileIdentifier: nil
            )
        // 摘要必须来自实际交给原子写入的数据。
        return makeSnapshot(data: data, url: url.standardizedFileURL, metadata: stableMetadata)
    }

    // 比较磁盘当前版本和上次打开或保存的可信基线。
    static func inspect(
        baseline: ExternalFileSnapshot?,
        at url: URL,
        fileManager: FileManager = .default
    ) -> ExternalChangeInspection {
        // 非本地地址不能安全比较，保守进入不可读状态。
        guard url.isFileURL else {
            // 返回稳定中文原因供模型显示。
            return ExternalChangeInspection(state: .unreadable("仅支持本地文件"), currentSnapshot: nil)
        }
        // 文件不存在时无需尝试读取。
        guard fileManager.fileExists(atPath: url.path) else {
            // 明确区分删除和读取失败。
            return ExternalChangeInspection(state: .deleted, currentSnapshot: nil)
        }

        do {
            // 读取当前原始字节和匹配快照。
            let currentRead = try readFile(at: url, fileManager: fileManager)
            // 没有可信基线时不能把既有磁盘文件视为未变化。
            guard let baseline else {
                // 当前文件相对未知版本按修改冲突处理。
                return ExternalChangeInspection(state: .modified, currentSnapshot: currentRead.snapshot)
            }
            // 基线必须属于同一规范化路径。
            guard baseline.fileURL == url.standardizedFileURL else {
                // 身份错配时禁止保存，避免把一个标签的基线用于另一文件。
                return ExternalChangeInspection(
                    state: .unreadable("磁盘基线与当前文件不匹配"),
                    currentSnapshot: currentRead.snapshot
                )
            }
            // 内容摘要相同即表示没有需要保护的数据差异。
            let state: ExternalDocumentChangeState =
                currentRead.snapshot.contentDigest == baseline.contentDigest
                ? .unchanged
                : .modified
            // 携带当前快照供无变化时刷新修改时间和文件身份。
            return ExternalChangeInspection(state: state, currentSnapshot: currentRead.snapshot)
        } catch ExternalChangeSupportError.fileMissing {
            // 读取竞态中消失仍归类为删除。
            return ExternalChangeInspection(state: .deleted, currentSnapshot: nil)
        } catch {
            // 权限、持续变化等问题都保守阻止普通保存。
            return ExternalChangeInspection(
                state: .unreadable(error.localizedDescription),
                currentSnapshot: nil
            )
        }
    }

    // 在系统协调写区内复核同一基线，并只在仍安全时执行一次写入。
    static func coordinatedWrite<Output>(
        at url: URL,
        baseline: ExternalFileSnapshot?,
        allowsOverwrite: Bool,
        fileManager: FileManager = .default,
        usesSystemFileCoordinator: Bool = true,
        beforeCommit: (() throws -> Void)? = nil,
        write: @escaping (URL) throws -> Output
    ) throws -> Output {
        // 网络地址不能进入本地文件协调器。
        guard url.isFileURL else { throw ExternalChangeSupportError.invalidFileURL }
        // 点路径段必须在协调、复核和最终写入之间保持一致。
        let normalizedURL = url.standardizedFileURL
        // 访问器内部错误通过 Result 带回同步调用方。
        var accessorResult: Result<Output, Error>?
        // 统一访问器保证生产协调和测试注入执行完全相同的复核与写入逻辑。
        let accessor: (URL) -> Void = { coordinatedURL in
            do {
                // 测试钩子稳定模拟预检后、承诺点复核前发生的外部改写。
                try beforeCommit?()
                // 普通原地保存必须在协调区内再次匹配打开或上次保存的同一内容基线。
                if !allowsOverwrite {
                    // 复用强摘要检查，同大小、同时间改写也不能绕过承诺点。
                    let inspection = inspect(
                        baseline: baseline,
                        at: coordinatedURL,
                        fileManager: fileManager
                    )
                    // 只有内容明确未变化才允许进入最终原子替换。
                    guard inspection.state == .unchanged else {
                        throw ExternalChangeSupportError.changedBeforeWrite(inspection.state)
                    }
                }
                // 写入必须使用协调器提供的地址并留在同一个访问器内完成。
                accessorResult = .success(try write(coordinatedURL))
            } catch {
                // 冲突、编码或文件系统错误都交回模型统一保护草稿。
                accessorResult = .failure(error)
            }
        }

        if usesSystemFileCoordinator {
            // 既有文件声明替换语义，新建或已删除文件使用普通协调写入。
            let options: NSFileCoordinator.WritingOptions =
                fileManager.fileExists(atPath: normalizedURL.path) ? .forReplacing : []
            // 不绑定文件展示者，避免把应用自身误当成外部协调参与者。
            let coordinator = NSFileCoordinator(filePresenter: nil)
            // 保存系统协调失败原因；失败时访问器可能完全不会执行。
            var coordinationError: NSError?
            // NSFileCoordinator 阻止遵循文件协调协议的其他编辑器穿过本次承诺区。
            coordinator.coordinate(
                writingItemAt: normalizedURL,
                options: options,
                error: &coordinationError,
                byAccessor: accessor
            )
            // 系统层协调失败优先返回，绝不绕过协调器直接覆盖。
            if let coordinationError { throw coordinationError }
        } else {
            // 受限测试宿主不能连接文件协调服务，直接注入同一同步访问器以稳定复现竞态。
            accessor(normalizedURL)
        }
        // 极端未执行访问器时返回稳定错误，不能伪装成保存成功。
        guard let accessorResult else { throw ExternalChangeSupportError.coordinatedWriteDidNotRun }
        // 返回访问器写入结果，或原样抛出承诺点冲突和底层错误。
        return try accessorResult.get()
    }

    // 保存一次轻量文件元数据读取结果。
    private struct FileMetadata: Equatable {
        // 当前普通文件字节数。
        let fileSize: Int
        // 文件系统报告的内容修改时间。
        let modificationDate: Date?
        // 文件系统资源身份的稳定文字形式。
        let fileIdentifier: String?
    }

    // 读取用于稳定性判断的文件元数据。
    private static func metadata(
        at url: URL,
        fileManager: FileManager
    ) throws -> FileMetadata {
        // 先用注入的文件管理器判断缺失，便于隔离测试。
        guard fileManager.fileExists(atPath: url.path) else {
            // 明确返回文件缺失。
            throw ExternalChangeSupportError.fileMissing
        }
        // 一次获取普通文件、大小、时间和资源身份。
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ])
        // 目录和特殊节点不允许作为编辑目标。
        guard values.isRegularFile == true else {
            // 防止后续原子保存替换非普通节点。
            throw ExternalChangeSupportError.notRegularFile
        }
        // 系统极端未返回大小时通过属性字典补充。
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        // 优先使用 URLResourceValues 的原生整数结果。
        let fileSize = values.fileSize ?? (attributes?[.size] as? NSNumber)?.intValue ?? 0
        // 资源身份只用于诊断和读取稳定性比较。
        let fileIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
        // 返回一次不可变元数据快照。
        return FileMetadata(
            fileSize: fileSize,
            modificationDate: values.contentModificationDate,
            fileIdentifier: fileIdentifier
        )
    }

    // 用已知原始数据生成强内容摘要及完整快照。
    private static func makeSnapshot(
        data: Data,
        url: URL,
        metadata: FileMetadata
    ) -> ExternalFileSnapshot {
        // SHA-256 系统实现不依赖随机种子且碰撞风险可忽略。
        let digest = SHA256.hash(data: data)
        // 固定两位十六进制编码便于 Equatable、日志和测试。
        let digestString = digest.map { String(format: "%02x", $0) }.joined()
        // 返回与本次原始数据严格对应的版本指纹。
        return ExternalFileSnapshot(
            fileURL: url.standardizedFileURL,
            fileSize: data.count,
            modificationDate: metadata.modificationDate,
            fileIdentifier: metadata.fileIdentifier,
            contentDigest: digestString
        )
    }
}
