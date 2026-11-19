#!/usr/bin/env bash
# Builds build/Cadenza-<version>.dmg: a compressed, read-only disk image
# with the app on the left and an Applications symlink on the right over
# a warm paper background. Needs only Command Line Tools (hdiutil,
# iconutil, codesign) - no Xcode.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

version="$(sed -n 's/^version="\(.*\)"/\1/p' Tools/make_app.sh)"
dmg_name="Cadenza-${version}.dmg"
build_dir="${repo_root}/build"
app="${build_dir}/Cadenza.app"
staging="${build_dir}/dmg-staging"
rm -rf "${staging}"
mkdir -p "${staging}"
tmp_dmg="${staging}/tmp.dmg"
final_dmg="${build_dir}/${dmg_name}"

echo "Building release and app bundle"
swift build -c release --product CadenzaApp >/dev/null
bash Tools/make_app.sh >/dev/null

echo "Staging ${staging}"
cp -R "${app}" "${staging}/Cadenza.app"
ln -s /Applications "${staging}/Applications"
swift Tools/dmg_background.swift "${staging}/.background.png" >/dev/null

# lay out the icon view on a temporary read-write image, then compress
echo "Creating read-write image for layout"
hdiutil create -volname "Cadenza" -srcfolder "${staging}" -size 64m -ov -format UDRW -o "${tmp_dmg}" >/dev/null

vol="$(hdiutil attach -nobrowse -mountpoint "${build_dir}/Cadenza" "${tmp_dmg}" | tail -1 | awk '{print $NF}')"
echo "Mounted at ${vol}"
trap 'hdiutil detach "${vol}" >/dev/null 2>&1 || true; rm -rf "${staging}" "${build_dir}/Cadenza"' EXIT

# NOTE: "set background picture" needs the macOS Automation permission
# (System Settings > Privacy & Security > Automation > Terminal/osascript
# allowed to control Finder). Without it the call fails with -10006, so it
# sits in a try block and the DMG simply ships with a plain icon view.
osascript - "${vol}" <<'APPLESCRIPT' || echo "warning: Finder layout partially skipped"
on run argv
    set vol to POSIX path of (item 1 of argv)
    tell application "Finder"
        repeat 20 times
            if exists disk "Cadenza" then exit repeat
            delay 0.5
        end repeat
        tell disk "Cadenza"
            open
            delay 1
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {80, 80, 80 + 1600, 80 + 940}
            try
                set background picture of container window to (POSIX file (vol & "/.background.png") as alias)
            end try
            try
                set icon size of container window to 128
            end try
            try
                set arrangement of container window to not arranged
            end try
            set position of item "Cadenza.app" of container window to {330, 300}
            set position of item "Applications" of container window to {1230, 300}
            update without registering applications
            delay 1
        end tell
    end tell
end run
APPLESCRIPT

hdiutil detach "${vol}" >/dev/null

echo "Compressing to ${final_dmg}"
rm -f "${final_dmg}"
hdiutil convert "${tmp_dmg}" -format UDZO -o "${final_dmg}" >/dev/null
hdiutil verify "${final_dmg}"

rm -rf "${staging}" "${build_dir}/Cadenza"
trap - EXIT
echo "DMG written: ${final_dmg}"
ls -la "${final_dmg}"
