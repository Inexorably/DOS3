#Requires -Version 5.1
<#
.SYNOPSIS
    Download the DOS3 mods from a GitHub release and install them into BG3.

.DESCRIPTION
    Resolves the release assets for Inexorably/DOS3 (default tag: latest),
    downloads every .pak to a staging folder, installs them into the BG3 user
    Mods folder, and rewrites modsettings.lsx so the mods are enabled in
    dependency order (OrbWeaver after DOS2Combat, for example).

    Module UUIDs, names, versions, and dependencies are read from each mod's
    meta.lsx in this checkout, so the release never has to be hardcoded here.
    Mods that were enabled before but are not part of the release are left
    untouched.

.PARAMETER Repo
    GitHub repository that owns the release. Default: Inexorably/DOS3.

.PARAMETER Tag
    Release tag to install. Default: latest (the single rolling release CD publishes).

.PARAMETER ModsDir
    BG3 Mods folder. Default: %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods

.PARAMETER ProfileDir
    Player profile folder that holds modsettings.lsx. Default: the Public profile,
    or the most recently written profile when Public has no modsettings.lsx.

.PARAMETER Only
    Install just these mod folders (for example -Only DOS2Combat,Relight).

.PARAMETER SkipModSettings
    Copy the packages but leave modsettings.lsx alone.

.PARAMETER SkipScriptExtender
    Do not install the fork's Script Extender build. DOS2Combat's armor needs it
    (Ext.Entity.GetArmorClass); see scripts/install-script-extender.ps1.

.PARAMETER GameDir
    Baldur's Gate 3 install folder, forwarded to the Script Extender installer
    when it cannot be detected from Steam.

.PARAMETER DryRun
    Print what would be downloaded and installed without touching the disk.

.PARAMETER KeepStaging
    Keep the downloaded .pak files in the staging folder instead of deleting them.

.PARAMETER WaitForGameSeconds
    0 (default) fails fast when BG3 is running because the engine keeps the
    loaded .pak files locked. -1 waits indefinitely, any other value waits that
    many seconds for the game to exit before installing.

.PARAMETER NoBackup
    Skip the Mods_backup\<timestamp> copy of the packages and modsettings.lsx.

.EXAMPLE
    .\scripts\install-release.ps1

.EXAMPLE
    .\scripts\install-release.ps1 -WaitForGameSeconds -1

.EXAMPLE
    .\scripts\install-release.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Repo = 'Inexorably/DOS3',
    [string]$Tag = 'latest',
    [string]$ModsDir,
    [string]$ProfileDir,
    [string[]]$Only,
    [switch]$SkipModSettings,
    [switch]$SkipScriptExtender,
    [string]$GameDir,
    [switch]$DryRun,
    [switch]$KeepStaging,
    [int]$WaitForGameSeconds = 0,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = Split-Path -Parent $PSScriptRoot
$GameNames = @('bg3', 'bg3_dx11', 'bg3_dx12', 'bg3_vulkan')
$ApiHeaders = @{
    'User-Agent' = 'dos3-install-release'
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

function Resolve-UserDataDir {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot locate the BG3 user folder.' }
    $dir = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "BG3 user folder not found: $dir (start the game once, then re-run)."
    }
    return $dir
}

function Resolve-ProfileDir([string]$UserDataDir) {
    $candidates = @()
    $profiles = Join-Path $UserDataDir 'PlayerProfiles'
    if (-not (Test-Path -LiteralPath $profiles)) { return $null }
    foreach ($dir in (Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue)) {
        $settings = Join-Path $dir.FullName 'modsettings.lsx'
        if (Test-Path -LiteralPath $settings) {
            $candidates += Get-Item -LiteralPath $settings
        }
    }
    if (-not $candidates) { return $null }

    $public = Join-Path $profiles 'Public'
    foreach ($candidate in $candidates) {
        if ($candidate.DirectoryName -eq $public) { return $public }
    }
    return ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).DirectoryName
}

function Get-Release([string]$RepoName, [string]$ReleaseTag) {
    $uri = "https://api.github.com/repos/$RepoName/releases/tags/$ReleaseTag"
    try {
        return Invoke-RestMethod -Uri $uri -Headers $ApiHeaders -UseBasicParsing
    }
    catch {
        throw "Could not read release '$ReleaseTag' from $RepoName. $($_.Exception.Message)"
    }
}

