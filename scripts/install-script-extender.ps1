#Requires -Version 5.1
<#
.SYNOPSIS
    Install the BG3 Script Extender build that DOS3 needs.

.DESCRIPTION
    DOS2Combat reads a character's total AC through Ext.Entity.GetArmorClass,
    which only exists in the Script Extender build published from the DOS3 fork
    (Inexorably/bg3se). A stock Norbyte BG3SE does not have that API, so the
    armour rule would report "GetArmorClass is missing" at runtime.

    This script puts a known-good DWrite.dll into the game's bin folder:

      1. If -FromPath (or a zip/DLL under vendor/bg3se or tools/bg3se) exists,
         install that. vendor/bg3se is tracked, so a pinned build reaches every
         clone without network access; tools/bg3se is a local override.
      2. Otherwise download the release asset from the fork, verify its SHA256
         when the release publishes one, and install it.

    Every candidate is validated before it is installed: it must be a real PE
    image and it must contain the GetArmorClass binding string. A build without
    the API is rejected, so this cannot silently install the wrong extender.

.PARAMETER Repo
    GitHub repository that publishes the Script Extender builds.
    Default: Inexorably/bg3se

.PARAMETER Tag
    Release tag to install, or latest for the newest published release.

.PARAMETER FromPath
    Local .zip or .dll to install instead of downloading a release.

.PARAMETER GameDir
    Baldur's Gate 3 install folder (the one containing bin\bg3.exe). Detected
    from Steam when omitted.

.PARAMETER DryRun
    Report what would be installed without writing anything.

.PARAMETER KeepStaging
    Keep the downloaded package in a staging folder instead of deleting it.

.PARAMETER NoBackup
    Do not keep a copy of the DWrite.dll that is being replaced.

.PARAMETER WaitForGameSeconds
    0 (default) fails fast when BG3 is running because the game keeps DWrite.dll
    loaded. -1 waits indefinitely; any other value waits that many seconds.

.EXAMPLE
    .\scripts\install-script-extender.ps1

.EXAMPLE
    .\scripts\install-script-extender.ps1 -Tag se-1.0.0-dos3

.EXAMPLE
    .\scripts\install-script-extender.ps1 -FromPath .\vendor\bg3se\BG3SE-DWrite.zip

.EXAMPLE
    .\scripts\install-script-extender.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Repo = 'Inexorably/bg3se',
    [string]$Tag = 'latest',
    [string]$FromPath,
    [string]$GameDir,
    [switch]$DryRun,
    [switch]$KeepStaging,
    [switch]$NoBackup,
    [int]$WaitForGameSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = Split-Path -Parent $PSScriptRoot
# vendor/bg3se is tracked, so a pinned package reaches everyone who clones DOS3.
# tools/bg3se is gitignored and acts as a local override.
$VendorDirs = @((Join-Path $RepoRoot 'vendor\bg3se'), (Join-Path $RepoRoot 'tools\bg3se'))
$TargetName = 'DWrite.dll'
# The binding this fork adds; a build without it cannot drive DOS2Combat's armor.
$RequiredBinding = 'GetArmorClass'
$MinDllBytes = 100KB
$GameNames = @('bg3', 'bg3_dx11', 'bg3_dx12', 'bg3_vulkan')
$ApiHeaders = @{
    'User-Agent' = 'dos3-install-script-extender'
    'Accept'     = 'application/vnd.github+json'
}

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

function Write-Info([string]$Message) {
    Write-Host "    $Message"
}

function Write-Warn([string]$Message) {
    Write-Host "!!  $Message" -ForegroundColor Yellow
}

function Get-GameProcess {
    foreach ($name in $GameNames) {
        $process = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($process) { return $process }
    }
    return $null
}

function Wait-ForGameToExit([int]$Seconds) {
    $process = Get-GameProcess
    if (-not $process) { return }

    if ($Seconds -eq 0) {
        throw "Baldur's Gate 3 is running (PID $($process.Id)); close it first, or pass -WaitForGameSeconds -1 to wait."
    }

    Write-Step "Waiting for Baldur's Gate 3 to exit"
    if ($Seconds -lt 0) {
        Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    }
    else {
        $exited = $process.WaitForExit($Seconds * 1000)
        if (-not $exited) { throw "Baldur's Gate 3 did not exit within $Seconds seconds." }
    }
    Write-Info 'game exited'
}

