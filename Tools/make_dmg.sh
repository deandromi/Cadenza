#!/usr/bin/env bash
# Builds build/Cadenza-<version>.dmg: a compressed, read-only disk image
# with the app and an Applications symlink in a laid-out icon view.
# Needs only Command Line Tools (hdiutil, codesign) - no Xcode.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

version="$(sed -n 's/^version="\(.*\)"/\1/p' Tools/make_app.sh)"
dmg_name="Cadenza-${version}.dmg"
build_dir="${repo_root}/build"
app="${build_dir}/Cadenza.app"
staging="${build_dir}/dmg-staging"
rm -rf "${staging}"
mkdir -p "${staging}" /tmp/cadenza-dmg-vol
tmp_dmg="${staging}/tmp.dmg"
final_dmg="${build_dir}/${dmg_name}"

echo "Building release and app bundle"
swift build -c release --product CadenzaApp >/dev/null
CADENZA_KEEP_BUILD=1 bash Tools/make_app.sh >/dev/null

echo "Staging ${staging}"
cp -R "${app}" "${staging}/Cadenza.app"
ln -s /Applications "${staging}/Applications"

# lay out the icon view on a temporary read-write image, then compress
echo "Creating read-write image for layout"
hdiutil create -volname "Cadenza" -srcfolder "${staging}" -size 160m -ov -format UDRW -o "${tmp_dmg}" >/dev/null

vol="$(hdiutil attach -nobrowse -mountpoint "/tmp/cadenza-dmg-vol/Cadenza" "${tmp_dmg}" | tail -1 | awk '{print $NF}')"
echo "Mounted at ${vol}"
trap 'hdiutil detach "${vol}" >/dev/null 2>&1 || true; rm -rf "${staging}" /tmp/cadenza-dmg-vol' EXIT

# Finder's automation is flaky about flushing .DS_Store, so retry the layout
# until the file actually lands on the volume (up to 3 attempts).
layout_ok=0
for attempt in 1 2 3; do
	if osascript - "${vol}" <<'APPLESCRIPT'
on run argv
    set vol to POSIX path of (item 1 of argv)
    tell application "Finder"
        repeat 20 times
            if exists disk "Cadenza" then exit repeat
            delay 0.5
        end repeat
        tell disk "Cadenza"
            open
            delay 2
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {80, 80, 80 + 1600, 80 + 940}
            try
                set icon size of container window to 128
            end try
            try
                set arrangement of container window to not arranged
            end try
            set position of item "Cadenza.app" of container window to {330, 300}
            set position of item "Applications" of container window to {1230, 300}
            update without registering applications
            delay 2
            close container window
            delay 1
        end tell
    end tell
end run
APPLESCRIPT
	then
		if [[ -f "${vol}/.DS_Store" ]]; then
			layout_ok=1
			break
		fi
	fi
	echo "layout attempt ${attempt} produced no .DS_Store, retrying"
	sleep 2
done
if [[ "${layout_ok}" != 1 ]]; then
	echo "warning: Finder layout skipped; icons will use the default arrangement"
fi

hdiutil detach "${vol}" >/dev/null

echo "Compressing to ${final_dmg}"
rm -f "${final_dmg}"
hdiutil convert "${tmp_dmg}" -format UDZO -o "${final_dmg}" >/dev/null
hdiutil verify "${final_dmg}"

rm -rf "${staging}" /tmp/cadenza-dmg-vol
trap - EXIT
echo "DMG written: ${final_dmg}"
ls -la "${final_dmg}"
