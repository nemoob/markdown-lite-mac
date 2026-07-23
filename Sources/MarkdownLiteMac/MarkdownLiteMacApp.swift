import AppKit
import SwiftUI

#if DEBUG
    import Darwin

    // 定义仅供自动化测试启动真实应用进程使用的隐藏命令行契约。
    enum CrashRecoveryProcessTestCLI {
        // 写进程创建恢复数据并等待父测试强制终止。
        static let writerMode = "--test-crash-recovery-writer"
        // 读进程模拟崩溃后的下一次真实启动。
        static let readerMode = "--test-crash-recovery-reader"
        // 两个子模式都必须显式提供隔离的系统临时目录。
        static let temporaryRootArgument = "--test-temp-root"
        // 写进程只有完成工作区会话和真实自动草稿落盘后才创建此标记。
        static let writerReadyFilename = "CrashRecoveryWriter.ready"
        // 读进程把实际恢复结果写回同一隔离目录供父测试复核。
        static let readerReportFilename = "CrashRecoveryReaderReport.json"
        // 第一标签使用固定正文，父测试可以逐字验证没有串稿或截断。
        static let firstDocumentText = "# 崩溃恢复测试\n\n第一标签尚未保存到正式文件。\n"
        // 第二标签使用不同固定正文，同时覆盖标签顺序和活动标签恢复。
        static let secondDocumentText = "# Crash Recovery\n\n第二标签必须在 SIGKILL 后完整恢复。\n"
    }

    // 保存读进程从真实工作区恢复到的可核对结果。
    struct CrashRecoveryProcessTestReport: Codable, Equatable {
        // 标签 UUID 顺序必须与崩溃前会话一致。
        let documentIDs: [UUID]
        // 每个 UUID 对应的草稿正文必须完整恢复。
        let documentTexts: [String]
        // 崩溃前最后活动的标签必须继续保持活动。
        let activeDocumentID: UUID?
        // 草稿恢复的标签仍应保持 dirty，不能伪装成已写回正式文件。
        let dirtyStates: [Bool]
    }

    // 构造测试子模式可直接输出的稳定错误。
    private func crashRecoveryProcessTestError(_ description: String) -> NSError {
        // 固定错误域让子进程 stderr 可快速区分参数与恢复失败。
        NSError(
            domain: "MarkdownLiteMac.CrashRecoveryProcessTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    // 使用 lstat 读取路径自身类型，避免 Foundation 目录检查跟随最终符号链接。
    private func crashRecoveryPathType(at url: URL) throws -> mode_t {
        // 预留 POSIX 元数据结构接收路径自身状态。
        var fileStatus = stat()
        // 清空旧 errno，路径无法表示时才能返回稳定参数错误。
        errno = 0
        // 文件系统表示只在闭包生命周期内有效。
        let result = url.withUnsafeFileSystemRepresentation { path in
            // 无法转换成本地路径时明确设置参数错误。
            guard let path else {
                // EINVAL 区分路径编码问题和真实 IO 失败。
                errno = EINVAL
                // lstat 风格以 -1 表示失败。
                return Int32(-1)
            }
            // lstat 不跟随最终符号链接，能够封闭测试根和子树边界。
            return Darwin.lstat(path, &fileStatus)
        }
        // 任意元数据读取失败都不能继续创建测试存储。
        guard result == 0 else {
            // 保留即时 errno 便于测试 stderr 定位夹具问题。
            throw crashRecoveryProcessTestError("无法检查测试路径类型（错误码 \(errno)）")
        }
        // 只返回文件类型位，调用方不依赖权限和时间元数据。
        return fileStatus.st_mode & mode_t(S_IFMT)
    }

    // 从命令行读取并验证隔离根目录，绝不允许测试模式触碰真实 Application Support。
    private func validatedCrashRecoveryTemporaryRoot(arguments: [String]) throws -> URL {
        // 根目录参数必须出现且后面紧跟非空路径。
        guard let argumentIndex = arguments.firstIndex(of: CrashRecoveryProcessTestCLI.temporaryRootArgument),
            arguments.indices.contains(argumentIndex + 1),
            !arguments[argumentIndex + 1].isEmpty
        else {
            // 缺少隔离参数时关闭式失败，不能回退生产默认目录。
            throw crashRecoveryProcessTestError("缺少 --test-temp-root 隔离目录")
        }
        // 先规范化调用方路径，但保留最终节点供 lstat 检查。
        let unresolvedRoot = URL(
            fileURLWithPath: arguments[argumentIndex + 1],
            isDirectory: true
        ).standardizedFileURL
        // 根节点自身必须是真目录，符号链接即使仍指向临时目录也不接受。
        guard try crashRecoveryPathType(at: unresolvedRoot) == mode_t(S_IFDIR) else {
            // 测试根必须由父测试直接创建，不能通过链接重定向。
            throw crashRecoveryProcessTestError("测试根目录不能是符号链接或普通文件")
        }
        // 根节点类型确认后再消除祖先路径中的点段和符号链接。
        let requestedRoot = unresolvedRoot.resolvingSymlinksInPath()
        // 同样解析系统临时目录，兼容 macOS 的 /var 到 /private/var 链接。
        let systemTemporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        // 路径组件比较避免仅靠字符串前缀误接收相邻目录。
        let requestedComponents = requestedRoot.pathComponents
        // 系统临时根目录组件作为必须完整匹配的安全前缀。
        let temporaryComponents = systemTemporaryRoot.pathComponents
        // 测试根必须是临时目录的真子目录，不能直接占用整个系统临时根。
        guard requestedComponents.count > temporaryComponents.count,
            Array(requestedComponents.prefix(temporaryComponents.count)) == temporaryComponents
        else {
            // 任意非临时路径都直接拒绝，尤其不能落入用户恢复目录。
            throw crashRecoveryProcessTestError("测试根目录必须位于系统临时目录内")
        }
        // 返回已经验证并解析过软链接的唯一隔离根。
        return requestedRoot
    }

    // 写进程只接受空目录，避免测试模式复用或覆盖任何既有恢复树。
    private func validateEmptyCrashRecoveryWriterRoot(_ rootDirectory: URL) throws {
        // 一次读取包含隐藏项在内的直接子项。
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )
        // 锁、会话、草稿或任意陌生文件存在时都关闭式拒绝。
        guard entries.isEmpty else {
            // 空目录契约同时阻止 Drafts 预置链接越过临时根。
            throw crashRecoveryProcessTestError("写进程测试根目录必须为空")
        }
    }

    // 递归验证读进程将访问的现有恢复树不包含符号链接或特殊节点。
    private func validateCrashRecoveryReaderTree(at directory: URL) throws {
        // 只列当前层，子目录由下方显式递归且先执行 lstat。
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        // 每个现有节点都必须保持在已经验证的真实目录树中。
        for entry in entries {
            // 读取节点自身类型，不能让 FileManager 自动跟随链接。
            let pathType = try crashRecoveryPathType(at: entry)
            // 任意符号链接都可能把草稿读取或报告写入引向根外。
            guard pathType != mode_t(S_IFLNK) else {
                // 错误只公开临时树内文件名，不输出正文。
                throw crashRecoveryProcessTestError("读进程恢复树包含符号链接：\(entry.lastPathComponent)")
            }
            // 真目录继续逐层验证全部后代。
            if pathType == mode_t(S_IFDIR) {
                // 递归前已经确认当前节点不是链接。
                try validateCrashRecoveryReaderTree(at: entry)
                // 目录完成后进入下一兄弟节点。
                continue
            }
            // 普通文件是会话、草稿、锁和测试标记允许的唯一叶子类型。
            guard pathType == mode_t(S_IFREG) else {
                // FIFO、socket 和设备节点可能阻塞或越过测试 IO 口径。
                throw crashRecoveryProcessTestError("读进程恢复树包含特殊文件：\(entry.lastPathComponent)")
            }
        }
    }

    // 校验生产会话存储实际选择的代只描述本测试固定创建的两个未命名标签。
    private func validateCrashRecoveryReaderSession(_ session: WorkspaceSessionState?) throws {
        // 两代都不存在不能进入工作区默认新建路径，否则会伪造恢复成功。
        guard let session else {
            // 缺失会话时关闭式失败且不创建任何报告。
            throw crashRecoveryProcessTestError("读进程缺少可恢复会话")
        }
        // 崩溃写夹具固定创建两个标签，更多或更少都不属于本测试数据。
        guard session.documents.count == 2 else {
            // 数量不符可能来自调用方伪造或意外复用临时根。
            throw crashRecoveryProcessTestError("读进程选中会话必须恰好包含两个标签")
        }
        // 两个 UUID 都必须唯一且非空布局有效，避免草稿身份发生竞争。
        guard session.hasValidDocumentIdentityLayout else {
            // 身份歧义时不能让 WorkspaceModel 尝试部分恢复。
            throw crashRecoveryProcessTestError("读进程选中会话的标签身份布局无效")
        }
        // 测试 writer 只创建未命名标签，任意文件 URL 都可能读取临时根外正文。
        guard session.documents.allSatisfy({ $0.fileURL == nil }) else {
            // 错误不回显路径或正文，只说明固定夹具契约。
            throw crashRecoveryProcessTestError("读进程选中会话只能包含未命名标签")
        }
        // 活动 UUID 必须真实属于这两个已验证标签，不能依赖工作区兜底选择。
        guard let activeDocumentID = session.activeDocumentID,
            session.documents.contains(where: { $0.id == activeDocumentID })
        else {
            // 无效活动身份说明会话并非写夹具最终状态。
            throw crashRecoveryProcessTestError("读进程选中会话的活动标签无效")
        }
    }

    // 驱动主运行循环，直到真实 700ms 自动草稿和最终会话都可以完整回读。
    @MainActor
    private func waitForCrashRecoveryAutosave(
        workspace: WorkspaceModel,
        documentStore: DocumentSupportStore,
        sessionStore: WorkspaceSessionStore,
        firstDocument: EditorModel,
        secondDocument: EditorModel,
        timeoutSeconds: Double = 10
    ) throws {
        // 使用单调时钟设置有界截止时间，系统时间调整不会延长测试。
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        // 自动草稿计时器和后台 IO 完成前持续短暂驱动主运行循环。
        while ProcessInfo.processInfo.systemUptime < deadline {
            // 会话必须包含崩溃前最终标签顺序和活动 UUID。
            let savedSession = try? sessionStore.load()
            // 第一标签必须由生产自动草稿计时器写出完整正文。
            let firstDraft = try? documentStore.loadDraft(for: nil, untitledID: firstDocument.id)
            // 第二标签使用独立 UUID 验证后台保存没有串稿。
            let secondDraft = try? documentStore.loadDraft(for: nil, untitledID: secondDocument.id)
            // 三份恢复数据全部就绪后才允许父测试发送 SIGKILL。
            if savedSession?.documents.map(\.id) == workspace.documents.map(\.id),
                savedSession?.activeDocumentID == secondDocument.id,
                firstDraft?.text == CrashRecoveryProcessTestCLI.firstDocumentText,
                secondDraft?.text == CrashRecoveryProcessTestCLI.secondDocumentText
            {
                // 返回时没有调用退出 flush，草稿只能来自真实 700ms 自动路径。
                return
            }
            // 默认模式会触发 EditorModel 的 700ms Timer 和后续 MainActor Task。
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.01)
            )
        }
        // 自动草稿或会话任一未就绪都禁止伪造 ready 标记。
        throw crashRecoveryProcessTestError("等待真实自动草稿落盘超时")
    }

    // 创建真实 dirty 工作区、等待自动恢复数据落盘并等待父测试发送 SIGKILL。
    @MainActor
    private func runCrashRecoveryWriter(rootDirectory: URL) throws -> Never {
        // 测试锁固定放在隔离根目录，绝不竞争真实用户应用实例。
        let lockFileURL = rootDirectory.appendingPathComponent(
            ApplicationInstanceLock.lockFilename,
            isDirectory: false
        )
        // 使用生产锁实现覆盖崩溃后内核释放描述符的启动条件。
        let instanceLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 文档草稿明确注入同一个隔离根目录。
        let documentStore = DocumentSupportStore(rootDirectory: rootDirectory)
        // 会话文件与草稿共享隔离根目录但保持生产文件布局。
        let sessionStore = WorkspaceSessionStore(rootDirectory: rootDirectory)
        // 不读取任何既有会话，以生产入口创建首个工作区标签。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: false
        )
        // 首次工作区必须提供唯一初始标签。
        guard let firstDocument = workspace.documents.first else {
            // 没有标签时不能生成虚假的就绪标记。
            throw crashRecoveryProcessTestError("写进程未创建首个标签")
        }
        // 第一标签写入固定且可独立识别的未保存正文。
        firstDocument.text = CrashRecoveryProcessTestCLI.firstDocumentText
        // 使用真实工作区入口追加第二标签并立即持久化新顺序。
        workspace.newDocument()
        // 第二标签必须真实存在且成为活动标签。
        guard workspace.documents.count == 2, let secondDocument = workspace.documents.last else {
            // 标签数量异常时停止，避免只验证单草稿恢复。
            throw crashRecoveryProcessTestError("写进程未创建第二个标签")
        }
        // 第二标签写入不同正文以检测 UUID 草稿键串写。
        secondDocument.text = CrashRecoveryProcessTestCLI.secondDocumentText
        // 驱动真实自动保存计时器并回读全部恢复数据，不能调用退出同步 flush。
        try waitForCrashRecoveryAutosave(
            workspace: workspace,
            documentStore: documentStore,
            sessionStore: sessionStore,
            firstDocument: firstDocument,
            secondDocument: secondDocument
        )
        // 就绪标记只保存固定短文本，不复制任何用户正文。
        let readyData = Data("ready\n".utf8)
        // 标记与恢复文件位于同一隔离根，父测试无需观察真实用户路径。
        let readyURL = rootDirectory.appendingPathComponent(
            CrashRecoveryProcessTestCLI.writerReadyFilename,
            isDirectory: false
        )
        // 原子写入确保父测试不会把半成品标记误判为已落盘。
        try readyData.write(to: readyURL, options: [.atomic])
        // 显式延长锁和工作区生命周期，等待期间不运行任何正常退出清理。
        return withExtendedLifetime((instanceLock, workspace)) { () -> Never in
            // 只有父测试的 SIGKILL 才会结束此进程。
            while true {
                // pause 不消耗 CPU，并会在其他信号后继续等待。
                _ = Darwin.pause()
            }
        }
    }

    // 使用同一隔离根模拟崩溃后的下一次真实应用启动并输出恢复结果。
    @MainActor
    private func runCrashRecoveryReader(rootDirectory: URL) throws {
        // 会话存储先按生产 current/previous 规则选择实际恢复代。
        let sessionStore = WorkspaceSessionStore(rootDirectory: rootDirectory)
        // current 损坏时这里取得 previous，安全校验不能误查原始 current 字节。
        let selectedSession = try sessionStore.loadWithRecoverySource()?.state
        // 在创建锁、文档存储或工作区前关闭式拒绝文件路径和异常身份。
        try validateCrashRecoveryReaderSession(selectedSession)
        // 读进程必须重新获取被 SIGKILL 进程持有过的同一路径锁。
        let lockFileURL = rootDirectory.appendingPathComponent(
            ApplicationInstanceLock.lockFilename,
            isDirectory: false
        )
        // 获取成功同时证明内核已经释放崩溃进程的独占描述符。
        let instanceLock = try ApplicationInstanceLock(lockFileURL: lockFileURL)
        // 文档存储仍只读取父测试提供的隔离根目录。
        let documentStore = DocumentSupportStore(rootDirectory: rootDirectory)
        // 正式恢复入口读取会话、按 UUID 加载草稿并恢复活动标签。
        let workspace = WorkspaceModel(
            documentStore: documentStore,
            sessionStore: sessionStore,
            restoresSession: true
        )
        // 捕获恢复后的真实标签顺序供父测试逐项核对。
        let report = CrashRecoveryProcessTestReport(
            documentIDs: workspace.documents.map(\.id),
            documentTexts: workspace.documents.map(\.text),
            activeDocumentID: workspace.activeDocumentID,
            dirtyStates: workspace.documents.map(\.isDirty)
        )
        // 关闭首轮预览任务，读进程不需要启动图形界面或等待渲染。
        workspace.documents.forEach { $0.prepareForClose() }
        // 使用确定性键顺序方便失败时直接检查临时 JSON。
        let encoder = JSONEncoder()
        // 排序键只影响测试报告，不改变生产恢复文件格式。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 完整编码实际恢复结果后再触碰报告文件。
        let reportData = try encoder.encode(report)
        // 报告固定落在隔离根目录，父测试可确认第二个进程真正完成恢复。
        let reportURL = rootDirectory.appendingPathComponent(
            CrashRecoveryProcessTestCLI.readerReportFilename,
            isDirectory: false
        )
        // 原子提交防止父测试读取到不完整 JSON。
        try reportData.write(to: reportURL, options: [.atomic])
        // 保持实例锁直到恢复结果已经完整落盘。
        withExtendedLifetime((instanceLock, workspace)) {}
    }

    // 执行一个明确请求的隐藏测试子模式；正常应用启动返回 false。
    @MainActor
    private func runCrashRecoveryProcessTestIfRequested(arguments: [String]) -> Bool {
        // 只识别两个完整固定标记，普通文档路径不会误触发测试模式。
        let requestedModes = arguments.filter {
            // 写模式和读模式都属于同一互斥命令。
            $0 == CrashRecoveryProcessTestCLI.writerMode || $0 == CrashRecoveryProcessTestCLI.readerMode
        }
        // 没有测试标记时继续正常应用初始化。
        guard !requestedModes.isEmpty else { return false }
        do {
            // 同一次启动只能选择一个且只能出现一次测试模式。
            guard requestedModes.count == 1, let requestedMode = requestedModes.first else {
                // 歧义参数必须关闭式失败，不能创建任何恢复存储。
                throw crashRecoveryProcessTestError("测试子模式参数重复或冲突")
            }
            // 在创建锁、存储或工作区前先完成临时根安全校验。
            let rootDirectory = try validatedCrashRecoveryTemporaryRoot(arguments: arguments)
            // 写模式准备完成后会一直等待父测试强制终止。
            if requestedMode == CrashRecoveryProcessTestCLI.writerMode {
                // 写进程在创建锁之前确认目录完全为空。
                try validateEmptyCrashRecoveryWriterRoot(rootDirectory)
                // 函数返回 Never，因此不会继续构造 SwiftUI 场景。
                try runCrashRecoveryWriter(rootDirectory: rootDirectory)
            }
            // 读进程在加载任何会话或草稿之前拒绝整棵树中的链接和特殊文件。
            try validateCrashRecoveryReaderTree(at: rootDirectory)
            // 唯一剩余合法值是读模式，执行真实恢复并写报告。
            try runCrashRecoveryReader(rootDirectory: rootDirectory)
            // 读模式完成后立即成功退出，不启动窗口事件循环。
            exit(EXIT_SUCCESS)
        } catch {
            // 错误仅写入子进程标准错误，父测试会收集并展示。
            let failureData = Data("崩溃恢复进程测试失败：\(error.localizedDescription)\n".utf8)
            // 标准错误写入失败也不能回退正常应用路径。
            try? FileHandle.standardError.write(contentsOf: failureData)
            // 参数或恢复失败都使用非零状态让父测试明确失败。
            exit(EXIT_FAILURE)
        }
    }
