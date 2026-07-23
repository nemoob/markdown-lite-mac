import Darwin
import Foundation
import Testing

@testable import MarkdownLiteMac

// 持有 posix_spawn 子进程的标准输入管道，并在失败时兜底回收子进程。
private final class SpawnedLockHolder {
    // 真实子进程 PID 供测试核对进程边界。
    let pid: pid_t
    // 关闭写端后 /bin/cat 收到 EOF 并正常退出。
    private var inputDescriptor: Int32
    // 记录 waitpid 已完成，避免 deinit 操作已回收 PID。
    private var isReaped = false

    // 保存已成功 spawn 的进程和唯一父进程管道端。
    init(pid: pid_t, inputDescriptor: Int32) {
        // 保存子进程身份。
        self.pid = pid
        // 保存控制子进程正常退出的写端。
        self.inputDescriptor = inputDescriptor
    }

    // 通过 EOF 让子进程正常退出，再确认 exit(0)。
    func exitNormally() throws {
        // 关闭父进程唯一写端，/bin/cat 会从标准输入读到 EOF。
        closeInput()
        // 等待子进程关闭继承的锁描述符。
        let status = try waitForExit()
        // 正常释放路径必须是 exit(0)。
        guard status == 0 else {
            // 保留原始 wait 状态供 CI 诊断。
            throw Self.failure("child normal exit status: \(status)")
        }
    }

    // 用 SIGKILL 让子进程无法主动清理，验证内核释放语义。
    func killAndWait() throws {
        // 只有真正送达 SIGKILL 才能继续验收。
        guard Darwin.kill(pid, SIGKILL) == 0 else {
            // kill 失败时返回即时 errno。
            throw Self.failure("kill failed with errno \(errno)")
        }
        // 信号送达后关闭父进程管道端，避免描述符泄漏。
        closeInput()
        // 等待内核完成子进程和锁描述符回收。
        let status = try waitForExit()
        // BSD wait 状态的低七位必须是 SIGKILL。
        guard status & 0x7f == SIGKILL else {
            // 其他退出方式不能证明强制终止路径。
            throw Self.failure("child signal status: \(status)")
        }
    }

    // 关闭管道写端并立即清空数字，防止误关闭被复用的描述符。
    private func closeInput() {
        // 只关闭尚未移交或关闭的写端。
        guard inputDescriptor >= 0 else { return }
        // close 同时完成正常退出通知。
        _ = Darwin.close(inputDescriptor)
        // 用 -1 标记所有权已终止。
        inputDescriptor = -1
    }

    // 同步回收子进程，并对信号中断重试。
    private func waitForExit() throws -> Int32 {
        // 接收内核返回的原始退出状态。
        var status: Int32 = 0
        // EINTR 只中断本次 waitpid，不代表子进程未退出。
        var result: pid_t
        // 持续等待直到目标 PID 被回收或发生真实错误。
        repeat {
            // 两条退出路径都已先发 EOF 或 SIGKILL，不会无限等待。
            result = Darwin.waitpid(pid, &status, 0)
        } while result == -1 && errno == EINTR
        // 只接受目标子进程的回收结果。
        guard result == pid else {
            // 返回 waitpid 故障的 errno。
            throw Self.failure("waitpid failed with errno \(errno)")
        }
        // 防止 deinit 再次杀死可能被系统复用的 PID。
        isReaped = true
        // 返回状态供正常退出或信号路径断言。
        return status
    }

