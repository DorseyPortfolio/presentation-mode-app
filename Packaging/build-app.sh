#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$project_dir/.build"
output_dir=${1:-"$project_dir/dist"}
app_dir="$output_dir/Presentation Mode.app"
assets_dir="$project_dir/Packaging"
if [ ! -f "$assets_dir/AppIcon.png" ]; then
    # Compatibility with the original imported workspace layout.
    assets_dir="$project_dir/work/PresentationMode-DeckLink/Packaging"
fi

mkdir -p "$build_dir/cache" "$build_dir/module-cache" "$build_dir/config" "$build_dir/security"

CLANG_MODULE_CACHE_PATH="$build_dir/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/module-cache" \
swift build \
    --package-path "$project_dir" \
    --configuration release \
    --disable-sandbox \
    --cache-path "$build_dir/cache" \
    --config-path "$build_dir/config" \
    --security-path "$build_dir/security"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
ditto "$project_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
ditto "$build_dir/release/PresentationMode" "$app_dir/Contents/MacOS/PresentationMode"
chmod 755 "$app_dir/Contents/MacOS/PresentationMode"
ditto "$project_dir/Packaging/libndi.dylib" "$app_dir/Contents/Frameworks/libndi.dylib"
ditto "$project_dir/Packaging/libndi_licenses.txt" "$app_dir/Contents/Resources/libndi_licenses.txt"
ditto "$project_dir/Packaging/NDI-SDK-License.rtf" "$app_dir/Contents/Resources/NDI-SDK-License.rtf"
ditto "$assets_dir/MenuBarIcon.png" "$app_dir/Contents/Resources/MenuBarIcon.png"

sips -s format icns "$assets_dir/AppIcon.png" --out "$app_dir/Contents/Resources/AppIcon.icns" >/dev/null

# Ad-hoc signing provides a stable local code identity. A Developer ID can
# replace this at deployment time without changing the bundle layout.
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
