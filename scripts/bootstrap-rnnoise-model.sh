#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RN_DIR="$ROOT_DIR/Libraries/RNNoise"

if [ ! -d "$RN_DIR" ]; then
  echo "RNNoise source directory not found at: $RN_DIR"
  exit 1
fi

cd "$RN_DIR"

HASH="$(cat model_version)"
MODEL="rnnoise_data-${HASH}.tar.gz"
URL="https://media.xiph.org/rnnoise/models/${MODEL}"

if [ ! -f "$MODEL" ]; then
  echo "Downloading $MODEL"
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$URL" -o "$MODEL"
  elif command -v wget >/dev/null 2>&1; then
    wget "$URL" -O "$MODEL"
  else
    echo "Neither curl nor wget is installed."
    exit 1
  fi
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$MODEL" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "$MODEL" | awk '{print $1}')"
else
  ACTUAL=""
fi

if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "$HASH" ]; then
  echo "Checksum mismatch for $MODEL"
  echo "Expected: $HASH"
  echo "Actual:   $ACTUAL"
  exit 1
fi

if [ ! -f src/rnnoise_data.c ] || [ ! -f src/rnnoise_data.h ]; then
  echo "Extracting model files"
  tar -xvf "$MODEL"
fi

if [ ! -f src/rnnoise_data.c ] || [ ! -f src/rnnoise_data.h ]; then
  echo "Model extraction failed: src/rnnoise_data.c/h missing"
  exit 1
fi

echo "RNNoise model files are ready."
