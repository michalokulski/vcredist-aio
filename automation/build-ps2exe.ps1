<#
.SYNOPSIS
    Build VC Redist AIO into a single EXE using PS2EXE (embed payload).

.DESCRIPTION
    This script locates the installer runtime files and packages, encodes
    them into Base64 blobs and emits a bootstrap PowerShell script that
    extracts those blobs at runtime before executing the requested
    install/uninstall logic. The bootstrap is compiled with PS2EXE into
    a single self-contained `vcredist-aio.exe`.

.REQUIREMENTS
    Install-Module ps2exe
#>

[CmdletBinding()]
param(
  [string]$Output = "vcredist-aio.exe",
  [switch]$VerboseBuild
)

$ErrorActionPreference = "Stop"

Write-Host "== VC Redist AIO – PS2EXE Builder (embed payload) =="
Write-Host "Output: $Output"

# Ensure all Join-Path inputs are explicitly strings to avoid array issues
$root = (Resolve-Path "$PSScriptRoot\.." -ErrorAction Stop).Path
$auto = [string](Join-Path -Path $root -ChildPath 'automation')
$stage = [string](Join-Path -Path $auto -ChildPath 'stage-ps2exe')

# Clean stage
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item $stage -ItemType Directory | Out-Null

Write-Host "Locating source scripts and packages..."

# Find install/uninstall from several candidate locations
$installCandidates = @(
  [string](Join-Path -Path $root -ChildPath 'runtime/install.ps1'),
  [string](Join-Path -Path $auto -ChildPath 'install.ps1'),
  [string](Join-Path -Path $root -ChildPath 'install.ps1')
) | Where-Object { Test-Path $_ }

$uninstallCandidates = @(
  [string](Join-Path -Path $root -ChildPath 'runtime/uninstall.ps1'),
  [string](Join-Path -Path $auto -ChildPath 'uninstall.ps1'),
  [string](Join-Path -Path $root -ChildPath 'uninstall.ps1')
) | Where-Object { Test-Path $_ }

if ($installCandidates.Count -eq 0 -or $uninstallCandidates.Count -eq 0) {
  Write-Error "Could not find install.ps1 or uninstall.ps1 in expected locations."
  exit 1
}

$installSource = $installCandidates[0]
$uninstallSource = $uninstallCandidates[0]

# Find packages directory (try repo packages/, dist/packages, automation/packages)

$pkgCandidates = @(
  [string](Join-Path -Path $root -ChildPath 'packages'),
  [string](Join-Path -Path $root -ChildPath 'dist/packages'),
  [string](Join-Path -Path $auto -ChildPath 'packages')
) | Where-Object { Test-Path $_ }

$packagesDir = $pkgCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $packagesDir) {
  Write-Warning "No packages directory found. The EXE will not include package binaries."
}

Write-Host "Staging and collecting payload files..."

$payloadDir = Join-Path $stage "payload"
New-Item $payloadDir -ItemType Directory | Out-Null

Copy-Item -Path $installSource -Destination (Join-Path $payloadDir "install.ps1") -Force
Copy-Item -Path $uninstallSource -Destination (Join-Path $payloadDir "uninstall.ps1") -Force

$payloadFiles = @()
$payloadFiles += @{ Full = (Join-Path $payloadDir "install.ps1"); Relative = "install.ps1" }
$payloadFiles += @{ Full = (Join-Path $payloadDir "uninstall.ps1"); Relative = "uninstall.ps1" }

if ($packagesDir) {
  $pkgTargetDir = Join-Path $payloadDir "packages"
  New-Item $pkgTargetDir -ItemType Directory -Force | Out-Null
  Get-ChildItem -Path $packagesDir -File -Recurse | ForEach-Object {
    $rel = Join-Path "packages" (Split-Path $_.FullName -Leaf)
    Copy-Item -Path $_.FullName -Destination (Join-Path $pkgTargetDir $_.Name) -Force
    $payloadFiles += @{ Full = (Join-Path $pkgTargetDir $_.Name); Relative = $rel }
  }
}

Write-Host "Encoding payload into bootstrap..."

$bootstrapBuilder = New-Object System.Text.StringBuilder

$bootstrapBuilder.AppendLine("param(") | Out-Null
$bootstrapBuilder.AppendLine("    [switch]`$Silent,") | Out-Null
$bootstrapBuilder.AppendLine("    [string]`$Packages,") | Out-Null
$bootstrapBuilder.AppendLine("    [string]`$LogDir,") | Out-Null
$bootstrapBuilder.AppendLine("    [switch]`$SkipValidation,") | Out-Null
$bootstrapBuilder.AppendLine("    [switch]`$NoReboot,") | Out-Null
$bootstrapBuilder.AppendLine("    [switch]`$Uninstall") | Out-Null
$bootstrapBuilder.AppendLine(")") | Out-Null
$bootstrapBuilder.AppendLine("") | Out-Null
$bootstrapBuilder.AppendLine("$ErrorActionPreference = 'Stop'") | Out-Null
$bootstrapBuilder.AppendLine("") | Out-Null
$bootstrapBuilder.AppendLine("$extractRoot = Join-Path $env:TEMP 'vcredist-aio-runtime'") | Out-Null
$bootstrapBuilder.AppendLine("if (Test-Path $extractRoot) { Remove-Item $extractRoot -Recurse -Force }") | Out-Null
$bootstrapBuilder.AppendLine("New-Item $extractRoot -ItemType Directory | Out-Null") | Out-Null
$bootstrapBuilder.AppendLine("") | Out-Null
$bootstrapBuilder.AppendLine("# Embedded payload (Base64)") | Out-Null
$bootstrapBuilder.AppendLine("$EmbeddedFiles = @{}") | Out-Null

