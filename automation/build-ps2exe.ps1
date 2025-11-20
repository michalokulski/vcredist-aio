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

# Ensure the script is saved with UTF-8 encoding and validate the param block
param(
  [string]$PackagesFile = $null,
  [string]$Output = "vcredist-aio.exe",
  [string]$OutputDir = $null,
  [switch]$VerboseBuild
)

$ErrorActionPreference = "Stop"

Write-Host "== VC Redist AIO – PS2EXE Builder (embed payload) =="
Write-Host "Output: $Output"

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Script,
    [int]$Attempts = 3,
    [int]$DelaySeconds = 2
  )
  for ($i = 1; $i -le $Attempts; $i++) {
    try {
      $result = & $Script
      return $result
    } catch {
      $msg = $_.Exception.Message
      if ($msg -match "403|rate limit") {
        Write-Host "⏳ GitHub API rate limit detected. Waiting 90 seconds..." -ForegroundColor Cyan
        Start-Sleep -Seconds 90
        continue
      }
      if ($i -lt $Attempts) {
        $wait = [math]::Min(30,$DelaySeconds * [math]::Pow(2,$i - 1))
        $wait = $wait + (Get-Random -Minimum 0 -Maximum 3)
        Write-Host ("Retry {0}/{1} failed: {2}. Waiting {3} seconds before retry..." -f $i,$Attempts,$msg,[int]$wait)
        Start-Sleep -Seconds $wait
      } else {
        Write-Warning ("Operation failed after {0} attempts: {1}" -f $Attempts,$msg)
        return $null
      }
    }
  }
}

function Get-InstallerInfoFromManifest {
  param(
    [Parameter(Mandatory = $true)] [string]$PackageId,
    [Parameter(Mandatory = $true)] [string]$Version,
    [Parameter(Mandatory = $true)] [hashtable]$Headers
  )

  try {
    $parts = $PackageId -split '\.'
    if ($parts.Length -lt 2) { return $null }

    $vendor = $parts[0]
    $product = $parts[1]

    $isArchSpecific = $PackageId -match "VCRedist" -and $parts.Length -ge 3

    if ($isArchSpecific) {
      $versionPart = $parts[2]
      $arch = if ($PackageId -match "x64") { "x64" } else { "x86" }
      $folderYear = if ($versionPart -eq "2015Plus") { "2015+" } else { $versionPart }
      $versionPath = "manifests/m/$vendor/$product/$folderYear/$arch/$Version"
    } else {
      $versionPath = "manifests/m/$vendor/$product/$Version"
    }

    $versionUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$versionPath"

    Write-Host "    Fetching manifest: $versionPath" -ForegroundColor DarkGray

    $manifestFiles = Invoke-WithRetry -Script {
      Invoke-RestMethod -Uri $versionUrl -Headers $Headers -ErrorAction Stop
    } -Attempts 2 -DelaySeconds 2

    if (-not $manifestFiles) { return $null }

    $installerYaml = $manifestFiles | Where-Object {
      $_.type -eq 'file' -and $_.Name -match 'installer\.ya?ml$'
    } | Select-Object -First 1

    if (-not $installerYaml) { return $null }

    $fileObj = Invoke-WithRetry -Script {
      Invoke-RestMethod -Uri $installerYaml.url -Headers $Headers -ErrorAction Stop
    } -Attempts 2 -DelaySeconds 2

    if (-not $fileObj -or -not $fileObj.content) { return $null }

    $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))

    $urlMatch = [regex]::Match($content,'InstallerUrl:\s*([^\s#]+)',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $shaMatch = [regex]::Match($content,'InstallerSha256:\s*([0-9A-Fa-f]{64})',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)

    if ($urlMatch.Success) {
      $url = $urlMatch.Groups[1].Value.Trim()
      $quoteChar = [char]34
      $singleQuote = [char]39
      while ($url.Length -gt 0 -and ($url[0] -eq $quoteChar -or $url[0] -eq $singleQuote)) {
        $url = $url.Substring(1)
      }
      while ($url.Length -gt 0 -and ($url[-1] -eq $quoteChar -or $url[-1] -eq $singleQuote)) {
        $url = $url.Substring(0,$url.Length - 1)
      }
      $sha = if ($shaMatch.Success) { $shaMatch.Groups[1].Value.Trim() } else { $null }
      Write-Host "    Found URL: $url" -ForegroundColor DarkGray
      if ($sha) { Write-Host "    Found SHA256: $sha" -ForegroundColor DarkGray }
      return [pscustomobject]@{ url = $url; Sha256 = $sha }
    }

    Write-Host "    No InstallerUrl found in manifest" -ForegroundColor DarkGray
    return $null
  } catch {
    Write-Host "    Error fetching manifest: $($_.Exception.Message)" -ForegroundColor DarkGray
    return $null
  }
}