function Get-LocalModuleMetadata {
    $result = @{}
    $modRoot = Join-Path $RepoRoot 'mods'
    if (-not (Test-Path -LiteralPath $modRoot)) { return $result }

    foreach ($modDir in (Get-ChildItem -LiteralPath $modRoot -Directory)) {
        $metaPath = Join-Path $modDir.FullName ("Mods\{0}\meta.lsx" -f $modDir.Name)
        if (-not (Test-Path -LiteralPath $metaPath)) { continue }
        try {
            [xml]$meta = Get-Content -LiteralPath $metaPath -Raw
        }
        catch {
            Write-Warn "Skipping unreadable manifest: $metaPath"
            continue
        }

        $moduleInfo = $meta.SelectSingleNode("//node[@id='ModuleInfo']")
        if (-not $moduleInfo) { continue }
        $values = @{}
        foreach ($attr in $moduleInfo.SelectNodes('attribute')) {
            $values[$attr.GetAttribute('id')] = $attr.GetAttribute('value')
        }
        if (-not $values.ContainsKey('Folder') -or -not $values.ContainsKey('UUID')) { continue }

        $dependencies = @()
        $depsNode = $meta.SelectSingleNode("//node[@id='Dependencies']/children")
        if ($depsNode) {
            foreach ($dep in $depsNode.SelectNodes("node[@id='ModuleShortDesc']")) {
                $depUuid = $dep.SelectSingleNode("attribute[@id='UUID']")
                if ($depUuid) { $dependencies += $depUuid.GetAttribute('value') }
            }
        }

        $result[$values['Folder']] = [pscustomobject]@{
            Folder       = $values['Folder']
            Name         = $values['Name']
            UUID         = $values['UUID']
            Version64    = if ($values.ContainsKey('Version64')) { $values['Version64'] } else { '36028797018963968' }
            Dependencies = $dependencies
        }
    }
    return $result
}

function Sort-ModulesByDependency($Modules) {
    $byUuid = @{}
    $byFolder = @{}
    foreach ($module in $Modules) {
        $byUuid[$module.UUID] = $module
        $byFolder[$module.Folder] = $module
    }

    $ordered = New-Object System.Collections.ArrayList
    $state = @{}

    function Visit([string]$Folder) {
        if ($state.ContainsKey($Folder)) {
            if ($state[$Folder] -eq 'visiting') {
                Write-Warn "Dependency cycle detected at '$Folder'; keeping the current order."
            }
            return
        }
        $state[$Folder] = 'visiting'
        $module = $byFolder[$Folder]
        foreach ($depUuid in $module.Dependencies) {
            if ($byUuid.ContainsKey($depUuid)) {
                Visit $byUuid[$depUuid].Folder
            }
        }
        $state[$Folder] = 'done'
        [void]$ordered.Add($module)
    }

    foreach ($module in $Modules) { Visit $module.Folder }
    return $ordered
}

function Test-GameAndWait([int]$Seconds) {
    $game = Get-GameProcess
    if (-not $game) { return }
    if ($Seconds -lt 0) {
        Write-Warn ("Baldur's Gate 3 is running (PID {0}). Waiting for it to exit before replacing locked .pak files..." -f $game.Id)
    }
    elseif ($Seconds -eq 0) {
        throw ("Baldur's Gate 3 is running (PID {0}) and holds the installed .pak files open. Close the game and re-run, or pass -WaitForGameSeconds -1." -f $game.Id)
    }
    else {
        Write-Warn ("Baldur's Gate 3 is running (PID {0}). Waiting up to {1}s for it to exit..." -f $game.Id, $Seconds)
    }

    $deadline = if ($Seconds -lt 0) { [datetime]::MaxValue } else { (Get-Date).AddSeconds($Seconds) }
    while ((Get-GameProcess) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
    }
    if (Get-GameProcess) {
        throw 'Timed out waiting for Baldur''s Gate 3 to exit; nothing was installed.'
    }
    # Let the engine flush its own modsettings.lsx before rewriting it.
    Start-Sleep -Seconds 5
}

function Copy-WithRetry([string]$Source, [string]$Destination) {
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq 6) { throw }
            Write-Warn "Copy failed (attempt $attempt): $($_.Exception.Message)"
            Start-Sleep -Seconds 5
        }
    }
}

