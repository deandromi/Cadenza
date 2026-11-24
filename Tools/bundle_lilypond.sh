#!/bin/bash
# Stage the part of LilyPond the app actually runs.
#
# LilyPond is not a single binary: it is a Scheme interpreter (guile) with a
# font stack (pango, cairo, freetype, fontconfig, harfbuzz) and a directory of
# .ly/.scm files it reads while it works. Homebrew installs all of that for the
# whole machine; the app needs one copy that lives inside its own bundle and
# finds its own libraries, whatever the machine's Homebrew happens to be.
#
# So: copy the binary, walk its library dependencies, rewrite every install
# name to @loader_path, bring the data directory along, and sign the result
# ad hoc — install_name_tool invalidates Homebrew's signature, and an unsigned
# binary is killed by the loader before it prints a line.
#
# usage: Tools/bundle_lilypond.sh [--force]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/build/engraver"
PREFIX="$(brew --prefix lilypond 2>/dev/null || true)"
if [ -z "$PREFIX" ] || [ ! -d "$PREFIX" ]; then
    echo "bundle_lilypond: lilypond is not installed (brew install lilypond)" >&2
    exit 1
fi
VERSION="$(ls "$PREFIX/share/lilypond" | head -1)"
BIN_SRC="$PREFIX/bin/lilypond"

if [ -x "$STAGE/bin/lilypond" ] && [ "${1:-}" != "--force" ]; then
    echo "bundle_lilypond: already staged at $STAGE (use --force to rebuild)"
    exit 0
fi

# Where a library may live. Homebrew's own prefix comes first; the Cellar
# globs catch a dependency that only exists under a versioned keg.
SEARCH_DIRS=("$(brew --prefix)/lib" "$(brew --prefix)"/*/lib "$(brew --prefix)"/Cellar/*/*/lib)

resolve() {
    local dep="$1" name dir
    case "$dep" in
        /usr/lib/*|/System/*) echo ""; return ;;
        @*) name="$(basename "$dep")" ;;
        *) echo "$dep"; return ;;
    esac
    for dir in "${SEARCH_DIRS[@]}"; do
        if [ -f "$dir/$name" ]; then
            echo "$dir/$name"
            return
        fi
    done
    echo ""
}

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share/lilypond"

echo "bundle_lilypond: lilypond $VERSION from $PREFIX"
cp "$BIN_SRC" "$STAGE/bin/lilypond"
chmod u+w "$STAGE/bin/lilypond"

# One library at a time, breadth first: a library arrives with its own
# dependencies, and each is copied once under its own file name.
copied() { ls "$STAGE/lib" | grep -qx "$1"; }

queue=("$STAGE/bin/lilypond")
while [ ${#queue[@]} -gt 0 ]; do
    target="${queue[0]}"
    queue=("${queue[@]:1}")
    for dep in $(otool -L "$target" | tail -n +2 | awk '{print $1}'); do
        resolved="$(resolve "$dep")"
        [ -n "$resolved" ] || continue
        name="$(basename "$resolved")"
        if ! copied "$name"; then
            cp "$resolved" "$STAGE/lib/$name"
            chmod u+w "$STAGE/lib/$name"
            queue+=("$STAGE/lib/$name")
        fi
    done
done

echo "bundle_lilypond: $(ls "$STAGE/lib" | wc -l | tr -d ' ') libraries"

# Every reference here points at Homebrew's absolute prefix, or at an @rpath
# the bundle does not define. Nothing outside this bundle may be left in an
# install name, or the app stops working on a machine without Homebrew.
rewrite() {
    local file="$1" prefix="$2" dep resolved
    for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}'); do
        case "$dep" in
            /usr/lib/*|/System/*) continue ;;
        esac
        resolved="$(resolve "$dep")"
        [ -n "$resolved" ] || continue
        install_name_tool -change "$dep" "$prefix$(basename "$resolved")" "$file" 2>/dev/null || true
    done
}
rewrite "$STAGE/bin/lilypond" "@loader_path/../lib/"
for lib in "$STAGE"/lib/*.dylib; do
    rewrite "$lib" "@loader_path/"
    install_name_tool -id "@loader_path/$(basename "$lib")" "$lib" 2>/dev/null || true
done

# The data directories LilyPond reads while engraving: the .ly definitions,
# the Scheme it bootstraps, the PostScript prologues and the fonts. Docs,
# examples, locales, vim files and the Python helper scripts stay behind —
# the app writes .ly itself, so musicxml2ly is not needed.
mkdir -p "$STAGE/share/lilypond/$VERSION"
for part in ly scm ps fonts; do
    cp -R "$PREFIX/share/lilypond/$VERSION/$part" "$STAGE/share/lilypond/$VERSION/"
done

# The compiled Scheme. LilyPond finds it beside its libraries, under
# lib/lilypond/<version>/ccache, and without it every run recompiles the
# engraver's Scheme from source: measured on a real take, 2.2 s with the cache
# against 8.4 s without.
mkdir -p "$STAGE/lib/lilypond/$VERSION"
rm -rf "$STAGE/lib/lilypond/$VERSION/ccache"
cp -R "$PREFIX/lib/lilypond/$VERSION/ccache" "$STAGE/lib/lilypond/$VERSION/ccache"
cp "$PREFIX/share/lilypond/$VERSION/VERSION" "$STAGE/share/lilypond/$VERSION/" 2>/dev/null || true

# License: the engraver is GPL-3.0, and a copy travels with the binary.
for candidate in "$ROOT/Resources/LilyPond-GPL.txt" "$PREFIX/COPYING" "$PREFIX/GPLv3"; do
    if [ -f "$candidate" ]; then
        cp "$candidate" "$STAGE/share/LilyPond-GPL.txt"
        break
    fi
done

cat > "$STAGE/run.sh" <<'WRAPPER'
#!/bin/sh
# The wrapper the app calls. LilyPond finds its Scheme and .ly files through
# LILYPOND_DATADIR; without it the binary looks in /usr/share and stops.
here="$(cd "$(dirname "$0")" && pwd)"
version="$(ls "$here/share/lilypond" | head -1)"
LILYPOND_DATADIR="$here/share/lilypond/$version"
export LILYPOND_DATADIR
export LILYPOND_RELOCATE_DATADIR="$LILYPOND_DATADIR"
exec "$here/bin/lilypond" "$@"
WRAPPER
chmod +x "$STAGE/run.sh"

# Editing the load commands threw away Homebrew's signature; without a fresh
# ad-hoc one the kernel kills the binary before main().
codesign --force --sign - --timestamp=none "$STAGE/bin/lilypond" >/dev/null 2>&1
for lib in "$STAGE"/lib/*.dylib; do
    codesign --force --sign - --timestamp=none "$lib" >/dev/null 2>&1 || true
done

echo "bundle_lilypond: staged $(du -sh "$STAGE" | cut -f1) at $STAGE"
