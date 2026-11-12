param([string]$OutputName = 'cargo_earth_career_0.8.6.zip')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([System.IO.Path]::GetFileName($OutputName) -ne $OutputName -or -not $OutputName.EndsWith('.zip')) {
  throw 'OutputName must be a ZIP filename without a directory.'
}
$distPath = Join-Path $projectRoot 'dist'
New-Item -ItemType Directory -Path $distPath -Force | Out-Null
$outputPath = Join-Path $distPath $OutputName
Compress-Archive -Path (Join-Path $projectRoot 'mod/cargo_earth/*') -DestinationPath $outputPath -CompressionLevel Optimal -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'helper/cargo_earth_helper.py') -Destination (Join-Path $distPath 'cargo_earth_helper_0.8.6.py') -Force
Get-Item -LiteralPath $outputPath | Select-Object FullName,Length
