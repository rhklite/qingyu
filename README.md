# 轻语 (Qingyu)

A personal, local-first dictation app for macOS — your own Wispr Flow. Hold a key,
talk, and the cleaned-up text is pasted into whatever app has focus. Everything runs
on-device: whisper.cpp (Metal) for transcription, an optional local LLM for cleanup.
No cloud, no account, no telemetry.

## How it works

```
hold Left-⌥ ──▶ record mic ──▶ whisper.cpp (Metal) ──▶ optional LLM cleanup ──▶ paste at cursor
  release          16kHz mono        transcript            local Ollama            ⌘V
```

- **Menu-bar only** (no Dock icon). The mic icon shows state: idle / listening (red) /
  transcribing (blue).
- **Push-to-talk, hybrid by default:** **hold Left-⌥** to talk; **double-tap** to lock
  hands-free (tap once to stop). Also selectable: plain hold, or tap-to-toggle.
- **Floating speech bar:** a small translucent pill with a live waveform appears while
  you dictate (like Wispr), then a shimmer while transcribing. Toggle it in the menu.
- **Instant on/off:** the mic opens on press and releases the moment you finish — no
  lingering mic indicator. The audio graph is reused so start-up stays snappy.
- **Transcription:** whisper.cpp `large-v3-turbo-q5_0` (multilingual) on the GPU,
  ~0.3–0.6s for a short utterance on Apple Silicon.
- **Cleanup (optional):** a local Ollama model removes filler words, fixes punctuation,
  and respects your custom vocabulary. If Ollama isn't running you get the raw
  transcript — nothing breaks.
- **Mic pinning:** pick a specific input device (pinned by stable CoreAudio UID, so it
  survives reboots / re-plugging), or follow the system default.
- **Multilingual:** whisper detects the language per utterance. You can pin one, or pick
  a **subset** (e.g. English + 中文) so detection only ever chooses among those — no more
  short/quiet clips wandering off to the wrong language.
- **Audio boost:** quiet / far-from-mic utterances are normalized to a consistent
  loudness (peak-limited, never clips) before transcription, improving accuracy.
- **Injection:** clipboard + synthetic ⌘V (fast), or Unicode typing (leaves the
  clipboard untouched).

## Build

Requires: Apple Silicon, Xcode Command Line Tools, CMake (`brew install cmake`).
The large models are **not** in the repo (GitHub size limits) — the scripts fetch them.

```bash
./scripts/build_whisper.sh      # build whisper.cpp static libs (once, ~2 min)
./scripts/download_model.sh     # fetch ggml-large-v3-turbo-q5_0.bin (~547 MB → ~/.config/qingyu/models)
./scripts/setup_signing.sh      # one-time: stable self-signed identity so TCC grants persist
./scripts/build.sh              # compile + bundle the app, then launch it:
open "$HOME/Library/Application Support/Qingyu/Qingyu.app"
```

> **Build location:** the `.app` is assembled under `~/Library/Application Support/Qingyu`,
> not inside the repo. If the project lives in a cloud-synced folder (iCloud/Dropbox),
> the file-provider re-tags `.app` bundles with `com.apple.FinderInfo` and codesign
> fails with "resource fork … not allowed"; `~/Library` is never synced. Override with
> `QINGYU_APP_DIR`.
>
> **Signing:** `setup_signing.sh` creates a self-signed code-signing cert in a dedicated
> keychain. Ad-hoc signatures change every rebuild, so macOS forgets your Microphone /
> Accessibility grants each time; a stable identity makes them persist. `build.sh` falls
> back to ad-hoc if you skip it.
>
> This project builds with `swiftc` directly rather than `swift build`, because some
> Command Line Tools installs ship a broken SwiftPM `ManifestAPI`. `Package.swift` is
> included for toolchains where `swift build` works.

## First-run permissions

