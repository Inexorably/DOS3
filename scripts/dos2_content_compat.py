"""Shared DOS2Combat content compatibility rules.

DOS2Combat removes attack rolls, saving throws, bonus actions, concentration,
and spell slots, and converts AC into damage reduction. Native content that
depends on those mechanics stops working. This module is the single source of
truth for:

* which native statuses still make sense for an enemy random buff;
* the deterministic replacement used when a status's native boost is dead;
* which statuses are unsafe or pointless and must never be rolled;
* which native spells must not be granted as random loot.

Both Enemy Randomization generators import this module, and source-level tests
compare it against the runtime tables in ``DOS2Combat/Server/Config.lua`` and
``EnemyRandomization/Server/Config.lua`` so the two layers cannot drift.
"""

from __future__ import annotations

# Statuses whose native payload is only saving-throw or attack-roll text. The
# native token is inert under DOS2Combat, so the generated wrapper (and the
# runtime patcher) replaces the boost with a deterministic DOS2 effect.
STATUS_BOOSTS_REPLACEMENTS = {
    # Charisma-to-saves aura -> flat damage reduction.
    'AURA_OF_PROTECTION': 'AC(2)',
    'AURA_OF_PROTECTION_BUFF': 'AC(2)',
    # -1d4 to attack and saves -> 5% more damage taken.
    'BANE': 'AC(-1)',
    # +1d4 to attack and saves -> +1d4 weapon damage.
    'BLESS': 'CharacterWeaponDamage(1d4)',
    # Attackers have disadvantage -> 15% damage reduction.
    'BLUR': 'AC(3)',
    # Both halves are roll bonuses -> 15% damage reduction.
    'PATIENT_DEFENCE': 'AC(3)',
    # +1d4 to saves -> 10% damage reduction.
    'RESISTANCE': 'AC(2)',
    # Advantage on the next attack -> +1d4 weapon damage.
    'TRUE_STRIKE': 'CharacterWeaponDamage(1d4)',
    # Attackers have disadvantage -> 15% damage reduction.
    'WARDING_FLARE': 'AC(3)',
    # Superiority die on the next attack roll -> the same die as damage.
    'PRECISION_ATTACK': 'CharacterWeaponDamage(LevelMapValue(SuperiorityDie))',
}

# Statuses whose native boost still does something but is missing a component
# that DOS2Combat needs. The extra tokens are appended.
STATUS_BOOSTS_ADDITIONS = {
    # Advantage(AttackTarget) is dead; the invisibility counter still works.
    'FAERIE_FIRE': 'AC(-2)',
    # WeaponAttackRollBonus is dead; keep the enchantment meaningful.
    'MAGIC_WEAPON': 'CharacterWeaponDamage(1)',
    'SACRED_WEAPON': 'CharacterWeaponDamage(1d4,Radiant)',
    # The wrapper cannot copy the native OnApply/Tick functor that applies
    # HEROISM_TEMP_HP, so grant the temporary HP directly.
    'HEROISM': 'TemporaryHP(5)',
}

# Native passives that are safe to copy into a permanent wrapper. Anything that
# reacts to the native status lifecycle (removal, downed state, rage) is
# excluded because the wrapper owns that lifecycle instead.
PERMANENT_PASSIVES = ('ArmorOfAgathys',)

# Statuses whose ally aura should survive into the permanent wrapper. The aura
# itself is a separate native status, so copying it is safe.
PERMANENT_AURA_SOURCES = ('ASPECT_OF_THE_ELK',)

# Functor patterns that only grant resources or healing. They do not reference
# the native status that the wrapper replaces, so they can be copied verbatim.
PERMANENT_FUNCTOR_PATTERNS = ('RegainHitPoints', 'TemporaryHP', 'IncreaseMaxHP')