function Install-Asset($Asset, [string]$Staging, [string]$Mods, [string]$BackupDir) {
    $name = $Asset.name
    $target = Join-Path $Mods $name
    $staged = Join-Path $Staging $name
    $size = $Asset.size
    $digestProp = $Asset.PSObject.Properties['digest']
    $digest = if ($digestProp) { $digestProp.Value } else { $null }

    if (-not $DryRun) {
        if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force }
        if ($size) {
            Write-Info "Downloading $name ($([math]::Round($size / 1MB, 2)) MB)"
        }
        else {
            Write-Info "Downloading $name"
        }
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $staged -UseBasicParsing
        $downloaded = Get-Item -LiteralPath $staged
        if ($size -and $downloaded.Length -ne $size) {
            throw "$name downloaded $($downloaded.Length) bytes, expected $size."
        }
        if ($digest -and $digest.StartsWith('sha256:')) {
            $actual = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $digest.Substring(7).ToLower()) {
                throw "$name failed its SHA-256 check."
            }
        }
    }

    if ($size -and (Test-Path -LiteralPath $target)) {
        $existing = Get-Item -LiteralPath $target
        if ($existing.Length -eq $size) {
            $sameStaged = $true
            if (-not $DryRun) {
                $sameStaged = (Get-FileHash -LiteralPath $staged -Algorithm MD5).Hash -eq
                              (Get-FileHash -LiteralPath $target -Algorithm MD5).Hash
            }
            if ($sameStaged) {
                Write-Info "$name is already up to date"
                return
            }
        }
    }

    if ($DryRun) {
        Write-Info "Would install $name -> $target"
        return
    }

    if ((Test-Path -LiteralPath $target) -and $BackupDir) {
        Copy-Item -LiteralPath $target -Destination (Join-Path $BackupDir $name) -Force
    }
    Copy-WithRetry $staged $target

    $sourceHash = (Get-FileHash -LiteralPath $staged -Algorithm MD5).Hash
    $targetHash = (Get-FileHash -LiteralPath $target -Algorithm MD5).Hash
    if ($sourceHash -ne $targetHash) { throw "$name does not match the download after copying." }
    Write-Info "Installed $name"
}

function Update-ModSettings([string]$Path, $Modules, [string]$BackupDir) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "modsettings.lsx not found: $Path (start BG3 once, enable a mod, then re-run)."
    }
    if ($BackupDir) {
        Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupDir 'modsettings.lsx') -Force
    }

    [xml]$xml = Get-Content -LiteralPath $Path -Raw
    $modsNode = $xml.SelectSingleNode("//node[@id='Mods']/children")
    if (-not $modsNode) { throw "Could not find the Mods list in $Path" }

    $desired = @{}
    foreach ($module in $Modules) { $desired[$module.Folder] = $module }

    $gameBase = $null
    $keep = @()
    foreach ($node in @($modsNode.SelectNodes('node'))) {
        $folderAttr = $node.SelectSingleNode("attribute[@id='Folder']")
        $folder = if ($folderAttr) { $folderAttr.GetAttribute('value') } else { '' }
        if ($desired.ContainsKey($folder)) { continue }
        if ($folder -eq 'GustavX') { $gameBase = $node } else { $keep += $node }
    }

    $modsNode.RemoveAll()

    function New-ModuleNode([xml]$Document, $Module) {
        $node = $Document.CreateElement('node')
        $node.SetAttribute('id', 'ModuleShortDesc')
        $pairs = @(
            @('Folder', 'LSString', $Module.Folder),
            @('MD5', 'LSString', ''),
            @('Name', 'LSString', $Module.Name),
            @('PublishHandle', 'uint64', '0'),
            @('UUID', 'guid', $Module.UUID),
            @('Version64', 'int64', $Module.Version64)
        )
        foreach ($pair in $pairs) {
            $attr = $Document.CreateElement('attribute')
            $attr.SetAttribute('id', $pair[0])
            $attr.SetAttribute('type', $pair[1])
            $attr.SetAttribute('value', $pair[2])
            [void]$node.AppendChild($attr)
        }
        return $node
    }

    if ($gameBase) {
        [void]$modsNode.AppendChild($gameBase)
    }
    else {
        Write-Warn 'modsettings.lsx has no GustavX entry; the game may reject this profile.'
    }
    foreach ($node in $keep) { [void]$modsNode.AppendChild($node) }
    foreach ($module in $Modules) {
        [void]$modsNode.AppendChild((New-ModuleNode $xml $module))
    }

    if ($DryRun) {
        Write-Info "Would enable in $Path : $(($Modules | ForEach-Object { $_.Folder }) -join ', ')"
        return
    }
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.IndentChars = '    '
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $xml.Save($writer)
    }
    finally {
        $writer.Close()
    }
    Write-Info "Enabled in modsettings.lsx: $(($Modules | ForEach-Object { $_.Folder }) -join ', ')"
}

# --- main ---------------------------------------------------------------

