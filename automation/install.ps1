<#
.SYNOPSIS
    VCRedist AIO Offline Installer - Installation Engine
.DESCRIPTION
    Installs Microsoft Visual C++ Redistributables with smart skip logic,
    architecture detection, comprehensive logging and validation.
.PARAMETER PackageDir
    Directory containing the redistributable executables
.PARAMETER LogDir
    Directory for installation logs (default: %TEMP%)
.PARAMETER Silent
    Suppress console output during installation
.PARAMETER SkipValidation
    Skip pre-installation validation checks
.PARAMETER PackageFilter
    Array of years to filter packages (e.g., "2022", "2019", "2015", "2013")
.PARAMETER ForceReinstall
    Reinstall even if already installed (overrides smart skip)
.PARAMETER ShowInstallerWindows
    Show installer UI windows (default: hidden)
#>

param(
    [Parameter(Mandatory = $false)]
    [string] $PackageDir,

    [Parameter(Mandatory = $false)]
    [string] $LogDir,

    [Parameter(Mandatory = $false)]
    [string[]] $PackageFilter,

    [switch] $Silent = $false,
    [switch] $SkipValidation = $false,
    [switch] $ForceReinstall = $false,
    [switch] $ShowInstallerWindows = $false
)

$ErrorActionPreference = "Continue"
$WarningPreference = "Continue"

# ============================================================================
# ARCHITECTURE DETECTION
# ============================================================================

$script:OSArch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
$script:IsWow64 = [Environment]::Is64BitOperatingSystem

# ============================================================================
# PATH RESOLUTION
# ============================================================================

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Get-Location
}

if ([string]::IsNullOrWhiteSpace($PackageDir)) {
    $PackageDir = Join-Path $scriptDir "packages"
}

if ($PackageFilter) {
    $PackageFilter = @(
        $PackageFilter | ForEach-Object { ($_ -split '\s*,\s*') } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

if ($LogDir -match '^("|)(.*)(\1)$') { $LogDir = $Matches[2] }

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = $env:TEMP
} else {
    if (-not (Test-Path $LogDir)) {
        try {
            New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
        } catch {
            $LogDir = $env:TEMP
        }
    }
}

# ============================================================================
# LOGGING INFRASTRUCTURE
# ============================================================================

$script:LogFile = Join-Path $LogDir "vcredist-install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$script:InstallStartTime = Get-Date
$script:RebootRequired = $false

try {
    "Installation started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFile -Encoding UTF8 -ErrorAction Stop
} catch {
    $LogDir = $env:TEMP
    $script:LogFile = Join-Path $LogDir "vcredist-install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    try {
        "Installation started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Error "FATAL: Cannot create log file even in TEMP directory!"
        exit 1
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)] [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')] [string] $Level = 'INFO',
        [switch] $NoConsole
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    try { Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction Stop } catch {}
    if (-not $NoConsole -and -not $Silent) {
        $color = switch ($Level) {
            'ERROR'   { 'Red' }
            'WARN'    { 'Yellow' }
            'SUCCESS' { 'Green' }
            'DEBUG'   { 'DarkGray' }
            default   { 'White' }
        }
        Write-Host $logEntry -ForegroundColor $color
    }
}

function Write-LogBlank {
    try { Add-Content -Path $script:LogFile -Value "" -ErrorAction Stop } catch {}
    if (-not $Silent) { Write-Host "" }
}

function Write-LogHeader {
    param([string] $Title)
    $separator = "=" * 80
    Write-Log $separator
    Write-Log $Title
    Write-Log $separator
}

# ============================================================================
# INSTALLED PACKAGE DETECTION (Smart Skip)
# ============================================================================

# Known VC++ Redistributable upgrade codes / product name patterns
# Used to detect already-installed packages and skip them
$script:InstalledVCCache = $null

