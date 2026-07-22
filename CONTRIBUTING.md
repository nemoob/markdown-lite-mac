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
swift test --disable-sandbox --no-parallel -Xswiftc -warnings-as-errors
swift run --configuration release --disable-sandbox -Xswiftc -warnings-as-errors MarkdownLiteMac --self-check
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

### 发布前 GUI smoke（v0.9 起）

使用临时 macOS 用户，避免触及真实的 `~/Library/Application Support/MarkdownLiteMac/`，并确保其他版本均已退出。

1. 从 Finder 打开 `dist/MarkdownLiteMac.app`；“关于”版本必须等于 `Support/Info.plist`，主窗口可编辑。
2. 输入中文、标题、任务、代码块和表格，着色、大纲和预览须同步；`- 项目`、`9. 项目`、`- [x] 完成` 后按 Return 须分别生成 `- `、`10. `、`- [ ] `，空项退出列表，围栏内只换行。
3. 修改两个标签后退出重启；顺序、活动标签、已保存文件和未保存草稿须保持。
4. 用其他编辑器改写已打开的临时文件后再保存；必须阻止静默覆盖，并提供重载、另存为和明确覆盖入口。
5. 退出后仅破坏 `WorkspaceSession.json`；重启须提示“已从上一代会话恢复”。再退出并破坏两代；重启须显示持续警示，Finder 入口能定位证据，归档默认取消不改数据，确认后须显示精确目录并保留“恢复归档”入口。
6. 首实例有未保存文字时执行 `open -n dist/MarkdownLiteMac.app`；第二实例须提示“已在运行”并退出，首实例内容不变。

## Pull request

- 一个 pull request 只解决一个清晰问题。
- 描述用户可见结果、关键实现取舍、测试证据和仍未覆盖的风险。
- 文件保存、草稿恢复、图片路径和 HTML 导出变化需要包含失败路径测试。
- 性能相关变化请附 `--self-check` 的 200KB/1MB 结果和测试环境说明。
- UI 变化可附脱敏截图；不要包含个人路径、最近文件、账号或文档正文。
- 不提交 `.build/`、`dist/`、本地缓存、签名材料或真实用户数据。
- 发布相关变更必须同步版本号、构建号、变更日志和支持架构，不得把本地 ad hoc 包描述为正式下载。

维护者会优先考虑范围小、行为可复核且不增加不必要依赖的改动。

## Source-only 发布清单

只使用 GitHub 自动生成的源码归档；不上传 `.app`、DMG、ZIP、签名材料或其他 asset。以下命令从仓库根目录执行。

1. 更新并确认干净 `main`：`git switch main && git pull --ff-only origin main && test -z "$(git status --porcelain)"`。
2. 同步版本入口：`VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Support/Info.plist)"; BUILD="$(plutil -extract CFBundleVersion raw -o - Support/Info.plist)"; rg -n "v${VERSION}" README.md; rg -n "^## \[${VERSION}\]" CHANGELOG.md; rg -n "build ${BUILD}" CHANGELOG.md`。
3. 执行 `bash Scripts/check.sh && bash Scripts/package-app.sh && codesign --verify --deep --strict dist/MarkdownLiteMac.app`，再完成上文 GUI smoke。
4. 等待当前 `main` SHA 的 CI 成功：`test -n "$(gh run list -w ci.yml -b main -c "$(git rev-parse HEAD)" -s success --json databaseId --jq '.[0].databaseId')"`。
5. 创建并推送与 Info.plist 精确一致的 tag：`VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Support/Info.plist)"; TAG="v${VERSION}"; test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"; git tag -a "$TAG" -m "Markdown Lite $TAG"; git push origin "$TAG"`。
6. 等待同一 tag SHA 的 CI 成功：`TAG="v$(plutil -extract CFBundleShortVersionString raw -o - Support/Info.plist)"; test -n "$(gh run list -w ci.yml -b "$TAG" -c "$(git rev-parse "${TAG}^{commit}")" -s success --json databaseId --jq '.[0].databaseId')"`。
7. 不带资产路径地创建 prerelease：`TAG="v$(plutil -extract CFBundleShortVersionString raw -o - Support/Info.plist)"; gh release create "$TAG" --verify-tag --prerelease --generate-notes --title "Markdown Lite $TAG"`。
8. 校验 tag 仍指向 `main`、Release 为 prerelease 且 assets 精确为 0：`TAG="v$(plutil -extract CFBundleShortVersionString raw -o - Support/Info.plist)"; git fetch --tags origin; test "$(git rev-parse "${TAG}^{commit}")" = "$(git rev-parse origin/main)"; test "$(gh release view "$TAG" --json isPrerelease --jq .isPrerelease)" = true; test "$(gh release view "$TAG" --json assets --jq '.assets | length')" -eq 0`。
