# DOS2 Combat Overhaul TODO

## Spell cooldowns

- [x] Spells that recharge on a **short rest** get a **3-turn cooldown**.
- [x] Spells that recharge on a **long rest** get a **5-turn cooldown**.
- [x] Numeric cooldowns for spells that previously relied on spell slots or
      at-will casting, balanced against the DOS2 3/4/5/6-turn distribution and
      the higher BG3 damage-to-HP ratio.
- [ ] Replace the temporary `UntilShortRest` native cooldown stamp with a true
      numeric cooldown display once the native cooldown component is verified.

## Surfaces

- [x] Turn-start DOS2-style surface status/damage tick (fire, poison, acid,
      water, electrified water, ice, oil, webs/vines, clouds).
- [ ] Port DOS2 surface combination rules that BG3 does not already handle.
- [ ] Add DOS2 surface-specific VFX/decals where BG3 has no equivalent.
- [ ] Tune surface damage after in-game testing.

## Movement AP

- [ ] DOS2 movement costs **1 AP per 5 units of distance**.
- [ ] Bridge BG3's native `Movement` resource to `ActionPoint`; currently
      movement does not consume AP (`MOVEMENT_AP_ENABLED = false`), so this is
      unimplemented rather than bugged.
- [ ] Decide how to handle fractional distance/AP and prevent movement once AP
      is exhausted.
