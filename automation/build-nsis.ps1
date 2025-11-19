param(
    [Parameter(Mandatory = $true)]
    [string] $PackagesFile,

    [Parameter(Mandatory = $true)]
    [string] $OutputDir,
    
    [Parameter(Mandatory = $false)]
    [switch] $DebugMode = $false
)

$ErrorActionPreference = "Stop"

if ($DebugMode) {
    Write-Host "🐛 DEBUG MODE ENABLED" -ForegroundColor Yellow
    $VerbosePreference = 'Continue'
    $DebugPreference = 'Continue'
}

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

Write-Host "🚀 Building VCRedist AIO NSIS Installer..." -ForegroundColor Cyan

# Load packages
$packagesJson = Get-Content $PackagesFile -Raw | ConvertFrom-Json
$packages = $packagesJson.packages

# Create output directory
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

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

# Ensure NSIS is installed
Write-Host "`n🔍 Checking for NSIS..." -ForegroundColor Cyan

$nsisPath = $null
$possiblePaths = @(
    "C:\Program Files (x86)\NSIS\makensis.exe",
    "C:\Program Files\NSIS\makensis.exe",
    "${env:ProgramFiles(x86)}\NSIS\makensis.exe",
    "$env:ProgramFiles\NSIS\makensis.exe"
)

foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
        $nsisPath = $path
        Write-Host "  Found NSIS at: $path" -ForegroundColor DarkGray
        break
    }
}

if (-not $nsisPath) {
    Write-Error "❌ NSIS not found. Checked paths:"
    foreach ($path in $possiblePaths) {
        Write-Host "  - $path" -ForegroundColor DarkGray
    }
    Write-Host "`nPlease install NSIS from: https://nsis.sourceforge.io/Download" -ForegroundColor Yellow
    Write-Host "Or run: choco install nsis -y" -ForegroundColor Yellow
    exit 1
}

# Verify NSIS version

try {
    $nsisVersion = & $nsisPath /VERSION 2>$null
    Write-Host "✔ NSIS found: $nsisPath (version: $nsisVersion)" -ForegroundColor Green
    # Enforce minimum version 3.0
    $verMatch = [regex]::Match($nsisVersion, '(\d+)\.(\d+)(?:\.(\d+))?')
    if ($verMatch.Success) {
        $major = [int]$verMatch.Groups[1].Value
        $minor = [int]$verMatch.Groups[2].Value
        if ($major -lt 3) {
            Write-Error "❌ NSIS version $nsisVersion is too old. Version 3.0 or higher is required."
            exit 1
        }
    } else {
        Write-Warning "⚠ Could not parse NSIS version string: $nsisVersion. Proceeding, but build may fail."
    }
} catch {
    Write-Host "✔ NSIS found: $nsisPath" -ForegroundColor Green
}

# Copy install.ps1 and uninstall.ps1 to output directory
$installScriptPath = Join-Path $PSScriptRoot "install.ps1"
$uninstallScriptPath = Join-Path $PSScriptRoot "uninstall.ps1"

# Ensure scripts are copied as UTF-8 (re-encode if needed)
function Copy-AsUtf8 {
    param(
        [string]$Source,
        [string]$Destination
    )
    $content = Get-Content -Path $Source -Raw
    [System.IO.File]::WriteAllText($Destination, $content, [System.Text.Encoding]::UTF8)
}

Copy-AsUtf8 -Source $installScriptPath -Destination (Join-Path $OutputDir 'install.ps1')
Copy-AsUtf8 -Source $uninstallScriptPath -Destination (Join-Path $OutputDir 'uninstall.ps1')

# === Diagnostics: Check for required files and list directory contents ===
$requiredFiles = @('install.ps1', 'uninstall.ps1')
foreach ($file in $requiredFiles) {
    $fullPath = Join-Path $OutputDir $file
    if (-not (Test-Path $fullPath)) {
        Write-Error "❌ Required file missing in output directory: $file"
        exit 1
    }
}