    // 任意测试失败都不应留下持锁或僵尸子进程。
    deinit {
        // 先关闭管道通知子进程退出。
        closeInput()
        // 已回收的 PID 不得被重复操作。
        guard !isReaped else { return }
        // 失败兜底使用 SIGKILL，确保子进程不继续持锁。
        _ = Darwin.kill(pid, SIGKILL)
        // 回收子进程，避免污染后续测试。
        var status: Int32 = 0
        // 信号中断时重试 waitpid，其他结果结束兜底。
        while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    // 统一构造可在 Swift Testing 输出中直接阅读的子进程错误。
    fileprivate static func failure(_ description: String) -> NSError {
        // 固定错误域并携带具体 POSIX 操作说明。
        NSError(
            domain: "ApplicationInstanceLockTests.SpawnedProcess",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

// 覆盖同路径互斥、真实跨进程释放、路径隔离和锁文件安全属性。
@Suite("应用单实例锁")
struct ApplicationInstanceLockTests {
    // 品牌迁移不能改变旧版本仍在使用的恢复根和锁文件身份。
    @Test("品牌迁移保留跨版本存储与锁身份")
    func brandMigrationRetainsStorageAndLockIdentity() {
        // 读取生产会话存储实际采用的默认根目录。
        let rootDirectory = WorkspaceSessionStore.defaultRootDirectory(fileManager: .default)
        // 旧目录名保证墨简可以继续恢复 v0.11 的会话和草稿。
        #expect(rootDirectory.lastPathComponent == "MarkdownLiteMac")
        // 旧锁文件名保证新旧版本不能同时写同一恢复目录。
        #expect(ApplicationInstanceLock.lockFilename == "ApplicationInstance.lock")
    }

    // 同一固定路径的第二个持有者必须立即得到已运行错误。
    @Test("相同路径非阻塞互斥")
    func samePathIsMutuallyExclusive() throws {
        // 每个测试使用唯一目录，避免与真实应用及并行测试竞争。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后只删除本次创建的隔离目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 两个实例明确竞争同一个固定文件。
        let lockFileURL = rootDirectory.appendingPathComponent("same.lock", isDirectory: false)
        // 第一个实例成功持有独占锁。
        let firstLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)

        // 保持首锁存活期间尝试第二次非阻塞获取。
        withExtendedLifetime(firstLock) {
            do {
                // 若错误地获取成功，测试必须显式失败。
                let secondLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
                // 防止优化器在失败记录前提前释放意外取得的锁。
                withExtendedLifetime(secondLock) {}
                // 相同路径同时成功会破坏恢复数据单写者约束。
                Issue.record("相同路径被两个实例同时获取")
            } catch ApplicationInstanceLockError.alreadyRunning {
                // 明确的已运行分类就是预期结果。
            } catch {
                // 锁竞争不能被误报为普通 IO 故障。
                Issue.record("相同路径返回了错误类型：\(error)")
            }
        }
    }

    // posix_spawn 子进程持锁时父进程必须失败，子进程正常退出后必须可重获。
    @Test("独立进程竞争且正常退出后释放")
    func spawnedProcessNormalExitReleasesLock() throws {
        // 唯一目录避免与真实应用或其他测试竞争。
        let rootDirectory = try makeTemporaryDirectory()
        // 结束后只删除本测试自己的目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 父子进程使用同一个锁文件。
        let lockFileURL = rootDirectory.appendingPathComponent("normal-exit.lock", isDirectory: false)
        // 启动独立 /bin/cat 进程并让它继承已取得的 flock 描述符。
        let childHolder = try spawnLockHolder(lockFileURL: lockFileURL)
        // 异常退出时由持有者 deinit 兜底杀死和回收子进程。
        defer { withExtendedLifetime(childHolder) {} }
        // 持锁者必须是与 Swift Testing 不同的 PID。
        #expect(childHolder.pid != Darwin.getpid())
        // 父进程的正式锁实现必须识别真实子进程竞争。
        expectAlreadyRunning(at: lockFileURL)
        // 关闭标准输入后等待子进程 exit(0) 和描述符释放。
        try childHolder.exitNormally()
        // 残留锁文件不得阻止新进程获取内核锁。
        let reacquiredLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 保持重获对象到测试结束。
        withExtendedLifetime(reacquiredLock) {}
    }

    // 持锁子进程无法主动清理时，内核仍必须在 SIGKILL 后释放锁。
    @Test("SIGKILL 后内核释放跨进程锁")
    func killedSpawnedProcessReleasesLock() throws {
        // 唯一目录隔离强制终止路径。
        let rootDirectory = try makeTemporaryDirectory()
        // 回收子进程后删除本测试目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 固定路径供子进程持有、父进程竞争和重获。
        let lockFileURL = rootDirectory.appendingPathComponent("killed.lock", isDirectory: false)
        // 启动继承锁描述符的独立子进程。
        let childHolder = try spawnLockHolder(lockFileURL: lockFileURL)
        // 任意断言失败时仍保证清理。
        defer { withExtendedLifetime(childHolder) {} }
        // 确认测试不是同一进程内的对象生命周期模拟。
        #expect(childHolder.pid != Darwin.getpid())
        // 杀死前先验证子进程确实持有锁。
        expectAlreadyRunning(at: lockFileURL)
        // 强制终止并 waitpid，子进程无机会运行主动解锁代码。
        try childHolder.killAndWait()
        // 内核关闭被杀进程的描述符后，正式实现必须可重获。
        let reacquiredLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 保持重获对象到测试结束。
        withExtendedLifetime(reacquiredLock) {}
    }

    // 不同恢复根目录应拥有独立锁，保证测试和显式隔离环境互不影响。
    @Test("不同路径可以独立持有")
    func differentPathsAreIndependent() throws {
        // 唯一根目录集中容纳两个不会竞争的锁文件。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后清理唯一隔离目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 两个不同文件代表两个独立恢复数据目录。
        let firstURL = rootDirectory.appendingPathComponent("first.lock", isDirectory: false)
        // 第二路径不能被第一路径的 flock 影响。
        let secondURL = rootDirectory.appendingPathComponent("second.lock", isDirectory: false)
        // 先取得第一把锁。
        let firstLock = try ApplicationInstanceLock(lockFileURL: firstURL)
        // 再取得不同路径的第二把锁。
        let secondLock = try ApplicationInstanceLock(lockFileURL: secondURL)
        // 同时延长两个对象生命周期以真实覆盖并存状态。
        withExtendedLifetime((firstLock, secondLock)) {}
    }

    // 首实例释放描述符后，残留锁文件不能阻止下一次正常启动。
    @Test("释放后可以重新获取")
    func releasedLockCanBeReacquired() throws {
        // 使用唯一目录隔离残留锁文件。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后删除锁文件及目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 两次获取都指向同一个文件。
        let lockFileURL = rootDirectory.appendingPathComponent("reusable.lock", isDirectory: false)
        // 可选引用允许显式触发 deinit 和 close。
        var firstLock: ApplicationInstanceLock? = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 首次获取必须真实产生对象。
        #expect(firstLock != nil)
        // 清空唯一强引用，立即释放 flock。
        firstLock = nil
        // 同一路径现在应能再次成功获取。
        let secondLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 保持重获对象到断言路径结束。
        withExtendedLifetime(secondLock) {}
    }

    // 新建和既有锁文件都必须收紧为当前用户可读写。
    @Test("锁文件是普通文件且权限为 0600")
    func lockFileHasPrivatePermissions() throws {
        // 使用唯一目录读取确定的文件属性。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后删除本次锁文件。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 固定文件地址供属性查询。
        let lockFileURL = rootDirectory.appendingPathComponent("permissions.lock", isDirectory: false)
        // 先模拟旧版本留下的过宽锁文件权限。
        try Data().write(to: lockFileURL)
        // 显式放宽为组和其他用户可读写，确保测试覆盖收紧路径。
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lockFileURL.path)
        // 获取锁必须对既有文件执行 fchmod 收紧权限。
        let lock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 从同一路径读取内核返回的文件属性。
        let attributes = try FileManager.default.attributesOfItem(atPath: lockFileURL.path)
        // 锁载体必须是普通文件而非目录或特殊节点。
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        // POSIX 权限只允许当前用户读写。
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // 属性核对期间保持锁仍被持有。
        withExtendedLifetime(lock) {}
    }

    // 锁目录不可写时初始化必须关闭式失败。
    @Test("锁目录无写权限时初始化失败")
    func unwritableLockDirectoryFailsInitialization() throws {
        // root 可绕过 POSIX 权限，无法验证普通 macOS 用户路径。
        guard Darwin.geteuid() != 0 else { return }
        // 唯一根目录使权限变化不影响用户文件。
        let rootDirectory = try makeTemporaryDirectory()
        // 结束后只删除本测试目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // 独立受限目录模拟无法初始化应用支持目录。
        let protectedDirectory = rootDirectory.appendingPathComponent("read-only", isDirectory: true)
        // 先创建目录，再单独收紧权限。
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        // 0500 保留遍历权限但禁止创建子目录。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: protectedDirectory.path
        )
        // 删除测试目录前恢复写权限。
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: protectedDirectory.path
            )
        }
        // 锁实现将先尝试在受限目录中创建 session 子目录。
        let lockFileURL =
            protectedDirectory
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("permission.lock", isDirectory: false)

