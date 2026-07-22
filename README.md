# Markdown Lite

[![CI](https://github.com/nemoob/markdown-lite-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/nemoob/markdown-lite-mac/actions/workflows/ci.yml)

一个以原生体验、数据安全和可测性能为优先级的 macOS Markdown 编辑器。

> **English:** Markdown Lite is a small, native Markdown editor for macOS, built with SwiftUI and AppKit. It focuses on fast editing, local-first data handling, crash recovery, and practical HTML publishing.

v0.5.0 是当前公开 Beta，适合本地试用、从源码构建和参与开发。项目主页：
[github.com/nemoob/markdown-lite-mac](https://github.com/nemoob/markdown-lite-mac)。

## 功能

- 原生 `NSTextView` 编辑，支持输入法、查找替换、撤销和长文输入。
- 增量 Markdown 语法着色；可调字号、行距，并提供常用格式快捷键。
- 多标签打开 Markdown/文本文件，恢复上次标签顺序、活动文档和独立草稿。
- 预览标题、列表、任务列表、引用、代码块、表格、链接及本地图片；HTTPS 远程图片需逐图确认后加载。
- 标题大纲跳转；每个标签保留独立编辑状态，预览随当前标签实时更新。
- 将拖入或粘贴的图片保存到文档同级 `assets/`，正文使用相对路径。
- 无损识别常见文本编码，保留 BOM，并以原子写入方式保存文件。
- 用内容指纹和 macOS 文件协调检测外部改写；普通保存不会静默覆盖磁盘版本。
- 草稿记录编辑起点的磁盘指纹，退出重启后仍能识别并阻止外部版本覆盖。
- 自动草稿在后台编码和原子写入，保存、重载后不会被过期任务复活。
- 导出包含安全本地图片的离线单文件 HTML，或复制“简洁”“技术文”两种公众号内联样式；导出结果默认不自动加载远程图片，单图上限 25 MiB、累计上限 100 MiB。
- 内置文档、会话、资源、导出和 Markdown 性能自检。

## 系统要求

- macOS 14 或更高版本
- Swift 6 工具链；推荐使用 Xcode 16 或更新版本
- 不依赖第三方 Swift Package

## v0.5 Public Beta 下载边界

- 源码可在满足上述要求的 Mac 上自行构建，SwiftPM 会为当前主机架构生成可执行文件。
- v0.5 的本地应用包，以及 GitHub Release 中可能提供的预编译应用，目前都只验证 Apple Silicon（arm64）；尚未提供经过验证的 Intel 或 Universal 2 应用包。
- `Scripts/package-app.sh` 生成的是本地 ad hoc 签名产物，未经过 Developer ID 签名或 Apple 公证，不能作为正式下载发布。
- 正式预编译下载必须单独完成 Developer ID 签名、公证和下载后验收；在此之前请使用源码构建。

## 构建与运行

```bash
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift run --disable-sandbox MarkdownLiteMac
```

一次执行格式、严格构建、标准测试和完整自检：

```bash
bash Scripts/check.sh
```

单独运行完整自检：

```bash
swift run --configuration release --disable-sandbox MarkdownLiteMac --self-check
```

单独执行 SwiftPM 测试入口：

```bash
swift test --disable-sandbox --no-parallel -Xswiftc -warnings-as-errors
```

`Scripts/check.sh` 会在本机仅选择 Command Line Tools、但已安装标准 Xcode 时自动使用 Xcode 工具链。标准 SwiftPM 测试串行覆盖文件冲突保护、既有回归和完整基准样本；release 配置的独立 `--self-check` 另外输出并强制验证可复核的性能数据。

生成本地 `.app`：

```bash
bash Scripts/package-app.sh
open dist/MarkdownLiteMac.app
```

脚本会生成 release 可执行文件、标准应用目录和本地图标，并执行可复现的本地 ad hoc 签名。该产物仅用于本地开发和验证，不得直接上传为 GitHub Release 的正式下载。

## 架构

生产代码保持单一 SwiftPM executable target，并使用独立 test target 覆盖回归；源码按职责拆分：

| 层次 | 主要职责 |
| --- | --- |
| `ContentView`、`NativeTextEditor` | SwiftUI 界面与 AppKit 原生编辑器桥接 |
| `WorkspaceModel`、`EditorModel` | 多标签生命周期、活动文档和每文档状态 |
| `MarkdownEngine`、`OutlineSupport`、`EditorFormattingSupport` | Markdown 解析、格式命令、增量着色和标题大纲 |
| `DocumentSupport`、`ExternalChangeSupport`、`SessionSupport` | 编码、原子保存、外部冲突、草稿和会话恢复 |
| `AssetSupport` | 本地图片验证、重名处理及 `assets/` 相对路径 |
| `ExportSupport` | 完整 HTML 与公众号粘贴格式 |

核心原则是让文档状态属于文档对象，让文件系统写入集中在支撑层，并让大文本解析离开主线程。

## 性能

内置基准以线性解析约 200KB 和 1MB 的 Markdown 文档，当前解析器门槛分别为：

- 200KB：小于 50ms
- 1MB：小于 200ms

这些数字只衡量 Markdown 解析器，不代表从键盘输入、语法着色到界面渲染的端到端延迟。CI 使用与最终应用一致的 release 配置，在独立进程中执行完整预热、三次解析中位数和块数校验；标准测试进程负责确定性功能与基准样本完整性。编辑输入采用短延迟合并，解析在后台任务执行，过期结果不会覆盖新正文。

## 隐私

- Markdown 正文、草稿、会话和导出均在本机处理，不上传到项目维护者或第三方服务。
- 草稿与会话保存在用户的 `~/Library/Application Support/MarkdownLiteMac/`。
- 图片导入只写入当前已保存文档同级的 `assets/` 目录。
- 应用没有账号、遥测或云同步功能。
- 远程图片默认不联网：明文 `http` 图片始终阻止，`https` 图片仅在用户点击当前图片的加载按钮后向对应站点发起请求。
- “复制公众号格式”会把生成结果写入系统剪贴板，只有用户随后粘贴时才会交给目标应用。

## 截图

![Markdown Lite 格式菜单、实时预览与远程图片隐私确认](docs/screenshots/markdown-lite-v04.png)

截图使用脱敏示例文档，展示原生编辑、格式菜单、增量语法着色、大纲、实时预览和远程图片默认不联网的确认状态。

## 已知边界

- v0.5 尚未提供经过 Developer ID 签名、公证和真实下载验收的预编译应用，也没有自动更新。
- 当前预编译验证边界为 Apple Silicon（arm64）；Intel Mac 用户需要从源码构建。
- 内容摘要复核与 `NSFileCoordinator` 能阻止遵循文件协调协议的常规外部修改被静默覆盖，但不承诺对完全不参与文件协调、且恰逢最终原子替换窗口的写入提供操作系统级绝对排他。
- 没有云同步、插件系统或 AI 功能。
- Markdown 解析器优先覆盖日常写作语法，并非完整 CommonMark/GFM 兼容实现。
- 公众号格式需要在目标后台进行真实粘贴验收，不同平台可能继续清理部分样式。

## 参与贡献与安全

问题和功能建议请提交到 [GitHub Issues](https://github.com/nemoob/markdown-lite-mac/issues)。贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [AGENTS.md](AGENTS.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

本项目使用 [MIT License](LICENSE)。