#endif

// 汇总所有无界面自检并输出可复核性能数据。
@MainActor
private func runSelfCheck() {
    do {
        // 文档层在临时目录验证编码、原子写入、草稿与最近文件。
        let documentReport = try DocumentSupportSelfCheck.run()
        // Markdown 层严格执行 200KB 和 1MB 性能目标。
        let markdownReport = EnhancedMarkdownSelfCheck.run()
        // 智能列表层用 1MB 文档严格执行 Return 延迟目标。
        let listContinuationReport = MarkdownListContinuationSelfCheck.run()
        // 会话层验证标签顺序和活动标签可跨启动恢复。
        let sessionReport = try SessionSupportSelfCheck.run()
        // 双代恢复层用 1MB 草稿和 100 标签会话执行功能与性能门禁。
        let recoveryReport = try RecoverySupportSelfCheck.run()
        // 图片层验证相对路径、重名、类型和目录安全。
        let assetCheckCount = AssetSupportSelfCheck.run(printResults: false)
        // 工作区层验证真实多标签去重、草稿和失效文件恢复。
        let workspaceReport = try WorkspaceModelSelfCheck.run()
        // 导出层验证转义、协议过滤和公众号结构。
        let exportFailures = ExportSupportSelfCheck.run()
        // 任一导出断言失败都终止自检。
        precondition(exportFailures.isEmpty, exportFailures.joined(separator: "；"))
        // 输出文档层通过项。
        print(documentReport)
        // 输出会话恢复通过项。
        print(sessionReport)
        // 输出双代恢复三条发布性能证据。
        print(
            "双代恢复性能通过：1MB 保存中位数 "
                + "\(String(format: "%.2f", recoveryReport.draftSaveMedianMilliseconds))ms，"
                + "1MB 回退中位数 \(String(format: "%.2f", recoveryReport.draftFallbackMedianMilliseconds))ms，"
                + "100 标签会话回退中位数 "
                + "\(String(format: "%.2f", recoveryReport.sessionFallbackMedianMilliseconds))ms"
        )
        // 输出图片资源层通过项。
        print("AssetSupportSelfCheck 通过 \(assetCheckCount) 项")
        // 输出多标签工作区综合通过项。
        print(workspaceReport)
        // 输出结构化性能汇总。
        print(
            "Markdown 性能通过：200KB \(String(format: "%.2f", markdownReport.mediumDocument.milliseconds))ms，"
                + "1MB \(String(format: "%.2f", markdownReport.largeDocument.milliseconds))ms"
        )
        // 输出智能 Return 的尾延迟和最大值，方便 CI 与发布复核。
        print(
            "智能列表 Return 性能通过：1MB p95 "
                + "\(String(format: "%.2f", listContinuationReport.p95Milliseconds))ms，"
                + "max \(String(format: "%.2f", listContinuationReport.maximumMilliseconds))ms"
        )
        // 输出导出层成功标记。
        print("ExportSupportSelfCheck：通过")
    } catch {
        // 抛错型自检失败时输出具体错误并终止。
        fatalError(error.localizedDescription)
    }
}