# Native statuses with no combat payload under DOS2Combat. They are never
# generated as an enemy random buff, and existing saves are scrubbed through
# ``REMOVED_BUFF_STATUSES``.
RETIRED_RANDOM_BUFFS = (
    'ASPECT_OF_THE_WOLF',
    'BLADE_FLOURISH_MOBILE',
    'BULLS_STRENGTH',
    'CATS_GRACE',
    'COMPREHEND_LANGUAGES',
    'DARKVISION',
    'DAYLIGHT',
    'DEATH_WARD',
    'DETECT_EVIL_GOOD',
    'DETECT_THOUGHTS',
    'EAGLES_SPLENDOR',
    'FLAME_BLADE',
    'FOXS_CUNNING',
    'FRIENDS',
    'GUIDANCE',
    'LIGHT',
    'MOBILE_NO_AOO',
    'MULTIATTACKDEFENSE',
    'OWLS_WISDOM',
    'PASS_WITHOUT_TRACE',
    'PATIENT_DEFENCE',
    'PRODUCE_FLAME',
    'RELENTLESS_RAGE',
    'SHILLELAGH',
    'SPEAK_WITH_DEAD',
    'UNDEAD_FORTITUDE',
    'VAMPIRE_REGENERATION',
)

# Combat-relevant buffs that still produce a DOS2 effect, either natively or
# through the replacement/addition tables above.
VALID_RANDOM_BUFFS = (
    'AID',
    'ARMOR_OF_AGATHYS',
    'ASPECT_OF_THE_ELK',
    'AURA_OF_COURAGE_BUFF',
    'AURA_OF_DEVOTION_BUFF',
    'AURA_OF_PROTECTION_BUFF',
    'AURA_OF_WARDING_BUFF',
    'BARKSKIN',
    'BEACON_OF_HOPE',
    'BEARS_ENDURANCE',
    'BLADE_FLOURISH_DEFENSIVE',
    'BLADE_WARD',
    'BLESS',
    'BLUR',
    'CALM_EMOTIONS',
    'CRYSTALSKIN',
    'DARK_ONES_BLESSING',
    'DIVINE_FAVOR',
    'DRUNKEN_TECHNIQUE',
    'EXPEDITIOUS_RETREAT',
    'FALSE_LIFE',
    'FEATHER_FALL',
    'FLY',
    'FREEDOM_OF_MOVEMENT',
    'HASTE',
    'HEROES_FEAST',
    'HEROISM',
    'INSPIRING_LEADER',
    'LONG_JUMP',
    'LONGSTRIDER',
    'MAGE_ARMOR',
    'MAGIC_WEAPON',
    'MIRROR_IMAGE_1',
    'MIRROR_IMAGE_2',
    'MIRROR_IMAGE_3',
    'PROTECTION_FROM_ENERGY_ACID',
    'PROTECTION_FROM_ENERGY_COLD',
    'PROTECTION_FROM_ENERGY_FIRE',
    'PROTECTION_FROM_ENERGY_LIGHTNING',
    'PROTECTION_FROM_ENERGY_THUNDER',
    'PROTECTION_FROM_EVIL_AND_GOOD',
    'PROTECTION_FROM_POISON',
    'RALLY',
    'REFLECTIVE_SHELL',
    'RESISTANCE',
    'RESISTANCE_ACID',
    'RESISTANCE_COLD',
    'RESISTANCE_FIRE',
    'RESISTANCE_FORCE',
    'RESISTANCE_LIGHTNING',
    'RESISTANCE_NECROTIC',
    'RESISTANCE_POISON',
    'RESISTANCE_PSYCHIC',
    'RESISTANCE_RADIANT',
    'RESISTANCE_THUNDER',
    'SACRED_WEAPON',
    'SHIELD',
    'SHIELD_OF_FAITH',
    'STONESKIN',
    'TRUE_STRIKE',
    'VAMPIRIC_TOUCH',
    'WARDING_FLARE',
)

# Utility and exploration conditions. They do nothing in combat but are valid
# on equipment, so the loot catalog keeps them out of the enemy buff pool.
UTILITY_CONDITIONS = (
    'ALCH_ELIXIR_ENLARGE',
    'ASPECT_OF_THE_WOLF',
    'BULLS_STRENGTH',
    'CATS_GRACE',
    'COMPREHEND_LANGUAGES',
    'DARKVISION',
    'DAYLIGHT',
    'DETECT_EVIL_GOOD',
    'DETECT_THOUGHTS',
    'EAGLES_SPLENDOR',
    'FEATHER_FALL',
    'FLY',
    'FOXS_CUNNING',
    'GUIDANCE',
    'LIGHT',
    'LONGSTRIDER',
    'OWLS_WISDOM',
    'PASS_WITHOUT_TRACE',
    'PRODUCE_FLAME',
    'SPEAK_WITH_DEAD',
)

