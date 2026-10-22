#!/usr/bin/env python3
"""List BG3 spells with native cooldown/recharge limits and their numeric turns.

This is an audit helper for the enemy/NPC cooldown conversion. It reads the
extracted BG3 stats under .analysis/bg3/Public/Shared/Stats/Generated/Data.

Usage:
    python scripts/audit-enemy-cooldowns.py
    python scripts/audit-enemy-cooldowns.py --json
"""
import argparse
import glob
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATS = os.path.join(
    ROOT, ".analysis", "bg3", "Public", "Shared", "Stats", "Generated", "Data"
)

COOLDOWN_TURNS = {
    "OncePerTurn": 1,
    "OncePerTurnNoRealtime": 1,
    "OncePerShortRest": 3,
    "OncePerShortRestPerItem": 3,
    "UntilShortRest": 3,
    "OncePerCombat": 5,
    "OncePerRest": 5,
    "OncePerRestPerItem": 5,
    "UntilRest": 5,
}


def recharge_turns(value):
    if not value:
        return None
    match = re.match(r"^\s*(\d+)\s*-\s*(\d+)\s*$", value)
    if match:
        return max(1, round((int(match.group(1)) + int(match.group(2))) / 2))
    match = re.match(r"^\s*(\d+)\s*$", value)
    if match:
        return max(1, int(match.group(1)))
    return None


def read_entries():
    rows = []
    for path in sorted(glob.glob(os.path.join(STATS, "Spell_*.txt"))):
        lines = open(path, encoding="utf-8-sig", errors="replace").read().splitlines()
        for index, line in enumerate(lines):
            match = re.match(r'new entry "([^"]+)"', line)
            if not match:
                continue
            fields = {}
            for candidate in lines[index + 1:index + 50]:
                if candidate.startswith("new entry"):
                    break
                field = re.match(r'data "([^"]+)" "([^"]*)"', candidate)
                if field:
                    fields[field.group(1)] = field.group(2)
            cooldown = fields.get("Cooldown", "")
            recharge = fields.get("RechargeValues", "")
            if not cooldown and not recharge:
                continue
            cooldown_turns = COOLDOWN_TURNS.get(cooldown)
            recharge_t = recharge_turns(recharge)
            if cooldown_turns is not None and recharge_t is not None:
                turns = max(cooldown_turns, recharge_t)
            elif cooldown_turns is not None:
                turns = cooldown_turns
            else:
                turns = recharge_t
            rows.append({
                "spell": match.group(1),
                "source": os.path.basename(path),
                "cooldown": cooldown,
                "recharge": recharge,
                "turns": turns,
            })
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    rows = read_entries()
    if args.json:
        print(json.dumps(rows, indent=2))
        return

    print(f"{'spell':55} {'cooldown':22} {'recharge':8} turns")
    print("-" * 95)
    for row in rows:
        print(
            f"{row['spell']:55} {row['cooldown'] or '-':22} "
            f"{row['recharge'] or '-':8} {row['turns'] if row['turns'] is not None else '-'}"
        )
    from collections import Counter

    counts = Counter(row["turns"] for row in rows if row["turns"] is not None)
    summary = ", ".join(f"{turn}:{counts[turn]}" for turn in sorted(counts))
    print(f"\n{len(rows)} spells with native cooldown/recharge limits")
    print(f"numeric turns: {summary}")


if __name__ == "__main__":
    main()
