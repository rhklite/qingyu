# Flow

A personal, local-first dictation app for macOS — your own Wispr Flow. Hold a key,
talk, and the cleaned-up text is pasted into whatever app has focus. Everything
runs on-device: whisper.cpp (Metal) for transcription, an optional local LLM for
cleanup. No cloud, no account, no telemetry.

## How it works

```
hold Right-⌥ ──▶ record mic ──▶ whisper.cpp (Metal) ──▶ optional LLM cleanup ──▶ paste at cursor
   release           16kHz mono        transcript            local Ollama            ⌘V
```

- **Menu-bar only** (no Dock icon). The mic icon shows state: idle / listening (red) /
  transcribing (blue).
- **Push-to-talk:** hold **Right-Option** to record, release to transcribe. Switch to
  tap-to-toggle in the menu.
- **Transcription:** whisper.cpp `large-v3-turbo-q5_0` (multilingual) on the GPU.
  ~0.3–0.6s for a short utterance on Apple Silicon.
- **Cleanup (optional):** a local Ollama model removes filler words, fixes punctuation,
  and respects your custom vocabulary. If Ollama isn't running, you get the raw
  transcript — nothing breaks.
- **Injection:** clipboard + synthetic ⌘V (fast), or Unicode typing (leaves clipboard
  untouched).

## Build

Requires: Apple Silicon, Xcode Command Line Tools, CMake (`brew install cmake`).

```bash
./scripts/build_whisper.sh      # build whisper.cpp static libs (once, ~2 min)
./scripts/download_model.sh     # fetch ggml-large-v3-turbo-q5_0.bin (~547 MB)
./scripts/build.sh              # compile + bundle .build/Flow.app
open .build/Flow.app
```

> This project builds with `swiftc` directly (see `scripts/build.sh`) rather than
> `swift build`, because some Command Line Tools installs ship a broken SwiftPM
> `ManifestAPI`. `Package.swift` is included for toolchains where `swift build` works.

## First-run permissions

macOS will prompt for three things (grant all in System Settings → Privacy & Security):

| Permission | Why | Where |
|---|---|---|
| **Microphone** | record your voice | Privacy → Microphone |
| **Input Monitoring** | detect the global hotkey | Privacy → Input Monitoring |
| **Accessibility** | paste text into the focused app | Privacy → Accessibility |

Use the menu's **Grant Permissions…** item to trigger the prompts and open Settings.
After granting, the hotkey starts working automatically (it retries every 2s).

## Optional: LLM cleanup

```bash
brew install ollama
ollama serve            # or launch the app
ollama pull qwen2.5:3b  # matches ollamaModel in config
```

Toggle cleanup from the menu. With Ollama offline the menu shows "On (Ollama offline)"
and Flow falls back to whisper's raw output.

## Configuration

`~/.config/flow/config.json`:

| Key | Default | Notes |
|---|---|---|
| `modelPath` | `…/models/ggml-large-v3-turbo-q5_0.bin` | any whisper.cpp GGML model |
| `language` | `auto` | `auto` detects; or `en`, `ja`, `zh`, … |
| `pttKeyCode` | `61` | Right-⌥. 58=Left-⌥, 62=Right-⌃, 54=Right-⌘ |
| `hotkeyMode` | `hold` | `hold` (push-to-talk) or `toggle` |
| `cleanup` | `true` | run the local-LLM pass |
| `ollamaModel` | `qwen2.5:3b` | any pulled Ollama model |
| `ollamaURL` | `http://127.0.0.1:11434` | |
| `injectionMode` | `paste` | `paste` (⌘V) or `type` (Unicode events) |
| `playSounds` | `true` | start/stop cues |
| `customVocabulary` | `[]` | proper nouns; biases whisper + cleanup |

Use a modifier key for `pttKeyCode` — a normal key would type its character while held.

## Layout

```
Sources/Flow/          Swift app (menu bar, audio, whisper, hotkey, cleanup, inject)
Sources/CWhisper/      C-interop module map exposing whisper.h to Swift
Resources/             Info.plist, entitlements
scripts/               build_whisper.sh, build.sh, download_model.sh
third_party/whisper.cpp GGML/whisper.cpp source + build/
```

## Status

Working v0.1: transcription verified end-to-end (Metal, ~18–27× realtime). Ideas next:
streaming/partial results, per-app vocabulary, a preferences window, code-signing +
notarization for distribution, Parakeet backend (whisper.cpp now bundles it).
