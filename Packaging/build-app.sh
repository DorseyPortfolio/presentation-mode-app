#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
flavor=${PRESENTATION_MODE_BUILD_FLAVOR:-validation}
case "$flavor" in
    validation) build_dir="$project_dir/.build"; output_dir=${1:-"$project_dir/dist"}; app_name="Presentation Mode Settings Preview.app" ;;
    production) echo "Settings preview is isolated; production packaging requires release review." >&2; exit 1 ;;
    *) echo "Unknown build flavor: $flavor" >&2; exit 1 ;;
esac
app_dir="$output_dir/$app_name"
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
    --scratch-path "$build_dir" \
    --disable-sandbox \
    --cache-path "$build_dir/cache" \
    --config-path "$build_dir/config" \
    --security-path "$build_dir/security"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
ditto --noextattr --norsrc --noqtn "$project_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
ditto --noextattr --norsrc --noqtn "$build_dir/release/PresentationMode" "$app_dir/Contents/MacOS/PresentationMode"
if [ "$flavor" = production ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wcmedia.PresentationMode.NDI" "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.4.5" "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 10" "$app_dir/Contents/Info.plist"
fi
chmod 755 "$app_dir/Contents/MacOS/PresentationMode"
ditto --noextattr --norsrc --noqtn "$project_dir/Packaging/libndi.dylib" "$app_dir/Contents/Frameworks/libndi.dylib"
ditto --noextattr --norsrc --noqtn "$project_dir/Packaging/libndi_licenses.txt" "$app_dir/Contents/Resources/libndi_licenses.txt"
ditto --noextattr --norsrc --noqtn "$project_dir/Packaging/NDI-SDK-License.rtf" "$app_dir/Contents/Resources/NDI-SDK-License.rtf"
ditto --noextattr --norsrc --noqtn "$assets_dir/MenuBarIcon.png" "$app_dir/Contents/Resources/MenuBarIcon.png"

sips -s format icns "$assets_dir/AppIcon.png" --out "$app_dir/Contents/Resources/AppIcon.icns" >/dev/null

# An ad-hoc signature is build-specific, not a stable identity across rebuilds.
# Supply a Developer ID identity for a stable release signing process.
codesign --force --deep --sign "${CODE_SIGN_IDENTITY:--}" "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
