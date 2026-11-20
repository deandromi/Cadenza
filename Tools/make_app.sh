#!/usr/bin/env bash
#
# Builds the Cadenza app bundle at build/Cadenza.app.
#
# Usage: Tools/make_app.sh

set -euo pipefail

# Single place to bump the bundle version. Both version keys in the Info.plist
# template carry the ${CADENZA_VERSION} placeholder.
version="1.0.0"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${repo_root}/build"
app_dir="${build_dir}/Cadenza.app"
binary_src="${repo_root}/.build/release/CadenzaApp"
plist_template="${repo_root}/Tools/Info.plist.template"

die() {
	echo "error: $*" >&2
	exit 1
}

# Sanity-check the resolved root before touching anything under it.
if [[ ! -f "${repo_root}/Package.swift" ]]; then
	die "Couldn't find Package.swift under ${repo_root}. Is this the Cadenza repository?"
fi
if [[ ! -f "${plist_template}" ]]; then
	die "Missing Info.plist template at ${plist_template}."
fi

cd "${repo_root}"

echo "Building CadenzaApp (release)"
swift build -c release --product CadenzaApp

if [[ ! -f "${binary_src}" ]]; then
	die "swift build finished, but there is no CadenzaApp binary at ${binary_src}."
fi

echo "Assembling build/Cadenza.app"
# Idempotent: drop any previous bundle, but only the exact path we are about
# to recreate inside this repository's build directory.
if [[ -e "${app_dir}" ]]; then
	case "${app_dir}" in
		"${build_dir}/Cadenza.app")
			rm -rf "${app_dir}"
			;;
		*)
			die "Refusing to remove ${app_dir}: expected ${build_dir}/Cadenza.app."
			;;
	esac
fi
mkdir -p "${app_dir}/Contents/MacOS"

cp "${binary_src}" "${app_dir}/Contents/MacOS/Cadenza"
chmod +x "${app_dir}/Contents/MacOS/Cadenza"

sed -e "s/\\\${CADENZA_VERSION}/${version}/g" "${plist_template}" > "${app_dir}/Contents/Info.plist"
printf 'APPL????' > "${app_dir}/Contents/PkgInfo"

# The notation font (Bravura, OFL) rides in the bundle's resources; the app
# registers it with CoreText at launch.
mkdir -p "${app_dir}/Contents/Resources"
cp "${repo_root}/Resources/Bravura.otf" "${app_dir}/Contents/Resources/Bravura.otf"
cp "${repo_root}/Resources/Bravura-OFL.txt" "${app_dir}/Contents/Resources/Bravura-OFL.txt"
cp "${repo_root}/Resources/AppIcon.icns" "${app_dir}/Contents/Resources/AppIcon.icns"

# The Transkun model and its tensors ship inside the bundle so the app is
# self-contained when installed from the DMG (no repo checkout needed).
cp -R "${repo_root}/Models" "${app_dir}/Contents/Resources/Models"

echo "Signing build/Cadenza.app (ad-hoc)"
codesign --force -s - "${app_dir}"

# Install into /Applications so Launchpad, the Dock and `open -a Cadenza`
# always land on the fresh build instead of a stale copy.
if [ -d /Applications/Cadenza.app ]; then
  echo "Replacing /Applications/Cadenza.app with the fresh build"
  rm -rf /Applications/Cadenza.app
fi
cp -R "${app_dir}" /Applications/Cadenza.app
codesign --force -s - /Applications/Cadenza.app

echo "You can run: open build/Cadenza.app (or open -a Cadenza)"