# Begin runtime checks and path normalization
Write-Host "🚀 Building VCRedist AIO Installer..." -ForegroundColor Cyan

# Check if PS2EXE is installed
if (-not (Get-Command ps2exe -ErrorAction SilentlyContinue)) {
  Write-Error "❌ PS2EXE module is not installed. Run 'Install-Module ps2exe -Scope CurrentUser' to install it."
  exit 1
}

# === Resolve repo root and inputs ===
try {
  $root = (Resolve-Path "$PSScriptRoot\.." -ErrorAction Stop | Select-Object -First 1).Path
} catch {
  $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ($VerboseBuild.IsPresent) { Write-Host "[debug] Root resolved to: $root" -ForegroundColor DarkYellow }

if (-not $PackagesFile -or [string]::IsNullOrWhiteSpace($PackagesFile)) {
  $candidate = Join-Path $root 'packages.json'
  if (Test-Path $candidate) { $PackagesFile = (Resolve-Path $candidate).Path }
}
if (-not $PackagesFile) {
  Write-Error "❌ Packages file not specified and no packages.json found at repo root."
  exit 1
}
try { $PackagesFile = (Resolve-Path $PackagesFile -ErrorAction Stop).Path } catch {
  Write-Error "❌ Could not resolve PackagesFile path: $PackagesFile"
  exit 1
}

if (-not $Output -or [string]::IsNullOrWhiteSpace($Output)) { $Output = 'vcredist-aio.exe' }
if (-not $OutputDir -or [string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Join-Path $root 'dist' }

try {
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
  $OutputDir = (Get-Item -Path $OutputDir -ErrorAction Stop).FullName
  Write-Host "  Normalized OutputDir: $OutputDir" -ForegroundColor DarkGray
} catch {
  Write-Error "❌ Failed to create/resolve OutputDir: $OutputDir. Error: $($_.Exception.Message)"
  exit 1
}

# Load packages manifest
try {
  $packagesJson = Get-Content $PackagesFile -Raw | ConvertFrom-Json
  $packages = $packagesJson.packages
} catch {
  Write-Error "❌ Failed to load packages.json: $($_.Exception.Message)"
  exit 1
}

# === Reuse existing packages if present, otherwise download once ===
$packagesSubDir = Join-Path $OutputDir "packages"
$canReusePackages = $false
$downloadedFiles = @()
if (Test-Path $packagesSubDir) {
  try {
    $missing = @()
    foreach ($pkg in $packages) {
      if (-not $pkg.id -or -not $pkg.version) { $missing += $pkg.id; continue }
      $rawFileName = "$($pkg.id.Replace('.', '_'))_$($pkg.version).exe"
      $fileName = $rawFileName -replace '[^A-Za-z0-9._-]','_'
      $candidate = Join-Path $packagesSubDir $fileName
      if (-not (Test-Path $candidate)) { $missing += $fileName } else {
        $downloadedFiles += @{
          PackageId = $pkg.id
          FilePath = (Resolve-Path $candidate).Path
          FileName = $fileName
        }
      }
    }
    if ($missing.Count -eq 0) {
      Write-Host "ℹ All package files already present in: $packagesSubDir. Skipping download." -ForegroundColor Cyan
      $canReusePackages = $true
    } else {
      Write-Host "ℹ Missing packages in $packagesSubDir, will download missing files." -ForegroundColor Yellow
      $downloadedFiles = @()
    }
  } catch {
    Write-Warning "⚠ Failed to verify existing packages: $($_.Exception.Message)"
    $downloadedFiles = @()
  }
}

if (-not $canReusePackages) {
  $downloadDir = Join-Path $OutputDir "downloads"
  New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
  Write-Host "📥 Downloading VCRedist packages..." -ForegroundColor Cyan

  $token = $env:GITHUB_TOKEN
  $headers = @{ 'User-Agent' = 'vcredist-aio-bot' }
  if ($token) { $headers.Authorization = "token $token" }

  $failedDownloads = @()
  foreach ($pkg in $packages) {
    Write-Host "`n➡ Processing: $($pkg.id)"
    if ([string]::IsNullOrWhiteSpace($pkg.version)) {
      Write-Warning "⚠ No version specified, skipping..."
      continue
    }
    Write-Host "  Version: $($pkg.version)"
    $installerInfo = Get-InstallerInfoFromManifest -PackageId $pkg.id -Version $pkg.version -Headers $headers
    if (-not $installerInfo) {
      Write-Warning "⚠ Failed to get download info for: $($pkg.id)"
      $failedDownloads += $pkg.id
      continue
    }
    $rawFileName = "$($pkg.id.Replace('.', '_'))_$($pkg.version).exe"
    $fileName = $rawFileName -replace '[^A-Za-z0-9._-]','_'
    if ($fileName.Length -gt 120) { $fileName = $fileName.Substring(0,120) }
    $outputPath = Join-Path $downloadDir $fileName
    Write-Host "    Downloading to: $fileName" -ForegroundColor DarkGray

    $downloadResult = Invoke-WithRetry -Script {
      Invoke-WebRequest -Uri $installerInfo.url -OutFile $outputPath -UseBasicParsing -ErrorAction Stop
      return $outputPath
    } -Attempts 3 -DelaySeconds 5

    if ($downloadResult -and (Test-Path $downloadResult)) {
      if ($installerInfo.Sha256) {
        try {
          $actual = (Get-FileHash -Algorithm SHA256 $downloadResult).Hash
          if ($actual -ne $installerInfo.Sha256) {
            Write-Warning "  ⚠ SHA256 mismatch for $($pkg.id). Expected: $($installerInfo.Sha256) Got: $actual"
            Remove-Item -Path $downloadResult -Force -ErrorAction SilentlyContinue
            $failedDownloads += $pkg.id
            continue
          } else {
            Write-Host "    SHA256 verified" -ForegroundColor DarkGray
          }
        } catch {
          Write-Warning "  ⚠ Failed to compute SHA256: $($_.Exception.Message)"
        }
      }
      $size = (Get-Item $downloadResult).Length / 1MB
      Write-Host "  ✔ Downloaded ($([math]::Round($size, 2)) MB)"
      $downloadedFiles += @{
        PackageId = $pkg.id
        FilePath = $downloadResult
        FileName = $fileName
      }
    } else {
      Write-Warning "⚠ Failed to download: $($pkg.id)"
      $failedDownloads += $pkg.id
    }
  }

  if ($failedDownloads.Count -gt 0) {
    Write-Warning "`n⚠ Failed to download $($failedDownloads.Count) package(s):"
    $failedDownloads | ForEach-Object { Write-Warning "  - $_" }
  }
  if ($downloadedFiles.Count -eq 0) {
    Write-Error "❌ No packages downloaded. Build failed."
    exit 1
  }

  # create packages dir and copy
  New-Item -ItemType Directory -Path $packagesSubDir -Force | Out-Null
  foreach ($file in $downloadedFiles) {
    Copy-Item -Path $file.FilePath -Destination (Join-Path $packagesSubDir $file.FileName) -Force
    $file.FilePath = (Join-Path $packagesSubDir $file.FileName)
  }

  # cleanup temporary downloads
  try { if (Test-Path $downloadDir) { Remove-Item -Path $downloadDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
}

Write-Host "`n📦 Downloaded $($downloadedFiles.Count) packages"

# === Stage payload ===
$automationDir = Join-Path $root 'automation'
$stage = Join-Path $automationDir 'stage-ps2exe'
$payloadDir = Join-Path $stage 'payload'
try {
  if (Test-Path $stage) { Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
} catch {
  Write-Error "❌ Failed to create staging directories: $($_.Exception.Message)"
  exit 1
}

# Resolve install/uninstall script paths
$installCandidatePaths = @(
  [System.IO.Path]::Combine($root,'automation','install.ps1'),
  [System.IO.Path]::Combine($root,'install.ps1')
)
$uninstallCandidatePaths = @(
  [System.IO.Path]::Combine($root,'automation','uninstall.ps1'),
  [System.IO.Path]::Combine($root,'uninstall.ps1')
)

$installCandidates = @()
foreach ($p in $installCandidatePaths) { if (Test-Path $p) { try { $installCandidates += (Resolve-Path $p -ErrorAction Stop).Path } catch {} } }
$uninstallCandidates = @()
foreach ($p in $uninstallCandidatePaths) { if (Test-Path $p) { try { $uninstallCandidates += (Resolve-Path $p -ErrorAction Stop).Path } catch {} } }

if ($installCandidates.Count -eq 0 -or $uninstallCandidates.Count -eq 0) {
  Write-Error "❌ Could not find install.ps1 or uninstall.ps1 in expected locations."
  Write-Host "  Searched: $($installCandidatePaths -join ', ')" -ForegroundColor DarkGray
  Write-Host "  Searched: $($uninstallCandidatePaths -join ', ')" -ForegroundColor DarkGray
  exit 1
}

$installSource = $installCandidates[0]
$uninstallSource = $uninstallCandidates[0]
if ($VerboseBuild.IsPresent) { Write-Host "[debug] Resolved installSource: $installSource"; Write-Host "[debug] Resolved uninstallSource: $uninstallSource" }

Copy-Item -Path $installSource -Destination (Join-Path $payloadDir "install.ps1") -Force
Copy-Item -Path $uninstallSource -Destination (Join-Path $payloadDir "uninstall.ps1") -Force
Write-Host "[debug] Copied install/uninstall to payload dir" -ForegroundColor DarkGray

# Copy packages into payload/packages
$payloadPackagesDir = Join-Path $payloadDir 'packages'
New-Item -ItemType Directory -Path $payloadPackagesDir -Force | Out-Null
foreach ($f in Get-ChildItem -Path $packagesSubDir -File) {
  Copy-Item -Path $f.FullName -Destination (Join-Path $payloadPackagesDir $f.Name) -Force
  if ($VerboseBuild.IsPresent) { Write-Host "[debug] payload: packages\$($f.Name) -> $(Join-Path $payloadPackagesDir $f.Name)" -ForegroundColor DarkGray }
}

if ($VerboseBuild.IsPresent) { Write-Host "[debug] Copied install/uninstall to payload dir" }


$payloadFiles = @()
$payloadFiles += @{ Full = (Join-Path $payloadDir "install.ps1"); Relative = "install.ps1" }
$payloadFiles += @{ Full = (Join-Path $payloadDir "uninstall.ps1"); Relative = "uninstall.ps1" }

# Include any package files copied into the staging payload/packages directory
if (Test-Path $payloadPackagesDir) {
  Get-ChildItem -Path $payloadPackagesDir -File -Recurse | ForEach-Object {
    $rel = Join-Path "packages" $_.Name
    $payloadFiles += @{ Full = $_.FullName; Relative = $rel }
  }
}

if ($VerboseBuild.IsPresent) { Write-Host "[debug] payloadFiles count: $($payloadFiles.Count)" -ForegroundColor DarkYellow }
if ($VerboseBuild.IsPresent) { foreach ($pf in $payloadFiles) { Write-Host "[debug] payload: $($pf.Relative) -> $($pf.Full)" -ForegroundColor DarkGray } }

Write-Host "Encoding payload into bootstrap..."

if ($VerboseBuild.IsPresent) { Write-Host "[debug] bootstrap will include $($payloadFiles.Count) files" -ForegroundColor DarkYellow }

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
$bootstrapBuilder.AppendLine('$extractRoot = Join-Path $env:TEMP ''vcredist-aio-runtime''') | Out-Null
$bootstrapBuilder.AppendLine("if (Test-Path $extractRoot) { Remove-Item $extractRoot -Recurse -Force }") | Out-Null
$bootstrapBuilder.AppendLine("New-Item $extractRoot -ItemType Directory | Out-Null") | Out-Null
$bootstrapBuilder.AppendLine("") | Out-Null
$bootstrapBuilder.AppendLine("# Embedded payload (Base64)") | Out-Null
$bootstrapBuilder.AppendLine("$EmbeddedFiles = @{}") | Out-Null

foreach ($p in $payloadFiles) {
  if (-not (Test-Path $p.Full)) { continue }
  $b64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p.Full))
  $relPath = ($p.Relative -replace "\\","/")
  $bootstrapBuilder.AppendLine('$EmbeddedFiles[' + "'" + $relPath + "'" + "] = @'") | Out-Null
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
$bootstrapBuilder.AppendLine('$script = if ($Uninstall) { Join-Path $extractRoot ''uninstall.ps1'' } else { Join-Path $extractRoot ''install.ps1'' }') | Out-Null
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

try {
  $bf = Get-Item $bootstrapFile -ErrorAction Stop
  if ($VerboseBuild.IsPresent) { Write-Host "[debug] Wrote bootstrap: $bootstrapFile ($([math]::Round($bf.Length/1KB,2)) KB)" -ForegroundColor DarkYellow }
} catch {}

### ---- RUN PS2EXE ----

Write-Host "Building EXE (PS2EXE)..."

$iconPath = Join-Path $root "icon.ico"
if (-not (Test-Path $iconPath)) { $iconPath = $null }
$exeFullPath = Join-Path $OutputDir $Output

# Prefer the cmdlet interface provided by the ps2exe module
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
  Write-Error "❌ PS2EXE cmdlet 'Invoke-ps2exe' not found. Ensure 'Install-Module ps2exe -Scope CurrentUser' ran successfully in CI."
  exit 1
}

$noConsoleBool = -not $VerboseBuild.IsPresent
$invokeParams = @{
  inputFile = $bootstrapFile
  outputFile = $exeFullPath
  noConsole = $noConsoleBool
  title = 'VC Redist AIO'
  description = 'All-in-one VC Redist installer'
}
if ($iconPath -and (Test-Path $iconPath)) { $invokeParams.iconFile = $iconPath }

if ($VerboseBuild.IsPresent) {
  Write-Host "[debug] Invoking Invoke-ps2exe with parameters:" -ForegroundColor DarkYellow
  $invokeParams.GetEnumerator() | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

try {
  Invoke-ps2exe @invokeParams
  Write-Host "Build complete. Output: $exeFullPath" -ForegroundColor Green
} catch {
  Write-Error "❌ PS2EXE build failed: $($_.Exception.Message)"
  if ($VerboseBuild.IsPresent) { Write-Host $_.Exception.StackTrace -ForegroundColor DarkGray }
  exit 1
}

### ---- CLEAN UP ----
try {
  if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
  if (Test-Path $downloadDir) { Remove-Item $downloadDir -Recurse -Force }
} catch {
  Write-Warning "⚠ Failed to clean up temporary directories: $($_.Exception.Message)"
}

if ($VerboseBuild.IsPresent) { Write-Host "[debug] cleanup attempted for stage and downloads" -ForegroundColor DarkYellow }

# Validate output file after build
## Locate output EXE (prefer OutputDir) and validate
$outputCandidates = @()
$outputCandidates += (Join-Path $OutputDir $Output)
try { $resolved = (Resolve-Path $Output -ErrorAction SilentlyContinue).Path; if ($resolved) { $outputCandidates += $resolved } } catch {}

$exePath = $null
foreach ($c in $outputCandidates) {
  if ($c -and (Test-Path $c)) { $exePath = $c; break }
}

if (-not $exePath) {
  Write-Error "❌ Build failed. Output file not found. Searched: $($outputCandidates -join ', ')"
  exit 1
}

Write-Host "✔ Build successful. Output: $exePath"

# Compute SHA256 and size, write checksum file(s) into OutputDir
try {
  $exeFileName = Split-Path $exePath -Leaf
  $exeHash = (Get-FileHash -Algorithm SHA256 -Path $exePath).Hash
  $exeSizeMB = [math]::Round((Get-Item $exePath).Length / 1MB,2)

  $shaFile = Join-Path $OutputDir "SHA256.txt"
  "$exeHash  $exeFileName" | Out-File -FilePath $shaFile -Encoding ASCII -Force

  $shaSumsFile = Join-Path $OutputDir "SHA256SUMS.txt"
  @("$exeHash  $exeFileName") | Out-File -FilePath $shaSumsFile -Encoding ASCII -Force

  Write-Host "🔐 SHA256: $exeHash" -ForegroundColor DarkGray
  Write-Host "📏 Size: $exeSizeMB MB" -ForegroundColor DarkGray
} catch {
  Write-Warning "⚠ Failed to compute SHA256 or write checksum files: $($_.Exception.Message)"
}

# Final message
Write-Host "Build metadata written to: $OutputDir" -ForegroundColor Green