function Get-InstalledVCRedistMap {
    <#
    .SYNOPSIS
        Builds a hashtable of installed VC++ redistributables keyed by
        a normalized "year+arch" string, e.g. "2015Plus_x64".
        Returns the map so callers can do O(1) lookups.
    #>
    if ($script:InstalledVCCache) { return $script:InstalledVCCache }

    $map = @{}

    $regPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $regPaths) {
        try {
            $items = Get-ItemProperty $path -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                $name = $item.DisplayName
                if (-not $name) { continue }
                if ($name -notmatch "Microsoft Visual C\+\+") { continue }

                # Determine year bucket
                $yearKey = $null
                switch -Regex ($name) {
                    "2005"      { $yearKey = "2005" }
                    "2008"      { $yearKey = "2008" }
                    "2010"      { $yearKey = "2010" }
                    "2012"      { $yearKey = "2012" }
                    "2013"      { $yearKey = "2013" }
                    "201[5-9]|202[0-9]" { $yearKey = "2015Plus" }
                }
                if (-not $yearKey) { continue }

                # Determine architecture
                $archKey = if ($name -match "\(x64\)|x64") { "x64" }
                           elseif ($name -match "\(x86\)|x86|32.bit") { "x86" }
                           elseif ($path -match "Wow6432Node") { "x86" }
                           else { "x64" }

                $key = "${yearKey}_${archKey}"
                $installedVer = $item.DisplayVersion

                # Keep the highest version found for this key
                if (-not $map.ContainsKey($key) -or
                    (Compare-VersionString $installedVer $map[$key].Version) -gt 0) {
                    $map[$key] = @{
                        Version     = $installedVer
                        DisplayName = $name
                    }
                }
            }
        } catch { }
    }

    $script:InstalledVCCache = $map
    return $map
}

function Compare-VersionString {
    param([string]$A, [string]$B)
    try {
        $va = [version]($A -replace '[^0-9.]','')
        $vb = [version]($B -replace '[^0-9.]','')
        return $va.CompareTo($vb)
    } catch {
        return [string]::Compare($A, $B)
    }
}

function Get-PackageYearArchKey {
    <#
    .SYNOPSIS
        Derives the "year+arch" lookup key from a package filename.
        e.g. "Microsoft_VCRedist_2015Plus_x64_14.40.33816.0.exe" -> "2015Plus_x64"
    #>
    param([string]$FileName)

    $yearKey = $null
    switch -Regex ($FileName) {
        "2005"      { $yearKey = "2005" }
        "2008"      { $yearKey = "2008" }
        "2010"      { $yearKey = "2010" }
        "2012"      { $yearKey = "2012" }
        "2013"      { $yearKey = "2013" }
        "2015Plus"  { $yearKey = "2015Plus" }
    }

    $archKey = if ($FileName -match "x64") { "x64" } else { "x86" }

    if ($yearKey) { return "${yearKey}_${archKey}" }
    return $null
}

function Test-PackageAlreadyInstalled {
    <#
    .SYNOPSIS
        Returns $true if the package is already installed at the same or newer version.
    #>
    param(
        [hashtable] $Package,
        [hashtable] $InstalledMap
    )

    $key = Get-PackageYearArchKey -FileName $Package.FileName
    if (-not $key) { return $false }
    if (-not $InstalledMap.ContainsKey($key)) { return $false }

    $installedEntry = $InstalledMap[$key]

    # Extract version from filename: last segment before .exe
    $verMatch = [regex]::Match($Package.FileName, '(\d+\.\d+[\.\d]*)\.exe$')
    if (-not $verMatch.Success) { return $false }

    $pkgVersion = $verMatch.Groups[1].Value
    $cmp = Compare-VersionString $installedEntry.Version $pkgVersion

    if ($cmp -ge 0) {
        Write-Log "  [SKIP] Already installed: $($installedEntry.DisplayName) v$($installedEntry.Version) >= v$pkgVersion" -Level INFO
        return $true
    }

    Write-Log "  [UPGRADE] Installed v$($installedEntry.Version) < package v$pkgVersion — will upgrade" -Level INFO
    return $false
}

# ============================================================================
# ARCHITECTURE FILTERING
# ============================================================================

function Test-PackageArchCompatible {
    <#
    .SYNOPSIS
        Returns $true if the package architecture is compatible with the OS.
        On x86 OS: skip x64 packages.
        On x64 OS: install both x86 and x64 (x86 needed for 32-bit apps).
    #>
    param([hashtable] $Package)

    if ($Package.FileName -match "x64" -and -not $script:IsWow64) {
        Write-Log "  [SKIP] x64 package skipped on 32-bit OS" -Level INFO
        return $false
    }
    return $true
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

function Write-SystemInfo {
    Write-Log "System Information:" -Level INFO
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            Write-Log "  OS: $($os.Caption) $($os.Version)" -Level INFO
            Write-Log "  Architecture: $($os.OSArchitecture)" -Level INFO
            Write-Log "  Build: $($os.BuildNumber)" -Level INFO
        }
        Write-Log "  PowerShell: $($PSVersionTable.PSVersion)" -Level INFO
        Write-Log "  OS Arch (runtime): $($script:OSArch)" -Level INFO
        Write-Log "  Silent: $Silent | ForceReinstall: $ForceReinstall" -Level INFO
    } catch {
        Write-Log "Failed to retrieve system information: $($_.Exception.Message)" -Level DEBUG
    }
}

