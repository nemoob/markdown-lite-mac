import Foundation

// 汇总文档支撑层可明确展示给用户的错误。
enum DocumentSupportError: LocalizedError {
    // 非文件 URL 不能参与本地文档读写。
    case invalidFileURL(URL)
    // 系统无法无损识别文件编码时拒绝返回乱码。
    case unsupportedTextEncoding(URL)
    // 当前文本不能被目标编码无损表示时拒绝覆盖原文件。
    case textCannotBeEncoded(String.Encoding)
    // 极低概率的草稿键碰撞需要显式中止恢复。
    case draftIdentityMismatch
    // 更晚的保存或删除请求已经生效，旧写入必须明确报告被取代。
    case draftWriteSuperseded
    // 自检断言失败时保留具体步骤，便于定位回归。
    case selfCheckFailed(String)

    // 将底层约束转换为适合状态栏或警告框的说明。
    var errorDescription: String? {
        // 每种错误都给出可操作且不泄露正文的提示。
        switch self {
        case let .invalidFileURL(url):
            return "仅支持本地文件：\(url.absoluteString)"
        case let .unsupportedTextEncoding(url):
            return "无法无损识别文本编码：\(url.lastPathComponent)"
        case let .textCannotBeEncoded(encoding):
            return "当前内容无法用 \(String.localizedName(of: encoding)) 无损保存"
        case .draftIdentityMismatch:
            return "草稿标识与原文件不一致，已停止恢复以避免串稿"
        case .draftWriteSuperseded:
            return "草稿写入已被更新的保存或删除操作取代"
        case let .selfCheckFailed(step):
            return "DocumentSupport 自检失败：\(step)"
        }
    }
}

// 保存一次安全读取后的正文及其原始编码信息。
struct TextFileContent: Equatable {
    // 提供已经完整解码的 Swift 字符串。
    let text: String
    // 记录来源编码，后续可选择按原编码保存。
    let encoding: String.Encoding
    // 记录源文件是否携带字节序标记。
    let includesByteOrderMark: Bool
}

// 集中处理文本文件的无损读取和原子写入。
enum TextFileIO {
    // 按明确优先级读取文本，避免系统使用替换字符掩盖损坏数据。
    static func read(from url: URL) throws -> TextFileContent {
        // 非本地 URL 不交给 Data 读取，避免调用方误以为支持网络资源。
        guard url.isFileURL else { throw DocumentSupportError.invalidFileURL(url) }

        // 映射大文件可减少额外内存复制，同时不改变调用方语义。
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        // 所有编码识别集中复用同一解码实现。
        return try decode(data, from: url)
    }

    // 一次读取同时返回无损正文和严格匹配的外部变化快照。
    static func readWithSnapshot(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> (content: TextFileContent, snapshot: ExternalFileSnapshot) {
        // 非本地 URL 不进入文件指纹流程。
        guard url.isFileURL else { throw DocumentSupportError.invalidFileURL(url) }
        // 原始数据和摘要由支撑层在同一稳定读取中生成。
        let fileRead = try ExternalChangeSupport.readFile(at: url, fileManager: fileManager)
        // 使用同一份原始字节执行无损编码识别。
        let content = try decode(fileRead.data, from: url)
        // 一次返回正文和可信磁盘基线，消除两次读取之间的竞态。
        return (content, fileRead.snapshot)
    }

    // 将一份完整原始数据按明确优先级无损解码。
    private static func decode(_ data: Data, from url: URL) throws -> TextFileContent {
        // 空文件统一视为无 BOM 的 UTF-8 文档。
        guard !data.isEmpty else {
            return TextFileContent(text: "", encoding: .utf8, includesByteOrderMark: false)
        }

        // UTF-32 的 BOM 包含 UTF-16 前缀，因此必须优先匹配四字节标记。
        let byteOrderMarkedEncodings: [(bytes: [UInt8], encoding: String.Encoding)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
        ]

        // 已声明字节序的文件按对应编码严格解码。
        for candidate in byteOrderMarkedEncodings where data.starts(with: candidate.bytes) {
            // 解码前去掉 BOM，避免正文首字符残留零宽标记。
            let payload = Data(data.dropFirst(candidate.bytes.count))
            // 声明编码与正文不匹配时停止，不能偷偷改用其他编码。
            guard let text = String(data: payload, encoding: candidate.encoding) else {
                throw DocumentSupportError.unsupportedTextEncoding(url)
            }
            // 返回正文并保留原始编码和 BOM 信息。
            return TextFileContent(
                text: text,
                encoding: candidate.encoding,
                includesByteOrderMark: true
            )
        }

        // 无 BOM 文档优先尝试严格 UTF-8，覆盖绝大多数 Markdown 文件。
        if let text = String(data: data, encoding: .utf8) {
            // UTF-8 成功时不再触发成本更高且可能模糊的自动检测。
            return TextFileContent(text: text, encoding: .utf8, includesByteOrderMark: false)
        }

        // 系统检测器补充 UTF-16、Shift-JIS、GB 系列和常见西文编码。
        var converted: NSString?
        // 明确要求检测器回报是否发生了有损替换。
        var usedLossyConversion = ObjCBool(false)
        // 不添加语言偏好，让系统根据字节内容选择最可信编码。
        let detectedRawValue = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &converted,
            usedLossyConversion: &usedLossyConversion
        )

        // 只有无损且确实得到正文时才接受系统检测结果。
        guard
            !usedLossyConversion.boolValue,
            detectedRawValue != 0,
            let text = converted as String?
        else {
            throw DocumentSupportError.unsupportedTextEncoding(url)
        }

        // 原始值转换为 Foundation 编码，便于后续原编码保存。
        let encoding = String.Encoding(rawValue: detectedRawValue)
        // 返回无损检测得到的正文和编码。
        return TextFileContent(text: text, encoding: encoding, includesByteOrderMark: false)
    }