// 将工作区和当前标签同时注入现有内容视图。
private struct WorkspaceHostView: View {
    // 观察标签切换并更新当前 EditorModel 环境对象。
    @ObservedObject var workspace: WorkspaceModel
    // App delegate 在终止决策阶段读取当前工作区。
    let applicationDelegate: MarkdownLiteApplicationDelegate

    // 主窗口始终由工作区保证至少一个标签。
    var body: some View {
        Group {
            // 有活动标签时注入工作区和标签自身模型。
            if let activeDocument = workspace.activeDocument {
                ContentView()
                    .environmentObject(workspace)
                    .environmentObject(activeDocument)
            } else {
                // 极端初始化失败时展示无数据占位，不强制解包崩溃。
                Text("正在恢复工作区…")
            }
        }
        // 视图进入窗口后把工作区交给可取消退出的 delegate。
        .onAppear {
            applicationDelegate.workspace = workspace
        }
    }
}

// 声明原生 macOS 应用入口。
@main
struct MarkdownLiteMacApp: App {
    // AppKit delegate 在 willTerminate 之前提供可取消的退出钩子。
    @NSApplicationDelegateAdaptor(MarkdownLiteApplicationDelegate.self) private var applicationDelegate
    // 正常进程全生命周期持有独占锁，避免第二实例写同一份恢复数据。
    private let instanceLock: ApplicationInstanceLock
    // 单窗口共享同一份多标签工作区。
    @StateObject private var workspace: WorkspaceModel

