# 参与贡献

感谢你愿意改进 [Markdown Lite](https://github.com/nemoob/markdown-lite-mac)。请先阅读仓库级硬规则 [AGENTS.md](AGENTS.md)；本文只说明协作流程，避免重复维护编码规范。

## 开始之前

1. 搜索已有 [issue](https://github.com/nemoob/markdown-lite-mac/issues) 和 [pull request](https://github.com/nemoob/markdown-lite-mac/pulls)，确认问题尚未解决。
2. 对较大的行为变化先开 [issue](https://github.com/nemoob/markdown-lite-mac/issues/new)，写清用户场景、数据安全影响和最小验收条件。
3. 安全漏洞不要公开讨论，请改用 [SECURITY.md](SECURITY.md) 中的私下报告方式。

## 本地验证

项目要求 macOS 14+ 和 Swift 6 工具链。提交前先执行统一检查入口：

```bash
bash Scripts/check.sh
```

该脚本等价执行以下关键门禁：

```bash
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -warnings-as-errors
swift run --disable-sandbox MarkdownLiteMac --self-check
bash -n Scripts/package-app.sh
plutil -lint Support/Info.plist
```

新增行为必须补充标准 SwiftPM 测试；涉及性能或完整应用链路时，同时扩展 `--self-check`。

涉及打包流程时，再执行：

```bash
bash Scripts/package-app.sh
plutil -lint dist/MarkdownLiteMac.app/Contents/Info.plist
codesign --verify --deep --strict dist/MarkdownLiteMac.app
```

`Scripts/package-app.sh` 只生成供本地验证的 ad hoc 签名应用。不要把 `dist/` 产物附到正式 Release；预编译下载必须另行说明架构，并完成 Developer ID 签名、公证和下载后验收。

## Pull request

- 一个 pull request 只解决一个清晰问题。
- 描述用户可见结果、关键实现取舍、测试证据和仍未覆盖的风险。
- 文件保存、草稿恢复、图片路径和 HTML 导出变化需要包含失败路径测试。
- 性能相关变化请附 `--self-check` 的 200KB/1MB 结果和测试环境说明。
- UI 变化可附脱敏截图；不要包含个人路径、最近文件、账号或文档正文。
- 不提交 `.build/`、`dist/`、本地缓存、签名材料或真实用户数据。
- 发布相关变更必须同步版本号、构建号、变更日志和支持架构，不得把本地 ad hoc 包描述为正式下载。

维护者会优先考虑范围小、行为可复核且不增加不必要依赖的改动。