    // 将完整正文一次性原子替换到目标文件。
    static func save(
        _ text: String,
        to url: URL,
        encoding: String.Encoding = .utf8,
        includeByteOrderMark: Bool = false
    ) throws {
        // 非本地 URL 不允许进入文件系统写入流程。
        guard url.isFileURL else { throw DocumentSupportError.invalidFileURL(url) }
        // 先在内存完整编码，失败时不触碰已有文件。
        let data = try encodedData(
            text,
            encoding: encoding,
            includeByteOrderMark: includeByteOrderMark
        )
        // .atomic 会先在同目录写临时文件，再一次性替换目标，避免留下半个文档。
        try data.write(to: url, options: [.atomic])
    }

    // 原子保存并返回与实际写入字节严格一致的新磁盘基线。
    static func saveWithSnapshot(
        _ text: String,
        to url: URL,
        encoding: String.Encoding = .utf8,
        includeByteOrderMark: Bool = false,
        fileManager: FileManager = .default
    ) throws -> ExternalFileSnapshot {
        // 非本地 URL 不允许进入文件系统写入流程。
        guard url.isFileURL else { throw DocumentSupportError.invalidFileURL(url) }
        // 先在内存完整编码，失败时不触碰已有文件。
        let data = try encodedData(
            text,
            encoding: encoding,
            includeByteOrderMark: includeByteOrderMark
        )
        // 原子替换保持原有半写保护能力。
        try data.write(to: url, options: [.atomic])
        // 摘要直接由实际交给原子写入的数据生成，外部竞态会在下次检查被识别。
        return ExternalChangeSupport.snapshotForKnownData(data, at: url, fileManager: fileManager)
    }

    // 将正文按目标编码和 BOM 策略转换为最终落盘字节。
    private static func encodedData(
        _ text: String,
        encoding: String.Encoding,
        includeByteOrderMark: Bool
    ) throws -> Data {
        // 禁止有损转换，避免打开旧编码后保存时静默丢字。
        guard var data = text.data(using: encoding, allowLossyConversion: false) else {
            throw DocumentSupportError.textCannotBeEncoded(encoding)
        }

        // UTF-16 和 UTF-32 通用编码会由 Foundation 自动写入 BOM。
        if !includeByteOrderMark, encodingWritesByteOrderMarkByDefault(encoding) {
            // 仅去掉编码器自动生成的第一段 BOM，不触碰正文中的真实零宽字符。
            data = removingLeadingByteOrderMark(from: data)
        }

        // 显式要求 BOM 时为固定字节序编码补上对应标记。
        if includeByteOrderMark, let marker = byteOrderMark(for: encoding), !data.starts(with: marker) {
            // 先写 BOM 再追加正文编码字节。
            var markedData = Data(marker)
            // 保持正文完整顺序。
            markedData.append(data)
            // 使用带标记的数据执行后续原子写入。
            data = markedData
        }
        // 返回与最终文件完全一致的字节序列。
        return data
    }

    // 返回固定编码对应的标准字节序标记。
    private static func byteOrderMark(for encoding: String.Encoding) -> [UInt8]? {
        // 通过 rawValue 比较可兼容 Foundation 的编码别名。
        switch encoding.rawValue {
        case String.Encoding.utf8.rawValue:
            return [0xEF, 0xBB, 0xBF]
        case String.Encoding.utf16LittleEndian.rawValue:
            return [0xFF, 0xFE]
        case String.Encoding.utf16BigEndian.rawValue:
            return [0xFE, 0xFF]
        case String.Encoding.utf32LittleEndian.rawValue:
            return [0xFF, 0xFE, 0x00, 0x00]
        case String.Encoding.utf32BigEndian.rawValue:
            return [0x00, 0x00, 0xFE, 0xFF]
        default:
            return nil
        }
    }

    // 判断 Foundation 是否会为通用 Unicode 编码主动添加 BOM。
    private static func encodingWritesByteOrderMarkByDefault(_ encoding: String.Encoding) -> Bool {
        // 固定大小端编码不会自动加标记，只有通用 UTF-16/32 需要清理。
        encoding.rawValue == String.Encoding.utf16.rawValue || encoding.rawValue == String.Encoding.utf32.rawValue
    }

