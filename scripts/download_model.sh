#!/bin/bash
# Downloads a whisper.cpp GGML model into ~/.config/qingyu/models/.
#
# Usage: scripts/download_model.sh [model]
#   model defaults to large-v3-turbo-q5_0 (multilingual, ~547 MB, fast on Apple Silicon).
#   Examples: tiny.en  base.en  large-v3-turbo-q8_0  large-v3-turbo  large-v3
set -euo pipefail

MODEL="${1:-large-v3-turbo-q5_0}"
DEST="$HOME/.config/qingyu/models"
FILE="ggml-${MODEL}.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${FILE}"

mkdir -p "$DEST"
if [[ -f "$DEST/$FILE" ]]; then
    echo "Already present: $DEST/$FILE"
    exit 0
fi

echo "Downloading $FILE ..."
curl -L --fail -o "$DEST/$FILE" "$URL"
echo "Saved to $DEST/$FILE"
echo
echo "Point Qingyu at it by setting modelPath in ~/.config/qingyu/config.json:"
echo "  \"modelPath\": \"$DEST/$FILE\""
