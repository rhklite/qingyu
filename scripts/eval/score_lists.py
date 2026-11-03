#!/usr/bin/env python3
"""Score the list pass (qingyu-eval --lists) against what Wispr Flow did.

- caught: share of Wispr's lists that came out as a list
- false lists: share of prose dictations that came out as a list
- check said yes: the first step alone; "yes but rejected" = the rewrite failed the
  drift / item-count guard, so the dictation was kept as spoken
- check time: what every dictation of listMinWords or more pays

Usage: python3 -I scripts/eval/score_lists.py [LISTS_OUT_JSONL]
"""
import json
import os
import sys


def pct(n, d):
    return 100.0 * n / d if d else float("nan")


def main():
    path = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.config/qingyu/eval/lists-out.jsonl")
    rows = [json.loads(line) for line in open(path)]
    for kind, label in (("list", "caught"), ("prose", "false lists")):
        g = [r for r in rows if r["kind"] == kind]
        yes = [r for r in g if r["yes"]]
        listed = [r for r in g if r["listed"]]
        check = sorted(r["check_secs"] for r in g)
        total = sorted(r["secs"] for r in yes) or [float("nan")]
        print(f"{kind:6} n={len(g):3d}  {label} {pct(len(listed), len(g)):5.1f}%  "
              f"check said yes {pct(len(yes), len(g)):5.1f}%  yes but rejected {len(yes) - len(listed):3d}  "
              f"check {check[len(check) // 2]:.2f}s (p90 {check[int(0.9 * (len(check) - 1))]:.2f}s)  "
              f"check+rewrite {total[len(total) // 2]:.2f}s")


if __name__ == "__main__":
    main()