    // 移除通用 Unicode 编码器自动生成的一个 BOM。
    private static func removingLeadingByteOrderMark(from data: Data) -> Data {
        // 四字节 BOM 必须先判断，避免被两字节前缀提前截断。
        let knownMarkers: [[UInt8]] = [
            [0x00, 0x00, 0xFE, 0xFF],
            [0xFF, 0xFE, 0x00, 0x00],
            [0xFE, 0xFF],
            [0xFF, 0xFE],
        ]
        // 找到实际前缀后只移除一次。
        for marker in knownMarkers where data.starts(with: marker) {
            return Data(data.dropFirst(marker.count))
        }
        // 编码器未生成 BOM 时保持原数据不变。
        return data
    }
}

// 保存一份可独立恢复的文档草稿。
struct DocumentDraft: Codable, Equatable, Sendable {
    // 草稿正文与编辑器当前内容完全一致。
    let text: String
    // 已命名文档记录规范化 URL，未命名草稿保持 nil。
    let fileURL: URL?
    // 未命名文档用标签 UUID 区分，旧版单草稿没有此字段时自动解码为 nil。
    let untitledID: UUID?
    // 记录草稿捕获时最后可信磁盘摘要；旧草稿和未命名草稿没有该字段时为 nil。
    let baselineContentDigest: String?
    // Codable 直接保存 Foundation 编码原始值。
    private let encodingRawValue: UInt
    // 保留来源文件 BOM 策略，防止恢复后改变保存格式。
    let includesByteOrderMark: Bool
    // 时间用于 UI 判断草稿是否比磁盘版本更新。
    let updatedAt: Date

    // 将持久化原始值恢复为 Foundation 编码。
    var encoding: String.Encoding {
        // 所有 NSStringEncoding 原始值都可包装成 String.Encoding。
        String.Encoding(rawValue: encodingRawValue)
    }

    // 由存储层创建规范化草稿，避免调用方写入不稳定 URL。
    init(
        text: String,
        fileURL: URL?,
        untitledID: UUID? = nil,
        baselineContentDigest: String? = nil,
        encoding: String.Encoding,
        includesByteOrderMark: Bool,
        updatedAt: Date
    ) {
        // 保存当前完整正文。
        self.text = text
        // 保存已经规范化的原文件地址。
        self.fileURL = fileURL
        // 已命名文档只按路径识别，未命名文档才保留标签 UUID。
        self.untitledID = fileURL == nil ? untitledID : nil
        // 只有已命名文档可能携带可信磁盘基线，nil 保持旧 JSON 向后兼容。
        self.baselineContentDigest = fileURL == nil ? nil : baselineContentDigest
        // 将编码转换为可序列化原始值。
        encodingRawValue = encoding.rawValue
        // 保存 BOM 策略。
        self.includesByteOrderMark = includesByteOrderMark
        // 保存草稿写入时间。
        self.updatedAt = updatedAt
    }
}

// 保存一个最近打开文档及其最后访问时间。
struct RecentDocument: Codable, Equatable, Identifiable {
    // 规范化 URL 同时作为菜单去重标识。
    let fileURL: URL
    // 最近时间用于保持菜单顺序。
    let lastOpenedAt: Date

    // SwiftUI 菜单可直接使用稳定 URL 字符串作为 ID。
    var id: String {
        // fileURL 已由存储层规范化。
        fileURL.absoluteString
    }
}

// 管理 Application Support 下的独立草稿和最近文件索引。
final class DocumentSupportStore: @unchecked Sendable {
    // 固定产品目录，调试运行和正式 App 使用同一份数据。
    private static let applicationFolderName = "MarkdownLiteMac"
    // 草稿使用独立子目录，避免与后续主题或设置混放。
    private static let draftsFolderName = "Drafts"
    // 最近文件使用单个小型索引，便于原子更新顺序。
    private static let recentsFilename = "RecentDocuments.json"

    // 保留注入的文件管理器，便于临时目录自检。
    private let fileManager: FileManager
    // 保存全部支撑数据的根目录。
    private let rootDirectory: URL
    // 草稿写入和删除共享同一把锁，防止后台旧任务覆盖更新结果。
    private let draftMutationLock = NSLock()
    // 进程内单调递增序号不受系统时间回拨影响。
    private var nextDraftMutationGeneration: UInt64 = 0
    // 每个草稿路径记录已经生效的最新操作序号。
    private var latestAppliedDraftGeneration: [String: UInt64] = [:]

