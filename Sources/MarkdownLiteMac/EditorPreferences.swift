import SwiftUI

// 集中定义稳定的偏好键和默认值，避免不同视图写入不一致的设置。
enum EditorPreferenceDefaults {
    // 编辑器字号默认兼顾中文阅读和紧凑布局。
    static let fontSize = 15.0
    // 默认行距保持原生文本视图的轻量排版。
    static let lineSpacing = 4.0
    // 语法高亮默认启用，大文档降级由编辑器内部负责。
    static let syntaxHighlightingEnabled = true
}

// 提供只包含日常写作必要选项的原生设置页。
struct EditorSettingsView: View {
    // 字号使用 AppStorage 跨启动持久化。
    @AppStorage("editorFontSize") private var fontSize = EditorPreferenceDefaults.fontSize
    // 行距与字号独立调整。
    @AppStorage("editorLineSpacing") private var lineSpacing = EditorPreferenceDefaults.lineSpacing
    // 用户可以完全关闭语法高亮以获得纯文本体验。
    @AppStorage("syntaxHighlightingEnabled") private var syntaxHighlightingEnabled =
        EditorPreferenceDefaults.syntaxHighlightingEnabled

    // 设置项保持单页、即时生效，不增加额外确认流程。
    var body: some View {
        Form {
            // 编辑器区域只暴露能明显影响写作体验的选项。
            Section("编辑器") {
                // 字号滑杆同时展示当前精确数值。
                HStack {
                    Text("字号")
                    Slider(value: $fontSize, in: 12...24, step: 1)
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                // 行距范围受限，避免产生不可读布局。
                HStack {
                    Text("行距")
                    Slider(value: $lineSpacing, in: 0...12, step: 1)
                    Text("\(Int(lineSpacing)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                // 关闭后只保留系统正文颜色和原生编辑行为。
                Toggle("Markdown 语法高亮", isOn: $syntaxHighlightingEnabled)
            }
        }
        // 固定紧凑宽度，适合 macOS 设置窗口。
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }
}