function Test-AdministratorPrivileges {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "Administrator privileges: NOT GRANTED" -Level ERROR
        return $false
    }
    Write-Log "Administrator privileges: GRANTED" -Level SUCCESS
    return $true
}

function Test-DiskSpace {
    param([string] $Path, [int] $RequiredMB = 500)
    try {
        $drive = (Get-Item $Path).PSDrive
        $freeSpaceMB = [math]::Round($drive.Free / 1MB, 2)
        if ($freeSpaceMB -lt $RequiredMB) {
            Write-Log "Insufficient disk space: $freeSpaceMB MB available, $RequiredMB MB required" -Level ERROR
            return $false
        }
        Write-Log "Disk space: $freeSpaceMB MB available — OK" -Level SUCCESS
        return $true
    } catch {
        Write-Log "Failed to check disk space: $($_.Exception.Message)" -Level WARN
        return $true
    }
}

function Get-PackageManifest {
    param([string] $PackageDir)

    Write-Log "Scanning package directory: $PackageDir" -Level DEBUG

    if (-not (Test-Path $PackageDir)) {
        Write-Log "Package directory not found: $PackageDir" -Level ERROR
        return $null
    }

    $exeFiles = Get-ChildItem -Path $PackageDir -Filter "*.exe" -File
    if ($exeFiles.Count -eq 0) {
        Write-Log "No executable files found in: $PackageDir" -Level ERROR
        return $null
    }

    Write-Log "Found $($exeFiles.Count) package file(s)" -Level INFO

    $manifest = @()
    foreach ($file in $exeFiles) {
        $fileName = $file.BaseName

        # Determine year for sort order
        $year = 0
        if ($fileName -match '2015Plus') { $year = 2015 }
        elseif ($fileName -match '(\d{4})') { try { $year = [int]$matches[1] } catch {} }

        # Determine arch sort key (x86=0, x64=1)
        $archSort = if ($fileName -match 'x64') { 1 } else { 0 }

        # Determine install argument style
        $argStyle = if ($year -le 2008 -and $year -gt 0) { 'legacy' } else { 'modern' }

        $manifest += @{
            PackageId  = ($fileName -replace '_(\d+\.)+\d+$','') -replace '_','.'
            FileName   = $file.Name
            FilePath   = $file.FullName
            Size       = [math]::Round($file.Length / 1MB, 2)
            Year       = $year
            ArchSort   = $archSort
            ArgStyle   = $argStyle
        }
        Write-Log "  + $($file.Name) ($([math]::Round($file.Length/1MB,2)) MB)" -Level DEBUG
    }

    # Sort: year ascending, then x86 before x64 (matches abbodi1406 ordering)
    $manifest = $manifest | Sort-Object Year, ArchSort

    # Apply package filter
    if ($PackageFilter -and $PackageFilter.Count -gt 0) {
        Write-Log "Applying package filter: $($PackageFilter -join ', ')" -Level INFO
        $originalCount = $manifest.Count
        $filtered = @()
        foreach ($pkg in $manifest) {
            foreach ($filter in $PackageFilter) {
                $matched = $false
                if ($filter -match '^\d{4}$') {
                    $fy = [int]$filter
                    if ($fy -ge 2015 -and $pkg.FileName -match '2015Plus') { $matched = $true; break }
                    elseif ($fy -lt 2015 -and $pkg.FileName -match $filter) { $matched = $true; break }
                } elseif ($filter -match '2015\+') {
                    if ($pkg.FileName -match '2015Plus') { $matched = $true; break }
                } elseif ($pkg.FileName -match [regex]::Escape($filter)) {
                    $matched = $true; break
                }
            }
            if ($matched) { $filtered += $pkg }
        }
        $manifest = $filtered
        Write-Log "Filtered: $($manifest.Count) of $originalCount package(s)" -Level INFO
    }

    return $manifest
}