    // 默认使用用户 Application Support，也允许测试注入隔离目录。
    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        // 缓存文件管理器，所有后续 IO 使用同一实例。
        self.fileManager = fileManager
        // 优先使用调用方目录，否则生成稳定的产品目录。
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
    }

    // 保存一次已分配单调序号、但尚未执行磁盘写入的草稿请求。
    struct DraftWriteReservation: Sendable {
        // 草稿正文和 Date 元数据保持调用时快照。
        fileprivate let draft: DocumentDraft
        // 目标地址已经按文档身份规范化。
        fileprivate let destinationURL: URL
        // 进程内单调序号是唯一正确性顺序依据。
        fileprivate let generation: UInt64
    }

    // 将正文原子保存为当前文档的独立草稿。
    @discardableResult
    func saveDraft(
        _ text: String,
        for fileURL: URL?,
        untitledID: UUID? = nil,
        encoding: String.Encoding = .utf8,
        includesByteOrderMark: Bool = false,
        baselineContentDigest: String? = nil,
        updatedAt: Date = Date()
    ) throws -> DocumentDraft {
        // 调用时立即分配单调序号，系统时间只写入草稿元数据。
        let reservation = try reserveDraftWrite(
            text,
            for: fileURL,
            untitledID: untitledID,
            encoding: encoding,
            includesByteOrderMark: includesByteOrderMark,
            baselineContentDigest: baselineContentDigest,
            updatedAt: updatedAt
        )
        // 同步调用必须准确报告实际提交或被更新请求取代。
        return try commitDraftWrite(reservation)
    }

    // 为草稿写入预留一个不受系统时间影响的进程内顺序号。
    func reserveDraftWrite(
        _ text: String,
        for fileURL: URL?,
        untitledID: UUID? = nil,
        encoding: String.Encoding = .utf8,
        includesByteOrderMark: Bool = false,
        baselineContentDigest: String? = nil,
        updatedAt: Date = Date()
    ) throws -> DraftWriteReservation {
        // 规范化已命名文件 URL，确保同一路径只产生一个草稿。
        let normalizedURL = try normalizedOptionalFileURL(fileURL)
        // 将完整恢复信息封装进单个原子 JSON 文件。
        let draft = DocumentDraft(
            text: text,
            fileURL: normalizedURL,
            untitledID: normalizedURL == nil ? untitledID : nil,
            baselineContentDigest: baselineContentDigest,
            encoding: encoding,
            includesByteOrderMark: includesByteOrderMark,
            updatedAt: updatedAt
        )
        // 提前计算唯一草稿文件地址作为进程内顺序键。
        let destination = draftFileURL(for: normalizedURL, untitledID: untitledID)
        // 序号分配与删除操作使用同一把锁保持全序。
        draftMutationLock.lock()
        // 分配下一个严格递增的进程内序号。
        let generation = nextDraftGenerationWhileLocked()
        // 分配完成后立即释放锁，正文编码将在提交阶段执行。
        draftMutationLock.unlock()
        // 返回可由后台任意时刻提交的不可变请求。
        return DraftWriteReservation(
            draft: draft,
            destinationURL: destination,
            generation: generation
        )
    }

    // 提交一个已预留顺序号的草稿写入。
    @discardableResult
    func commitDraftWrite(_ reservation: DraftWriteReservation) throws -> DocumentDraft {
        // 串行化检查、编码、写入和删除，确保完成顺序不会反转结果。
        draftMutationLock.lock()
        // 任意退出路径都必须释放锁。
        defer { draftMutationLock.unlock() }
        // 更晚操作已经生效时，旧请求必须明确失败而非伪报保存成功。
        if let latestGeneration = latestAppliedDraftGeneration[reservation.destinationURL.path],
            latestGeneration >= reservation.generation
        {
            // 调用方可区分取消任务和真实写入成功。
            throw DocumentSupportError.draftWriteSuperseded
        }
        // 先推进生效序号；即使本次 IO 失败，也不能让更旧正文随后落盘。
        latestAppliedDraftGeneration[reservation.destinationURL.path] = reservation.generation
        // 首次保存前创建草稿目录。
        try ensureDirectoryExists(draftsDirectory)
        // 每次调用使用独立编码器，避免后台草稿与最近文件共享可变实例。
        let encoder = Self.makeEncoder()
        // 编码在内存完成，失败时不会碰触已有草稿。
        let data = try encoder.encode(reservation.draft)
        // 原子替换确保崩溃时保留旧草稿或新草稿之一。
        try data.write(
            to: reservation.destinationURL,
            options: [.atomic]
        )
        // 返回已落盘记录，调用方可同步更新时间。
        return reservation.draft
    }

    // 在后台执行完整 JSON 编码和原子草稿写入。
    @discardableResult
    func saveDraftInBackground(
        _ text: String,
        for fileURL: URL?,
        untitledID: UUID? = nil,
        encoding: String.Encoding = .utf8,
        includesByteOrderMark: Bool = false,
        baselineContentDigest: String? = nil,
        updatedAt: Date = Date()
    ) async throws -> DocumentDraft {
        // 保存或重载已取消尚未开始的旧任务时不能再预留新序号。
        try Task.checkCancellation()
        // 在离开调用执行器前预留顺序，避免后台完成先后影响最终内容。
        let reservation = try reserveDraftWrite(
            text,
            for: fileURL,
            untitledID: untitledID,
            encoding: encoding,
            includesByteOrderMark: includesByteOrderMark,
            baselineContentDigest: baselineContentDigest,
            updatedAt: updatedAt
        )
        // 预留后若任务已被取消，不启动无意义磁盘工作。
        try Task.checkCancellation()
        // detached 任务确保完整正文编码和磁盘 IO 不占用主 actor。
        return try await Task.detached(priority: .utility) { [self] in
            // 后台提交复用同一单调序号屏障。
            try commitDraftWrite(reservation)
        }.value
    }

    // 恢复指定文件或未命名文档自己的草稿。
    func loadDraft(for fileURL: URL?, untitledID: UUID? = nil) throws -> DocumentDraft? {
        // 使用与保存完全相同的 URL 规范化规则。
        let normalizedURL = try normalizedOptionalFileURL(fileURL)
        // 根据稳定键定位唯一草稿文件。
        let url = draftFileURL(for: normalizedURL, untitledID: untitledID)
        // 没有草稿属于正常状态，不转成错误。
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        // 一次读取完整 JSON，避免部分字段来自不同版本。
        let data = try Data(contentsOf: url)
        // 每次调用使用独立解码器，允许与后台写入并发执行。
        let decoder = Self.makeDecoder()
        // 解码完整恢复记录。
        let draft = try decoder.decode(DocumentDraft.self, from: data)
        // 对比记录内 URL，防止哈希碰撞造成跨文档恢复。
        let expectedUntitledID = normalizedURL == nil ? untitledID : nil
        // 文件路径和未命名标签 UUID 都必须匹配，防止跨标签串稿。
        guard draft.fileURL == normalizedURL, draft.untitledID == expectedUntitledID else {
            throw DocumentSupportError.draftIdentityMismatch
        }
        // 返回已经验证身份的草稿。
        return draft
    }

    // 删除保存成功后不再需要的指定草稿。
    func removeDraft(for fileURL: URL?, untitledID: UUID? = nil) throws {
        // 规范化 URL 以命中保存时的稳定键。
        let normalizedURL = try normalizedOptionalFileURL(fileURL)
        // 计算草稿文件地址。
        let url = draftFileURL(for: normalizedURL, untitledID: untitledID)
        // 删除和后台写入必须经过同一顺序屏障。
        draftMutationLock.lock()
        // 任意退出路径都必须释放锁。
        defer { draftMutationLock.unlock() }
        // 删除分配更晚单调序号，不依赖可回拨的墙上时钟。
        let removalGeneration = nextDraftGenerationWhileLocked()
        // 即使文件已不存在也推进生效序号，阻止已排队旧任务重新创建。
        latestAppliedDraftGeneration[url.path] = removalGeneration
        // 草稿本就不存在时保持幂等。
        guard fileManager.fileExists(atPath: url.path) else { return }
        // 只删除精确草稿文件，不递归触碰其他文档。
        try fileManager.removeItem(at: url)
    }

    // 记录一次成功打开或保存的本地文件。
    func recordRecentDocument(
        _ fileURL: URL,
        openedAt: Date = Date(),
        limit: Int = 10
    ) throws {
        // 最近文件只接受规范化本地 URL。
        let normalizedURL = try normalizedFileURL(fileURL)
        // 先读取现有顺序；首次使用得到空数组。
        var documents = try loadRecentDocuments()
        // 去掉旧位置，保证同一文件只出现一次。
        documents.removeAll { $0.fileURL == normalizedURL }
        // 最新访问记录始终放在菜单最前面。
        documents.insert(RecentDocument(fileURL: normalizedURL, lastOpenedAt: openedAt), at: 0)
        // 负数按零处理，避免数组范围错误。
        let safeLimit = max(0, limit)
        // 只保留调用方需要的最大数量。
        if documents.count > safeLimit {
            documents.removeSubrange(safeLimit..<documents.count)
        }
        // 首次记录前创建根目录。
        try ensureDirectoryExists(rootDirectory)
        // 每次调用使用独立编码器，避免与后台草稿编码竞争。
        let encoder = Self.makeEncoder()
        // 在内存编码完整新索引。
        let data = try encoder.encode(documents)
        // 原子替换避免中断后丢失整个最近文件列表。
        try data.write(to: recentsFileURL, options: [.atomic])
    }

    // 按最近访问顺序返回记录。
    func recentDocuments(limit: Int = 10) throws -> [RecentDocument] {
        // 先完整读取并验证持久化索引。
        let documents = try loadRecentDocuments()
        // 负数按零处理，保持 API 幂等可预测。
        let safeLimit = max(0, limit)
        // 返回前缀而不修改磁盘记录。
        return Array(documents.prefix(safeLimit))
    }

    // 为文件 URL 生成跨启动稳定的草稿键；nil 专门表示未命名草稿。
    func draftKey(for fileURL: URL?, untitledID: UUID? = nil) throws -> String {
        // 未命名草稿使用独立常量，不可能与 file- 前缀碰撞。
        guard let fileURL else {
            // v0.2 标签使用 UUID 独立存储，nil 保留旧版单草稿兼容键。
            return untitledID.map { "untitled-\($0.uuidString.lowercased())" } ?? "untitled"
        }
        // 规范化路径避免 ./、.. 或重复斜杠产生多份草稿。
        let normalizedURL = try normalizedFileURL(fileURL)
        // 以完整 URL 字节计算确定性 64 位 FNV-1a。
        let hash = Self.fnv1a64(normalizedURL.absoluteString.utf8)
        // 固定十六进制宽度使文件名短小且排序稳定。
        return String(format: "file-%016llx", hash)
    }

    // 返回系统默认的产品支撑目录，不在初始化阶段主动写磁盘。
    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        // 使用系统 API 获取用户级 Application Support。
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        // 极端环境取不到目录时安全回退到用户 Library 下的标准位置。
        let baseDirectory =
            applicationSupport
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        // 固定产品名保证调试包和正式包共享草稿。
        return baseDirectory.appendingPathComponent(applicationFolderName, isDirectory: true)
    }

    // 计算草稿目录。
    private var draftsDirectory: URL {
        // 所有草稿集中在根目录的 Drafts 子目录。
        rootDirectory.appendingPathComponent(Self.draftsFolderName, isDirectory: true)
    }

    // 计算最近文件索引地址。
    private var recentsFileURL: URL {
        // 单文件索引足以覆盖最小版本的最近文件菜单。
        rootDirectory.appendingPathComponent(Self.recentsFilename, isDirectory: false)
    }

    // 计算某个已规范化文档的草稿地址。
    private func draftFileURL(for normalizedURL: URL?, untitledID: UUID?) -> URL {
        // normalizedURL 已经验证，因此这里生成键不会失败。
        let key = try? draftKey(for: normalizedURL, untitledID: untitledID)
        // 理论异常回退只会用于 nil，保持未命名草稿可恢复。
        let safeKey = key ?? "untitled"
        // 每个文档对应一个独立 JSON 文件。
        return draftsDirectory.appendingPathComponent("\(safeKey).json", isDirectory: false)
    }

    // 读取最近文件索引，不存在时返回空列表。
    private func loadRecentDocuments() throws -> [RecentDocument] {
        // 首次启动没有索引属于正常状态。
        guard fileManager.fileExists(atPath: recentsFileURL.path) else { return [] }
        // 读取完整索引。
        let data = try Data(contentsOf: recentsFileURL)
        // 每次调用使用独立解码器，避免共享可变 Foundation 对象。
        let decoder = Self.makeDecoder()
        // 解码失败显式抛出，避免用空列表静默覆盖可修复数据。
        return try decoder.decode([RecentDocument].self, from: data)
    }

    // 创建使用统一 ISO 8601 日期策略的独立编码器。
    private static func makeEncoder() -> JSONEncoder {
        // 新实例不与其他线程共享可变状态。
        let encoder = JSONEncoder()
        // 可读稳定时间格式便于手工排查草稿。
        encoder.dateEncodingStrategy = .iso8601
        // 返回本次调用专用编码器。
        return encoder
    }

    // 创建与编码器日期策略匹配的独立解码器。
    private static func makeDecoder() -> JSONDecoder {
        // 新实例不与其他线程共享可变状态。
        let decoder = JSONDecoder()
        // 使用相同 ISO 8601 策略恢复记录。
        decoder.dateDecodingStrategy = .iso8601
        // 返回本次调用专用解码器。
        return decoder
    }

    // 在持有 draftMutationLock 时分配下一个严格递增序号。
    private func nextDraftGenerationWhileLocked() -> UInt64 {
        // 正常应用生命周期不可能耗尽 UInt64，普通加法保留溢出保护。
        nextDraftMutationGeneration += 1
        // 返回当前请求的唯一顺序号。
        return nextDraftMutationGeneration
    }

    // 将可选文件 URL 转换为稳定形式。
    private func normalizedOptionalFileURL(_ fileURL: URL?) throws -> URL? {
        // nil 保持为独立未命名草稿身份。
        guard let fileURL else { return nil }
        // 已命名文档复用严格规范化逻辑。
        return try normalizedFileURL(fileURL)
    }

    // 验证并规范化一个本地文件 URL。
    private func normalizedFileURL(_ fileURL: URL) throws -> URL {
        // 网络 URL 和自定义 scheme 不进入本地文档索引。
        guard fileURL.isFileURL else { throw DocumentSupportError.invalidFileURL(fileURL) }
        // standardizedFileURL 消除相对段，同时不因符号链接目标变化而改变草稿键。
        return fileURL.standardizedFileURL
    }

    // 确保存储目录存在且确实是目录。
    private func ensureDirectoryExists(_ url: URL) throws {
        // 获取已存在路径的类型。
        var isDirectory = ObjCBool(false)
        // 已有目录无需再次触碰文件系统。
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        // 同名普通文件会由 createDirectory 抛出明确错误。
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // 使用固定参数计算稳定且足够低碰撞率的文件名哈希。
    private static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        // FNV-1a 的标准 64 位偏移基数。
        var hash: UInt64 = 14_695_981_039_346_656_037
        // 逐字节更新，结果不受 Swift 进程随机哈希种子影响。
        for byte in bytes {
            // 先混入当前字节。
            hash ^= UInt64(byte)
            // 溢出乘法符合 FNV-1a 定义。
            hash = hash &* 1_099_511_628_211
        }
        // 返回确定性 64 位结果。
        return hash
    }
}

