#!/usr/bin/env python3
"""Reads the balance harness CSVs and reports the design doc's tuning targets.

Usage: python3 tools/analyze_balance.py balance_out/
Standard library only, so it runs anywhere Python 3 does.
"""
import csv
import sys
from collections import Counter, defaultdict
from pathlib import Path

TARGETS = [
    "About 40% of seasons end with less than one season of upkeep in the bank.",
    "Betrayal pays 1.5-2x in the short term but costs roughly two pennant tiers of future access.",
    "A run with zero betrayals is winnable on normal difficulty.",
    "First-run win rate 10-20%; experienced players above 50%.",
]


def load(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def main(out_dir):
    out = Path(out_dir)
    runs = load(out / "runs.csv")
    seasons = load(out / "seasons.csv")
    by_policy = defaultdict(list)
    for r in runs:
        by_policy[r["policy"]].append(r)
    season_by_policy = defaultdict(list)
    for s in seasons:
        season_by_policy[s["policy"]].append(s)

    print("Tuning targets (design doc):")
    for t in TARGETS:
        print("  -", t)
    print()
    header = f"{'policy':<10}{'runs':>6}{'win%':>7}{'lowbank%':>10}{'pennants':>10}{'maxtier':>9}{'betray':>8}{'income/s':>10}"
    print(header)
    print("-" * len(header))
    for policy, rs in sorted(by_policy.items()):
        n = len(rs)
        wins = sum(int(r["won"]) for r in rs)
        ss = season_by_policy[policy]
        low = sum(int(s["low_bank"]) for s in ss) / max(len(ss), 1)
        pen = sum(int(r["pennants"]) for r in rs) / n
        tier = sum(int(r["max_tier"]) for r in rs) / n
        bet = sum(int(r["betrayals"]) for r in rs) / n
        inc = sum(int(r["income"]) / max(int(r["seasons"]), 1) for r in rs) / n
        print(f"{policy:<10}{n:>6}{100 * wins / n:>6.1f}%{100 * low:>9.1f}%{pen:>10.1f}{tier:>9.2f}{bet:>8.2f}{inc:>10.0f}")
    print()
    for policy, rs in sorted(by_policy.items()):
        endings = Counter(r["ending"] for r in rs)
        print(f"{policy} endings: " + ", ".join(f"{k} {v}" for k, v in endings.most_common()))
    # Pennants over time, honest vs betrayer.
    print("\nAverage pennants by year:")
    years = sorted({int(s["year"]) for s in seasons})
    print("year    " + "".join(f"{p:>10}" for p in sorted(season_by_policy)))
    for y in years:
        row = f"{y:<8}"
        for p in sorted(season_by_policy):
            vals = [int(s["pennants"]) for s in season_by_policy[p] if int(s["year"]) == y]
            row += f"{(sum(vals) / len(vals)) if vals else 0:>10.1f}"
        print(row)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "balance_out")
