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
