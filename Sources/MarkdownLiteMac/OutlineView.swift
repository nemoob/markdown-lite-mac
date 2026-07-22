import SwiftUI

// 在预览侧展示紧凑、可点击的标题大纲。
struct MarkdownOutlineView: View {
    // 当前活动文档的标题列表。
    let items: [MarkdownOutlineItem]
    // 当前光标所属章节 ID；未接线时保持 nil 兼容旧界面。
    let currentItemID: Int?
    // 选择标题后由上层同步编辑器与预览位置。
    let onSelect: (MarkdownOutlineItem) -> Void

    // 保持旧调用只传 items 和 onSelect 即可编译。
    init(
        items: [MarkdownOutlineItem],
        currentItemID: Int? = nil,
        onSelect: @escaping (MarkdownOutlineItem) -> Void
    ) {
        // 保存当前活动文档大纲。
        self.items = items
        // 保存可选当前章节供视觉标记。
        self.currentItemID = currentItemID
        // 保存选择回调。
        self.onSelect = onSelect
    }

    // 构建不抢占正文焦点的轻量侧栏。
    var body: some View {
        ScrollView {
            // 大纲条目按源文件顺序纵向排列。
            LazyVStack(alignment: .leading, spacing: 2) {
                // 没有标题时给出可理解的空状态。
                if items.isEmpty {
                    Text("暂无标题")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(12)
                } else {
                    // 每条标题保持稳定行号身份。
                    ForEach(items) { item in
                        Button {
                            // 把具体跳转交给活动编辑器与预览容器。
                            onSelect(item)
                        } label: {
                            // 标题层级转换为最多五档缩进。
                            Text(item.title)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, CGFloat(max(0, min(5, item.level - 1))) * 10)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                // 当前章节使用轻量强调底色，不遮盖层级缩进。
                                .background(
                                    item.id == currentItemID
                                        ? Color.accentColor.opacity(0.12)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .help("跳转到第 \(item.id + 1) 行")
                    }
                }
            }
            // 大纲与边缘保持紧凑留白。
            .padding(.vertical, 6)
        }
        // 使用系统控制背景与编辑区形成层次。
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
