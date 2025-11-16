param(
    [Parameter(Mandatory = $true)]
    [string] $PackagesFile,

    [Parameter(Mandatory = $true)]
    [string] $OutputDir
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

    $downloadUrl = Get-DownloadUrlFromManifest -PackageId $pkg.id -Version $pkg.version -Headers $headers

    if (-not $downloadUrl) {
        Write-Warning "⚠ Failed to get download URL for: $($pkg.id)"
        $failedDownloads += $pkg.id
        continue
    }

    $downloadResult = Invoke-WithRetry -Script {
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

$nsisPath = "C:\Program Files (x86)\NSIS\makensis.exe"
if (-not (Test-Path $nsisPath)) {
    # Try 64-bit path as fallback
    $nsisPath = "C:\Program Files\NSIS\makensis.exe"
}

if (-not (Test-Path $nsisPath)) {
    Write-Error "❌ NSIS not found at: C:\Program Files (x86)\NSIS\makensis.exe or C:\Program Files\NSIS\makensis.exe"
    Write-Host "Please install NSIS from: https://nsis.sourceforge.io/Download" -ForegroundColor Yellow
    Write-Host "Or run: choco install nsis -y" -ForegroundColor Yellow
    exit 1
}

Write-Host "✔ NSIS found: $nsisPath" -ForegroundColor Green

# Copy install.ps1 to output directory
$installScriptPath = Join-Path $PSScriptRoot "install.ps1"
Copy-Item -Path $installScriptPath -Destination $OutputDir -Force

# Generate file list for NSIS
$fileList = ""
foreach ($file in $downloadedFiles) {
    $fileList += "  File `"packages\$($file.FileName)`"`n"
}

# Get version from 2015+ x64 package
$vcredist2015Plus = $packages | Where-Object { $_.id -eq "Microsoft.VCRedist.2015Plus.x64" }
$productVersion = if ($vcredist2015Plus) { $vcredist2015Plus.version } else { "1.0.0.0" }

# Create NSIS script
Write-Host "`n📝 Creating NSIS installer script..." -ForegroundColor Cyan

$nsisScript = Join-Path $OutputDir "installer.nsi"

$nsisContent = @"
; VCRedist AIO Offline Installer
; Generated by build-nsis.ps1

!define PRODUCT_NAME "VCRedist AIO Offline Installer"
!define PRODUCT_VERSION "$productVersion"
!define PRODUCT_PUBLISHER "VCRedist AIO"
!define PRODUCT_WEB_SITE "https://github.com/michalokulski/vcredist-aio"

; Compression
SetCompressor /SOLID lzma
SetCompressorDictSize 64

; Modern UI
!include "MUI2.nsh"
!include "LogicLib.nsh"

; Request admin privileges
RequestExecutionLevel admin

; Installer settings
Name "`${PRODUCT_NAME}"
OutFile "VC_Redist_AIO_Offline.exe"
InstallDir "`$TEMP\VCRedist_AIO_Install"
ShowInstDetails show

; Modern UI Configuration
!define MUI_ABORTWARNING
!define MUI_ICON "`${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP "`${NSISDIR}\Contrib\Graphics\Header\nsis.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP "`${NSISDIR}\Contrib\Graphics\Wizard\nsis.bmp"

; Pages
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

; Language
!insertmacro MUI_LANGUAGE "English"

; Version Information
VIProductVersion "$productVersion"
VIAddVersionKey "ProductName" "`${PRODUCT_NAME}"
VIAddVersionKey "CompanyName" "`${PRODUCT_PUBLISHER}"
VIAddVersionKey "FileDescription" "Offline installer for Microsoft Visual C++ Redistributables"
VIAddVersionKey "FileVersion" "$productVersion"
VIAddVersionKey "ProductVersion" "$productVersion"
VIAddVersionKey "LegalCopyright" "(c) 2025 VCRedist AIO"

; Installer Section
Section "MainSection" SEC01
  SetOutPath "`$INSTDIR"
  
  DetailPrint "Extracting installation files..."
  
  ; Extract installer script
  File "install.ps1"
  
  ; Create packages directory
  CreateDirectory "`$INSTDIR\packages"
  SetOutPath "`$INSTDIR\packages"
  
  ; Extract all packages
$fileList
  
  DetailPrint "Running PowerShell installation script..."
  SetOutPath "`$INSTDIR"
  
  ; Run PowerShell installer with proper error handling
  nsExec::ExecToLog 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File "`$INSTDIR\install.ps1" -PackageDir "`$INSTDIR\packages" -LogDir "`$TEMP"'
  Pop `$0
  
  ; Check exit code
  DetailPrint "Installation exit code: `$0"
  
  `${If} `$0 == 0
    DetailPrint "Installation completed successfully"
  `${ElseIf} `$0 == 1
    DetailPrint "Installation completed with warnings"
  `${Else}
    DetailPrint "Installation exited with code: `$0"
  `${EndIf}
  
  ; Cleanup
  DetailPrint "Cleaning up temporary files..."
  SetOutPath "`$TEMP"
  RMDir /r "`$INSTDIR"
  
SectionEnd

; Uninstaller (required by NSIS but not used)
Section "Uninstall"
  ; Nothing to uninstall - this is a redistributable installer
SectionEnd
"@

$nsisContent | Out-File $nsisScript -Encoding ASCII -Force
Write-Host "✔ NSIS script created" -ForegroundColor Green

# Compile NSIS installer
Write-Host "`n🔨 Compiling NSIS installer..." -ForegroundColor Cyan

$nsisArgs = @(
    "/V4"
    "`"$nsisScript`""
)

$process = Start-Process -FilePath $nsisPath -ArgumentList $nsisArgs -Wait -PassThru -NoNewWindow

if ($process.ExitCode -ne 0) {
    Write-Error "❌ NSIS compilation failed with exit code: $($process.ExitCode)"
    exit 1
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
if (Test-Path $nsisScript) {
    Remove-Item -Path $nsisScript -Force -ErrorAction SilentlyContinue
}
Write-Host "✔ Cleanup complete"

Write-Host "`n✅ Build completed successfully!" -ForegroundColor Green
Write-Host "📦 Output: $outputExe"
Write-Host "📊 Total packages: $($downloadedFiles.Count)"
$exeSize = [math]::Round((Get-Item $outputExe).Length / 1MB, 2)
Write-Host "📏 Installer size: $exeSize MB"

exit 0