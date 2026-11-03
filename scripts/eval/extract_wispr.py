#!/usr/bin/env python3
"""Build an accuracy test set from Wispr Flow's local history.

Wispr keeps the audio of recent dictations next to its own transcript and the text
that was before the cursor. That gives real utterances, from this user's mic, with a
reference transcript and the screen context at the time - exactly what's needed to
compare decoding settings.

Reads Wispr's database read-only. Writes WAV clips and a manifest.jsonl into OUT_DIR
(default ~/.config/qingyu/eval). The clips are private recordings: keep OUT_DIR out of
the repo.

Usage: python3 -I scripts/eval/extract_wispr.py [OUT_DIR]
"""
import json
import os
import sqlite3
import sys

WISPR_DB = os.path.expanduser("~/Library/Application Support/Wispr Flow/flow.sqlite")
LANGS = {"en": "en", "zhcn": "zh", "zh": "zh"}


def main():
    out_dir = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.config/qingyu/eval")
    clips_dir = os.path.join(out_dir, "clips")
    os.makedirs(clips_dir, exist_ok=True)

    db = sqlite3.connect(f"file:{WISPR_DB}?mode=ro", uri=True)
    rows = db.execute(
        """SELECT transcriptEntityId, audio, asrText, formattedText, duration,
                  coalesce(detectedLanguage, language), additionalContext, app
           FROM History
           WHERE audio IS NOT NULL AND length(audio) > 0
             AND coalesce(asrText, '') != ''
           ORDER BY timestamp"""
    ).fetchall()

    kept = 0
    with open(os.path.join(out_dir, "manifest.jsonl"), "w") as manifest:
        for clip_id, audio, asr, formatted, duration, lang, extra, app in rows:
            lang = LANGS.get(lang or "", "")
            if not lang:
                continue
            # Wispr writes 16 kHz mono 16-bit PCM WAV; anything else would need resampling.
            if audio[:4] != b"RIFF" or audio[22:24] != b"\x01\x00" or audio[24:28] != (16000).to_bytes(4, "little"):
                continue
            before = ""
            try:
                box = (json.loads(extra or "{}") or {}).get("textbox_contents") or {}
                before = box.get("beforeText") or ""
            except (ValueError, AttributeError):
                pass
            wav = os.path.join(clips_dir, f"{clip_id}.wav")
            with open(wav, "wb") as f:
                f.write(audio)
            manifest.write(json.dumps({
                "id": clip_id, "wav": wav, "ref": asr.strip(), "formatted": (formatted or "").strip(),
                "lang": lang, "before_text": before, "duration": duration, "app": app,
            }, ensure_ascii=False) + "\n")
            kept += 1
    print(f"{kept} clips -> {out_dir}")


if __name__ == "__main__":
    main()
