# Pinned BG3 Script Extender

`DOS2Combat` reads a character's total AC through `Ext.Entity.GetArmorClass`,
which only the [DOS3 fork of bg3se][fork] provides. A stock Norbyte release does
not have it, so the armour rule would report a missing API at runtime.

`pin.json` names the release that has it. Nothing binary is committed: the
installer downloads the pinned asset and refuses anything whose SHA256 differs.

```json
{
  "repo": "Inexorably/bg3se",
  "tag": "se-0.2.0-dos3",
  "asset": "BG3SE-DWrite.zip",
  "sha256": "52B71B90..."
}
```

## Installing

```powershell
# installs the pinned release
.\scripts\install-script-extender.ps1

# or a file you already have, for a fully offline install
.\scripts\install-script-extender.ps1 -FromPath .\BG3SE-DWrite.zip
```

To install a different release, change `tag` (and `sha256`) in `pin.json`; the
installer reads the build from there and nowhere else.

Either way the payload is validated before anything is copied: it must be a real
PE image and contain the `GetArmorClass` binding. The replaced `DWrite.dll` is
backed up and what was installed is recorded in `bin\ScriptExtender.dos3.json`.
`scripts\install-release.ps1` does this automatically after installing the mods.

## Bumping the pin

Cut a release in the fork (`.github/workflows/release.yml`; push a tag such as
`se-0.2.0-dos3`), then update `pin.json` with the new tag and the SHA256 from the
release's `.sha256` asset. The release workflow already refuses to publish a DLL
that lacks `GetArmorClass`:

```powershell
gh release download se-0.2.0-dos3 -R Inexorably/bg3se -p '*.sha256' -O -
```

| Pinned tag | Built from | Verified |
|------------|------------|----------|
| `se-0.2.0-dos3` | `c913bc99` | checksum matches, `DWrite.dll` contains `GetArmorClass` |

[fork]: https://github.com/Inexorably/bg3se
