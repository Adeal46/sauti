#!/usr/bin/env bash
# Downloads the Kokoro English voice model (int8, 11 voices) used by sherpa-onnx.
# Run from the repository root. Safe to run repeatedly.
set -euo pipefail

DEST="App/Resources/KokoroModel"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"

if [ -f "$DEST/model.int8.onnx" ] && [ -f "$DEST/lexicon-en-us.txt" ]; then
  echo "Kokoro model already present in $DEST"
  exit 0
fi

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Kokoro int8 model…"
curl -fSL --retry 3 -o "$TMP/kokoro.tar.bz2" "$BASE/kokoro-int8-en-v0_19.tar.bz2"
tar xjf "$TMP/kokoro.tar.bz2" -C "$TMP"
SRC="$TMP/kokoro-int8-en-v0_19"
cp "$SRC/model.int8.onnx" "$SRC/voices.bin" "$SRC/tokens.txt" "$SRC/LICENSE" "$DEST/"

echo "Downloading English pronunciation lexicon…"
curl -fSL --retry 3 -o "$DEST/lexicon-en-us.txt" "$BASE/lexicon-en-us.txt"

ls -lh "$DEST"
