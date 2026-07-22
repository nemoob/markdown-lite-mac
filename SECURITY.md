# Security Policy

## Supported versions

v0.10.x 是 Markdown Lite 当前支持的公开 Beta。安全修复优先进入[默认分支和最新标记版本](https://github.com/nemoob/markdown-lite-mac)；v0.1.x 至 v0.9.x 不承诺回补。建议先在最新代码上确认问题仍然存在。

## Reporting a vulnerability

请不要在公开 issue、discussion 或 pull request 中披露尚未修复的漏洞、利用步骤、个人文档或本机路径。

优先使用仓库 [Security 页面](https://github.com/nemoob/markdown-lite-mac/security) 提供的 **Report a vulnerability / GitHub Security Advisory** 私下提交报告。如果该入口尚未启用，请创建一个 [不含敏感细节的普通 issue](https://github.com/nemoob/markdown-lite-mac/issues/new)，仅请求维护者提供私下联系方式。

报告尽量包含：

- 受影响版本或 commit；
- macOS 与 Swift/Xcode 版本；
- 最小复现步骤和预期/实际结果；
- 对文档完整性、路径边界、剪贴板或导出内容的影响；
- 已知缓解方式；
- 可安全共享的测试文件，且不含真实用户数据。

维护者会尽力确认收到报告、复现问题并协调修复与披露时间，但当前不承诺固定响应时限。修复公开前，请给维护者合理时间完成验证和发布准备。

## Security scope

尤其欢迎报告以下问题：

- 草稿、会话或保存流程造成静默覆盖或数据丢失；
- `assets/`、相对图片或符号链接导致目录穿越；
- 恶意 Markdown、链接或 HTML 导出绕过协议过滤；
- 剪贴板或拖放把数据写入错误文档；
- 本地文件内容、路径或元数据被意外上传或记录。

普通兼容性问题、功能建议和不含安全影响的崩溃可以使用公开 issue。