function Test-PackageIntegrity {
    param([array] $Packages)
    $valid = $true
    foreach ($pkg in $Packages) {
        if (-not (Test-Path $pkg.FilePath)) {
            Write-Log "Missing: $($pkg.FileName)" -Level ERROR
            $valid = $false
            continue
        }
        if ((Get-Item $pkg.FilePath).Length -eq 0) {
            Write-Log "Corrupted (0 bytes): $($pkg.FileName)" -Level ERROR
            $valid = $false
        }
    }
    if ($valid) { Write-Log "Package integrity: PASSED" -Level SUCCESS }
    else        { Write-Log "Package integrity: FAILED" -Level ERROR }
    return $valid
}

# ============================================================================
# INSTALLATION FUNCTION
# ============================================================================

function Install-Package {
    param([Parameter(Mandatory = $true)] [hashtable] $Package)

    Write-Log "Installing: $($Package.PackageId)" -Level INFO
    Write-Log "  File: $($Package.FileName) | Size: $($Package.Size) MB" -Level DEBUG

    # Architecture compatibility check
    if (-not (Test-PackageArchCompatible -Package $Package)) {
        return @{ PackageId = $Package.PackageId; ExitCode = 0; Success = $true
                  Message = "Skipped (incompatible architecture)"; Skipped = $true }
    }

    # Smart skip: already installed at same/newer version
    if (-not $ForceReinstall) {
        $installedMap = Get-InstalledVCRedistMap
        if (Test-PackageAlreadyInstalled -Package $Package -InstalledMap $installedMap) {
            return @{ PackageId = $Package.PackageId; ExitCode = 0; Success = $true
                      Message = "Skipped (already installed)"; Skipped = $true }
        }
    }

    # Build install arguments
    $installArgs = if ($Package.ArgStyle -eq 'legacy') {
        @("/Q")                                    # VC++ 2005/2008
    } else {
        @("/install", "/quiet", "/norestart")      # VC++ 2010+
    }

    try {
        $startTime = Get-Date
        $windowStyle = if ($ShowInstallerWindows) { 'Normal' } else { 'Hidden' }
        Write-Log "  Exec: $($Package.FilePath) $($installArgs -join ' ')" -Level DEBUG

        $process = Start-Process -FilePath $Package.FilePath `
                                 -ArgumentList $installArgs `
                                 -Wait -PassThru -WindowStyle $windowStyle

        $duration = (Get-Date) - $startTime
        $exitCode = $process.ExitCode

        Write-Log "  Exit: $exitCode | Duration: $([math]::Round($duration.TotalSeconds,1))s" -Level DEBUG

        $result = @{
            PackageId     = $Package.PackageId
            ExitCode      = $exitCode
            Duration      = $duration.TotalSeconds
            Success       = $false
            Message       = ""
            RebootRequired = $false
            Skipped       = $false
        }

        switch ($exitCode) {
            0    { $result.Success = $true;  $result.Message = "Installed successfully"
                   Write-Log "  [OK] Installed" -Level SUCCESS }
            3010 { $result.Success = $true;  $result.RebootRequired = $true
                   $script:RebootRequired = $true
                   $result.Message = "Installed (reboot required)"
                   Write-Log "  [OK] Installed — reboot required" -Level SUCCESS }
            1641 { $result.Success = $true;  $result.RebootRequired = $true
                   $script:RebootRequired = $true
                   $result.Message = "Installed (reboot initiated)"
                   Write-Log "  [OK] Installed — reboot initiated" -Level SUCCESS }
            1638 { $result.Success = $true;  $result.Message = "Already installed (newer/same version)"
                   Write-Log "  [INFO] Already installed (newer/same)" -Level INFO }
            5100 { $result.Message = "System requirements not met"
                   Write-Log "  [FAIL] System requirements not met" -Level ERROR }
            default {
                   $result.Message = "Failed (exit code: $exitCode)"
                   Write-Log "  [FAIL] Exit code $exitCode" -Level WARN }
        }

        return $result

    } catch {
        Write-Log "  [FAIL] Exception: $($_.Exception.Message)" -Level ERROR
        return @{ PackageId = $Package.PackageId; ExitCode = -1; Duration = 0
                  Success = $false; Message = "Exception: $($_.Exception.Message)"; Skipped = $false }
    }
}

