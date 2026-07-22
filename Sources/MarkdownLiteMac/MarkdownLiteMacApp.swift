import AppKit
import SwiftUI

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
    // 单窗口共享同一份多标签工作区。
    @StateObject private var workspace: WorkspaceModel

    // 支持从同一个可执行文件运行完整自检。
    init() {
        // 命令行自检不启动窗口或读取用户草稿。
        if CommandLine.arguments.contains("--self-check") {
            runSelfCheck()
            exit(EXIT_SUCCESS)
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
