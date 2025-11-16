param(
    [Parameter(Mandatory = $true)]
    [string] $PackagesFile,

    [Parameter(Mandatory = $true)]
    [string] $OutputDir,

    [Parameter(Mandatory = $true)]
    [string] $PSEXEPath
)

$ErrorActionPreference = "Stop"

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
            if ($i -lt $Attempts) {
                $wait = [math]::Min(30, $DelaySeconds * [math]::Pow(2, $i - 1))
                $wait = $wait + (Get-Random -Minimum 0 -Maximum 3)
                Write-Host ("Retry {0}/{1} failed: {2}. Waiting {3} seconds before retry..." -f $i, $Attempts, $_.Exception.Message, [int]$wait)
                Start-Sleep -Seconds $wait
            }
            else {
                Write-Warning ("Operation failed after {0} attempts: {1}" -f $Attempts, $_.Exception.Message)
                return $null
            }
        }
    }
}

function Get-DownloadUrlFromManifest {
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
        
        # Determine if this is an architecture-specific package (VCRedist)
        $isArchSpecific = $PackageId -match "VCRedist" -and $parts.Length -ge 3
        
        if ($isArchSpecific) {
            # VCRedist packages: manifests/m/Microsoft/VCRedist/2008/x64/version
            $versionPart = $parts[2]
            $arch = if ($PackageId -match "x64") { "x64" } else { "x86" }
            $folderYear = if ($versionPart -eq "2015Plus") { "2015+" } else { $versionPart }
            $versionPath = "manifests/m/$vendor/$product/$folderYear/$arch/$Version"
        } else {
            # Other packages: manifests/m/Microsoft/VSTOR/version
            $versionPath = "manifests/m/$vendor/$product/$Version"
        }
        
        $versionUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$versionPath"

        Write-Host "    Fetching manifest: $versionPath" -ForegroundColor DarkGray

        # Get manifest files
        $manifestFiles = Invoke-WithRetry -Script { 
            Invoke-RestMethod -Uri $versionUrl -Headers $Headers -ErrorAction Stop 
        } -Attempts 2 -DelaySeconds 2

        if (-not $manifestFiles) { return $null }

        # Find the installer YAML file
        $installerYaml = $manifestFiles | Where-Object { 
            $_.type -eq 'file' -and $_.name -match 'installer\.ya?ml$' 
        } | Select-Object -First 1

        if (-not $installerYaml) { return $null }

        # Fetch and parse YAML content
        $fileObj = Invoke-WithRetry -Script { 
            Invoke-RestMethod -Uri $installerYaml.url -Headers $Headers -ErrorAction Stop 
        } -Attempts 2 -DelaySeconds 2

        if (-not $fileObj -or -not $fileObj.content) { return $null }

        $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))

        # Extract InstallerUrl from YAML
        $urlMatch = [regex]::Match($content, 'InstallerUrl:\s*([^\s#]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
        
        if ($urlMatch.Success) {
            $url = $urlMatch.Groups[1].Value.Trim()
            # Remove surrounding quotes if present
            $quoteChar = [char]34  # Double quote
            $singleQuote = [char]39  # Single quote
            while ($url.Length -gt 0 -and ($url[0] -eq $quoteChar -or $url[0] -eq $singleQuote)) {
                $url = $url.Substring(1)
            }
            while ($url.Length -gt 0 -and ($url[-1] -eq $quoteChar -or $url[-1] -eq $singleQuote)) {
                $url = $url.Substring(0, $url.Length - 1)
            }
            Write-Host "    Found URL: $url" -ForegroundColor DarkGray
            return $url
        }

        Write-Host "    No InstallerUrl found in manifest" -ForegroundColor DarkGray
        return $null
    } catch {
        Write-Host "    Error fetching manifest: $($_.Exception.Message)" -ForegroundColor DarkGray
        return $null
    }
}

