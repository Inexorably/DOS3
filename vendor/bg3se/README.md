# Pinned BG3 Script Extender (optional)

`scripts/install-script-extender.ps1` installs the Script Extender build that
`DOS2Combat` needs. It needs `Ext.Entity.GetArmorClass`, which only exists in
the build published from the [DOS3 fork of bg3se][fork]; a stock Norbyte
release does not have it.

Put a package here to make a checkout self-contained, so cloning DOS3 and
running the installer needs no release download. This folder is tracked (unlike
`tools/`, which is gitignored), so a committed package reaches every clone:

| File | Accepted |
|------|----------|
| `BG3SE-DWrite.zip` | the fork's release asset (offline package containing `DWrite.dll`) |
| `DWrite.dll` | an already-extracted extender DLL |

The installer picks the newest `.zip`/`.dll` in this folder and validates it
before installing:

- it must be a real PE image (not an HTML error page saved as a zip)
- it must contain the `GetArmorClass` binding

A package that fails either check is rejected, so this folder cannot silently
pin a stock extender that would make the armour rule report a missing API.

## Where the package comes from

Cut a release in the fork (`.github/workflows/release.yml`, `workflow_dispatch`,
tag such as `se-1.0.0-dos3`), then either

```powershell
# download straight from the release
.\scripts\install-script-extender.ps1 -Tag se-1.0.0-dos3

# or pin it in the checkout first
Invoke-WebRequest -OutFile vendor\bg3se\BG3SE-DWrite.zip `
  https://github.com/Inexorably/bg3se/releases/download/se-1.0.0-dos3/BG3SE-DWrite.zip
```

Record the tag and SHA256 you pinned here so the provenance is auditable:

| Pinned tag | SHA256 | Date |
|------------|--------|------|
| `se-0.1.0-dos3` | `57E223D90F22C0E7431ED50860EEEF5274A2AB3DC8ECED034B1F4B8AE3CE3500` | 2026-11-01 |

`BG3SE-DWrite.zip` in this folder is that release asset. It was built by
Inexorably/bg3se CI (`windows-latest`, MSVC) from commit `4e5c5777`, and its
`DWrite.dll` was verified to contain the `GetArmorClass` binding.

[fork]: https://github.com/Inexorably/bg3se
