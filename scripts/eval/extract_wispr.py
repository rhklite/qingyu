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
    extract_lists(db, out_dir)


def extract_lists(db, out_dir, negatives=200, min_words=12):
    """Text-only set for list formatting: every dictation Wispr turned into a list
    (its formatted output has <ol>/<ul>), plus a seeded sample of comparably long ones
    it left as prose. The input is Wispr's raw transcript."""
    import random

    rows = db.execute(
        """SELECT transcriptEntityId, asrText, formattedText FROM History
           WHERE coalesce(asrText, '') != '' AND coalesce(formattedText, '') != ''
           ORDER BY timestamp"""
    ).fetchall()
    pos = [r for r in rows if "<ol>" in r[2] or "<ul>" in r[2]]
    prose = [r for r in rows if r not in pos and len(r[1].split()) >= min_words]
    neg = random.Random(0).sample(prose, min(negatives, len(prose)))
    with open(os.path.join(out_dir, "lists.jsonl"), "w") as f:
        for kind, group in (("list", pos), ("prose", neg)):
            for clip_id, asr, formatted in group:
                f.write(json.dumps({"id": clip_id, "kind": kind, "text": asr.strip(),
                                    "wispr": formatted.strip()}, ensure_ascii=False) + "\n")
    print(f"{len(pos)} list + {len(neg)} prose dictations -> {out_dir}/lists.jsonl")


if __name__ == "__main__":
    main()