Write-Host "🚀 Building VCRedist AIO Offline Installer..." -ForegroundColor Cyan

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

    # Get download URL from manifest
    $downloadUrl = Get-DownloadUrlFromManifest -PackageId $pkg.id -Version $pkg.version -Headers $headers

    if (-not $downloadUrl) {
        Write-Warning "⚠ Failed to get download URL for: $($pkg.id)"
        $failedDownloads += $pkg.id
        continue
    }

    # Download the file
    $downloadResult = Invoke-WithRetry -Script {
        # Generate unique filename based on PackageId and version
        $fileName = "$($pkg.id.Replace('.', '_'))_$($pkg.version).exe"
        $outputPath = Join-Path $downloadDir $fileName
        
        Write-Host "    Downloading to: $fileName" -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $downloadUrl -OutFile $outputPath -UseBasicParsing -ErrorAction Stop
        return $outputPath
    } -Attempts 3 -DelaySeconds 5

    if ($downloadResult -and (Test-Path $downloadResult)) {
        $size = (Get-Item $downloadResult).Length / 1MB
        Write-Host "  ✔ Downloaded ($([math]::Round($size, 2)) MB)"
        $downloadedFiles += @{
            PackageId = $pkg.id
            FilePath = $downloadResult
            FileName = Split-Path $downloadResult -Leaf
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

# Verify we have at least some files
if ($downloadedFiles.Count -eq 0) {
    Write-Error "❌ No packages downloaded. Build failed."
    exit 1
}

Write-Host "`n📦 Downloaded $($downloadedFiles.Count) packages"

# Create installer wrapper script that uses install.ps1
Write-Host "`n📄 Generating installer wrapper..." -ForegroundColor Cyan

$scriptPath = Join-Path $OutputDir "installer.ps1"

# Read the standalone install.ps1 template
$installScriptPath = Join-Path $PSScriptRoot "install.ps1"

if (-not (Test-Path $installScriptPath)) {
    Write-Error "❌ install.ps1 template not found at: $installScriptPath"
    exit 1
}

$installScriptTemplate = Get-Content $installScriptPath -Raw

# Create a lightweight wrapper that calls the install script with proper paths
$installerScript = @"
# VCRedist AIO Offline Installer Wrapper
# Generated by build script at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# This wrapper sets up the environment and invokes the installation engine

param(
    [switch] `$Silent = `$false,
    [switch] `$SkipValidation = `$false
)

# Determine paths relative to this script
`$scriptDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$packageDir = Join-Path `$scriptDir "packages"
`$logDir = `$scriptDir

# Embedded installation engine from install.ps1
$installScriptTemplate

# End of wrapper
"@

$installerScript | Out-File $scriptPath -Encoding UTF8 -Force
Write-Host "✔ Installer wrapper created" -ForegroundColor Green

Write-Host "`n📋 Creating package bundle..." -ForegroundColor Cyan

# Create packages subfolder with organized structure
$packagesSubDir = Join-Path $OutputDir "packages"
New-Item -ItemType Directory -Path $packagesSubDir -Force | Out-Null

foreach ($file in $downloadedFiles) {
    Copy-Item -Path $file.FilePath -Destination (Join-Path $packagesSubDir $file.FileName) -Force
    $size = (Get-Item $file.FilePath).Length / 1MB
    Write-Host "  ✔ $($file.FileName) ($([math]::Round($size, 2)) MB)"
}

Write-Host "✔ Packages bundled ($($downloadedFiles.Count) files)"

# Ensure ps2exe module is available
Write-Host "`n📦 Verifying ps2exe environment..." -ForegroundColor Cyan

$ps2exeCheck = pwsh -Command "
    try {
        if (-not (Get-Module -ListAvailable -Name ps2exe)) {
            Write-Host 'Installing ps2exe module...'
            Install-Module -Name ps2exe -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        }
        Import-Module ps2exe -ErrorAction Stop
        Write-Host 'ps2exe ready'
        exit 0
    } catch {
        Write-Error `"ps2exe setup failed: `$_`"
        exit 1
    }
"

if ($LASTEXITCODE -ne 0) {
    Write-Error "❌ Failed to initialize ps2exe. Aborting build."
    exit 1
}

# Convert PowerShell script to EXE
Write-Host "`n🔨 Converting installer.ps1 → EXE using ps2exe..." -ForegroundColor Cyan

$cfg = Get-Content $PSEXEPath -Raw | ConvertFrom-Json
$inputFile = $scriptPath
$outputFile = Join-Path $OutputDir "VC_Redist_AIO_Offline.exe"
$requireAdmin = $cfg.requireAdmin
$noConsole = $cfg.noConsole

$ps2exeCmd = @"
Import-Module ps2exe -ErrorAction Stop
Invoke-ps2exe -InputFile `"$inputFile`" -OutputFile `"$outputFile`" -RequireAdmin:`$$requireAdmin -NoConsole:`$$noConsole -ErrorAction Stop
"@

$ps2exeResult = pwsh -Command $ps2exeCmd

if ($LASTEXITCODE -ne 0) {
    Write-Error "❌ ps2exe conversion failed: $ps2exeResult"
    exit 1
}

if (-not (Test-Path $outputFile)) {
    Write-Error "❌ Output EXE not created: $outputFile"
    exit 1
}

Write-Host "✔ EXE created: $outputFile"

# Create SHA256 checksum
if (Test-Path $outputFile) {
    $hash = Get-FileHash $outputFile -Algorithm SHA256
    $checksumFile = Join-Path (Split-Path $outputFile -Parent) "SHA256.txt"
    
    "$($hash.Hash)  $(Split-Path $outputFile -Leaf)" | Out-File $checksumFile -Encoding ASCII -Force
    Write-Host "🔐 SHA256: $($hash.Hash)"
    Write-Host "📄 Checksum: $checksumFile"
}

Write-Host "`n✅ Build completed successfully!" -ForegroundColor Green
Write-Host "📦 Output: $outputFile"
Write-Host "📊 Total packages: $($downloadedFiles.Count)"

exit 0