function Resolve-SteamLibrary([string]$LibraryVdf) {
    if (-not (Test-Path -LiteralPath $LibraryVdf)) { return @() }
    $paths = @()
    foreach ($line in Get-Content -LiteralPath $LibraryVdf) {
        if ($line -match '"path"\s+"([^"]+)"') {
            $paths += ($Matches[1] -replace '\\\\', '\')
        }
    }
    return $paths
}

function Resolve-GameBin([string]$ExplicitDir) {
    if ($ExplicitDir) {
        if (-not (Test-Path -LiteralPath $ExplicitDir)) {
            throw "Game folder not found: $ExplicitDir"
        }
        # Accept either the install folder (has bin\bg3.exe) or the bin folder
        # itself. Test the executables first: a stray DWrite.dll must not make a
        # parent folder look like the bin folder.
        if (Test-Path -LiteralPath (Join-Path $ExplicitDir 'bg3.exe')) { return $ExplicitDir }
        $bin = Join-Path $ExplicitDir 'bin'
        if (Test-Path -LiteralPath (Join-Path $bin 'bg3.exe')) { return $bin }
        if (Test-Path -LiteralPath $bin) { return $bin }
        throw "Game folder has no bin directory: $ExplicitDir"
    }

    $roots = @()
    foreach ($key in @(
            'HKCU:\Software\Valve\Steam',
            'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
            'HKLM:\SOFTWARE\Valve\Steam')) {
        $value = $null
        try { $value = (Get-ItemProperty -Path $key -ErrorAction Stop).SteamPath } catch { }
        if (-not $value) {
            try { $value = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath } catch { }
        }
        if ($value) { $roots += $value }
    }
    if (-not $roots) { $roots += 'C:\Program Files (x86)\Steam' }

    $libraries = @()
    foreach ($root in $roots) {
        $libraries += $root
        $libraries += Resolve-SteamLibrary (Join-Path $root 'steamapps\libraryfolders.vdf')
    }

    $checked = @()
    foreach ($library in ($libraries | Select-Object -Unique)) {
        $bin = Join-Path $library "steamapps\common\Baldurs Gate 3\bin"
        $checked += $bin
        if (Test-Path -LiteralPath (Join-Path $bin 'bg3.exe')) { return $bin }
    }

    throw ("Could not find Baldur's Gate 3. Pass -GameDir <install folder>.`nChecked:`n  " + ($checked -join "`n  "))
}

function Get-Release([string]$RepoName, [string]$ReleaseTag) {
    $uri = if ($ReleaseTag -eq 'latest') {
        "https://api.github.com/repos/$RepoName/releases/latest"
    }
    else {
        "https://api.github.com/repos/$RepoName/releases/tags/$ReleaseTag"
    }
    try {
        return Invoke-RestMethod -Uri $uri -Headers $ApiHeaders -UseBasicParsing
    }
    catch {
        throw "Could not read release '$ReleaseTag' from $RepoName. $($_.Exception.Message)"
    }
}

function Select-Asset($Release) {
    # Prefer the offline package (DWrite.dll); fall back to a bare extender DLL.
    $preferred = @('DWrite\.dll$', 'offline', 'BG3ScriptExtender\.dll$')
    foreach ($pattern in $preferred) {
        foreach ($asset in $Release.assets) {
            if ($asset.name -match $pattern) { return $asset }
        }
    }
    throw "Release '$($Release.tag_name)' has no DWrite.dll or BG3ScriptExtender.dll asset."
}

function Get-Sha256File($Release) {
    foreach ($asset in $Release.assets) {
        if ($asset.name -match '\.sha256$') { return $asset }
    }
    return $null
}

function Find-LocalCandidate([string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath)) { throw "Local package not found: $ExplicitPath" }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    # A pinned build checked into the checkout wins over the network. The local
    # (ignored) override folder is checked first, then the tracked vendor folder.
    foreach ($dir in $VendorDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $local = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.zip', '.dll') } |
            Sort-Object Name -Descending)
        if ($local.Count -gt 0) { return $local[0].FullName }
    }
    return $null
}

function Expand-Package([string]$PackagePath, [string]$Staging) {
    if ($PackagePath -match '\.dll$') { return $PackagePath }
    New-Item -ItemType Directory -Force -Path $Staging | Out-Null
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $Staging -Force
    $dll = Get-ChildItem -LiteralPath $Staging -Recurse -File -Filter 'DWrite.dll' | Select-Object -First 1
    if (-not $dll) {
        $dll = Get-ChildItem -LiteralPath $Staging -Recurse -File -Filter 'BG3ScriptExtender.dll' | Select-Object -First 1
    }
    if (-not $dll) { throw "Package has no DWrite.dll or BG3ScriptExtender.dll: $PackagePath" }
    return $dll.FullName
}

