import AppKit
import Darwin
import Foundation

// 区分已有实例占用与本地锁文件故障，启动层据此展示可行动提示。
enum ApplicationInstanceLockError: Error, Equatable, LocalizedError {
    // 同一路径已经由另一个仍存活的实例持有独占锁。
    case alreadyRunning
    // 任何不能安全确认独占性的 IO 故障都阻止继续启动。
    case ioFailure(operation: String, code: Int32)

    // 把锁失败转换为不会暴露用户路径的启动说明。
    var errorDescription: String? {
        // 已运行实例使用明确文案，避免被误解为文档损坏。
        switch self {
        case .alreadyRunning:
            return "墨简已在运行"
        case let .ioFailure(operation, code):
            // 系统错误码保留给用户反馈和问题排查。
            return "无法完成进程锁操作 \(operation)（错误码 \(code)）"
        }
    }
}

// 用固定本地文件的非阻塞独占锁阻止多个进程同时写恢复数据。
final class ApplicationInstanceLock {
    // 锁文件与会话文件同目录，名称不随进程或版本变化。
    static let lockFilename = "ApplicationInstance.lock"
    // 记录实际锁文件，测试可核对隔离路径和权限。
    let lockFileURL: URL
    // 描述符存活期就是独占锁存活期，不能提前关闭。
    private let descriptor: Int32

    // 正常启动固定使用工作区会话所在的产品目录。
    convenience init(fileManager: FileManager = .default) throws {
        // 复用会话存储的唯一默认目录，避免锁与恢复数据落到不同位置。
        let rootDirectory = WorkspaceSessionStore.defaultRootDirectory(fileManager: fileManager)
        // 固定文件名保证所有正常实例竞争同一把锁。
        let lockFileURL = rootDirectory.appendingPathComponent(Self.lockFilename, isDirectory: false)
        // 进入可注入路径的核心实现，测试不会触碰真实用户目录。
        try self.init(lockFileURL: lockFileURL, fileManager: fileManager)
    }

