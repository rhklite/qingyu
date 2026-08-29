轻语 (Qingyu) — on-device push-to-talk dictation for macOS
==========================================================

Runs on any Mac with macOS 13 or later — Apple Silicon (M1 or newer) or Intel.
Everything runs locally; the speech model is downloaded once on first launch,
and nothing you say is ever uploaded.

INSTALL
-------
1. Drag 轻语 onto the Applications folder in this window.
2. Open Applications and double-click 轻语.

If dragging into Applications asks for a password you don't have, drop it into
the Applications folder inside your Home folder instead (Finder > Go > Home,
make an "Applications" folder if there isn't one). 轻语 runs identically there.

CHOOSING A SPEECH MODEL  (needs internet, once)
-----------------------------------------------
On first launch 轻语 asks which of two speech models to use, showing how fast
each one is on YOUR Mac, then downloads it (about 550 MB) with a progress bar.
After that 轻语 never needs the internet again.

"Save to:" on that screen lets you put the model somewhere other than your
home folder — an external drive, for instance. No password needed.

You can change models any time from the menu-bar icon > Speech Model.

  - Apple Silicon: transcription runs on the GPU. Both models finish in well
    under a second, so just take Turbo, the more accurate one.

  - Intel: there is no GPU path (whisper's Metal kernels need an Apple-family
    GPU), so transcription runs on the CPU and takes a few seconds per
    sentence. Medium is the suggested default because it's meaningfully
    faster; pick Turbo if you dictate Chinese/Japanese or lots of names and
    would rather wait than correct.

FIRST LAUNCH — macOS WILL BLOCK IT ONCE
---------------------------------------
This app is signed with a personal certificate, not an Apple Developer ID, so
macOS refuses the first launch ("cannot be opened because the developer cannot
be verified", or "damaged").

  - Double-click 轻语 once and dismiss the warning.
  - Open System Settings > Privacy & Security, scroll to Security,
    and click "Open Anyway" next to 轻语. Confirm with "Open".

If macOS says "damaged", open Terminal and run this once, then launch again:

  xattr -dr com.apple.quarantine /Applications/轻语.app

PERMISSIONS  (setup walks you through this — nothing here blocks you)
---------------------------------------------------------------------
  - Microphone         — to hear you.        Simple yes/no prompt, no password.
  - Accessibility      — to paste for you.   Needs an ADMIN password.
  - Input Monitoring   — the push-to-talk key. Needs an ADMIN password.

The last two are stored system-wide by macOS, so System Settings asks for an
administrator password. If this Mac isn't yours to administer, just skip them.

WITHOUT THOSE TWO, 轻语 STILL WORKS:
  - Start and stop dictation from the menu-bar icon instead of the ⌥ key.
  - The transcript lands on your clipboard; paste it yourself with ⌘V.

The menu-bar icon's "Permissions" submenu shows live checkmarks and jumps
straight to the right settings pane if you get admin access later.

SETTINGS
--------
Menu-bar icon > "Open Settings..." opens a small panel where you can set:

  - Cleanup: Raw (exactly what you said), Light (drops "um"/"uh", fixes
    punctuation), or Heavy (also tightens into proper written grammar).
  - Spoken punctuation: say "question mark" and get "?".
  - Personal dictionary: words to spell your way, and find/replace pairs.
  - While dictating: leave other audio alone, lower it, or pause it
    (needs macOS 14.4 or later).

New names you use get added to the dictionary automatically - a notice
appears with a 10-second countdown and a "No thanks" button if you'd
rather it didn't.

USING IT
--------
轻语 lives in the menu bar (no Dock icon or window).

  - Hold Left Option, speak, release — the text is pasted where you're typing.
  - Double-tap Left Option to lock it hands-free; tap again to stop.
  - Change the key, language, microphone, and sounds from the menu-bar icon.

English and Chinese are auto-detected by default.

TEXT CLEANUP (optional — skip it if you have no admin password)
---------------------------------------------------------------
Setup also offers an optional tidy-up pass: a small language model that drops
"um"/"uh", fixes punctuation, and respects your custom words. It needs Ollama
(a separate free app). If Ollama is already running, 轻语 offers to download
the model for you — that part needs no password. If Ollama isn't installed,
installing it does need an administrator password, so just skip this step.

Skipping is completely fine — you get whisper's raw transcript, which is what
most people want out of the box. Turn it on later from the menu bar:
"Set Up Text Cleanup…".

TO UNINSTALL
------------
Drag /Applications/轻语.app to the Trash and delete ~/.config/qingyu.