// 记录最后一次成功打开或保存的完整快照。
struct DocumentSnapshot: Equatable {
    // 保存时的完整正文用于关闭前精确核对撤销结果。
    let text: String
    // 保存目标用于区分另存为后的新文档身份。
    let fileURL: URL?
    // 保存编码用于下一次原地写回。
    let encoding: String.Encoding
    // 保存 BOM 策略避免改写格式。
    let includesByteOrderMark: Bool
    // 保存时间可直接用于状态栏或恢复判断。
    let savedAt: Date
}

// 以常量时间维护常用 dirty 状态，并保留可精确核对的保存快照。
struct DocumentSaveState {
    // 对外只读暴露最近成功保存快照。
    private(set) var savedSnapshot: DocumentSnapshot
    // 输入事件只需把标记置为 true，不必每次比较整篇大文档。
    private(set) var isDirty: Bool

    // 建立一个已知干净的初始或打开状态。
    init(
        text: String,
        fileURL: URL?,
        encoding: String.Encoding = .utf8,
        includesByteOrderMark: Bool = false,
        savedAt: Date = Date()
    ) {
        // 记录初始完整快照。
        savedSnapshot = DocumentSnapshot(
            text: text,
            fileURL: fileURL?.standardizedFileURL,
            encoding: encoding,
            includesByteOrderMark: includesByteOrderMark,
            savedAt: savedAt
        )
        // 初始化内容由调用方声明为干净基线。
        isDirty = false
    }