# Check for all package files
$missingPackages = @()
foreach ($file in $downloadedFiles) {
    $pkgPath = Join-Path $packagesSubDir $file.FileName
    if (-not (Test-Path $pkgPath)) {
        $missingPackages += $file.FileName
    }
}
if ($missingPackages.Count -gt 0) {
    Write-Error "❌ Missing package files in $packagesSubDir:`n  $($missingPackages -join "`n  ")"
    exit 1
}

# Warn if scripts contain non-ASCII characters
foreach ($script in @('install.ps1', 'uninstall.ps1')) {
    $path = Join-Path $OutputDir $script
    $content = Get-Content $path -Raw
    if ($content -match '[^\x00-\x7F]') {
        Write-Warning "⚠ $script contains non-ASCII characters. This may cause encoding issues."
    }
}

Write-Host "`n📂 Output directory contents before NSIS compilation:" -ForegroundColor Yellow
Get-ChildItem -Path $OutputDir -Recurse | ForEach-Object {
    $size = if ($_.PSIsContainer) { "<DIR>" } else { "$([math]::Round($_.Length/1KB,1)) KB" }
    Write-Host ("  {0,-60} {1,8}" -f $_.FullName, $size)
}

# Read template

try {
    $templateContent = Get-Content -Path $templatePath -Raw -ErrorAction Stop
} catch {
    Write-Error "❌ Failed to read template file: $templatePath. Error: $($_.Exception.Message)"
    exit 1
}

# Validate required placeholders exist
if ($templateContent -notmatch '\{\{VERSION\}\}') {
    Write-Error "❌ Template missing {{VERSION}} placeholder"
    exit 1
}

if ($templateContent -notmatch '\{\{FILE_LIST\}\}') {
    Write-Error "❌ Template missing {{FILE_LIST}} placeholder"
    exit 1
}

Write-Host "  Template validation: OK" -ForegroundColor DarkGray

# Build file list for packages
$fileListLines = @()
foreach ($file in $downloadedFiles) {
    $fileListLines += "  File `"packages\$($file.FileName)`""
}
$fileList = $fileListLines -join "`r`n"

# Replace placeholders in template
$nsisContent = $templateContent -replace '{{VERSION}}', $productVersion
$nsisContent = $nsisContent -replace '{{FILE_LIST}}', $fileList

# Write NSIS script with ASCII encoding

try {
    [System.IO.File]::WriteAllText($nsisScript, $nsisContent, [System.Text.Encoding]::ASCII)
} catch {
    Write-Error "❌ Failed to write NSIS script: $nsisScript. Error: $($_.Exception.Message)"
    exit 1
}
Write-Host "`n📝 First 20 lines of NSIS script:" -ForegroundColor Yellow
Get-Content $nsisScript -TotalCount 20 | ForEach-Object { Write-Host "  $_" }

# Set working directory for NSIS compilation
Push-Location $OutputDir
try {
    # Compile NSIS installer
    Write-Host "`n🔨 Compiling NSIS installer..." -ForegroundColor Cyan

    # Create log file for NSIS output
    $nsisLogFile = Join-Path $OutputDir "nsis-build.log"

    $nsisArgs = @(
        "/V4",  # Verbosity level 4 (highest)
        $nsisScript
    )

    Write-Host "  NSIS command: $nsisPath $($nsisArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host "  NSIS log: $nsisLogFile" -ForegroundColor DarkGray

    # Run NSIS with simple output redirection (avoiding runspace issues)
    try {
        $output = & $nsisPath $nsisArgs 2>&1
        $exitCode = $LASTEXITCODE
        
        # Save output to log file
        $logContent = "NSIS Build Log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
        $logContent += "=" * 80 + "`n"
        $logContent += "Script: $nsisScript`n"
        $logContent += "Output File: VC_Redist_AIO_Offline.exe`n"
        $logContent += "Exit Code: $exitCode`n"
        $logContent += "`nOutput:`n"
        $logContent += $output -join "`n"
        
        $logContent | Out-File $nsisLogFile -Encoding UTF8 -Force
        
        # Display output with color coding
        if ($DebugMode) {
            $output | ForEach-Object {
                $line = $_.ToString()
                if ($line -match "error|fail|warning") {
                    Write-Host "  NSIS: $line" -ForegroundColor Yellow
                } else {
                    Write-Host "  NSIS: $line" -ForegroundColor DarkGray
                }
            }
        }
        
        # Check exit code
        if ($exitCode -ne 0) {
            Write-Error "❌ NSIS compilation failed with exit code: $exitCode"
            Write-Host "`n📋 NSIS build log saved to: $nsisLogFile" -ForegroundColor Yellow
            
            # Display full log content on failure
            if (Test-Path $nsisLogFile) {
                Write-Host "`n📄 Full NSIS build log:" -ForegroundColor Yellow
                Write-Host "================================" -ForegroundColor Yellow
                Get-Content $nsisLogFile | ForEach-Object { Write-Host $_ }
                Write-Host "================================" -ForegroundColor Yellow
            } else {
                Write-Host "`nLast 20 lines of output:" -ForegroundColor Yellow
                $output | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
            }
            exit 1
        }
        
        Write-Host "✔ NSIS compilation successful" -ForegroundColor Green
        
    } catch {
        Write-Host "`n❌ NSIS execution failed: $($_.Exception.Message)" -ForegroundColor Red
        
        # Try to display the log file if it exists
        if (Test-Path $nsisLogFile) {
            Write-Host "`n📄 Full NSIS build log:" -ForegroundColor Yellow
            Write-Host "================================" -ForegroundColor Yellow
            Get-Content $nsisLogFile | ForEach-Object { Write-Host $_ }
            Write-Host "================================" -ForegroundColor Yellow
        }
        
        Write-Error "NSIS compilation failed"
        exit 1
    }
} finally {
    Pop-Location
}

$outputExe = Join-Path $OutputDir "VC_Redist_AIO_Offline.exe"
if (-not (Test-Path $outputExe)) {
    Write-Error "❌ Output EXE not created: $outputExe"
    exit 1
}

Write-Host "✔ NSIS installer created: $outputExe" -ForegroundColor Green

# Compute checksums
Write-Host "`n🔐 Computing SHA256 checksums..." -ForegroundColor Cyan

$checksumFile = Join-Path $OutputDir "SHA256.txt"
$hash = Get-FileHash $outputExe -Algorithm SHA256
$checksumContent = "$($hash.Hash)  $(Split-Path $outputExe -Leaf)"
$checksumContent | Out-File $checksumFile -Encoding ASCII -Force
Write-Host "  EXE: $($hash.Hash)" -ForegroundColor DarkGray

# Cleanup
Write-Host "`n🧹 Cleaning up temporary files..." -ForegroundColor Cyan
if (Test-Path $downloadDir) {
    Remove-Item -Path $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
}
# Keep NSIS script for debugging
Write-Host "  ℹ NSIS script kept for debugging: $nsisScript" -ForegroundColor DarkGray
Write-Host "  ℹ NSIS build log: $nsisLogFile" -ForegroundColor DarkGray
Write-Host "✔ Cleanup complete"

Write-Host "`n✅ Build completed successfully!" -ForegroundColor Green
Write-Host "📦 Output: $outputExe"
Write-Host "📊 Total packages: $($downloadedFiles.Count)"
$exeSize = [math]::Round((Get-Item $outputExe).Length / 1MB, 2)
Write-Host "📏 Installer size: $exeSize MB"

exit 0