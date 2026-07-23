#if DEBUG
    import Darwin
    import Foundation
    import Testing

    @testable import MarkdownLiteMac

    // 标记当前测试代码实际加载自哪个 xctest bundle，用于定位同一构建产物。
    private final class CrashRecoveryTestBundleMarker: NSObject {}

    // 保存一个已启动的真实 MarkdownLiteMac 子进程及其错误输出。
    private struct SpawnedMarkdownLiteProcess {
        // Foundation Process 提供 PID、运行状态和退出原因。
        let process: Process
        // 独立错误管道让失败报告包含应用子模式的明确原因。
        let standardError: Pipe
    }

    // 使用真实可执行文件验证 SIGKILL 后的跨进程工作区和草稿恢复。
    @Suite("真实进程崩溃恢复", .serialized)
    struct CrashRecoveryProcessTests {
        // 子进程启动和临时磁盘 IO 在较慢 CI 上最多等待十秒。
        private static let processTimeoutSeconds = 10.0
        // 生产自动草稿延迟为 700ms，保留 100ms 调度容差后仍须拒绝立即手动刷盘。
        private static let minimumAutosaveDelaySeconds = 0.6

        // 写进程完成恢复数据提交后由父测试强杀，再由第二个真实进程重新恢复。
        @Test("SIGKILL 后重新启动恢复全部 dirty 标签")
        func killedApplicationRestoresWorkspaceAndDraftsOnNextLaunch() throws {
            // 每次测试使用系统临时目录下的唯一真目录。
            let rootDirectory = try makeTemporaryDirectory()
            // 只清理本次创建的精确目录，不触碰真实 Application Support。
            defer { try? FileManager.default.removeItem(at: rootDirectory) }
            // 明确解析当前构建配置对应的 MarkdownLiteMac 可执行产品。
            let executableURL = try markdownLiteExecutableURL()
            // 在启动写进程前记录单调时钟，验证 ready 不能来自立即同步刷盘。
            let writerLaunchUptime = ProcessInfo.processInfo.systemUptime
            // 首个真实子进程创建两个 dirty 标签并等待 SIGKILL。
            let writer = try launchApplication(
                executableURL: executableURL,
                mode: CrashRecoveryProcessTestCLI.writerMode,
                rootDirectory: rootDirectory
            )
            // 任意断言提前失败时也强制回收写进程。
            defer { killAndReapIfNeeded(writer.process) }
            // 父测试只在写进程原子创建就绪标记后继续。
            let readyURL = rootDirectory.appendingPathComponent(
                CrashRecoveryProcessTestCLI.writerReadyFilename,
                isDirectory: false
            )
            // 等待期间同时监控子进程是否提前失败。
            try waitForFile(
                at: readyURL,
                from: writer,
                timeoutSeconds: Self.processTimeoutSeconds
            )
            // ready 从进程启动到出现必须跨过生产 700ms 自动保存等待窗口。
            let autosaveElapsedSeconds =
                ProcessInfo.processInfo.systemUptime - writerLaunchUptime
            // 允许小幅计时与调度容差，但显式 flush 的立即就绪不能通过。
            #expect(autosaveElapsedSeconds >= Self.minimumAutosaveDelaySeconds)
            // 就绪后的写进程必须仍然存活，确保没有走正常退出清理。
            #expect(writer.process.isRunning)
            // 真实子进程 PID 必须与 Swift Testing 父进程不同。
            #expect(writer.process.processIdentifier != ProcessInfo.processInfo.processIdentifier)
            // SIGKILL 不给应用 delegate 或析构逻辑任何主动刷盘机会。
            guard Darwin.kill(writer.process.processIdentifier, SIGKILL) == 0 else {
                // 返回即时 errno 便于定位 CI 权限或进程生命周期异常。
                throw failure("向写进程发送 SIGKILL 失败，errno=\(errno)")
            }
            // 同步等待内核回收被强杀的真实应用进程。
            writer.process.waitUntilExit()
            // Foundation 必须识别本次不是普通 exit。
            #expect(writer.process.terminationReason == .uncaughtSignal)
            // 终止信号必须精确为 SIGKILL。
            #expect(writer.process.terminationStatus == SIGKILL)
            // 崩溃前的会话 current 文件必须位于隔离根目录。
            #expect(
                FileManager.default.fileExists(
                    atPath: rootDirectory.appendingPathComponent("WorkspaceSession.json").path
                )
            )
            // 两个独立未命名草稿都应位于隔离根下的 Drafts 目录。
            let draftFiles = try FileManager.default.contentsOfDirectory(
                at: rootDirectory.appendingPathComponent("Drafts", isDirectory: true),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".previous.") }
            // 两个 dirty 标签必须产生两个不同 current 草稿文件。
            #expect(draftFiles.count == 2)

            // 第二个真实应用进程使用完全相同的隔离根模拟下一次启动。
            let reader = try launchApplication(
                executableURL: executableURL,
                mode: CrashRecoveryProcessTestCLI.readerMode,
                rootDirectory: rootDirectory
            )
            // 读进程异常挂起时也强制回收，避免污染后续测试。
            defer { killAndReapIfNeeded(reader.process) }
            // 等待读进程自行完成恢复并正常退出。
            try waitForExit(reader, timeoutSeconds: Self.processTimeoutSeconds)
            // 读进程必须走显式成功退出，而不是收到信号。
            #expect(reader.process.terminationReason == .exit)
            // 非零状态会携带子进程 stderr 作为测试错误。
            guard reader.process.terminationStatus == EXIT_SUCCESS else {
                // 完整读取已经关闭写端的错误管道。
                throw failure("读进程退出失败：\(standardErrorText(from: reader))")
            }
            // 读进程只有完成真实 WorkspaceModel 恢复后才会原子写出报告。
            let reportURL = rootDirectory.appendingPathComponent(
                CrashRecoveryProcessTestCLI.readerReportFilename,
                isDirectory: false
            )
            // 报告字节必须来自第二个进程，而不是父测试内存模型。
            let reportData = try Data(contentsOf: reportURL)
            // 解码实际标签顺序、正文、活动 UUID 和 dirty 状态。
            let report = try JSONDecoder().decode(
                CrashRecoveryProcessTestReport.self,
                from: reportData
            )
            // 两份不同正文必须按崩溃前顺序逐字恢复。
            #expect(
                report.documentTexts
                    == [
                        CrashRecoveryProcessTestCLI.firstDocumentText,
                        CrashRecoveryProcessTestCLI.secondDocumentText,
                    ]
            )
            // UUID 数量必须与正文和草稿数量一致。
            #expect(report.documentIDs.count == 2)
            // 崩溃前最后活动的第二标签必须继续保持活动。
            #expect(report.activeDocumentID == report.documentIDs.last)
            // 草稿恢复后两标签都仍是未写回正式文件的 dirty 状态。
            #expect(report.dirtyStates == [true, true])

            // 父测试再独立读取会话文件，排除报告伪造或内存默认值。
            let sessionStore = WorkspaceSessionStore(rootDirectory: rootDirectory)
            // 第二次启动后的 current 会话必须仍然完整可解码。
            let restoredSession = try #require(try sessionStore.load())
            // 会话 UUID 顺序必须与读进程报告完全一致。
            #expect(restoredSession.documents.map(\.id) == report.documentIDs)
            // 会话活动 UUID 必须与读进程实际状态一致。
            #expect(restoredSession.activeDocumentID == report.activeDocumentID)
            // 父测试从同一隔离存储逐个读取 UUID 对应草稿。
            let documentStore = DocumentSupportStore(rootDirectory: rootDirectory)
            // 第一份草稿必须完整且只归属第一标签。
            #expect(
                try documentStore.loadDraft(for: nil, untitledID: report.documentIDs[0])?.text
                    == CrashRecoveryProcessTestCLI.firstDocumentText
            )
            // 第二份草稿必须完整且只归属第二标签。
            #expect(
                try documentStore.loadDraft(for: nil, untitledID: report.documentIDs[1])?.text
                    == CrashRecoveryProcessTestCLI.secondDocumentText
            )
        }

        // 写模式必须在创建锁或恢复文件前关闭式拒绝任何非空根目录。
        @Test("写进程拒绝非空临时根目录")
        func writerRejectsNonemptyTemporaryRoot() throws {
            // 本用例使用独立标签方便失败时定位精确临时目录。
            let rootDirectory = try makeTemporaryDirectory(label: "nonempty-writer")
            // 只清理本次创建的精确目录。
            defer { try? FileManager.default.removeItem(at: rootDirectory) }
            // 预置固定哨兵，验证隐藏测试模式不会覆盖既有内容。
            let sentinelURL = rootDirectory.appendingPathComponent(
                "sentinel.txt",
                isDirectory: false
            )
            // 哨兵正文保持最小且可逐字复核。
            let sentinelData = Data("keep\n".utf8)
            // 先写入非空证据，再启动应用写子模式。
            try sentinelData.write(to: sentinelURL, options: [.atomic])
            // 使用当前 xctest 同级的真实应用产品。
            let executableURL = try markdownLiteExecutableURL()
            // 写子模式应在接触应用锁和恢复存储之前直接失败。
            let writer = try launchApplication(
                executableURL: executableURL,
                mode: CrashRecoveryProcessTestCLI.writerMode,
                rootDirectory: rootDirectory
            )
            // 子进程异常挂起时也只回收这一精确 PID。
            defer { killAndReapIfNeeded(writer.process) }
            // 使用有界等待避免误入 GUI 事件循环挂住测试。
            try waitForExit(writer, timeoutSeconds: Self.processTimeoutSeconds)
            // 安全拒绝必须是普通非零退出，不依赖信号终止。
            #expect(writer.process.terminationReason == .exit)
            // 参数边界失败统一返回 EXIT_FAILURE。
            #expect(writer.process.terminationStatus == EXIT_FAILURE)
            // 进程退出后只读取一次 stderr，避免重复读取空管道。
            let errorText = standardErrorText(from: writer)
            // 错误必须明确指出空目录契约。
            #expect(errorText.contains("必须为空"))
            // 原有哨兵内容必须逐字保持不变。
            #expect(try Data(contentsOf: sentinelURL) == sentinelData)
            // 写模式不得提前创建实例锁。
            #expect(
                !FileManager.default.fileExists(
                    atPath: rootDirectory.appendingPathComponent(
                        ApplicationInstanceLock.lockFilename,
                        isDirectory: false
                    ).path
                )
            )
            // 写模式不得提前创建工作区会话。
            #expect(
                !FileManager.default.fileExists(
                    atPath: rootDirectory.appendingPathComponent(
                        "WorkspaceSession.json",
                        isDirectory: false
                    ).path
                )
            )
            // 写模式不得提前创建草稿目录。
            #expect(
                !FileManager.default.fileExists(
                    atPath: rootDirectory.appendingPathComponent(
                        "Drafts",
                        isDirectory: true
                    ).path
                )
            )
            // 根目录最终仍只能包含父测试预置的哨兵。
            let remainingEntries = try FileManager.default.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil
            )
            // 排序后逐字比较，避免文件系统枚举顺序影响结果。
            #expect(remainingEntries.map(\.lastPathComponent).sorted() == ["sentinel.txt"])
        }

        // 读模式必须在创建锁和报告前拒绝恢复树中的任意符号链接。
        @Test("读进程拒绝包含符号链接的恢复树")
        func readerRejectsSymlinkInRecoveryTree() throws {
            // 恢复根与链接目标使用两个互不包含的唯一临时目录。
            let rootDirectory = try makeTemporaryDirectory(label: "symlink-reader")
            // 根目录清理由本测试精确负责。
            defer { try? FileManager.default.removeItem(at: rootDirectory) }
            // 链接目标单独创建，验证读进程不能越界访问或写入。
            let outsideDirectory = try makeTemporaryDirectory(label: "symlink-target")
            // 目标目录也只清理本测试创建的精确路径。
            defer { try? FileManager.default.removeItem(at: outsideDirectory) }
            // 外部哨兵提供越界目录未被修改的直接证据。
            let outsideSentinelURL = outsideDirectory.appendingPathComponent(
                "outside-sentinel.txt",
                isDirectory: false
            )
            // 使用固定字节避免文本编码差异。
            let outsideSentinelData = Data("outside-keep\n".utf8)
            // 在创建链接前写入外部目录的唯一内容。
            try outsideSentinelData.write(to: outsideSentinelURL, options: [.atomic])
            // 将恢复树常用 Drafts 节点恶意指向根外目录。
            let draftsLinkURL = rootDirectory.appendingPathComponent(
                "Drafts",
                isDirectory: true
            )
            // 父测试显式创建真实 POSIX 符号链接夹具。
            try FileManager.default.createSymbolicLink(
                at: draftsLinkURL,
                withDestinationURL: outsideDirectory
            )
            // 仍然只启动当前 xctest 同一产品目录中的应用。
            let executableURL = try markdownLiteExecutableURL()
            // 读子模式应在构造 ApplicationInstanceLock 和 WorkspaceModel 前失败。
            let reader = try launchApplication(
                executableURL: executableURL,
                mode: CrashRecoveryProcessTestCLI.readerMode,
                rootDirectory: rootDirectory
            )
            // 任何异常挂起都只强杀并回收当前读进程。
            defer { killAndReapIfNeeded(reader.process) }
            // 有界等待关闭失败路径。
            try waitForExit(reader, timeoutSeconds: Self.processTimeoutSeconds)
            // 安全拒绝必须通过正常错误出口完成。
            #expect(reader.process.terminationReason == .exit)
            // 符号链接树统一产生非零状态。
            #expect(reader.process.terminationStatus == EXIT_FAILURE)
            // 退出后集中读取一次错误输出。
            let errorText = standardErrorText(from: reader)
            // stderr 必须精确表明拒绝原因是符号链接。
            #expect(errorText.contains("符号链接"))
            // 根目录内不能在安全校验前创建应用锁。
            #expect(
                !FileManager.default.fileExists(
                    atPath: rootDirectory.appendingPathComponent(
                        ApplicationInstanceLock.lockFilename,
                        isDirectory: false
                    ).path
                )
            )
            // 根目录内不能生成伪恢复报告。
            #expect(
                !FileManager.default.fileExists(
                    atPath: rootDirectory.appendingPathComponent(
                        CrashRecoveryProcessTestCLI.readerReportFilename,
                        isDirectory: false
                    ).path
                )
            )
            // 链接外的哨兵内容必须逐字保持不变。
            #expect(try Data(contentsOf: outsideSentinelURL) == outsideSentinelData)
            // 根外目标仍只能包含原始哨兵，没有被当成 Drafts 写入。
            let outsideEntries = try FileManager.default.contentsOfDirectory(
                at: outsideDirectory,
                includingPropertiesForKeys: nil
            )
            // 排序后复核唯一文件，排除隐藏的新草稿或锁。
            #expect(outsideEntries.map(\.lastPathComponent).sorted() == ["outside-sentinel.txt"])
        }

        // 读模式只能恢复 writer 固定创建的未命名标签，不能成为任意文件读取入口。
        @Test("读进程拒绝会话中的外部文件路径")
        func readerRejectsExternalFileURLInSession() throws {
            // 恢复根只保存本用例伪造的会话描述。
            let rootDirectory = try makeTemporaryDirectory(label: "external-file-reader")
            // 测试结束后只清理精确恢复根。
            defer { try? FileManager.default.removeItem(at: rootDirectory) }
            // 外部目录模拟临时根之外、应用可能有权限读取的本地位置。
            let outsideDirectory = try makeTemporaryDirectory(label: "external-file-target")
            // 外部夹具同样只由本测试清理。
            defer { try? FileManager.default.removeItem(at: outsideDirectory) }
            // 固定文件名与正文用于确认失败路径没有修改来源。
            let outsideFileURL = outsideDirectory.appendingPathComponent(
                "private.md",
                isDirectory: false
            )
            // 内容包含不可由默认示例偶然产生的标记。
            let outsideData = Data("private-reader-sentinel\n".utf8)
            // 在根外写入真实可读文件，确保校验不是依赖读取失败才通过。
            try outsideData.write(to: outsideFileURL, options: [.atomic])
            // 构造两个唯一标签以通过数量和 UUID 布局的前置条件。
            let firstDocumentID = UUID()
            // 第二个标签保持未命名，只有第一项携带危险文件地址。
            let secondDocumentID = UUID()
            // 使用生产会话编码入口写入当前代，读进程会按真实规则选择它。
            let sessionStore = WorkspaceSessionStore(rootDirectory: rootDirectory)
            // 文件路径故意指向已验证临时根之外。
            try sessionStore.save(
                WorkspaceSessionState(
                    documents: [
                        WorkspaceSessionDocument(id: firstDocumentID, fileURL: outsideFileURL),
                        WorkspaceSessionDocument(id: secondDocumentID, fileURL: nil),
                    ],
                    activeDocumentID: secondDocumentID
                )
            )
            // 只启动当前 xctest 产品目录中的 Debug 应用测试入口。
            let executableURL = try markdownLiteExecutableURL()
            // Reader 必须在构造 WorkspaceModel 和读取文件之前关闭式失败。
            let reader = try launchApplication(
                executableURL: executableURL,
                mode: CrashRecoveryProcessTestCLI.readerMode,
                rootDirectory: rootDirectory
            )
            // 异常挂起时也只回收当前精确 PID。
            defer { killAndReapIfNeeded(reader.process) }
            // 有界等待同时证明实现没有尝试进入普通 GUI 运行循环。
            try waitForExit(reader, timeoutSeconds: Self.processTimeoutSeconds)
            // 安全拒绝必须走普通错误出口。
            #expect(reader.process.terminationReason == .exit)
            // 任意含文件 URL 的会话统一返回失败。
            #expect(reader.process.terminationStatus == EXIT_FAILURE)
            // 错误只说明夹具契约，不得回显外部路径或正文。
            let errorText = standardErrorText(from: reader)
            // 稳定文案证明失败发生在工作区恢复之前。
            #expect(errorText.contains("只能包含未命名标签"))
            // 错误输出不得泄露文件名、完整路径或外部正文。
            #expect(!errorText.contains(outsideFileURL.lastPathComponent))
            #expect(!errorText.contains(outsideFileURL.path))
            #expect(!errorText.contains("private-reader-sentinel"))
            // Reader 在校验失败前不能生成包含正文的报告。
            #expect(
                !FileManager.default.fileExists(
                    atPath: rootDirectory.appendingPathComponent(
                        CrashRecoveryProcessTestCLI.readerReportFilename,
                        isDirectory: false
                    ).path
                )
            )
            // 校验失败发生在实例锁创建之前。
            #expect(
                !FileManager.default.fileExists(
                    atPath: rootDirectory.appendingPathComponent(
                        ApplicationInstanceLock.lockFilename,
                        isDirectory: false
                    ).path
                )
            )
            // 根外来源字节保持完全不变。
            #expect(try Data(contentsOf: outsideFileURL) == outsideData)
        }

        // 在系统临时目录下创建父测试拥有的唯一隔离根。
        private func makeTemporaryDirectory(label: String = "process") throws -> URL {
            // UUID 防止串行重跑或残留目录发生路径冲突。
            let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "MarkdownLiteMac-CrashRecoveryProcessTests-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
            // 先由父测试创建目录，应用子模式只接受已存在的临时真目录。
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: false
            )
            // 返回标准化路径供两个真实子进程复用。
            return rootDirectory.standardizedFileURL
        }

        // 从当前 xctest bundle 定位同一 scratch 与构建配置的应用产品。
        private func markdownLiteExecutableURL() throws -> URL {
            // Objective-C bundle 查找以测试 target 内标记类为锚点，不依赖源码绝对路径。
            let testBundleURL = Bundle(for: CrashRecoveryTestBundleMarker.self).bundleURL
            // 仅接受 SwiftPM 实际加载的 xctest bundle，异常布局关闭式失败。
            guard testBundleURL.pathExtension == "xctest" else {
                // 输出精确 bundle 路径便于排查测试运行器差异。
                throw failure("当前测试未加载自 xctest bundle：\(testBundleURL.path)")
            }
            // SwiftPM 把应用可执行文件放在当前 xctest bundle 的同级产品目录。
            let productsDirectory = testBundleURL.deletingLastPathComponent()
            // 固定产品名只会选择本次 scratch 与配置刚链接的应用。
            let candidateURL = productsDirectory.appendingPathComponent(
                "MarkdownLiteMac",
                isDirectory: false
            )
            // 只接受当前产品目录内的真实可执行文件，绝不回退仓库 .build 或 PATH。
            guard FileManager.default.isExecutableFile(atPath: candidateURL.path) else {
                // 输出精确候选路径便于排查 SwiftPM 自定义 scratch 布局。
                throw failure("找不到当前测试产品目录的 MarkdownLiteMac 可执行文件：\(candidateURL.path)")
            }
            // 返回标准化的当前测试产品路径，不解析到其他 scratch。
            return candidateURL.standardizedFileURL
        }

        // 用隐藏测试子模式和隔离根启动一个真实 MarkdownLiteMac 进程。
        private func launchApplication(
            executableURL: URL,
            mode: String,
            rootDirectory: URL
        ) throws -> SpawnedMarkdownLiteProcess {
            // Foundation Process 直接 exec 当前构建的应用产品。
            let process = Process()
            // 固定绝对路径避免 PATH 或已安装旧版本干扰。
            process.executableURL = executableURL
            // 子模式与临时根均使用明确的成对命令行参数。
            process.arguments = [
                mode,
                CrashRecoveryProcessTestCLI.temporaryRootArgument,
                rootDirectory.path,
            ]
            // 错误输出不进入父测试控制台，失败时再精确附加。
            let standardError = Pipe()
            // 保存子进程唯一错误管道供退出后读取。
            process.standardError = standardError
            // 启动真实独立 PID；失败时由 Foundation 原样抛出。
            try process.run()
            // 返回进程和管道的共同生命周期。
            return SpawnedMarkdownLiteProcess(process: process, standardError: standardError)
        }

        // 等待写进程创建原子就绪标记，同时拒绝提前退出。
        private func waitForFile(
            at fileURL: URL,
            from child: SpawnedMarkdownLiteProcess,
            timeoutSeconds: Double
        ) throws {
            // 使用单调时钟避免系统时间调整影响超时。
            let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
            // 在有限窗口内轮询小型本地标记。
            while ProcessInfo.processInfo.systemUptime < deadline {
                // 文件存在表示写进程已经完成恢复数据回读和提交。
                if FileManager.default.fileExists(atPath: fileURL.path) { return }
                // 提前退出说明写子模式失败，立即返回其具体错误。
                if !child.process.isRunning {
                    // waitUntilExit 固化退出状态并关闭错误管道写端。
                    child.process.waitUntilExit()
                    // stderr 包含应用入口返回的隔离或存储失败原因。
                    throw failure("写进程提前退出：\(standardErrorText(from: child))")
                }
                // 十毫秒间隔避免忙等，同时远低于磁盘门禁粒度。
                Thread.sleep(forTimeInterval: 0.01)
            }
            // 超时路径由外层 defer 强杀并回收仍存活的进程。
            throw failure("等待写进程就绪超过 \(timeoutSeconds) 秒")
        }

        // 有界等待任意测试子进程自行完成，防止错误进入图形事件循环后挂住测试。
        private func waitForExit(
            _ child: SpawnedMarkdownLiteProcess,
            timeoutSeconds: Double
        ) throws {
            // 单调截止时间不受系统时钟回拨影响。
            let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
            // 仅在子进程仍运行且未超时时继续等待。
            while child.process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                // 十毫秒轮询兼顾快速测试和低 CPU 占用。
                Thread.sleep(forTimeInterval: 0.01)
            }
            // 超时后不调用无界 waitUntilExit，交给 defer 强制回收。
            guard !child.process.isRunning else {
                // 明确指出很可能未命中隐藏 CLI 子模式。
                throw failure("等待测试子进程退出超过 \(timeoutSeconds) 秒")
            }
            // 进程已退出时同步完成 Foundation 状态收集。
            child.process.waitUntilExit()
        }

        // 测试失败时只处理仍存活的精确子进程 PID。
        private func killAndReapIfNeeded(_ process: Process) {
            // 已退出进程已经由正常断言路径 wait，不重复发送信号。
            guard process.isRunning else { return }
            // SIGKILL 保证错误进入 GUI 循环时也不会遗留应用进程。
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            // 同步回收防止僵尸进程污染后续测试。
            process.waitUntilExit()
        }

        // 在子进程退出后读取 UTF-8 错误文本。
        private func standardErrorText(from child: SpawnedMarkdownLiteProcess) -> String {
            // 管道写端已随子进程退出关闭，此读取不会阻塞。
            let data = child.standardError.fileHandleForReading.readDataToEndOfFile()
            // 无法解码时仍返回稳定占位，不隐藏退出状态。
            return String(data: data, encoding: .utf8) ?? "<非 UTF-8 错误输出>"
        }

        // 统一构造 Swift Testing 可直接展示的本地过程错误。
        private func failure(_ description: String) -> NSError {
            // 固定域携带具体阶段说明，不引入新的测试依赖。
            NSError(
                domain: "CrashRecoveryProcessTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }
#endif
