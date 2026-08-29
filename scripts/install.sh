#!/usr/bin/env bash
# One-command first-run setup for 轻语 (Qingyu):
#   1. builds whisper.cpp (once) and installs 轻语.app into /Applications
#   2. downloads the whisper transcription model (required)
#   3. optionally sets up local-LLM cleanup (Ollama + Qwen) if you want it
#
# The LLM step is optional and you're asked up front, so the rest runs unattended.
# Non-interactive overrides:
#   QINGYU_LLM=1|0            enable / skip LLM cleanup without the prompt
#   QINGYU_WHISPER_MODEL=…    whisper model (default large-v3-turbo-q5_0)
#   QINGYU_OLLAMA_MODEL=…     cleanup model (default qwen2.5:3b)
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

say "轻语 (Qingyu) setup"
command -v cmake >/dev/null || { echo "CMake required — install it first: brew install cmake" >&2; exit 1; }

# Build only for this Mac. The universal (arm64 + x86_64) build is for handing the app
# to someone else — see scripts/makedmg.sh.
export QINGYU_ARCHS="${QINGYU_ARCHS:-$(uname -m)}"
if [[ "$QINGYU_ARCHS" == "x86_64" ]]; then
    echo "Intel Mac: transcription will run on the CPU (no Metal). A smaller model is" >&2
    echo "much snappier here — consider QINGYU_WHISPER_MODEL=medium-q5_0." >&2
fi

MODEL="${QINGYU_WHISPER_MODEL:-large-v3-turbo-q5_0}"
OLLAMA_MODEL="${QINGYU_OLLAMA_MODEL:-qwen2.5:3b}"

# --- Ask about optional LLM cleanup up front, then run unattended -------------------
want_llm="${QINGYU_LLM:-}"
if [[ -z "$want_llm" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Enable local-LLM cleanup? Installs Ollama + ${OLLAMA_MODEL} (~1.9 GB). [y/N] " ans
        [[ "$ans" =~ ^[Yy] ]] && want_llm=1 || want_llm=0
    else
        want_llm=0   # non-interactive default: raw whisper output
    fi
fi
if [[ "$want_llm" == "1" ]] && ! command -v brew >/dev/null; then
    echo "Homebrew is needed to install Ollama (https://brew.sh) — or re-run with QINGYU_LLM=0." >&2
    exit 1
fi

# --- whisper.cpp static libraries --------------------------------------------------
if [[ ! -f "third_party/whisper.cpp/build-$QINGYU_ARCHS/src/libwhisper.a" ]]; then
    if [[ ! -f third_party/whisper.cpp/CMakeLists.txt ]]; then
        say "Cloning whisper.cpp"
        git clone --depth 1 https://github.com/ggml-org/whisper.cpp third_party/whisper.cpp
    fi
    say "Building whisper.cpp (once, ~2 min)"
    bash scripts/build_whisper.sh
fi

# --- Whisper model (required) ------------------------------------------------------
say "Downloading whisper model: $MODEL (~547 MB)"
bash scripts/download_model.sh "$MODEL"

# --- Build + install the app -------------------------------------------------------
say "Building + installing 轻语.app"
bash scripts/setup_signing.sh
bash scripts/build.sh

# --- Optional local-LLM cleanup ----------------------------------------------------
if [[ "$want_llm" == "1" ]]; then
    say "Setting up local-LLM cleanup ($OLLAMA_MODEL)"
    command -v ollama >/dev/null || brew install ollama
    brew services start ollama >/dev/null 2>&1 || (nohup ollama serve >/dev/null 2>&1 &)
    for _ in $(seq 1 30); do curl -sf http://127.0.0.1:11434/api/tags >/dev/null && break; sleep 1; done
    ollama pull "$OLLAMA_MODEL"
fi

# --- Point the config at the model + record the cleanup choice ---------------------
# (The app fills in every other default on first launch; this just pre-seeds these.)
MODEL_FILE="$HOME/.config/qingyu/models/ggml-${MODEL}.bin"
python3 - "$MODEL_FILE" "$want_llm" "$OLLAMA_MODEL" <<'PY'
import json, os, sys
path, want, omodel = sys.argv[1], sys.argv[2], sys.argv[3]
p = os.path.expanduser("~/.config/qingyu/config.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg["modelPath"] = path
cfg["cleanup"] = (want == "1")
if want == "1":
    cfg["ollamaModel"] = omodel
json.dump(cfg, open(p, "w"), indent=2)
PY

say "Done"
echo "Launch:  open \"/Applications/轻语.app\"   (or double-click 轻语 in Finder / Launchpad)"
echo "Then grant Microphone + Accessibility, hold Left-⌥, and speak."
[[ "$want_llm" == "1" ]] || echo "LLM cleanup is off — you can turn it on later from the menu (needs Ollama)."