    // 测试和正常启动共用同一套目录、权限与 flock 语义。
    init(lockFileURL: URL, fileManager: FileManager = .default) throws {
        // 只允许本地文件 URL 进入 POSIX 文件锁。
        guard lockFileURL.isFileURL else {
            // 非本地地址无法形成可靠进程互斥，必须关闭式失败。
            throw ApplicationInstanceLockError.ioFailure(operation: "validate", code: EINVAL)
        }
        // 标准化路径避免同一文件因点路径得到不同调用参数。
        let normalizedLockFileURL = lockFileURL.standardizedFileURL
        // 首次启动时只创建锁文件的直属产品目录。
        do {
            // 中间目录由系统文件管理器按用户权限创建。
            try fileManager.createDirectory(
                at: normalizedLockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            // Foundation 目录错误转换为稳定 IO 分类且绝不继续创建工作区。
            throw ApplicationInstanceLockError.ioFailure(
                operation: "createDirectory",
                code: Self.posixCode(from: error)
            )
        }

        // 清空可能由先前成功调用留下的 errno，路径编码失败才能稳定回退 EINVAL。
        errno = 0
        // 禁止跟随最终软链接和阻塞特殊文件，并让子进程不能继承锁。
        let openedDescriptor = normalizedLockFileURL.withUnsafeFileSystemRepresentation { path in
            // 无法表示为本地路径时按参数错误处理。
            guard let path else { return Int32(-1) }
            // 0600 让锁文件只对当前用户可读写。
            return Darwin.open(
                path,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        // 必须在其他系统调用前保存 open 的即时错误码。
        let openErrorCode = errno
        // 打开失败时不尝试恢复或创建工作区。
        guard openedDescriptor >= 0 else {
            // 路径编码失败没有可靠 errno，统一使用 EINVAL。
            let failureCode = openErrorCode == 0 ? EINVAL : openErrorCode
            // 返回明确 IO 故障并保持关闭式启动策略。
            throw ApplicationInstanceLockError.ioFailure(operation: "open", code: failureCode)
        }
        // 任一后续校验失败都关闭尚未交给对象持有的描述符。
        var shouldCloseDescriptor = true
        // 初始化完成后对象接管描述符，失败路径则由 defer 关闭。
        defer {
            // 只有成功接管前才需要在本作用域关闭。
            if shouldCloseDescriptor {
                // 关闭即可释放可能已经取得的临时锁。
                _ = Darwin.close(openedDescriptor)
            }
        }

        // 针对同一已打开对象核对文件类型，拒绝目录、FIFO 和设备节点。
        var fileStatus = stat()
        // fstat 失败时保留即时 errno 并停止启动。
        guard Darwin.fstat(openedDescriptor, &fileStatus) == 0 else {
            // 元数据不可确认时不能假定锁文件安全可用。
            throw ApplicationInstanceLockError.ioFailure(operation: "fstat", code: errno)
        }
        // 只有普通文件能作为稳定的跨进程锁载体。
        guard (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            // 特殊节点使用参数错误表示不满足锁文件契约。
            throw ApplicationInstanceLockError.ioFailure(operation: "validate", code: EINVAL)
        }

        // 非阻塞独占锁确保第二实例不会挂起等待首实例退出。
        guard flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            // 必须在 close 之前保存 flock 的即时错误码。
            let lockErrorCode = errno
            // 锁竞争是可识别的已运行状态，不归类为磁盘损坏。
            if lockErrorCode == EWOULDBLOCK || lockErrorCode == EAGAIN {
                // 调用方展示已运行提示并立即结束第二实例。
                throw ApplicationInstanceLockError.alreadyRunning
            }
            // 其他 flock 故障都不能绕过互斥继续运行。
            throw ApplicationInstanceLockError.ioFailure(operation: "flock", code: lockErrorCode)
        }

        // 每次成功获取后收紧既有文件权限，避免旧权限持续过宽。
        guard Darwin.fchmod(openedDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            // 权限无法确认时释放临时锁并关闭式失败。
            throw ApplicationInstanceLockError.ioFailure(operation: "fchmod", code: errno)
        }
        // 保存标准化路径供测试和诊断使用。
        self.lockFileURL = normalizedLockFileURL
        // 对象从此持有描述符直到析构。
        descriptor = openedDescriptor
        // 禁止 defer 关闭已经由对象接管的描述符。
        shouldCloseDescriptor = false
    }

    // 对象释放时主动解锁并关闭描述符，允许下一次启动立即获取。
    deinit {
        // 显式解锁让生命周期语义可读，close 仍是最终兜底。
        _ = flock(descriptor, LOCK_UN)
        // 关闭描述符完成内核锁资源释放。
        _ = Darwin.close(descriptor)
    }

    // 从 Foundation 错误中提取底层 POSIX 码，无法识别时回退 EIO。
    private static func posixCode(from error: Error) -> Int32 {
        // NSError 统一承载 Foundation 的错误域和底层信息。
        let cocoaError = error as NSError
        // 直接的 POSIX 错误可以原样返回。
        if cocoaError.domain == NSPOSIXErrorDomain {
            // 系统 errno 均可安全收窄到 Int32。
            return Int32(cocoaError.code)
        }
        // 文件管理器通常把真实 errno 放在底层错误中。
        if let underlyingError = cocoaError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlyingError.domain == NSPOSIXErrorDomain
        {
            // 返回底层文件系统错误便于测试和诊断。
            return Int32(underlyingError.code)
        }
        // 无法取得 POSIX 原因时仍保持统一 IO 失败。
        return EIO
    }
}

// 在应用真正终止前同步全部草稿，并允许失败时取消退出。
@MainActor
final class MarkdownLiteApplicationDelegate: NSObject, NSApplicationDelegate {
    // 弱引用工作区避免 App 与 delegate 形成持有环。
    weak var workspace: WorkspaceModel?

    // 系统请求退出时先完成可失败的数据保护步骤。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 工作区尚未注入时没有可等待的数据。
        guard let workspace else { return .terminateNow }
        // 所有 dirty 标签草稿与会话都成功后立即退出。
        guard !workspace.flushDraftsAndSession() else { return .terminateNow }
        // 任一草稿或会话失败时默认取消退出，保留仍在内存中的状态。
        let alert = NSAlert()
        alert.messageText = "编辑状态保存失败"
        alert.informativeText = "退出可能丢失尚未写入磁盘的内容或标签顺序。建议返回编辑器另存为后重试。"
        alert.addButton(withTitle: "返回编辑")
        alert.addButton(withTitle: "仍要退出")
        // 只有用户明确接受风险时才允许终止进程。
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
