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
- **Transcription:** whisper.cpp `large-v3-turbo-q5_0` (multilingual). ~0.7s for a short
  utterance on Apple Silicon (Metal). On Intel it's CPU-only — see below.
- **Universal:** one build runs on Apple Silicon and Intel. On first launch it asks which
  speech model you want — the trade-off is very different per architecture — and
  downloads it (**Speech models**, below). The DMG itself stays ~10 MB.
- **Cleanup, three levels:** **Raw** (no LLM), **Light** (drops "um"/"uh" and false
  starts, fixes punctuation, keeps your wording), **Heavy** (also tightens into proper
  written grammar — never dropping a fact). One global setting. First-run setup offers
  to pull the model when Ollama is running; without it you get the raw transcript.
- **Spoken punctuation:** say "question mark" and get `?`. Deterministic, so it works at
  Raw level and with Ollama absent.
- **Personal dictionary:** terms that bias transcription, plus literal find → replace
  pairs. New proper nouns are added automatically with a 10-second undo.
- **Quiet other audio while dictating** (optional): lower or pause background media,
  vendored from [speak-duck](https://github.com/rhklite/speak-duck).
- **Mic pinning:** pick a specific input device (pinned by stable CoreAudio UID, so it
  survives reboots / re-plugging), or follow the system default.
- **Multilingual:** whisper detects the language per utterance. You can pin one, or pick
  a **subset** (e.g. English + 中文) so detection only ever chooses among those — no more
  short/quiet clips wandering off to the wrong language.
- **Audio boost:** quiet / far-from-mic utterances are normalized to a consistent
  loudness (peak-limited, never clips) before transcription, improving accuracy.
- **Injection:** clipboard + synthetic ⌘V (fast), or Unicode typing (leaves the
  clipboard untouched).

## Speech models

whisper always encodes a padded 30-second window, so encoder cost is fixed no matter
how short the utterance is. `large-v3-turbo` carries the full large-v3 encoder and only
saves on the decoder — which means **Medium is the faster model, not Turbo**, on both
backends. Measured on an M4 Max with a 5.7s utterance:

| Machine | Turbo (large-v3-turbo-q5_0) | Medium (medium-q5_0) |
|---|---|---|
| Apple Silicon, Metal | 0.71s | 0.44s |
| Apple Silicon, CPU only | 1.84s | 1.20s |
| Intel, CPU (estimated) | ≈5–10s | ≈3–6s |

On Apple Silicon both are effectively instant, so Turbo wins on accuracy. On Intel the
gap is seconds of dead time after every phrase, so Medium is the better default unless
you dictate 中文 / 日本語, where Turbo is clearly stronger.

Models are **downloaded, not bundled**. On first launch — or any time no model is on
disk — 轻语 shows the setup window, and the model you pick is fetched from Hugging Face
into `~/.config/qingyu/models` with progress and a cancel button
(`ModelDownloader.swift`). It's verified by GGML header + size before being moved into
place, so an interrupted download can never leave something that looks installed. After
that the app is fully offline. Switch models later from the menu bar → **Speech Model**;
one that isn't downloaded yet is marked `⤓` with its size.

**Why Intel has no GPU path:** ggml gates its Metal matmul kernels on
`MTLGPUFamilyApple7` (`ggml-metal-device.m`), which no Intel GPU reports — every matmul
would fall back to the CPU anyway. So the x86_64 slice is built with `GGML_METAL=OFF`
and runs on Accelerate + AVX2, and `WhisperEngine` turns off `use_gpu`/`flash_attn`
there.

## Install

Requires: Xcode Command Line Tools, CMake (`brew install cmake`). Apple Silicon or Intel.
The large models aren't in the repo (GitHub size limits) — setup fetches them.

**Easiest — guided GUI.** Double-click **`Install 轻语.app`** in the project folder. It
asks whether you want LLM cleanup, then builds everything, downloads the speech model,
and installs `轻语.app` into /Applications (progress shows in a Terminal window).

**Or one command:**

```bash
./scripts/install.sh            # build + install, download the model, ask about LLM cleanup
```

**Or step by step:**

```bash
./scripts/build_whisper.sh      # whisper.cpp static libs (once, ~2 min per arch)
./scripts/download_model.sh     # ggml-large-v3-turbo-q5_0.bin (~547 MB → ~/.config/qingyu/models)
./scripts/setup_signing.sh      # stable self-signed identity so TCC grants persist
./scripts/build.sh              # compile + install 轻语.app into /Applications
open "/Applications/轻语.app"    # or double-click 轻语 in Finder / Launchpad
```

`install.sh` also handles optional LLM cleanup (Ollama + qwen2.5:3b) — set `QINGYU_LLM=1`
or `0` to skip the prompt. Regenerate the GUI installer with `./scripts/build_installer.sh`.

> **Install location:** `build.sh` installs `轻语.app` into `/Applications` (falling back
> to `~/Applications` if that needs admin) — both outside iCloud/Dropbox sync. That
> matters: in a synced folder like `~/Documents`, the file-provider re-tags `.app`
> bundles with `com.apple.FinderInfo` and codesign fails with "resource fork … not
> allowed". Override the location with `QINGYU_APP_DIR`.
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

Setup's second step explains these before firing the prompts, and never blocks — you can
Continue with none of them granted. The menu's **Permissions ▸** submenu shows live ✓/✗
and jumps to each pane; **Request All Permissions…** re-fires the prompts.

| Permission | Why | Password? |
|---|---|---|
| **Microphone** | record your voice | no — plain TCC prompt, per-user |
| **Accessibility** | paste text, and satisfy the global-hotkey event tap | **admin** |
| **Input Monitoring** | alternative to Accessibility for the hotkey tap | **admin** |

Accessibility alone is enough for the hotkey *and* pasting, so 轻语 often never needs a
separate Input Monitoring toggle. After granting, the hotkey arms itself within 2s.

**Why two of them need an admin password:** Accessibility and Input Monitoring live in
the root-owned system TCC database (`/Library/Application Support/com.apple.TCC/TCC.db`,
`root:wheel`), not the per-user one — so a standard, non-admin account cannot grant them
at all. That's macOS, not something 轻语 can work around.

**Degraded mode.** With neither granted, the event tap can't run and synthetic ⌘V can't
be posted, so 轻语 falls back to what needs no privileges:

- **● Start Dictation / ■ Stop Dictation** appear in the menu — clicking the menu-bar
  icon replaces the push-to-talk key.
- The transcript is left on the clipboard (`TextInjector.Result.clipboardOnly`) and the
  menu reports "Copied — press ⌘V to paste" instead of silently doing nothing.

轻语 itself never asks for a password: there is no `sudo`, no `AuthorizationCreate`, and
no privileged helper anywhere in `Sources/` or `scripts/`. The only installer that wants
admin is Ollama's, and that step is optional.

## Optional: LLM cleanup

Setup's second step handles this in-app: it probes `ollamaURL`, and if Ollama is running
it either confirms the model is there or offers to pull it with a progress bar
(`OllamaClient.swift` streams `/api/pull`). 轻语 can't install Ollama itself — that needs
Homebrew or an installer — so when the server isn't reachable the step says so and links
to the download. Reopen it any time from the menu: **Set Up Text Cleanup…**.

By hand:

```bash
brew install ollama
brew services start ollama   # or `ollama serve`
ollama pull qwen2.5:3b       # matches ollamaModel in config (~1.9 GB, managed by Ollama)
```

Toggle cleanup from the menu. With Ollama offline the menu shows "On (Ollama offline)"
and 轻语 falls back to whisper's raw output.

## Settings window

Menu bar → **Open Settings…**. Deliberately light (forced Aqua appearance, no icon set);
Save applies and closes, Cancel discards. The menu keeps every control it always had —
this window covers the things that are awkward in a menu:

- **Cleanup** — Raw / Light / Heavy, with what each does spelled out.
- **Spoken punctuation** and **Learn new words automatically** toggles.
- **While dictating** — Leave audio alone / Lower other audio / Pause media.
- **Personal dictionary** — a term on its own biases transcription toward that spelling;
  give it a replacement and every transcript gets that substitution.

### How a transcript is processed

```
whisper  →  spoken punctuation  →  LLM cleanup (level)  →  replacements  →  paste
                (deterministic)        (skipped at Raw)      (always win)
```

Replacements run *after* the LLM on purpose, so the model can't undo a substitution you
asked for. Spoken punctuation runs *before* it, so the model sees real sentences rather
than the words "question mark" sitting mid-clause.

### Learning new words

After each dictation, `JargonDetector` looks for a proper noun or product name it hasn't
seen — named entities via NaturalLanguage's on-device tagger, plus casing signals
(`GitHub`, `PyTorch`, `HTTP`). The term is added immediately and a notice takes the
speech bar's place: **「Kubernetes」 added to your dictionary**, with a shrinking bar and
a **No thanks** button. Let it run out and the term stays; decline and it's removed and
never offered again (`declinedJargon`).

Adding first and offering an undo is deliberate — dictation is a flow activity, and a
confirmation prompt mid-flow is a tax.

> This deliberately does **not** use `NSSpellChecker`, which would be the obvious way to
> find "words macOS doesn't know". Its spell service hangs indefinitely in this app's
> context (verified — it blocks even inside a real `NSApplication`), and a hang there
> would freeze the app after every dictation.

## Quiet other audio while dictating

Vendored from [speak-duck](https://github.com/rhklite/speak-duck) as
`DuckEngine.swift` — a Core Audio process tap that either lowers all background audio to
a chosen level or pauses the Now Playing source via MediaRemote, then restores it.

Two changes from the original: everything is gated `@available(macOS 14.4, *)` (the
process-tap API is 14.4+, while 轻语 targets 13 so it still runs on older Intel Macs —
below 14.4 the option is disabled and says why), and 轻语 drives the trigger directly
from its own recording lifecycle instead of sniffing the process list for a dictation app
holding the mic.

Off by default. Requires `NSAudioCaptureUsageDescription`, which is a per-user prompt —
no admin password.

## Menu

Mic icon in the menu bar → status, hotkey hint, and:

- **LLM Cleanup** on/off · **Set Up Text Cleanup…** (probes Ollama, offers to pull the
  model) · **Boost Quiet Audio** on/off · **Mode** (Hold / Toggle / Hold + double-tap
  lock) · **Floating Bar** on/off
- **● Start / ■ Stop Dictation** — only when neither Accessibility nor Input Monitoring
  is granted, i.e. when the push-to-talk key can't work
- **Speech Model ▸** — switch models, with the speed each one gets on this Mac and a `⤓`
  plus size for any not downloaded yet; **Compare Models…** reopens the setup window
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
| `modelChosen` | `false` | set once a model is settled; setup only reopens if none is on disk |
| `cleanupLevel` | `light` | `raw` / `light` / `heavy`; migrated from the old `cleanup` boolean |
| `spokenPunctuation` | `true` | "question mark" → `?` before the LLM sees it |
| `autoJargon` | `true` | learn new proper nouns, with a 10s undo |
| `replacements` | `{}` | literal find → replace, applied after cleanup |
| `declinedJargon` | `[]` | terms refused via the toast; never offered again |
| `duckMode` | `off` | `off` / `lower` / `pause` — other audio while dictating (macOS 14.4+) |
| `duckLevel` | `0.25` | gain for `lower`; `0` mutes |
| `modelsDir` | *(unset)* | where speech models live; unset = `~/.config/qingyu/models`. Setup's "Save to:" writes this. Reverts to the default if the folder is missing or read-only |
| `boostAudio` | `true` | normalize quiet / far-mic audio before transcription |
| `pttKeyCode` | `58` | Left-⌥. 61=Right-⌥, 59=Left-⌃, 62=Right-⌃, 55=Left-⌘ |
| `hotkeyMode` | `hybrid` | `hybrid` (hold + double-tap lock), `hold`, or `toggle` |
| `inputDeviceUID` | *(unset)* | pinned mic UID; unset = system default |
| `showOverlay` | `true` | floating speech bar while dictating |
| `overlayBottomMargin` | `20` | points above the Dock for the floating bar; raise to lift it |
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
                        cleanup, injection, floating bar, permissions, key capture,
                        two-step setup wizard: model chooser + downloader,
                        Ollama probe/pull for the cleanup model, settings
                        window, cleanup levels, spoken punctuation, personal
                        dictionary + jargon toast, audio ducking
Sources/CWhisper/       C-interop module map exposing whisper.h to Swift
Resources/              Info.plist, entitlements, AppIcon.icns, menu-bar PNGs
Resources/icon-source/  icon masters (SVG + iconset) and the design notes
scripts/                build_whisper.sh, build.sh, download_model.sh, setup_signing.sh,
                        makedmg.sh
third_party/whisper.cpp GGML/whisper.cpp source (vendored; build-<arch>/ is gitignored)
```

## Status

Working: transcription verified end-to-end on both architectures (arm64/Metal natively,
x86_64/CPU under Rosetta), universal build, first-run model chooser, local-LLM cleanup, hybrid
push-to-talk with in-app rebinding, mic pinning, floating waveform bar, instant mic
on/off, synthetic-event filtering (ignores injected keystrokes from e.g. mouse
software). Ideas next: streaming/partial results, per-app vocabulary, a preferences
window, notarization for distribution, Parakeet backend.