    // 输入变化时以 O(1) 成本标记未保存。
    mutating func markChanged() {
        // 重复标记保持幂等。
        isDirty = true
    }

    // 成功保存或打开后刷新干净快照。
    mutating func markSaved(
        text: String,
        fileURL: URL?,
        encoding: String.Encoding = .utf8,
        includesByteOrderMark: Bool = false,
        savedAt: Date = Date()
    ) {
        // 用本次确实落盘的内容替换旧快照。
        savedSnapshot = DocumentSnapshot(
            text: text,
            fileURL: fileURL?.standardizedFileURL,
            encoding: encoding,
            includesByteOrderMark: includesByteOrderMark,
            savedAt: savedAt
        )
        // 只有成功调用此方法才清除 dirty 标记。
        isDirty = false
    }

    // 在关闭或撤销后按完整快照精确重新计算 dirty 状态。
    @discardableResult
    mutating func reconcile(text: String, fileURL: URL?) -> Bool {
        // URL 与正文都回到保存快照时才视为干净。
        isDirty = savedSnapshot.text != text || savedSnapshot.fileURL != fileURL?.standardizedFileURL
        // 返回新状态，方便调用方直接决定是否弹窗。
        return isDirty
    }
}

// 提供无需 UI、可在临时目录直接运行的持久化回归检查。
enum DocumentSupportSelfCheck {
    // 汇总成功步骤，方便命令行和调试菜单展示。
    struct Report: Equatable, CustomStringConvertible {
        // 按执行顺序记录通过的检查项。
        let passedChecks: [String]