# ============================================================================
# MAIN WORKFLOW
# ============================================================================

Write-LogHeader "VCRedist AIO Offline Installer"
Write-Log "Started: $script:InstallStartTime" -Level INFO
Write-Log "Package dir: $PackageDir" -Level INFO
Write-Log "Log file: $script:LogFile" -Level INFO
Write-SystemInfo

# Phase 1: Validation
Write-LogHeader "Phase 1: Pre-Installation Validation"
if (-not $SkipValidation) {
    if (-not (Test-AdministratorPrivileges)) {
        Write-Log "Requires Administrator. Please re-run as Administrator." -Level ERROR
        exit 1
    }
    if (-not (Test-DiskSpace -Path $PackageDir -RequiredMB 500)) {
        Write-Log "Insufficient disk space." -Level ERROR
        exit 1
    }
} else {
    Write-Log "Validation skipped (-SkipValidation)" -Level WARN
}

# Phase 2: Discovery
Write-LogHeader "Phase 2: Package Discovery"
$packages = Get-PackageManifest -PackageDir $PackageDir
if (-not $packages -or $packages.Count -eq 0) {
    Write-Log "No packages found." -Level ERROR
    exit 1
}
Write-Log "Discovered $($packages.Count) package(s)" -Level SUCCESS

# Phase 3: Integrity
Write-LogHeader "Phase 3: Package Integrity"
if (-not (Test-PackageIntegrity -Packages $packages)) {
    Write-Log "Integrity check failed. Aborting." -Level ERROR
    exit 1
}

# Phase 4: Pre-scan installed state
Write-LogHeader "Phase 4: Scanning Installed VC++ Redistributables"
$installedMap = Get-InstalledVCRedistMap
if ($installedMap.Count -gt 0) {
    Write-Log "Currently installed VC++ packages:" -Level INFO
    foreach ($k in ($installedMap.Keys | Sort-Object)) {
        Write-Log "  $k : $($installedMap[$k].DisplayName) v$($installedMap[$k].Version)" -Level INFO
    }
} else {
    Write-Log "No VC++ redistributables currently installed." -Level INFO
}
if ($ForceReinstall) { Write-Log "ForceReinstall enabled — skipping smart-skip logic" -Level WARN }

# Phase 5: Installation
Write-LogHeader "Phase 5: Installing Packages"

$results   = @()
$success   = 0
$failed    = 0
$skipped   = 0
$total     = $packages.Count
$current   = 0

foreach ($pkg in $packages) {
    $current++
    Write-LogBlank
    Write-Log "[$current/$total] $($pkg.FileName)" -Level INFO

    $result = Install-Package -Package $pkg
    $results += $result

    if ($result.Skipped)       { $skipped++ }
    elseif ($result.Success)   { $success++ }
    else                       { $failed++ }
}

# Phase 6: Summary
Write-LogHeader "Phase 6: Summary"
$elapsed = (Get-Date) - $script:InstallStartTime
Write-Log "Total:    $total" -Level INFO
Write-Log "Installed: $success" -Level SUCCESS
Write-Log "Skipped:  $skipped (already up-to-date)" -Level INFO
Write-Log "Failed:   $failed" -Level $(if ($failed -gt 0) { 'WARN' } else { 'INFO' })
Write-Log "Duration: $([math]::Round($elapsed.TotalSeconds,2))s" -Level INFO

if ($script:RebootRequired) {
    Write-LogBlank
    Write-Log "[!] REBOOT REQUIRED — restart to complete installation" -Level WARN
}

Write-LogBlank
Write-Log "Detailed Results:" -Level INFO
foreach ($r in $results) {
    $tag = if ($r.Skipped) { "[SKIP]" } elseif ($r.Success) { "[OK]  " } else { "[FAIL]" }
    Write-Log "  $tag $($r.PackageId) — $($r.Message)" -Level $(if ($r.Success -or $r.Skipped) { 'INFO' } else { 'WARN' })
}

Write-Log "Log: $script:LogFile" -Level INFO

if ($failed -gt 0) { Write-Log "Completed with errors." -Level WARN; exit 1 }
else               { Write-Log "Completed successfully." -Level SUCCESS; exit 0 }