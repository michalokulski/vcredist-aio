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

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $Script,
        [int] $Attempts = 3,
        [int] $DelaySeconds = 2
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
                $wait = [math]::Min(30, $DelaySeconds * [math]::Pow(2, $i - 1))
                $wait = $wait + (Get-Random -Minimum 0 -Maximum 3)
                Write-Host ("Retry {0}/{1} failed: {2}. Waiting {3} seconds before retry..." -f $i, $Attempts, $msg, [int]$wait)
                Start-Sleep -Seconds $wait
            }
            else {
                Write-Warning ("Operation failed after {0} attempts: {1}" -f $Attempts, $msg)
                return $null
            }
        }
    }
}

function Get-InstallerInfoFromManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageId,
        [Parameter(Mandatory = $true)]
        [string] $Version,
        [Parameter(Mandatory = $true)]
        [hashtable] $Headers
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
            $_.type -eq 'file' -and $_.name -match 'installer\.ya?ml$' 
        } | Select-Object -First 1

        if (-not $installerYaml) { return $null }

        $fileObj = Invoke-WithRetry -Script { 
            Invoke-RestMethod -Uri $installerYaml.url -Headers $Headers -ErrorAction Stop 
        } -Attempts 2 -DelaySeconds 2

        if (-not $fileObj -or -not $fileObj.content) { return $null }

        $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))

        $urlMatch = [regex]::Match($content, 'InstallerUrl:\s*([^\s#]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $shaMatch = [regex]::Match($content, 'InstallerSha256:\s*([0-9A-Fa-f]{64})', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)

        if ($urlMatch.Success) {
            $url = $urlMatch.Groups[1].Value.Trim()
            $quoteChar = [char]34
            $singleQuote = [char]39
            while ($url.Length -gt 0 -and ($url[0] -eq $quoteChar -or $url[0] -eq $singleQuote)) {
                $url = $url.Substring(1)
            }
            while ($url.Length -gt 0 -and ($url[-1] -eq $quoteChar -or $url[-1] -eq $singleQuote)) {
                $url = $url.Substring(0, $url.Length - 1)
            }
            $sha = if ($shaMatch.Success) { $shaMatch.Groups[1].Value.Trim() } else { $null }
            Write-Host "    Found URL: $url" -ForegroundColor DarkGray
            if ($sha) { Write-Host "    Found SHA256: $sha" -ForegroundColor DarkGray }
            return [pscustomobject]@{ Url = $url; Sha256 = $sha }
        }

        Write-Host "    No InstallerUrl found in manifest" -ForegroundColor DarkGray
        return $null
    } catch {
        Write-Host "    Error fetching manifest: $($_.Exception.Message)" -ForegroundColor DarkGray
        return $null
    }
}

Write-Host "🚀 Building VCRedist AIO Installer..." -ForegroundColor Cyan

# Check if PS2EXE is installed
if (-not (Get-Command ps2exe -ErrorAction SilentlyContinue)) {
    Write-Error "❌ PS2EXE module is not installed. Run 'Install-Module ps2exe -Scope CurrentUser' to install it."
    exit 1
}

# Validate PackagesFile parameter
if (-not (Test-Path $PackagesFile)) {
    Write-Error "❌ Packages file not found: $PackagesFile"
    exit 1
}

# Load packages
$packagesJson = Get-Content $PackagesFile -Raw | ConvertFrom-Json
$packages = $packagesJson.packages

# Create output directory
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Normalize OutputDir to an absolute path to avoid relative path duplication later
try {
    $OutputDir = (Get-Item -Path $OutputDir -ErrorAction Stop).FullName
    Write-Host "  Normalized OutputDir: $OutputDir" -ForegroundColor DarkGray
} catch {
    Write-Error "❌ Failed to resolve OutputDir to full path: $OutputDir. Error: $($_.Exception.Message)"
    exit 1
}

# Create temporary download directory
$downloadDir = Join-Path $OutputDir "downloads"
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

Write-Host "📥 Downloading VCRedist packages..." -ForegroundColor Cyan

$token = $env:GITHUB_TOKEN
$headers = @{ 'User-Agent' = 'vcredist-aio-bot' }
if ($token) { $headers.Authorization = "token $token" }

$failedDownloads = @()
$downloadedFiles = @()

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

    # Sanitize filename: allow only alphanumerics, dash, underscore, and dot
    $rawFileName = "$($pkg.id.Replace('.', '_'))_$($pkg.version).exe"
    $fileName = $rawFileName -replace '[^A-Za-z0-9._-]', '_'
    if ($fileName -ne $rawFileName) {
        Write-Host "  Filename sanitized: $rawFileName -> $fileName" -ForegroundColor Yellow
    }
    if ($fileName.Length -gt 100) {
        $fileName = $fileName.Substring(0, 100)
        Write-Host "  Filename truncated to 100 chars: $fileName" -ForegroundColor Yellow
    }
    if ($fileName -match '^[.]+$' -or [string]::IsNullOrWhiteSpace($fileName)) {
        Write-Warning "❌ Invalid filename generated for $($pkg.id). Skipping."
        $failedDownloads += $pkg.id
        continue
    }

    $downloadResult = Invoke-WithRetry -Script {
        $outputPath = Join-Path $downloadDir $fileName
        Write-Host "    Downloading to: $fileName" -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $installerInfo.Url -OutFile $outputPath -UseBasicParsing -ErrorAction Stop
        return $outputPath
    } -Attempts 3 -DelaySeconds 5

    if ($downloadResult -and (Test-Path $downloadResult)) {
        # Optional: verify SHA256 if available
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

Write-Host "`n📦 Downloaded $($downloadedFiles.Count) packages"

# Create packages subfolder
$packagesSubDir = Join-Path $OutputDir "packages"
New-Item -ItemType Directory -Path $packagesSubDir -Force | Out-Null

Write-Host "`n📋 Creating package bundle..." -ForegroundColor Cyan

foreach ($file in $downloadedFiles) {
    Copy-Item -Path $file.FilePath -Destination (Join-Path $packagesSubDir $file.FileName) -Force
    $size = (Get-Item $file.FilePath).Length / 1MB
    Write-Host "  ✔ $($file.FileName) ($([math]::Round($size, 2)) MB)"
}

Write-Host "✔ Packages bundled ($($downloadedFiles.Count) files)"

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
    Join-Path $root "automation/install.ps1",
    Join-Path $root "install.ps1"
) | Where-Object { Test-Path $_ }

$uninstallCandidates = @(
    Join-Path $root "automation/uninstall.ps1",
    Join-Path $root "uninstall.ps1"
) | Where-Object { Test-Path $_ }

if ($installCandidates.Count -eq 0 -or $uninstallCandidates.Count -eq 0) {
    Write-Error "❌ Could not find install.ps1 or uninstall.ps1 in expected locations."
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
try {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    if (Test-Path $downloadDir) { Remove-Item $downloadDir -Recurse -Force }
} catch {
    Write-Warning "⚠ Failed to clean up temporary directories: $($_.Exception.Message)"
}

# Validate output file after build
if (-not (Test-Path $Output)) {
    Write-Error "❌ Build failed. Output file not found: $Output"
    exit 1
}
Write-Host "✔ Build successful. Output: $Output"
