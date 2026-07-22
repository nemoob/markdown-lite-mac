#!/bin/bash

# 任一未处理错误、未定义变量或管道错误都会终止打包。
set -euo pipefail

# 解析脚本目录，保证从任意工作目录执行都得到相同结果。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 项目目录位于脚本目录的上一级。
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# 输出固定放在项目 dist 目录。
DIST_DIR="$PROJECT_DIR/dist"
# 应用包名称与可执行产品保持一致。
APP_BUNDLE="$DIST_DIR/MarkdownLiteMac.app"
# 应用包内部目录使用标准 macOS 布局。
CONTENTS_DIR="$APP_BUNDLE/Contents"
# 复用仓库内唯一的 Info.plist 源文件。
INFO_PLIST="$PROJECT_DIR/Support/Info.plist"
# SVG 始终随应用保留，图标转换失败时也能追溯源资源。
ICON_SVG="$PROJECT_DIR/Resources/AppIcon.svg"

# 缺少必要输入时立即失败，避免产出残缺应用。
[[ -f "$INFO_PLIST" ]] || { echo "错误：缺少 $INFO_PLIST" >&2; exit 1; }
# 图标源同样属于可重复打包输入。
[[ -f "$ICON_SVG" ]] || { echo "错误：缺少 $ICON_SVG" >&2; exit 1; }

# Command Line Tools 与已安装 Xcode SDK 不匹配时优先使用标准 Xcode。
SELECTED_DEVELOPER="$(xcode-select -p 2>/dev/null || true)"
# 仅在调用方未指定工具链且当前只选中 CLT 时进行安全回退。
if [[ -z "${DEVELOPER_DIR:-}" ]] &&
   [[ "$SELECTED_DEVELOPER" == "/Library/Developer/CommandLineTools" ]] &&
   [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# 将编译缓存限制在项目 .build 内，兼容受限工作区并便于清理。
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PROJECT_DIR/.build/module-cache/clang}"
# SwiftPM 使用独立模块缓存，避免写入用户全局缓存。
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PROJECT_DIR/.build/module-cache/swiftpm}"
# 临时 Swift 图标渲染器也使用项目内模块缓存。
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$PROJECT_DIR/.build/module-cache/swift}"
# 提前创建缓存目录，使后续编译错误更明确。
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$SWIFT_MODULECACHE_PATH"

# 先编译优化后的 release 可执行文件；关闭 SwiftPM 嵌套沙箱以兼容受限运行环境。
swift build --disable-sandbox --package-path "$PROJECT_DIR" -c release
# 由 SwiftPM 返回当前架构和工具链对应的真实产物目录。
BIN_DIR="$(swift build --disable-sandbox --package-path "$PROJECT_DIR" -c release --show-bin-path)"
# 校验可执行文件存在后再覆盖旧应用包。
[[ -x "$BIN_DIR/MarkdownLiteMac" ]] || { echo "错误：未找到 release 可执行文件" >&2; exit 1; }

# 临时图标转换目录由系统创建，避免固定目录残留污染下一次打包。
PACKAGE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/markdown-lite-package.XXXXXX")"
# 无论成功失败都清理本次临时文件。
trap 'rm -rf "$PACKAGE_TMP"' EXIT

# 只替换本项目下的明确应用包目标，保证脚本可重复执行。
rm -rf "$APP_BUNDLE"
# 创建标准的可执行文件和资源目录。
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
# 安装 release 二进制并确保具有执行权限。
install -m 755 "$BIN_DIR/MarkdownLiteMac" "$CONTENTS_DIR/MacOS/MarkdownLiteMac"
# 从 Support 复制原始应用元数据，不修改源 plist。
install -m 644 "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
# 无论系统是否支持转换，都保留 SVG 源图标。
install -m 644 "$ICON_SVG" "$CONTENTS_DIR/Resources/AppIcon.svg"