foreach ($p in $payloadFiles) {
  if (-not (Test-Path $p.Full)) { continue }
  $b64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p.Full))
  $relPath = ($p.Relative -replace "\\","/")
  $bootstrapBuilder.AppendLine("$EmbeddedFiles['$relPath'] = @'") | Out-Null
  $bootstrapBuilder.AppendLine($b64) | Out-Null
  $bootstrapBuilder.AppendLine("'@") | Out-Null
}

$bootstrapBuilder.AppendLine('') | Out-Null
$bootstrapBuilder.AppendLine('Write-Host ''Extracting embedded payload...''') | Out-Null
$bootstrapBuilder.AppendLine('foreach ($k in $EmbeddedFiles.Keys) {') | Out-Null
$bootstrapBuilder.AppendLine('    $rel = $k -replace ''/'', ''\''') | Out-Null
$bootstrapBuilder.AppendLine('    $outPath = Join-Path $extractRoot $rel') | Out-Null
$bootstrapBuilder.AppendLine('    $dir = Split-Path $outPath -Parent') | Out-Null
$bootstrapBuilder.AppendLine('    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }') | Out-Null
$bootstrapBuilder.AppendLine('    $b = [Convert]::FromBase64String($EmbeddedFiles[$k])') | Out-Null
$bootstrapBuilder.AppendLine('    [System.IO.File]::WriteAllBytes($outPath, $b)') | Out-Null
$bootstrapBuilder.AppendLine('    Write-Host "  Wrote: $outPath"') | Out-Null
$bootstrapBuilder.AppendLine('}') | Out-Null
$bootstrapBuilder.AppendLine("") | Out-Null
$bootstrapBuilder.AppendLine("# Choose script to run") | Out-Null
$bootstrapBuilder.AppendLine("$script = if ($Uninstall) { Join-Path $extractRoot 'uninstall.ps1' } else { Join-Path $extractRoot 'install.ps1' }") | Out-Null
$bootstrapBuilder.AppendLine("") | Out-Null
$bootstrapBuilder.AppendLine('# Build argument list') | Out-Null
$bootstrapBuilder.AppendLine('$argsList = @()') | Out-Null
$bootstrapBuilder.AppendLine('if ($Silent) { $argsList += ''-Silent'' }') | Out-Null
$bootstrapBuilder.AppendLine('if ($Packages) { $argsList += "-PackageFilter `"$Packages`"" }') | Out-Null
$bootstrapBuilder.AppendLine('if ($LogDir) { $argsList += "-LogDir `"$LogDir`"" }') | Out-Null
$bootstrapBuilder.AppendLine('if ($SkipValidation) { $argsList += ''-SkipValidation'' }') | Out-Null
$bootstrapBuilder.AppendLine('if ($NoReboot) { $argsList += ''-NoReboot'' }') | Out-Null
$bootstrapBuilder.AppendLine('') | Out-Null
$bootstrapBuilder.AppendLine('Write-Host "Running script: $script"') | Out-Null
$bootstrapBuilder.AppendLine('Write-Host "Arguments: $argsList"') | Out-Null
$bootstrapBuilder.AppendLine('powershell.exe -ExecutionPolicy Bypass -NoProfile -File $script @argsList') | Out-Null
$bootstrapBuilder.AppendLine('exit $LASTEXITCODE') | Out-Null

$bootstrap = $bootstrapBuilder.ToString()

$bootstrapFile = Join-Path $stage "bootstrap.ps1"
$bootstrap | Out-File -FilePath $bootstrapFile -Encoding UTF8 -Force

### ---- RUN PS2EXE ----

Write-Host "Building EXE (PS2EXE)..."

$iconPath = Join-Path $root "icon.ico"
if (-not (Test-Path $iconPath)) { $iconPath = $null }

$noConsole = if ($VerboseBuild.IsPresent) { 'False' } else { 'True' }

$cmd = @"
ps2exe `
  -inputFile `"$bootstrapFile`" `
  -outputFile `"$Output`" `
"@

if ($iconPath) { $cmd += "  -iconFile `"$iconPath`" `n" }
$cmd += "  -noConsole:$noConsole `n  -title `"VC Redist AIO`" `n  -description `"All-in-one VC Redist installer`""

Invoke-Expression $cmd

Write-Host "Build complete. Output: $Output"

### ---- CLEAN UP ----
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