# Equipment-only conditions that are safe to apply while an item is equipped
# but are not part of the enemy buff pool.
ITEM_CONDITIONS = (
    'RAGE',
    'SANCTUARY',
    'VAMPIRIC_TOUCH',
    'VAMPIRE_REGENERATION',
)

# Conditions that must never be applied by loot: not positive, not usable, or
# already broken by the rules layer with no DOS2 replacement.
UNUSABLE_CONDITIONS = (
    'ASPECT_OF_THE_STALLION',
    'DEATH_WARD',
    'FRIENDS',
    'MOBILE_NO_AOO',
    'MULTIATTACKDEFENSE',
    'PATIENT_DEFENCE',
    'RELENTLESS_RAGE',
    'UNDEAD_FORTITUDE',
)

VALID_LOOT_CONDITIONS = tuple(sorted(
    (set(VALID_RANDOM_BUFFS) | set(UTILITY_CONDITIONS) | set(ITEM_CONDITIONS))
    - set(UNUSABLE_CONDITIONS)
))


def status_boosts(name: str, native: str, *, allow_empty: bool = False) -> str:
    """Return the Boosts value a wrapper should carry for ``name``.

    A replacement wins over the native text because the native text is exactly
    what stopped working. Additions are appended to the native text.
    """
    replacement = STATUS_BOOSTS_REPLACEMENTS.get(name)
    if replacement is not None:
        return replacement
    native = (native or '').strip()
    addition = STATUS_BOOSTS_ADDITIONS.get(name)
    if addition:
        return (native + ';' + addition) if native else addition
    if not native and not allow_empty:
        return ''
    return native


def is_retired_buff(name: str) -> bool:
    return name in RETIRED_RANDOM_BUFFS


def is_valid_loot_condition(name: str) -> bool:
    return name in VALID_LOOT_CONDITIONS


def keeps_passive(name: str) -> bool:
    return name in PERMANENT_PASSIVES


def copies_aura(name: str) -> bool:
    return name in PERMANENT_AURA_SOURCES


def keeps_functor(text: str) -> bool:
    """True when a native functor is safe to copy into a permanent wrapper."""
    if not text:
        return False
    return any(pattern in text for pattern in PERMANENT_FUNCTOR_PATTERNS)


def permanent_wrapper_fields(name: str, native: dict) -> list[tuple[str, str]]:
    """Return the extra status fields a permanent wrapper should carry.

    ``native`` is the parsed StatusData field map. Only fields that cannot
    reference the replaced native status are returned.
    """
    fields: list[tuple[str, str]] = []
    passives = [
        item for item in (native.get('Passives') or '').split(';')
        if item.strip() and keeps_passive(item.strip())
    ]
    if passives:
        fields.append(('Passives', ';'.join(passives)))
    if copies_aura(name):
        radius = (native.get('AuraRadius') or '').strip()
        statuses = (native.get('AuraStatuses') or '').strip()
        if radius and statuses:
            fields.append(('AuraRadius', radius))
            fields.append(('AuraStatuses', statuses))
    for field in ('OnApplyFunctors', 'TickFunctors'):
        value = (native.get(field) or '').strip()
        if value and keeps_functor(value):
            fields.append((field, value))
    return fields


# ---------------------------------------------------------------------------
# Loot spells
# ---------------------------------------------------------------------------

# Spells that only reference a mechanic DOS2Combat removes and that have no
# deterministic replacement. They are excluded from the random loot catalog so
# a rolled item never grants an unusable hotbar entry.
UNUSABLE_LOOT_SPELLS = frozenset({
    'Target_BardicInspiration',
    'Target_CuttingWords',
    'Target_FlurryOfBlows',
    'Target_PatientDefense',
    'Target_RecklessAttack',
    'Target_Riposte',
    'Target_StepOfTheWind',
    'Target_StunningStrike',
    'Target_WardingFlare',
})
