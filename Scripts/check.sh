#!/bin/bash

# 任一构建、测试、格式或元数据检查失败都立即终止。
set -euo pipefail

# 解析仓库根目录，保证从任意工作目录得到相同行为。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 脚本目录的上一级就是 Swift Package 根目录。
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 本机只选择 Command Line Tools 时，优先使用已安装 Xcode 提供的测试框架。
SELECTED_DEVELOPER="$(xcode-select -p 2>/dev/null || true)"
# 调用方显式指定工具链时保持其选择不变。
if [[ -z "${DEVELOPER_DIR:-}" ]] &&
   [[ "$SELECTED_DEVELOPER" == "/Library/Developer/CommandLineTools" ]] &&
   [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# 模块缓存限制在仓库 .build，避免污染用户全局目录。
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PROJECT_DIR/.build/module-cache/clang}"
# SwiftPM 使用独立缓存路径，兼容受限执行环境。
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PROJECT_DIR/.build/module-cache/swiftpm}"
# 提前创建缓存目录，让权限错误在检查开始时明确暴露。
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

# 先验证两个公开脚本都能被 Bash 无副作用解析。
bash -n "$PROJECT_DIR/Scripts/check.sh" "$PROJECT_DIR/Scripts/package-app.sh"
# 应用元数据必须保持合法 plist。
plutil -lint "$PROJECT_DIR/Support/Info.plist"
# 公开显示名必须与当前产品品牌一致。
PLIST_DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw -o - "$PROJECT_DIR/Support/Info.plist")"
# 品牌误回退时立即阻断提交。
[[ "$PLIST_DISPLAY_NAME" == "墨简" ]] || { echo "CFBundleDisplayName 必须为墨简" >&2; exit 1; }
# SwiftPM 可执行名称作为当前稳定技术标识继续保留。
PLIST_EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "$PROJECT_DIR/Support/Info.plist")"
# 打包脚本与 plist 不一致会生成无法启动的应用包。
[[ "$PLIST_EXECUTABLE" == "MarkdownLiteMac" ]] || { echo "CFBundleExecutable 兼容标识发生变化" >&2; exit 1; }
# 读取沿用 v0.11 的应用身份，防止设置和系统关联被意外切换。
PLIST_BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$PROJECT_DIR/Support/Info.plist")"
# Bundle ID 迁移需要独立的数据迁移方案，不能混入普通品牌修改。
[[ "$PLIST_BUNDLE_IDENTIFIER" == "cn.nemoob.markdown-lite-mac" ]] || { echo "CFBundleIdentifier 兼容标识发生变化" >&2; exit 1; }
# 严格格式门禁禁止只输出告警却继续成功。
swift format lint --strict --recursive \
    "$PROJECT_DIR/Sources" \
    "$PROJECT_DIR/Tests" \
    "$PROJECT_DIR/Package.swift"
# 所有编译警告都按错误处理。
swift build --disable-sandbox --package-path "$PROJECT_DIR" -Xswiftc -warnings-as-errors
# 标准 SwiftPM 测试显式串行执行，避免共享测试进程的调度影响确定性回归。
swift test --disable-sandbox --package-path "$PROJECT_DIR" --no-parallel -Xswiftc -warnings-as-errors
# 大样本端到端测试只在独立 release 进程执行，避免 Debug 全量测试重复 50MB IO。
swift test --configuration release --disable-sandbox --package-path "$PROJECT_DIR" \
    --no-parallel -Xswiftc -warnings-as-errors --filter WorkspaceEndToEndPerformanceTests
# 发布配置的独立进程验证完整链路和两档性能目标，口径与最终应用一致。
swift run --configuration release --disable-sandbox --package-path "$PROJECT_DIR" \
    -Xswiftc -warnings-as-errors MarkdownLiteMac --self-check
# 先完整扫描刚构建的 Release 可执行文件；strings 失败会由 set -e 关闭式阻断。
RELEASE_BINARY_STRINGS="$(strings "$PROJECT_DIR/.build/release/MarkdownLiteMac")"
# 再从已成功取得的字符串中查找测试参数；grep 无匹配是唯一允许的非零状态。
RELEASE_TEST_CLI_MARKERS="$(
    grep -E -- '--test-crash-recovery-(writer|reader)|--test-temp-root' \
        <<<"$RELEASE_BINARY_STRINGS" || true
)"
# 任一隐藏测试入口残留都立即阻断发布检查。
if [[ -n "$RELEASE_TEST_CLI_MARKERS" ]]; then
    # 只输出固定错误，不回显二进制内容或本机路径。
    echo "Release 可执行文件仍包含崩溃恢复测试入口" >&2
    # 非零退出让本地和 CI 使用同一安全门禁。
    exit 1
fi
