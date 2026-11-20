#!/bin/bash
# Scores the streaming transcription against a folder of MIDI files: each
# piece is rendered to mono audio with the harness synth (the cleanest signal
# the engine can see), then transcribed and compared with its own MIDI.
#
# Usage: Tools/corpus_eval.sh <outdir> <seconds> <midi...>
# Prints one eval line per piece into <outdir>/<name>.log.
set -u
cd "$(dirname "$0")/.." || exit 1

out="$1"; shift
seconds="$1"; shift
mkdir -p "$out"

for midi in "$@"; do
    name="$(basename "$midi" .mid)"
    audio="$out/$name.f32"
    log="$out/$name.log"
    if [ ! -s "$audio" ]; then
        ./.build/release/CadenzaApp --synth-midi "$midi" "$audio" 48000 "$seconds" >/dev/null 2>&1
    fi
    CDZ_FIXED_STEP=0.9 CDZ_DUMP_MISMATCH=1 \
        ./.build/release/CadenzaApp --eval "$audio" "$midi" 48000 >"$log" 2>&1
    echo "$name: $(tail -1 "$log")"
done
