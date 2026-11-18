#!/usr/bin/env bash
#
# Builds the Cadenza app bundle at build/Cadenza.app.
#
# Usage: Tools/make_app.sh

set -euo pipefail

# Single place to bump the bundle version. Both version keys in the Info.plist
# template carry the ${CADENZA_VERSION} placeholder.
version="0.1.0"

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

echo "Signing build/Cadenza.app (ad-hoc)"
codesign --force -s - "${app_dir}"

echo "You can run: open build/Cadenza.app"
