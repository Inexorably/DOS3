"""Generate data used to scale spells granted by Enemy Randomization champions.

The expected-access table uses the 95th-percentile native damage-spell level
observed at each enemy level, capped by BG3's normal full-caster spell-slot
progression. Story/boss templates carry arbitrary high-level abilities, so raw
maxima are not used. The damage curve comes from native SpellData damage dice
and is made monotonic so a lower-level spell cannot accidentally exceed a
higher-level one.
"""

from __future__ import annotations

import glob
import re
import statistics
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = (
    ROOT
    / "mods"
    / "EnemyRandomization"
    / "Mods"
    / "EnemyRandomization"
    / "ScriptExtender"
    / "Lua"
    / "Server"
    / "GeneratedSpellScaling.lua"
)

MAX_LEVEL = 6
DICE = re.compile(r"(\d*)d(\d+)")
ENTRY = re.compile(r'new entry "([^"]+)"\n(.*?)(?=\nnew entry |\Z)', re.S)
LEVEL_RE = re.compile(r'\ndata "Level" "([^"]*)"')
DAMAGE_FIELD_RE = re.compile(
    r'\ndata "(?:TooltipDamageList|SpellSuccess|SpellProperties)" "([^"]*)"'
)


def _stat_files(pattern: str) -> list[Path]:
    base = ROOT / ".analysis" / "allstats" / "Public"
    return [Path(path) for path in glob.glob(str(base / "*" / "Stats" / "Generated" / "Data" / pattern))]


def native_damage_curve() -> dict[int, float]:
    values: dict[int, list[float]] = {}
    for path in _stat_files("Spell_*.txt"):
        text = path.read_text(errors="ignore")
        for match in ENTRY.finditer(text):
            body = match.group(2)
            level_match = LEVEL_RE.search(body)
            if not level_match or not level_match.group(1).strip().isdigit():
                continue
            level = int(level_match.group(1))
            if level < 0 or level > MAX_LEVEL:
                continue
            for field in DAMAGE_FIELD_RE.finditer(body):
                for call in re.finditer(r"DealDamage\(([^,)]+)", field.group(1)):
                    dice = DICE.findall(call.group(1))
                    if not dice:
                        continue
                    total = sum(
                        (int(count or 1) * (int(sides) + 1)) / 2
                        for count, sides in dice
                    )
                    if total > 0:
                        values.setdefault(level, []).append(total)

    curve: dict[int, float] = {}
    previous = 1.0
    for level in range(0, MAX_LEVEL + 1):
        candidates = values.get(level)
        raw = statistics.median(candidates) if candidates else previous
        raw = max(previous, raw, 1.0)
        curve[level] = raw
        previous = raw
    return curve


def native_spell_access() -> dict[int, int]:
    """95th-percentile native damage-spell level observed at each enemy level."""
    spell_levels: dict[str, int] = {}
    damage_spells: set[str] = set()
    for path in _stat_files("Spell_*.txt"):
        text = path.read_text(errors="ignore")
        for match in ENTRY.finditer(text):
            name, body = match.group(1), match.group(2)
            level_match = LEVEL_RE.search(body)
            if not level_match or not level_match.group(1).strip().isdigit():
                continue
            spell_levels.setdefault(name, int(level_match.group(1)))
            if any("DealDamage" in value and DICE.search(value) for value in DAMAGE_FIELD_RE.findall(body)):
                damage_spells.add(name)

    char_levels: dict[str, int] = {}
    for path in _stat_files("Character.txt"):
        text = path.read_text(errors="ignore")
        for match in ENTRY.finditer(text):
            level_match = LEVEL_RE.search(match.group(2))
            if level_match and level_match.group(1).strip().isdigit():
                char_levels.setdefault(match.group(1), int(level_match.group(1)))

    observed: dict[int, list[int]] = {}
    root_paths: list[str] = glob.glob(
        str(ROOT / ".analysis" / "rootsshared" / "Public" / "Shared" / "RootTemplates" / "_merged.lsx")
    )
    root_paths += glob.glob(
        str(ROOT / ".analysis" / "roots" / "Public" / "SharedDev" / "RootTemplates" / "_merged.lsx")
    )
    for root_path in root_paths:
        root = ET.parse(root_path).getroot()
        for game_object in root.findall('.//node[@id="GameObjects"]'):
            attrs = {attr.get("id"): attr.get("value") for attr in game_object.findall("attribute")}
            stats_id = attrs.get("Stats") or ""
            level = attrs.get("LevelOverride") or char_levels.get(stats_id)
            if not level or not str(level).strip().isdigit():
                continue
            level = int(float(level))
            if level <= 0:
                continue
            for skill in game_object.findall('.//node[@id="Skill"]'):
                skill_attrs = {attr.get("id"): attr.get("value") for attr in skill.findall("attribute")}
                spell = skill_attrs.get("Skill")
                if spell in damage_spells:
                    observed.setdefault(level, []).append(spell_levels[spell])

    result: dict[int, int] = {}
    for level, values in observed.items():
        values.sort()
        result[level] = values[int((len(values) - 1) * 0.95)]
    return result


def progression_cap(level: int) -> int:
    # BG3 full-caster slot progression: 1/1, 2/2, 3/3, 4/4, 5/5, 6/6 at
    # the spell-slot breakpoints 1, 3, 5, 7, 9, and 11.
    return min(MAX_LEVEL, max(1, (level + 1) // 2))


def expected_max_level(level: int, native: dict[int, int]) -> int:
    known = sorted(native)
    if not known:
        return progression_cap(level)
    if level in native:
        value = native[level]
    elif level <= known[0]:
        value = native[known[0]]
    elif level >= known[-1]:
        value = native[known[-1]]
    else:
        lower = max(candidate for candidate in known if candidate < level)
        upper = min(candidate for candidate in known if candidate > level)
        ratio = (level - lower) / (upper - lower)
        value = round(native[lower] + (native[upper] - native[lower]) * ratio)
    return min(progression_cap(level), max(1, value))


def main() -> None:
    curve = native_damage_curve()
    native = native_spell_access()
    expected: dict[int, int] = {}
    previous = 1
    for level in range(1, 21):
        value = max(previous, expected_max_level(level, native))
        expected[level] = value
        previous = value

    lines = [
        "-- Generated by scripts/generate-enr-spell-scaling.py. Do not edit by hand.",
        "-- expectedMaxByLevel: native enemy 95th-percentile damage-spell level,",
        "-- capped by BG3 full-caster spell-slot progression and made monotonic.",
        "-- damageByLevel: native SpellData damage dice by spell level.",
        "",
        "ER = ER or {}",
        "ER.SpellScaling = {",
        "    expectedMaxByLevel = {",
    ]
    for level in range(1, 21):
        lines.append("        [%d] = %d," % (level, expected[level]))
    lines += [
        "    },",
        "    damageByLevel = {",
    ]
    for level in range(0, MAX_LEVEL + 1):
        lines.append("        [%d] = %.3f," % (level, curve[level]))
    lines += [
        "    },",
        "    maxSpellLevel = %d," % MAX_LEVEL,
        "    nativeP95ByLevel = {",
    ]
    for level in sorted(native):
        lines.append("        [%d] = %d," % (level, native[level]))
    lines += [
        "    },",
        "}",
        "",
    ]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print("wrote %s" % OUT)
    print("native p95:", native)
    print("expected levels:", expected)
    print("damage curve:", {k: round(v, 2) for k, v in curve.items()})


if __name__ == "__main__":
    main()