# 使用系统 AppKit 从 SVG 直接生成多尺寸 icns。
generate_icns() {
    # Swift 小工具只使用系统框架，并将结果写入本次临时目录。
    xcrun swift -e '
import AppKit

// 以大端序写入 icns 的 32 位长度字段。
func appendUInt32(_ value: UInt32, to data: inout Data) {
    // icns 容器规定整数采用网络字节序。
    var bigEndian = value.bigEndian
    // 将四个原始字节追加到结果。
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

// 直接从矢量源渲染指定像素尺寸，避免逐级缩放失真。
func renderPNG(_ image: NSImage, size: Int) -> Data {
    // 创建带透明通道的标准 RGBA 位图。
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("无法创建位图") }
    // 将逻辑尺寸与像素尺寸对齐。
    bitmap.size = NSSize(width: size, height: size)
    // 创建位图绘制上下文。
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("无法创建绘制上下文") }
    // 保存调用前的 AppKit 绘制状态。
    NSGraphicsContext.saveGraphicsState()
    // 无论后续结果如何都恢复原绘制状态。
    defer { NSGraphicsContext.restoreGraphicsState() }
    // 启用高质量矢量采样。
    context.imageInterpolation = .high
    // 将当前绘制目标切换到图标位图。
    NSGraphicsContext.current = context
    // 清除圆角外区域并保留透明度。
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    // 以目标尺寸直接绘制 SVG。
    image.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    // 使用无损 PNG 作为各 icns 数据块载荷。
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("无法编码 PNG") }
    // 返回当前尺寸图像数据。
    return data
}

// 从脚本参数读取 SVG 和目标 icns。
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
// 使用系统 NSImage 解码 SVG 矢量资源。
guard let image = NSImage(contentsOf: input) else { fatalError("无法读取 SVG") }
// 提供 Finder 需要的 16 到 1024 像素图标块。
let variants = [
    (16, "icp4"),
    (32, "icp5"),
    (64, "icp6"),
    (128, "ic07"),
    (256, "ic08"),
    (512, "ic09"),
    (1024, "ic10"),
]
// 依次构造各尺寸 icns 数据块。
var chunks = Data()
for (size, type) in variants {
    // 每个尺寸都直接由 SVG 渲染成 PNG。
    let imageData = renderPNG(image, size: size)
    // 四字节类型标识当前图标尺寸。
    chunks.append(contentsOf: type.utf8)
    // 数据块长度包含类型和长度本身的八个字节。
    appendUInt32(UInt32(imageData.count + 8), to: &chunks)
    // 追加无损图像载荷。
    chunks.append(imageData)
}
// 写入 icns 容器标识。
var result = Data("icns".utf8)
// 容器总长度包含八字节文件头。
appendUInt32(UInt32(chunks.count + 8), to: &result)
// 追加全部图标数据块。
result.append(chunks)
// 原子写入最终图标，避免中断后留下半个文件。
try result.write(to: output, options: .atomic)
' "$ICON_SVG" "$PACKAGE_TMP/AppIcon.icns" >/dev/null 2>&1 || return 1
}

# 仅在系统 Swift 工具齐备且转换成功时启用 icns。
if command -v xcrun >/dev/null 2>&1 &&
   generate_icns; then
    # 安装转换后的原生应用图标。
    install -m 644 "$PACKAGE_TMP/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
    # 只修改应用包内副本，声明 Finder 应使用 AppIcon.icns。
    plutil -replace CFBundleIconFile -string AppIcon "$CONTENTS_DIR/Info.plist"
    # 明确报告本次已生成原生图标。
    echo "图标：已从 SVG 生成 AppIcon.icns"
else
    # 转换能力不可用时仍保留 SVG 并明确说明 Finder 图标限制。
    echo "警告：无法稳定生成 icns，应用包已保留 AppIcon.svg，Finder 将使用默认图标。" >&2
fi

# 验证最终 plist 语法有效。
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
# 验证最终可执行文件仍具有运行权限。
[[ -x "$CONTENTS_DIR/MacOS/MarkdownLiteMac" ]] || { echo "错误：应用包可执行文件不可运行" >&2; exit 1; }

# 使用本机 ad hoc 身份密封整个应用包，避免只含链接器签名的可执行文件无法通过包级校验。
codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"
# 打包结束前校验资源和可执行文件都与当前签名一致。
codesign --verify --deep --strict "$APP_BUNDLE"
# 明确区分本地 ad hoc 密封与 Developer ID 签名、公证或正式发布。
echo "签名：已执行本地 ad hoc 签名；未执行 Developer ID 签名或公证"
# 输出确定的最终应用路径供调用方打开或继续验收。
echo "完成：$APP_BUNDLE"