function Test-ExtenderDll([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Extender DLL not found: $Path" }
    $info = Get-Item -LiteralPath $Path
    if ($info.Length -lt $MinDllBytes) {
        throw "Extender DLL is implausibly small ($($info.Length) bytes): $Path"
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "Extender DLL is not a PE image (no MZ header): $Path"
    }

    $text = [Text.Encoding]::ASCII.GetString($bytes)
    if (-not $text.Contains($RequiredBinding)) {
        throw ("This Script Extender build has no Ext.Entity.$RequiredBinding binding; " +
            'DOS2Combat needs a build published from the DOS3 fork.')
    }

    return $info
}

function Install-Dll([string]$SourceDll, [string]$BinDir, [string]$Source) {
    $target = Join-Path $BinDir $TargetName
    $backup = $null
    if ((Test-Path -LiteralPath $target) -and -not $NoBackup) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$target.bak-$stamp"
        Copy-Item -LiteralPath $target -Destination $backup -Force
        Write-Info "backed up existing $TargetName to $(Split-Path -Leaf $backup)"
    }

    Copy-Item -LiteralPath $SourceDll -Destination $target -Force
    $installed = Get-Item -LiteralPath $target
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash

    $record = [ordered]@{
        source      = $Source
        installedAt = (Get-Date).ToString('o')
        sha256      = $hash
        bytes       = $installed.Length
        binding     = "Ext.Entity.$RequiredBinding"
        backup      = if ($backup) { Split-Path -Leaf $backup } else { $null }
    }
    $record | ConvertTo-Json | Out-File -FilePath (Join-Path $BinDir 'ScriptExtender.dos3.json') -Encoding utf8

    return $record
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
Write-Step 'Resolving Baldur''s Gate 3'
$binDir = Resolve-GameBin $GameDir
Write-Info "bin: $binDir"
Wait-ForGameToExit $WaitForGameSeconds

$staging = Join-Path ([IO.Path]::GetTempPath()) ("dos3-se-" + [Guid]::NewGuid().ToString('n').Substring(0, 8))
$package = $null
$source = $null
$expectedHash = $null

try {
    $local = Find-LocalCandidate $FromPath
    if ($local) {
        Write-Step 'Using a local Script Extender package'
        Write-Info $local
        $package = $local
        $source = "local:$local"
    }
    else {
        Write-Step "Reading release '$Tag' from $Repo"
        $release = Get-Release $Repo $Tag
        $asset = Select-Asset $release
        Write-Info "release $($release.tag_name): $($asset.name)"

        New-Item -ItemType Directory -Force -Path $staging | Out-Null
        $package = Join-Path $staging $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $package -UseBasicParsing
        $source = "release:$($release.tag_name)/$($asset.name)"

        $hashAsset = Get-Sha256File $release
        if ($hashAsset) {
            $hashPath = Join-Path $staging $hashAsset.name
            Invoke-WebRequest -Uri $hashAsset.browser_download_url -OutFile $hashPath -UseBasicParsing
            $expectedHash = ((Get-Content -LiteralPath $hashPath -TotalCount 1) -split '\s+')[0]
        }
        else {
            Write-Warn "release has no .sha256 asset; installing without a published checksum"
        }
    }

    if ($expectedHash) {
        $actual = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
        if ($actual -ne $expectedHash) {
            throw "Checksum mismatch for $package (expected $expectedHash, got $actual)"
        }
        Write-Info 'checksum verified'
    }

    Write-Step 'Validating the extender build'
    $dll = Expand-Package $package $staging
    $info = Test-ExtenderDll $dll
    Write-Info ("{0} bytes, Ext.Entity.{1} present" -f $info.Length, $RequiredBinding)

    if ($DryRun) {
        Write-Step 'Dry run: nothing written'
        Write-Info "would install $dll -> $(Join-Path $binDir $TargetName)"
        return
    }

    Write-Step "Installing into $binDir"
    $record = Install-Dll $dll $binDir $source
    Write-Info "sha256 $($record.sha256)"

    Write-Step 'Done'
    Write-Info "Launch BG3; in the Script Extender console run !dos2c_ac to compare AC with the character sheet."
}
finally {
    if (-not $KeepStaging -and (Test-Path -LiteralPath $staging)) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