try {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    $userData = Resolve-UserDataDir
    if (-not $ModsDir) { $ModsDir = Join-Path $userData 'Mods' }
    if (-not $ProfileDir) { $ProfileDir = Resolve-ProfileDir $userData }
    if (-not $ProfileDir) { throw "No PlayerProfiles\*\modsettings.lsx found under $userData; start BG3 once first." }
    $settingsPath = Join-Path $ProfileDir 'modsettings.lsx'

    Write-Step "Release $Repo@$Tag"
    $release = Get-Release $Repo $Tag
    $assets = @($release.assets | Where-Object { $_.name -like '*.pak' })
    if (-not $assets) { throw "Release '$Tag' in $Repo has no .pak assets." }

    # -Only works with both `-Only A,B` (PowerShell) and `-Only A,B` from cmd,
    # where the comma arrives as part of one string.
    $onlyList = @()
    foreach ($entry in @($Only)) {
        if (-not $entry) { continue }
        foreach ($piece in $entry.Split(',')) {
            $trimmed = $piece.Trim()
            if ($trimmed) { $onlyList += $trimmed }
        }
    }
    if ($onlyList.Count -gt 0) {
        $assets = @($assets | Where-Object { $onlyList -contains [System.IO.Path]::GetFileNameWithoutExtension($_.name) })
        if (-not $assets) { throw "None of the requested mods exist in release '$Tag': $($onlyList -join ', ')" }
    }
    Write-Info "Published $($release.published_at) ($($assets.Count) packages)"

    $metadata = Get-LocalModuleMetadata
    $modules = New-Object System.Collections.ArrayList
    $unmanaged = @()
    foreach ($asset in $assets) {
        $folder = [System.IO.Path]::GetFileNameWithoutExtension($asset.name)
        if ($metadata.ContainsKey($folder)) {
            [void]$modules.Add($metadata[$folder])
        }
        else {
            $unmanaged += $folder
        }
    }
    if ($unmanaged.Count -gt 0) {
        Write-Warn ("No local meta.lsx for: {0}. The packages install but stay disabled." -f ($unmanaged -join ', '))
    }
    $ordered = @()
    if ($modules.Count -gt 0) { $ordered = @(Sort-ModulesByDependency $modules) }
    if ($ordered.Count -gt 0) {
        Write-Info "Load order: $(($ordered | ForEach-Object { $_.Folder }) -join ' -> ')"
    }

    if ($DryRun) {
        Write-Info "Mods folder: $ModsDir"
        Write-Info "Profile:     $ProfileDir"
    }

    if (-not $DryRun) {
        Test-GameAndWait $WaitForGameSeconds
        New-Item -ItemType Directory -Path $ModsDir -Force | Out-Null
    }

    $backupDir = $null
    if (-not $DryRun -and -not $NoBackup) {
        $backupRoot = Split-Path -Parent $ModsDir
        $backupDir = Join-Path $backupRoot ('Mods_backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    $staging = Join-Path $env:TEMP ('dos3-release-' + $Tag)
    if ($DryRun) {
        Write-Step 'Packages'
        foreach ($asset in $assets) {
            Install-Asset $asset $staging $ModsDir $backupDir
        }
    }
    else {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            Write-Step 'Installing packages'
            foreach ($asset in $assets) {
                Install-Asset $asset $staging $ModsDir $backupDir
            }
        }
        finally {
            if (-not $KeepStaging) {
                Get-ChildItem -LiteralPath $staging -Filter '*.pak' -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($SkipModSettings) {
        Write-Step 'Skipping modsettings.lsx (-SkipModSettings)'
    }
    elseif ($ordered.Count -eq 0) {
        Write-Warn 'No release packages matched a local manifest; modsettings.lsx was not changed.'
    }
    else {
        Write-Step 'Updating modsettings.lsx'
        Update-ModSettings $settingsPath $ordered $backupDir
    }

    if ($backupDir) {
        Write-Step "Backup written to $backupDir"
    }

    # The mods need the fork's Script Extender (Ext.Entity.GetArmorClass), so a
    # fresh install is incomplete without it. Failure is fatal rather than a
    # warning: shipping mods whose armor silently cannot work is worse than
    # stopping and saying why.
    if (-not $SkipScriptExtender) {
        $extender = Join-Path $PSScriptRoot 'install-script-extender.ps1'
        if (-not (Test-Path -LiteralPath $extender)) {
            throw "install-script-extender.ps1 is missing next to this script; DOS2Combat's armor needs that extender build."
        }
        Write-Step 'Installing the Script Extender build DOS3 needs'
        $extenderArgs = @{ WaitForGameSeconds = $WaitForGameSeconds }
        if ($DryRun) { $extenderArgs['DryRun'] = $true }
        if ($GameDir) { $extenderArgs['GameDir'] = $GameDir }
        # The extender installer resolves the build from vendor/bg3se/pin.json.
        & $extender @extenderArgs
        if ($LASTEXITCODE -ne 0) { throw "Script Extender install failed: $LASTEXITCODE" }
    }

    Write-Host ''
    Write-Host 'Done. Launch BG3 and load a save; the mods are enabled in the order above.'
    if ($WaitForGameSeconds -eq 0 -or $DryRun) {
        Write-Host 'Tip: pass -WaitForGameSeconds -1 to have this script install on its own after you quit the game.'
    }
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