    // 支持从同一个可执行文件运行完整自检。
    init() {
        #if DEBUG
            // 隐藏进程测试在生产锁和默认存储初始化之前完成隔离校验与执行。
            if runCrashRecoveryProcessTestIfRequested(arguments: CommandLine.arguments) {
                // 测试函数的两条执行路径都会 exit 或等待 SIGKILL，此处仅满足控制流可读性。
                exit(EXIT_SUCCESS)
            }
        #endif
        // 命令行自检不启动窗口或读取用户草稿。
        if CommandLine.arguments.contains("--self-check") {
            runSelfCheck()
            exit(EXIT_SUCCESS)
        }
        // 必须在 WorkspaceModel 读取或写入用户恢复数据之前取得进程锁。
        do {
            // 默认锁与工作区会话固定使用同一产品目录。
            instanceLock = try ApplicationInstanceLock()
        } catch {
            // 锁竞争与 IO 故障都通过原生提示明确阻止本次启动。
            let alert = NSAlert()
            // 已运行实例提供直接结论，其他故障说明数据保护原因。
            if error as? ApplicationInstanceLockError == .alreadyRunning {
                // 第二实例不创建工作区，也不会触碰草稿或会话。
                alert.messageText = "Markdown Lite 已在运行"
                // 引导用户回到首实例继续编辑。
                alert.informativeText = "为避免多个进程同时写入恢复数据，本次启动已取消。请切换到已经打开的 Markdown Lite。"
            } else {
                // 无法确认互斥时按数据安全优先级关闭式失败。
                alert.messageText = "无法安全启动 Markdown Lite"
                // 计算固定恢复目录，只展示应用元数据位置而不暴露任何正文。
                let storageDirectory = WorkspaceSessionStore.defaultRootDirectory(
                    fileManager: .default
                )
                // 拼出可操作的失败说明，避免用户在不清楚原因时反复启动。
                let lockFailureDescription = """
                    无法取得恢复数据进程锁，本次启动已取消。请检查下列目录的权限、磁盘空间和锁文件类型后重试：

                    \(storageDirectory.path)

                    \(error.localizedDescription)
                    """
                // 提供目录、常见检查项和底层错误，用户可以修复后安全重试。
                alert.informativeText = lockFailureDescription
            }
            // 单按钮提示不提供绕过锁继续运行的危险入口。
            alert.addButton(withTitle: "退出")
            // 同步展示提示后才结束进程，确保用户能看到失败原因。
            alert.runModal()
            // 锁失败路径绝不创建 WorkspaceModel。
            exit(EXIT_FAILURE)
        }
        // 正常启动时创建并恢复工作区模型。
        _workspace = StateObject(wrappedValue: WorkspaceModel())
    }

