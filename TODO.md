# DOS2 Combat Overhaul TODO

## Spell cooldowns

- [ ] Spells that recharge on a **short rest** should get a **3-turn cooldown**.
- [ ] Spells that recharge on a **long rest** should get a **5-turn cooldown**.
- [ ] Apply the cooldown after the spell resolves and clear it on the matching rest.

## Movement AP

- [ ] DOS2 movement costs **1 AP per 5 units of distance**.
- [ ] Bridge BG3's native `Movement` resource to `ActionPoint`; currently movement does not consume AP (`MOVEMENT_AP_ENABLED = false`), so this is unimplemented rather than bugged.
- [ ] Decide how to handle fractional distance/AP and prevent movement once AP is exhausted.
