<#
.SYNOPSIS
  Installs, updates or removes the Cargo Earth mod and its helper for BeamNG.drive with BeamNG.Earth.

.DESCRIPTION
  - Downloads the mod ZIP and the helper from a GitHub release of themazzy/cargo-earth (or uses local files).
  - Puts the mod ZIP into the BeamNG user folder's mods folder. Older Cargo Earth ZIPs are moved to
    <user folder>\cargo_earth_old_mods so only one version is enabled.
  - Copies the helper to %LOCALAPPDATA%\CargoEarth\helper, installs its Python libraries (duckdb, fsspec)
    and registers it as a BeamNG.Earth companion add-on in %LOCALAPPDATA%\beamng-earth\addons\local.json
    (the file is backed up first; other add-ons in it are kept).
  - Career saves (settings\cargoEarth in the BeamNG user folder) are never touched.

.EXAMPLE
  irm https://raw.githubusercontent.com/themazzy/cargo-earth/main/install.ps1 | iex
  Installs the latest release of the mod and the helper.

.EXAMPLE
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/themazzy/cargo-earth/main/install.ps1))) -Uninstall
  Runs the downloaded installer with options (here: remove Cargo Earth).

.EXAMPLE
  .\install.ps1 -Version 0.3.5 -UserFolder "D:\BeamNG\userfolder"

.EXAMPLE
  .\install.ps1 -ZipPath .\dist\cargo_earth_career_0.3.5.zip -HelperPath .\helper\cargo_earth_helper.py

.EXAMPLE
  .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [string]$Version,            # release to install, e.g. 0.3.5 (default: the latest release)
  [string]$UserFolder,         # BeamNG user folder (default: found automatically)
  [string]$ZipPath,            # use this mod ZIP instead of downloading
  [string]$HelperPath,         # use this helper .py instead of downloading
  [switch]$ModOnly,            # install only the mod
  [switch]$HelperOnly,         # install only the helper
  [switch]$SkipPython,         # don't install the helper's Python libraries
  [switch]$Uninstall,          # remove the mod ZIP, the helper and its add-on entry (saves are kept)
  [switch]$DryRun              # show what would happen, change nothing
)

$ErrorActionPreference = 'Stop'
$Repo = 'themazzy/cargo-earth'
$AddonId = 'cargo-earth-helper'
$HelperPort = 47820
$Local = $env:LOCALAPPDATA
if (-not $Local) { throw 'LOCALAPPDATA is not set. Run this in Windows PowerShell.' }
$HelperDir = Join-Path $Local 'CargoEarth\helper'
$AddonsFile = Join-Path $Local 'beamng-earth\addons\local.json'

function Say([string]$text) { Write-Host "  $text" }
function Step([string]$text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Warn([string]$text) { Write-Host "  ! $text" -ForegroundColor Yellow }
function Do-It([string]$what, [scriptblock]$action) {
  if ($DryRun) { Say "[dry run] $what" } else { & $action }
}

# ------------------------------------------------------------------ the BeamNG user folder

function Find-UserFolder {
  if ($UserFolder) {
    if (-not (Test-Path -LiteralPath $UserFolder)) { throw "The user folder '$UserFolder' does not exist." }
    return (Resolve-Path -LiteralPath $UserFolder).Path
  }
  $candidates = @()
  $current = Join-Path $Local 'BeamNG\BeamNG.drive\current'
  if (Test-Path -LiteralPath $current) { $candidates += $current }
  # older game versions: %LOCALAPPDATA%\BeamNG.drive\<version>, newest first
  foreach ($root in @((Join-Path $Local 'BeamNG\BeamNG.drive'), (Join-Path $Local 'BeamNG.drive'))) {
    if (Test-Path -LiteralPath $root) {
      $versions = Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending
      foreach ($v in $versions) { $candidates += $v.FullName }
    }
  }
  if ($candidates.Count -eq 0) {
    throw ("The BeamNG user folder was not found. Open the BeamNG launcher > Manage User Folder > Open, " +
      "then run this again with -UserFolder ""<that folder>"".")
  }
  return $candidates[0]
}

# ------------------------------------------------------------------ downloads

function Get-Release {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $url = if ($Version) { "https://api.github.com/repos/$Repo/releases/tags/v$($Version.TrimStart('v'))" }
         else { "https://api.github.com/repos/$Repo/releases/latest" }
  try {
    return Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'cargo-earth-installer' }
  } catch {
    throw "Could not find a Cargo Earth release at $url. Check the version, or pass -ZipPath / -HelperPath. ($($_.Exception.Message))"
  }
}

function Get-Asset($release, [string]$pattern, [string]$what) {
  $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
  if (-not $asset) { throw "Release $($release.tag_name) has no $what file." }
  $target = Join-Path ([IO.Path]::GetTempPath()) $asset.name
  Say "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)"
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $target -UseBasicParsing -Headers @{ 'User-Agent' = 'cargo-earth-installer' }
  return $target
}