        // 输出紧凑的人类可读结果。
        var description: String {
            // 包含数量和名称，失败排查时无需翻源码。
            "DocumentSupportSelfCheck 通过 \(passedChecks.count) 项：\(passedChecks.joined(separator: "、"))"
        }
    }

    // 在独立临时目录验证读写、草稿、最近文件和 dirty 快照。
    static func run(fileManager: FileManager = .default) throws -> Report {
        // 每次运行使用唯一目录，避免并行自检互相覆盖。
        let rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MarkdownLiteMac-SelfCheck-\(UUID().uuidString)", isDirectory: true)
        // 自检结束后只清理由本次创建的精确临时目录。
        defer { try? fileManager.removeItem(at: rootDirectory) }
        // 创建注入临时根目录的存储层。
        let store = DocumentSupportStore(rootDirectory: rootDirectory, fileManager: fileManager)
        // 收集已经通过的步骤。
        var passedChecks: [String] = []

        // 创建一个真实 Markdown 目标文件地址。
        let markdownURL = rootDirectory.appendingPathComponent("示例.md", isDirectory: false)
        // 文件写入前先建立父目录。
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // 使用多语言和 emoji 验证 UTF-8 无损原子保存。
        let originalText = "# 自检\n\n中文、English 与 emoji 🚀\n"
        // 执行正式文件原子保存路径。
        try TextFileIO.save(originalText, to: markdownURL)
        // 从磁盘重新读取而非复用内存正文。
        let loadedUTF8 = try TextFileIO.read(from: markdownURL)
        // 正文、编码和 BOM 策略必须完全一致。
        try require(
            loadedUTF8
                == TextFileContent(
                    text: originalText,
                    encoding: .utf8,
                    includesByteOrderMark: false
                ),
            "UTF-8 原子读写"
        )
        // 标记基础文件读写通过。
        passedChecks.append("UTF-8 原子读写")

        // 创建第二个文件验证带 BOM 的 Unicode 恢复。
        let utf16URL = rootDirectory.appendingPathComponent("UTF16.md", isDirectory: false)
        // 按固定小端编码并显式保留 BOM 保存。
        try TextFileIO.save(
            originalText,
            to: utf16URL,
            encoding: .utf16LittleEndian,
            includeByteOrderMark: true
        )
        // 重新读取并走 BOM 优先分支。
        let loadedUTF16 = try TextFileIO.read(from: utf16URL)
        // 验证正文和格式元信息都被保留。
        try require(
            loadedUTF16.text == originalText && loadedUTF16.encoding == .utf16LittleEndian
                && loadedUTF16.includesByteOrderMark,
            "UTF-16 BOM 读取"
        )
        // 标记常见 Unicode 编码通过。
        passedChecks.append("UTF-16 BOM 读取")

        // 为真实文件保存独立草稿。
        try store.saveDraft("文件草稿", for: markdownURL, updatedAt: Date(timeIntervalSince1970: 10))
        // 同时保存未命名草稿，验证两个身份不会覆盖。
        try store.saveDraft("未命名草稿", for: nil, updatedAt: Date(timeIntervalSince1970: 20))
        // 从磁盘分别恢复两份内容。
        let namedDraft = try store.loadDraft(for: markdownURL)
        let untitledDraft = try store.loadDraft(for: nil)
        // 两份草稿必须命中自己的正文和 URL。
        try require(
            namedDraft?.text == "文件草稿" && namedDraft?.fileURL == markdownURL.standardizedFileURL
                && untitledDraft?.text == "未命名草稿" && untitledDraft?.fileURL == nil,
            "独立草稿恢复"
        )
        // 标记核心崩溃恢复路径通过。
        passedChecks.append("独立草稿恢复")

        // 为两个未命名标签生成稳定且互不相同的身份。
        let firstUntitledID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondUntitledID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        // 分别保存两份未命名标签正文。
        try store.saveDraft("标签一", for: nil, untitledID: firstUntitledID)
        try store.saveDraft("标签二", for: nil, untitledID: secondUntitledID)
        // 分别读取两份标签草稿，验证不会共用旧版 untitled 键。
        let firstUntitledDraft = try store.loadDraft(for: nil, untitledID: firstUntitledID)
        let secondUntitledDraft = try store.loadDraft(for: nil, untitledID: secondUntitledID)
        // UUID 与正文都必须完整对应。
        try require(
            firstUntitledDraft?.text == "标签一" && firstUntitledDraft?.untitledID == firstUntitledID
                && secondUntitledDraft?.text == "标签二" && secondUntitledDraft?.untitledID == secondUntitledID,
            "多未命名草稿隔离"
        )
        // 标记 v0.2 多标签草稿隔离通过。
        passedChecks.append("多未命名草稿隔离")

        // 先记录当前文件，再重复记录以验证去重和顺序更新。
        try store.recordRecentDocument(markdownURL, openedAt: Date(timeIntervalSince1970: 30))
        try store.recordRecentDocument(utf16URL, openedAt: Date(timeIntervalSince1970: 40))
        try store.recordRecentDocument(markdownURL, openedAt: Date(timeIntervalSince1970: 50))
        // 读取持久化后的最近列表。
        let recents = try store.recentDocuments()
        // 最新文件必须置顶且重复项只保留一个。
        try require(
            recents.map(\.fileURL) == [markdownURL.standardizedFileURL, utf16URL.standardizedFileURL],
            "最近文件去重排序"
        )
        // 标记最近文件索引通过。
        passedChecks.append("最近文件去重排序")

        // 以刚保存内容建立干净基线。
        var saveState = DocumentSaveState(text: originalText, fileURL: markdownURL)
        // 模拟一次输入事件。
        saveState.markChanged()
        // dirty 应立即变为 true。
        try require(saveState.isDirty, "dirty 标记")
        // 模拟撤销回保存正文并精确核对。
        let reconciledDirty = saveState.reconcile(text: originalText, fileURL: markdownURL)
        // 完全回到快照时 dirty 必须清除。
        try require(!reconciledDirty && !saveState.isDirty, "保存快照核对")
        // 标记 dirty 和快照流程通过。
        passedChecks.append("dirty 与保存快照")

        // 返回所有通过项供调用方展示。
        return Report(passedChecks: passedChecks)
    }

    // 将自检布尔断言转换为带步骤信息的错误。
    private static func require(_ condition: @autoclosure () -> Bool, _ step: String) throws {
        // 条件满足时直接继续下一项。
        guard condition() else { throw DocumentSupportError.selfCheckFailed(step) }
    }
}