    // 创建主窗口、注入模型并注册原生命令。
    var body: some Scene {
        WindowGroup {
            WorkspaceHostView(
                workspace: workspace,
                applicationDelegate: applicationDelegate
            )
        }
        .defaultSize(width: 1_080, height: 720)
        .commands {
            // 替换默认新建组，保证菜单与顶部按钮使用同一模型。
            CommandGroup(replacing: .newItem) {
                Button("新建", action: workspace.newDocument)
                    .keyboardShortcut("n", modifiers: .command)
                Button("打开…", action: workspace.openDocument)
                    .keyboardShortcut("o", modifiers: .command)
            }
            // 替换默认保存组并补齐另存为。
            CommandGroup(replacing: .saveItem) {
                Button("保存", action: workspace.saveDocument)
                    .keyboardShortcut("s", modifiers: .command)
                Button("另存为…", action: workspace.saveDocumentAs)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            // 发布相关能力进入独立导出菜单。
            CommandMenu("导出") {
                Button("导出 HTML…", action: workspace.exportHTML)
                Menu("复制公众号格式") {
                    ForEach(WechatExportTemplate.allCases) { template in
                        Button(template.displayName) {
                            workspace.copyWechatHTML(template: template)
                        }
                    }
                }
            }
            // 提供符合 macOS 习惯的关闭标签快捷键。
            CommandGroup(after: .saveItem) {
                Button("关闭标签", action: workspace.closeActiveDocument)
                    .keyboardShortcut("w", modifiers: .command)
            }
            // 提供浏览器式标签切换快捷键。
            CommandMenu("标签") {
                Button("下一个标签") {
                    workspace.activateAdjacentDocument()
                }
                .keyboardShortcut(.tab, modifiers: .control)
                Button("上一个标签") {
                    workspace.activateAdjacentDocument(reverse: true)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                // 分隔浏览与重排动作，避免用户把移动误认为激活。
                Divider()
                // 菜单和键盘共用模型层单步左移，VoiceOver 用户无需拖放。
                Button("向左移动当前标签") {
                    // 模型处理边界 no-op 和会话持久化。
                    workspace.moveActiveDocument(by: -1)
                }
                // Control-Shift-PageUp 与日常文本光标键分离。
                .keyboardShortcut(.pageUp, modifiers: [.control, .shift])
                // 首个标签已无左侧槽位，菜单直接显示不可用。
                .disabled(workspace.activeDocumentID == workspace.documents.first?.id)
                // 明确说明操作对象是当前标签。
                .accessibilityLabel("向左移动当前标签")
                // 对称右移使用正向单步偏移。
                Button("向右移动当前标签") {
                    // 模型保持活动 UUID 不变，只调整数组顺序。
                    workspace.moveActiveDocument(by: 1)
                }
                // Control-Shift-PageDown 与左移快捷键对称。
                .keyboardShortcut(.pageDown, modifiers: [.control, .shift])
                // 最后一个标签已无右侧槽位。
                .disabled(workspace.activeDocumentID == workspace.documents.last?.id)
                // 菜单项文案同时作为 VoiceOver 动作名。
                .accessibilityLabel("向右移动当前标签")
            }
            // 显式把快捷键转发给原生 NSTextView 查找器。
            CommandMenu("查找") {
                Button("查找…") {
                    NativeEditorActions.showFind(replacing: false)
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("查找并替换…") {
                    NativeEditorActions.showFind(replacing: true)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
            // 常用 Markdown 格式动作直接复用当前活动 NSTextView 的撤销栈。
            CommandMenu("格式") {
                Button("粗体") {
                    NativeEditorActions.applyFormatting(.bold, documentID: workspace.activeDocumentID)
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("斜体") {
                    NativeEditorActions.applyFormatting(.italic, documentID: workspace.activeDocumentID)
                }
                .keyboardShortcut("i", modifiers: .command)
                Button("行内代码") {
                    NativeEditorActions.applyFormatting(.inlineCode, documentID: workspace.activeDocumentID)
                }
                .keyboardShortcut("e", modifiers: .command)
                Button("链接") {
                    NativeEditorActions.applyFormatting(.link, documentID: workspace.activeDocumentID)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                // 当前行已有任务标记时执行单步可撤销状态切换。
                Button("切换任务状态") {
                    NativeEditorActions.applyFormatting(.toggleTask, documentID: workspace.activeDocumentID)
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                // 一到六级标题使用统一快捷键规则，避免增加格式工具栏噪声。
                ForEach(1...6, id: \.self) { level in
                    Button("\(level) 级标题") {
                        NativeEditorActions.applyFormatting(
                            .heading(level: level),
                            documentID: workspace.activeDocumentID
                        )
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(level))), modifiers: [.command, .option])
                }
            }
        }
        // 使用系统设置场景承载可持久化的编辑体验选项。
        Settings {
            EditorSettingsView()
        }
    }
}
