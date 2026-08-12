#!/bin/zsh
set -eu

snapshot_name="${1:-decklink-$(date +%Y-%m-%d-%H%M%S)}"
output_dir="${0:A:h}/snapshots/${snapshot_name}"
prefs='/Library/Preferences/com.blackmagic-design.desktopvideo.prefspanel.plist'

mkdir -p "$output_dir"

if [[ -r "$prefs" ]]; then
  cp -p "$prefs" "$output_dir/desktopvideo-settings.plist"
  plutil -convert xml1 -o "$output_dir/desktopvideo-settings.xml" "$prefs"
  plutil -convert json -o - "$prefs" \
    | jq 'to_entries | map(select(.value.ProfileFourCC != null) | {
        device_key: .key,
        profile_fourcc_decimal: .value.ProfileFourCC,
        default_video_output_mode: .value.DefaultVideoOutputMode,
        sdi_output_link: .value.SDIOutputLinkConfiguration,
        force_progressive_output: .value.ForceProgressiveVideoOutput,
        idle_output: .value.IdleOutputOperation
      })' > "$output_dir/decklink-key-settings.json"
fi

{
  echo '# DeckLink machine snapshot'
  echo
  echo "- Captured: $(date -Iseconds)"
  echo "- Computer name: $(scutil --get ComputerName 2>/dev/null || echo unknown)"
  echo "- Model: $(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2; exit}')"
  echo "- Model identifier: $(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Identifier/{print $2; exit}')"
  echo "- Chip: $(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip/{print $2; exit}')"
  echo "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "- Desktop Video: $(pkgutil --pkg-info com.blackmagic-design.DesktopVideo 2>/dev/null | awk '/version:/{print $2; exit}')"
  echo "- DeckLink framework: $(file '/Library/Frameworks/DeckLinkAPI.framework/Versions/A/DeckLinkAPI' 2>/dev/null)"
  echo "- Presentation Mode: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '/Applications/Presentation Mode.app/Contents/Info.plist' 2>/dev/null || echo not-installed)"
  echo
  echo '## Detected DeckLink services'
  echo
  ioreg -l 2>/dev/null | sed -nE 's/.*\+-o (DeckLink[^<]+).*/- \1/p' | sort -u
  echo
  echo '## Important note'
  echo
  echo 'Profile FourCC values commonly seen here: `1dfd` = one sub-device full duplex, `2dfd` = two sub-devices full duplex, and `4dhd` = four sub-devices half duplex.'
  echo 'The raw plist can contain records for disconnected or previously configured devices. Match the current I/O Registry instance numbers before interpreting a record as active.'
} > "$output_dir/SUMMARY.md"

echo "$output_dir"
