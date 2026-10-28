#!/usr/bin/env bash
# Downloads the full-precision Kokoro v1.0 voice model (English voices, US + UK
# pronunciation dictionaries) used by sherpa-onnx. Run from the repository root.
set -euo pipefail

DEST="App/Resources/KokoroModel"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
PKG="kokoro-multi-lang-v1_0"

if [ -f "$DEST/model.onnx" ] && [ -f "$DEST/lexicon-gb-en.txt" ]; then
  echo "Kokoro v1.0 model already present in ${DEST}"
  exit 0
fi

rm -rf "$DEST"
mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ${PKG}..."
curl -fSL --retry 3 -o "$TMP/kokoro.tar.bz2" "$BASE/$PKG.tar.bz2"
tar xjf "$TMP/kokoro.tar.bz2" -C "$TMP" \
  "$PKG/model.onnx" "$PKG/voices.bin" "$PKG/tokens.txt" \
  "$PKG/lexicon-us-en.txt" "$PKG/lexicon-gb-en.txt" "$PKG/LICENSE"
cp "$TMP/$PKG/"* "$DEST/"

ls -lh "$DEST"
test -f "$DEST/model.onnx" || { echo "Voice model download failed" >&2; exit 1; }