function Test-ModZip([string]$path) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  try { $zip = [IO.Compression.ZipFile]::OpenRead($path) }
  catch { throw "$path is not a readable ZIP file. Download it again." }
  try {
    $names = $zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') }
    if ($names -notcontains 'lua/ge/extensions/cargoEarth/core.lua') {
      throw "$path is not a Cargo Earth mod ZIP (lua/ge/extensions/cargoEarth/core.lua is missing at its root)."
    }
  } finally { $zip.Dispose() }
}

# ------------------------------------------------------------------ the mod

function Move-OldMods([string]$mods, [string]$user, [string]$keepName) {
  $old = @(Get-ChildItem -LiteralPath $mods -Recurse -File -Filter 'cargo_earth*.zip' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $keepName -or $_.DirectoryName -ne $mods })
  if ($old.Count -eq 0) { return }
  $backup = Join-Path $user 'cargo_earth_old_mods'
  foreach ($f in $old) {
    Do-It "move $($f.FullName) to $backup" {
      New-Item -ItemType Directory -Path $backup -Force | Out-Null
      Move-Item -LiteralPath $f.FullName -Destination (Join-Path $backup $f.Name) -Force
    }
    Say "Moved the older $($f.Name) out of mods (kept in cargo_earth_old_mods)."
  }
  $unpacked = Join-Path $mods 'unpacked\cargo_earth'
  if (Test-Path -LiteralPath $unpacked) { Warn "An unpacked copy exists in $unpacked. Remove it, or it loads together with the ZIP." }
}

function Install-Mod([string]$zip, [string]$user) {
  Step 'Mod'
  Test-ModZip $zip
  $mods = Join-Path $user 'mods'
  $name = [IO.Path]::GetFileName($zip)
  if ($name -notmatch '^cargo_earth.*\.zip$') { $name = 'cargo_earth_career.zip' }
  Do-It "create $mods" { New-Item -ItemType Directory -Path $mods -Force | Out-Null }
  if (Test-Path -LiteralPath $mods) { Move-OldMods $mods $user $name }
  Do-It "copy $name to $mods" { Copy-Item -LiteralPath $zip -Destination (Join-Path $mods $name) -Force }
  Say "Installed $name in $mods"
}

function Remove-Mod([string]$user) {
  Step 'Mod'
  $mods = Join-Path $user 'mods'
  $found = @(Get-ChildItem -LiteralPath $mods -Recurse -File -Filter 'cargo_earth*.zip' -ErrorAction SilentlyContinue)
  if ($found.Count -eq 0) { Say 'No Cargo Earth ZIP in mods.' }
  foreach ($f in $found) {
    Do-It "delete $($f.FullName)" { Remove-Item -LiteralPath $f.FullName -Force }
    Say "Removed $($f.Name)"
  }
  Say "Career saves stay in $(Join-Path $user 'settings\cargoEarth')."
}

# ------------------------------------------------------------------ the helper

function Find-Python {
  foreach ($cmd in @(@('py', '-3'), @('python'), @('python3'))) {
    $exe = Get-Command $cmd[0] -ErrorAction SilentlyContinue
    if (-not $exe) { continue }
    $extra = @($cmd | Select-Object -Skip 1)
    try {
      $out = & $exe.Source @extra -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null
      if ($LASTEXITCODE -eq 0 -and $out -and [version]$out -ge [version]'3.9') {
        return @{ Exe = $exe.Source; Args = $extra; Version = $out }
      }
    } catch { }
  }
  return $null
}

