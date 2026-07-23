// 标记一次预览请求来自自动调度还是用户显式操作。
enum PreviewWorkTrigger: Equatable, Sendable {
    // 自动请求必须同时遵守活动标签和文档大小限制。
    case automatic
    // 手动刷新只放行当前一次请求，不改变后续自动请求的判断。
    case manualRefresh
}

// 说明自动预览为什么没有执行，并提供可直接展示的短文案。
enum PreviewWorkPauseReason: Equatable, Sendable {
    // 后台标签不应消耗解析和渲染资源。
    case backgroundTab
    // 活动文档超过自动预览允许的五 MiB 上限。
    case documentTooLarge

    // 返回不包含文件内容或路径的稳定中文状态。
    var displayMessage: String {
        // 每个暂停原因使用独立文案，便于界面准确解释当前策略。
        switch self {
        case .backgroundTab:
            // 后台标签无需提示用户执行额外操作。
            return "后台标签不自动预览"
        case .documentTooLarge:
            // 大文档提示用户仍可按需触发单次刷新。
            return "文档超过 5 MiB，自动预览已暂停，可手动刷新"
        }
    }
}

// 表示一次预览请求应继续执行还是以明确原因暂停。
enum PreviewWorkDecision: Equatable, Sendable {
    // 当前请求可以进入后续解析和渲染流程。
    case allowed
    // 当前请求不得启动，并携带可供界面展示的暂停原因。
    case paused(PreviewWorkPauseReason)

    // 提取暂停原因；允许执行时返回空值。
    var pauseReason: PreviewWorkPauseReason? {
        // 仅暂停结果包含原因。
        switch self {
        case .allowed:
            // 允许执行时没有需要展示的暂停状态。
            return nil
        case let .paused(reason):
            // 原样返回策略选择的具体暂停原因。
            return reason
        }
    }
}

// 集中执行无状态的预览工作判定，避免界面和模型产生不同边界。
struct PreviewWorkPolicy: Equatable, Sendable {
    // 自动预览最多处理五 MiB 的 UTF-8 内容字节。
    static let automaticPreviewByteLimit = 5 * 1_024 * 1_024

    // 根据标签状态、内容字节数和本次触发来源给出唯一决策。
    static func decision(
        isActiveDocument: Bool,
        documentByteCount: Int,
        trigger: PreviewWorkTrigger
    ) -> PreviewWorkDecision {
        // 用户显式刷新优先，仅放行这一次而不保存任何豁免状态。
        if trigger == .manualRefresh {
            // 手动刷新允许用户自行承担任意大小文档的单次预览成本。
            return .allowed
        }

        // 自动请求来自后台标签时直接停止，避免无效解析和渲染。
        if !isActiveDocument {
            // 返回独立原因，供调用方选择静默处理或展示状态。
            return .paused(.backgroundTab)
        }

        // 活动文档只有严格超过五 MiB 时才暂停，保证边界值仍可执行。
        if documentByteCount > automaticPreviewByteLimit {
            // 大文档保留手动刷新入口，不在自动路径启动工作。
            return .paused(.documentTooLarge)
        }

        // 活动且未超过上限的自动请求正常进入预览流程。
        return .allowed
    }
}