        do {
            // 目录创建失败后不得继续 open 或 flock。
            let lock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
            // 防止意外成功对象提前释放。
            withExtendedLifetime(lock) {}
            // 无写权限仍成功说明锁目录初始化未关闭式失败。
            Issue.record("无写权限的锁目录被错误初始化")
        } catch let ApplicationInstanceLockError.ioFailure(operation, code) {
            // 失败必须发生在目录初始化阶段。
            #expect(operation == "createDirectory")
            // 底层错误必须保留权限被拒绝语义。
            #expect(code == EACCES || code == EPERM)
        } catch {
            // 权限故障不能被误报为已运行实例。
            Issue.record("锁目录权限失败返回了错误类型：\(error)")
        }
    }

    // 锁路径本身是目录时必须作为 IO 故障关闭式失败。
    @Test("锁文件 IO 错误不会退化为已运行")
    func invalidLockFileFailsClosed() throws {
        // 唯一临时目录同时作为非法锁文件节点。
        let rootDirectory = try makeTemporaryDirectory()
        // 测试结束后清理该目录。
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        do {
            // O_RDWR 打开目录必须失败且不得继续尝试 flock。
            let lock = try ApplicationInstanceLock(lockFileURL: rootDirectory)
            // 防止意外成功对象提前释放掩盖错误。
            withExtendedLifetime(lock) {}
            // 任何成功都说明非普通节点绕过了保护。
            Issue.record("目录被错误地用作锁文件")
        } catch let ApplicationInstanceLockError.ioFailure(operation, code) {
            // 错误应来自打开或普通文件校验阶段。
            #expect(operation == "open" || operation == "validate")
            // 系统错误码必须保留为非零诊断信息。
            #expect(code != 0)
        } catch {
            // IO 故障不能伪装成已有实例占用。
            Issue.record("非法锁节点返回了错误类型：\(error)")
        }
    }

    // 用正式实现验证当前路径已被另一进程持有。
    private func expectAlreadyRunning(at lockFileURL: URL) {
        do {
            // 父进程对子进程持有的文件执行非阻塞获取。
            let competingLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
            // 保持意外成功对象，不让优化掩盖同时持有故障。
            withExtendedLifetime(competingLock) {}
            // 两个独立 PID 同时获取锁必须让测试失败。
            Issue.record("两个独立进程同时获取了同一把锁")
        } catch ApplicationInstanceLockError.alreadyRunning {
            // 明确的已运行分类就是预期结果。
        } catch {
            // 真实进程竞争不能被误报为普通 IO 故障。
            Issue.record("跨进程竞争返回了错误类型：\(error)")
        }
    }

    // 先在父进程取得 flock，再用 posix_spawn 让 /bin/cat 继承同一描述符。
    private func spawnLockHolder(lockFileURL: URL) throws -> SpawnedLockHolder {
        // 子进程从读端获取标准输入，父进程保留写端控制生命周期。
        var inputPipe: [Int32] = [-1, -1]
        // 管道创建失败时不启动子进程。
        guard Darwin.pipe(&inputPipe) == 0 else {
            // 保留即时 errno 供诊断系统资源问题。
            throw SpawnedLockHolder.failure("pipe failed with errno \(errno)")
        }
        // 任何失败路径都关闭未移交的管道端。
        defer {
            // 读端只用于子进程标准输入。
            if inputPipe[0] >= 0 { _ = Darwin.close(inputPipe[0]) }
            // 写端成功时会移交给 SpawnedLockHolder。
            if inputPipe[1] >= 0 { _ = Darwin.close(inputPipe[1]) }
        }

        // 故意不使用 O_CLOEXEC，使 posix_spawn 子进程能继承已取得的锁描述符。
        let descriptor = lockFileURL.withUnsafeFileSystemRepresentation { path in
            // 无法转换本地路径时稳定返回失败。
            guard let path else { return Int32(-1) }
            // 子进程持有的测试锁与正式实现使用同样的普通文件。
            return Darwin.open(
                path,
                O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        // open 失败时立即结束，不执行 flock 或 spawn。
        guard descriptor >= 0 else {
            // 返回即时 errno，路径转换失败时回退 EINVAL。
            throw SpawnedLockHolder.failure("open failed with errno \(errno == 0 ? EINVAL : errno)")
        }
        // spawn 成功后只 close 父进程副本，失败时则显式解锁。
        var childInheritedLock = false
        // 本函数始终关闭父进程的锁描述符。
        defer {
            // 未启动子进程时显式撤销临时锁。
            if !childInheritedLock { _ = flock(descriptor, LOCK_UN) }
            // spawn 成功时 close 不会释放子进程继承的文件描述。
            _ = Darwin.close(descriptor)
        }
        // 父进程必须先取得非阻塞独占锁。
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            // 测试路径被意外占用时保留即时 errno。
            throw SpawnedLockHolder.failure("flock failed with errno \(errno)")
        }

        // 文件动作只把管道读端接到子进程标准输入并关闭多余端。
        var fileActions: posix_spawn_file_actions_t?
        // 初始化失败码由 posix_spawn API 直接返回。
        let initializationCode = posix_spawn_file_actions_init(&fileActions)
        // 未建立动作集时不调用 destroy。
        guard initializationCode == 0 else {
            // 保留直接返回的 POSIX 错误码。
            throw SpawnedLockHolder.failure("file actions init failed with code \(initializationCode)")
        }
        // 所有返回路径都销毁已初始化的动作集。
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // 将管道读端复制为 /bin/cat 的标准输入。
        let duplicateCode = posix_spawn_file_actions_adddup2(&fileActions, inputPipe[0], STDIN_FILENO)
        // dup2 失败时不启动一个无法受控退出的子进程。
        guard duplicateCode == 0 else {
            // 返回动作注册的直接错误码。
            throw SpawnedLockHolder.failure("stdin dup action failed with code \(duplicateCode)")
        }
        // 子进程不得继承管道写端，否则父进程关闭后不会产生 EOF。
        let closeWriteCode = posix_spawn_file_actions_addclose(&fileActions, inputPipe[1])
        // 无法关闭写端时停止 spawn。
        guard closeWriteCode == 0 else {
            // 保留动作注册错误码。
            throw SpawnedLockHolder.failure("write close action failed with code \(closeWriteCode)")
        }
        // dup2 完成后关闭子进程中原始读端，标准输入本身不重复关闭。
        if inputPipe[0] != STDIN_FILENO {
            // 注册原始读端关闭动作。
            let closeReadCode = posix_spawn_file_actions_addclose(&fileActions, inputPipe[0])
            // 动作注册失败时不执行 spawn。
            guard closeReadCode == 0 else {
                // 保留关闭动作错误码。
                throw SpawnedLockHolder.failure("read close action failed with code \(closeReadCode)")
            }
        }

        // argv 只需要程序名和 C 数组结尾空指针。
        guard let executableArgument = strdup("/bin/cat") else {
            // 参数分配失败时不启动子进程。
            throw SpawnedLockHolder.failure("argv allocation failed")
        }
        // 函数结束时释放父进程中的 argv 字符串。
        defer { free(executableArgument) }
        // posix_spawn 要求 argv 以 nil 结束。
        var arguments: [UnsafeMutablePointer<CChar>?] = [executableArgument, nil]
        // 接收成功启动的真实子进程 PID。
        var childPID: pid_t = 0
        // 使用当前环境启动系统 /bin/cat，不经过 shell 或外部依赖。
        let spawnCode = "/bin/cat".withCString { executablePath in
            // 文件动作保留锁描述符，并把管道接为标准输入。
            posix_spawn(&childPID, executablePath, &fileActions, nil, &arguments, environ)
        }
        // spawn 成功才能把锁与管道所有权交给子进程持有者。
        guard spawnCode == 0 else {
            // posix_spawn 直接返回启动错误码。
            throw SpawnedLockHolder.failure("posix_spawn failed with code \(spawnCode)")
        }
        // 标记子进程已继承同一锁描述符，defer 只关闭父进程副本。
        childInheritedLock = true
        // 把管道写端移交给持有者对象。
        let childInputDescriptor = inputPipe[1]
        // 清空本地所有权，防止 defer 提前关闭子进程输入。
        inputPipe[1] = -1
        // 返回可显式正常退出或 SIGKILL 的持有者。
        return SpawnedLockHolder(pid: childPID, inputDescriptor: childInputDescriptor)
    }

    // 创建唯一临时目录供单个测试安全读写。
    private func makeTemporaryDirectory() throws -> URL {
        // UUID 防止并行测试之间共享任何路径。
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownLiteMac-InstanceLock-\(UUID().uuidString)", isDirectory: true)
        // 只创建本测试拥有的唯一目录。
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // 返回可安全交给锁实现的本地路径。
        return rootDirectory
    }
}