On first launch 轻语 requests everything in one pass. Grant in System Settings →
Privacy & Security (the menu's **Permissions ▸** submenu shows live ✓/✗ and jumps to
each pane; **Request All Permissions…** re-fires the prompts):

| Permission | Why |
|---|---|
| **Microphone** | record your voice |
| **Accessibility** | paste text, and satisfy the global-hotkey event tap |
| **Input Monitoring** | alternative to Accessibility for the hotkey tap |

Accessibility alone is enough for the hotkey *and* pasting, so 轻语 often never needs a
separate Input Monitoring toggle. After granting, the hotkey arms itself within 2s.

## Optional: LLM cleanup

```bash
brew install ollama
brew services start ollama   # or `ollama serve`
ollama pull qwen2.5:3b       # matches ollamaModel in config (~1.9 GB, managed by Ollama)
```

Toggle cleanup from the menu. With Ollama offline the menu shows "On (Ollama offline)"
and 轻语 falls back to whisper's raw output.

## Menu

Mic icon in the menu bar → status, hotkey hint, and:

- **LLM Cleanup** on/off · **Boost Quiet Audio** on/off · **Mode** (Hold / Toggle /
  Hold + double-tap lock) · **Floating Bar** on/off
- **Microphone ▸** — System Default or any connected input (pinned by UID)
- **Language ▸** — Auto-detect, or toggle a subset to detect only among those
- **Change Push-to-Talk Key…** — press the key you want to bind
- **Permissions ▸** · **Open Config Folder** · **Copy Last Transcript**

## Configuration

`~/.config/qingyu/config.json`:

| Key | Default | Notes |
|---|---|---|
| `modelPath` | `…/models/ggml-large-v3-turbo-q5_0.bin` | any whisper.cpp GGML model |
| `language` | `auto` | `auto` detects; or `en`, `ja`, `zh`, … |
| `detectLanguages` | `[]` | restrict detection to these codes, e.g. `["en","zh"]`; `[]` = all |
| `boostAudio` | `true` | normalize quiet / far-mic audio before transcription |
| `pttKeyCode` | `58` | Left-⌥. 61=Right-⌥, 59=Left-⌃, 62=Right-⌃, 55=Left-⌘ |
| `hotkeyMode` | `hybrid` | `hybrid` (hold + double-tap lock), `hold`, or `toggle` |
| `inputDeviceUID` | *(unset)* | pinned mic UID; unset = system default |
| `showOverlay` | `true` | floating speech bar while dictating |
| `cleanup` | `true` | run the local-LLM pass |
| `ollamaModel` | `qwen2.5:3b` | any pulled Ollama model |
| `ollamaURL` | `http://127.0.0.1:11434` | |
| `injectionMode` | `paste` | `paste` (⌘V) or `type` (Unicode events) |
| `playSounds` | `true` | soft start/stop chimes |
| `customVocabulary` | `[]` | proper nouns; biases whisper + cleanup |

Prefer a modifier key for `pttKeyCode` — a normal key would type its character while held.
You can also set it live via **Change Push-to-Talk Key…**.

## Layout

```
Sources/Qingyu/           Swift app: menu bar, audio capture, whisper, hotkey,
                        cleanup, injection, floating bar, permissions, key capture
Sources/CWhisper/       C-interop module map exposing whisper.h to Swift
Resources/              Info.plist, entitlements
scripts/                build_whisper.sh, build.sh, download_model.sh, setup_signing.sh
third_party/whisper.cpp GGML/whisper.cpp source (vendored; build tree is gitignored)
```

## Status

Working: transcription verified end-to-end (Metal), local-LLM cleanup, hybrid
push-to-talk with in-app rebinding, mic pinning, floating waveform bar, instant mic
on/off, synthetic-event filtering (ignores injected keystrokes from e.g. mouse
software). Ideas next: streaming/partial results, per-app vocabulary, a preferences
window, notarization for distribution, Parakeet backend.