function Read-Addons {
  if (-not (Test-Path -LiteralPath $AddonsFile)) { return [pscustomobject]@{ format = 1; addons = @() } }
  try { $data = Get-Content -LiteralPath $AddonsFile -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { throw "$AddonsFile is not valid JSON. Fix or rename it, then run again." }
  if (-not $data) { $data = [pscustomobject]@{ format = 1; addons = @() } }
  if (-not ($data.PSObject.Properties.Name -contains 'addons')) { $data | Add-Member -NotePropertyName addons -NotePropertyValue @() }
  return $data
}

function Write-Addons($data) {
  $dir = Split-Path -Parent $AddonsFile
  Do-It "write $AddonsFile" {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if (Test-Path -LiteralPath $AddonsFile) { Copy-Item -LiteralPath $AddonsFile -Destination "$AddonsFile.bak" -Force }
    $json = ConvertTo-Json -InputObject $data -Depth 10
    [IO.File]::WriteAllText($AddonsFile, $json, (New-Object Text.UTF8Encoding $false))
  }
}

function Install-Helper([string]$py, [string]$tag) {
  Step 'Helper'
  $name = [IO.Path]::GetFileName($py)
  $target = Join-Path $HelperDir $name
  Do-It "copy $name to $HelperDir" {
    New-Item -ItemType Directory -Path $HelperDir -Force | Out-Null
    Get-ChildItem -LiteralPath $HelperDir -Filter 'cargo_earth_helper*.py' | Where-Object { $_.Name -ne $name } | Remove-Item -Force
    Copy-Item -LiteralPath $py -Destination $target -Force
  }
  Say "Helper: $target"

  $python = Find-Python
  if (-not $python) {
    Warn 'Python 3.9 or newer was not found. Install it (for example: winget install Python.Python.3.12), then run this again.'
  } else {
    Say "Python $($python.Version): $($python.Exe)"
    if (-not $SkipPython) {
      Do-It 'pip install duckdb fsspec' {
        & $python.Exe @($python.Args) -m pip install --user --upgrade --disable-pip-version-check duckdb fsspec
        if ($LASTEXITCODE -ne 0) { Warn 'pip could not install duckdb and fsspec. Run: python -m pip install duckdb fsspec' }
      }
    }
    $launcher = Join-Path $HelperDir 'start_helper.cmd'
    $line = (@('"' + $python.Exe + '"') + @($python.Args) + @('"' + $target + '"', '--port', $HelperPort)) -join ' '
    Do-It "write $launcher" { Set-Content -LiteralPath $launcher -Value @('@echo off', 'title Cargo Earth helper', $line, 'pause') -Encoding ASCII }
    Say "To run it by hand: $launcher"
  }

  # BeamNG.Earth starts companion add-ons listed in local.json
  $data = Read-Addons
  $entry = [pscustomobject]@{
    id = $AddonId; name = 'Cargo Earth helper'; author = 'themazzy'; repo = $Repo; kind = 'companion'
    summary = 'Restaurants, shops, workplaces and customer addresses anywhere in the world for the Cargo Earth mod.'
    licence = 'MIT'; asset = '^cargo_earth_helper.*\.py$'
    local = [pscustomobject]@{ file = $target; tag = $tag }
    run = [pscustomobject]@{ args = @(); port = $HelperPort }
  }
  $data.addons = @(@($data.addons) | Where-Object { $_ -and $_.id -ne $AddonId }) + $entry
  Write-Addons $data
  Say "Registered with BeamNG.Earth in $AddonsFile (other add-ons kept, old file saved as local.json.bak)."
  if (-not (Test-Path -LiteralPath (Join-Path $Local 'beamng-earth'))) {
    Warn 'BeamNG.Earth''s app folder was not found. Install BeamNG.Earth first, or run the helper with start_helper.cmd.'
  }
}

function Remove-Helper {
  Step 'Helper'
  if (Test-Path -LiteralPath $HelperDir) {
    Do-It "delete $HelperDir" { Remove-Item -LiteralPath $HelperDir -Recurse -Force }
    Say "Removed $HelperDir (its download cache too)."
  } else { Say 'No helper installed.' }
  if (Test-Path -LiteralPath $AddonsFile) {
    $data = Read-Addons
    $before = @($data.addons).Count
    $data.addons = @(@($data.addons) | Where-Object { $_ -and $_.id -ne $AddonId })
    if (@($data.addons).Count -ne $before) {
      Write-Addons $data
      Say 'Removed the helper from BeamNG.Earth''s add-on list.'
    }
  }
}

# ------------------------------------------------------------------ main

Write-Host 'Cargo Earth installer' -ForegroundColor Cyan
if ($ModOnly -and $HelperOnly) { throw 'Use -ModOnly or -HelperOnly, not both.' }
$doMod, $doHelper = (-not $HelperOnly), (-not $ModOnly)
$user = $null
if ($doMod) {
  $user = Find-UserFolder
  Say "BeamNG user folder: $user"
}

if ($Uninstall) {
  if ($doMod) { Remove-Mod $user }
  if ($doHelper) { Remove-Helper }
  Write-Host ''
  if ($DryRun) { Write-Host 'Dry run finished. Nothing was changed.' -ForegroundColor Green }
  else { Write-Host 'Done. Cargo Earth was removed.' -ForegroundColor Green }
  return
}

$release = $null
$tag = if ($Version) { 'v' + $Version.TrimStart('v') } else { 'local' }
if (($doMod -and -not $ZipPath) -or ($doHelper -and -not $HelperPath)) {
  Step 'Download'
  $release = Get-Release
  $tag = $release.tag_name
  Say "Release $tag"
}
if ($doMod) {
  $zip = if ($ZipPath) { (Resolve-Path -LiteralPath $ZipPath).Path } else { Get-Asset $release '^cargo_earth.*\.zip$' 'mod ZIP' }
  Install-Mod $zip $user
}
if ($doHelper) {
  $py = if ($HelperPath) { (Resolve-Path -LiteralPath $HelperPath).Path } else { Get-Asset $release '^cargo_earth_helper.*\.py$' 'helper' }
  Install-Helper $py $tag
}

Write-Host ''
if ($DryRun) { Write-Host 'Dry run finished. Nothing was changed.' -ForegroundColor Green; return }
Write-Host 'Done.' -ForegroundColor Green
if ($doMod) { Say 'Start BeamNG.drive, load a BeamNG.Earth world and add the "Cargo Earth: Phone" UI app.' }
if ($doHelper) { Say 'The helper starts with BeamNG.Earth. In Czechia the mod also works without it.' }
