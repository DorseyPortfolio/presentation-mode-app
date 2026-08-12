#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path=${1:-"$project_dir/dist/Presentation Mode.app"}
output_path=${2:-"$project_dir/dist/Presentation-Mode-Installer.dmg"}

if [ ! -d "$app_path" ]; then
    echo "Application bundle not found: $app_path" >&2
    echo "Build it first with Packaging/build-app.sh, or pass an existing app path." >&2
    exit 1
fi

if ! codesign --verify --deep --strict "$app_path"; then
    echo "The application bundle has an invalid code signature." >&2
    exit 1
fi

stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/presentation-mode-installer.XXXXXX")
cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT HUP INT TERM

volume_dir="$stage_dir/Presentation Mode"
mkdir -p "$volume_dir"
ditto "$app_path" "$volume_dir/Presentation Mode.app"
ditto "$project_dir/Packaging/INSTALL.txt" "$volume_dir/READ ME.txt"
ln -s /Applications "$volume_dir/Applications"

# Copying into an HFS/hybrid image can preserve FinderInfo/resource-fork
# metadata that strict code-signature validation rejects. Sanitize and sign
# the exact staged bundle that will be placed in the installer.
xattr -cr "$volume_dir/Presentation Mode.app"
codesign --force --deep --sign - "$volume_dir/Presentation Mode.app"
codesign --verify --deep --strict "$volume_dir/Presentation Mode.app"

mkdir -p "$(dirname -- "$output_path")"
rm -f "$output_path"
if ! hdiutil create \
    -volname "Presentation Mode Installer" \
    -srcfolder "$volume_dir" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$output_path"; then
    # Some managed macOS environments cannot allocate the device used by
    # `hdiutil create`. A hybrid HFS image remains Finder-mountable and can be
    # generated directly from the staged installer folder without that device.
    rm -f "$output_path"
    hdiutil makehybrid \
        -hfs \
        -hfs-volume-name "Presentation Mode Installer" \
        -o "$output_path" \
        "$volume_dir"
fi

echo "$output_path"
