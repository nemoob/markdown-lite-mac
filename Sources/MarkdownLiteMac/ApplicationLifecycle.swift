import AppKit

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
