#!/usr/bin/env python3
"""Score Tools/eval output: error rate per decoder setting, overall and per language.

Tokens are English words and individual Chinese characters, so one number covers
mixed Chinese/English dictation (word error rate for English, character error rate
for Chinese). Case, punctuation and filler sounds are ignored on both sides: the
reference is Wispr's transcript, which formats differently from raw whisper.

Usage: python3 -I scripts/eval/score.py [HYPS_JSONL]
"""
import json
import os
import re
import sys
from collections import defaultdict

TOKEN = re.compile(r"[㐀-䶿一-鿿]|[a-z0-9]+(?:'[a-z]+)?")
FILLERS = {"um", "uh", "erm", "hmm", "mm", "mhm", "ah", "嗯", "呃", "啊"}


def tokens(text):
    return [t for t in TOKEN.findall(text.lower()) if t not in FILLERS]


def edits(ref, hyp):
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def main():
    path = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.config/qingyu/eval/hyps.jsonl")
    stats = defaultdict(lambda: defaultdict(lambda: [0, 0]))   # setting -> group -> [errors, ref tokens]
    secs = defaultdict(list)
    runaway = defaultdict(int)                                   # output far longer than speech
    order = []
    for line in open(path):
        row = json.loads(line)
        s = row["setting"]
        if s not in order:
            order.append(s)
        ref, hyp = tokens(row["ref"]), tokens(row["hyp"])
        e = edits(ref, hyp)
        for group in ("all", row["lang"]):
            stats[s][group][0] += e
            stats[s][group][1] += len(ref)
        secs[s].append(row["secs"])
        if len(hyp) > 1.5 * len(ref) + 3:
            runaway[s] += 1

    def rate(s, g):
        e, n = stats[s][g]
        return 100.0 * e / n if n else float("nan")

    base = order[0]
    print(f"{'setting':34} {'all':>6} {'en':>6} {'zh':>6} {'vs ' + base:>10} {'s/clip':>7} {'p90':>6} {'runaway':>7}")
    for s in order:
        t = sorted(secs[s])
        p90 = t[int(0.9 * (len(t) - 1))]
        delta = rate(s, "all") - rate(base, "all")
        print(f"{s:34} {rate(s, 'all'):6.2f} {rate(s, 'en'):6.2f} {rate(s, 'zh'):6.2f} "
              f"{delta:+10.2f} {sum(t) / len(t):7.2f} {p90:6.2f} {runaway[s]:7d}")


if __name__ == "__main__":
    main()
