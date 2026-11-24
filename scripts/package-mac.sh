#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

build_dir=".local/build-mac-release"
output_dir="Artifacts"
identity="${PAPERREADER_DEVELOPER_ID:--}"
product="PageWise"
products="$build_dir/Build/Products/Release"
app="$products/$product.app"
mkdir -p "$output_dir"
work_dir=$(mktemp -d "$output_dir/.pagewise-dmg.XXXXXXXX")
cleanup() {
  rm -r -- "$work_dir"
  if [[ -d "$app" ]]; then rm -r -- "$app"; fi
}
trap cleanup EXIT

# SwiftPM copies whole resource directories. Remove the built bundles so a replaced PDF cannot survive an incremental build.
for built in "$app" "$products/PaperReader_PaperReaderKit.bundle" "$products/PaperReader_PaperReaderUI.bundle"; do
  if [[ -d "$built" ]]; then rm -r -- "$built"; fi
done

xcodebuild -quiet -jobs 2 -project PaperReader.xcodeproj -scheme PaperReader -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$build_dir" \
  -clonedSourcePackagesDirPath .local/build-mac/SourcePackages -skipPackageUpdates \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME=YES \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=debugging \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CODE_SIGN_IDENTITY="$identity" build

version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
minimum_os=$(plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")
plist="$app/Contents/Info.plist"
[[ $(plutil -extract CFBundleDisplayName raw "$plist") == "$product" ]]
[[ $(plutil -extract CFBundleIdentifier raw "$plist") == dev.paperreader.mac ]]
executable="$app/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$plist")"
lipo "$executable" -verify_arch arm64 x86_64
if LC_ALL=C grep -aFq "$(pwd -P)/" "$executable" || LC_ALL=C grep -aFq "$HOME/" "$executable"; then
  echo "Release 可执行文件中仍含本机构建路径。" >&2
  exit 1
fi

resources="$app/Contents/Resources"
kit="$resources/PaperReader_PaperReaderKit.bundle/Contents/Resources"
ui="$resources/PaperReader_PaperReaderUI.bundle/Contents/Resources"
test -s "$kit/Samples/When the Average Misleads.pdf"
diff -qr Sources/PaperReaderKit/Resources/Samples "$kit/Samples"
for file in Prompts/CloseReadingNotebook.md \
    KaTeX/katex.min.js Marked/marked.umd.js ThirdPartyNotices.txt; do
  cmp "Sources/PaperReaderKit/Resources/$file" "$kit/$file"
done
cmp Sources/PaperReaderUI/Platform/HTML/ReaderWarmup.html "$ui/ReaderWarmup.html"
cmp Sources/PaperReaderUI/Platform/HTML/NoteEditor/NoteEditor.bundle/editor.js "$ui/NoteEditor.bundle/editor.js"
if [[ ! -s "$resources/AppIcon.icns" || ! -s "$resources/Assets.car" ]]; then
  echo "Release 应用缺少编译后的图标资源。" >&2
  exit 1
fi

volume="$work_dir/volume"
mkdir "$volume"
ditto "$app" "$volume/$product.app"
codesign --verify --deep --strict --all-architectures "$volume/$product.app"
ln -s /Applications "$volume/Applications"
cat > "$volume/安装与上手.txt" <<EOF
$product $version
适用于 macOS $minimum_os 或更高版本，支持 Apple 芯片和 Intel Mac。

1. 把 $product 拖到旁边的 Applications（应用程序）文件夹，然后从那里打开。
   如已使用 PaperReader，请先退出旧版，PageWise 将沿用原书库。
2. 首次打开空书库时，点「快速上手」中的「直接试读示例」，即可阅读
   随应用提供的英文 PDF《When the Average Misleads》。
   已有论文的书库可从「帮助 → 快速上手」重看同一示例。
3. 阅读原文、划线和写笔记可离线使用。需要翻译或 AI 助读时，
   打开「设置 → 模型服务」，选择服务并保存自己的 API 密钥。
EOF
if [[ "$identity" == "-" ]]; then
  cat >> "$volume/安装与上手.txt" <<'EOF'

此测试版采用本地签名，尚未经过 Apple 公证。若首次打开时系统提示无法验证开发者，
请先确认文件来自你信任的分享者，再按 Apple 说明为此 App 单独确认打开：
https://support.apple.com/zh-cn/102445
EOF
fi

image="$work_dir/$product.dmg"
hdiutil create -quiet -volname "$product" -fs HFS+ -format UDZO -srcfolder "$volume" "$image"
if [[ "$identity" != "-" ]]; then
  codesign --verify -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
  codesign --sign "$identity" --timestamp --identifier dev.paperreader.mac.dmg "$image"
  codesign --verify --strict "$image"
fi
hdiutil verify -quiet "$image"
filename="$product-$version-macOS.dmg"
mv -f "$image" "$output_dir/$filename"
(cd "$output_dir" && shasum -a 256 "$filename" | tee "$filename.sha256")
