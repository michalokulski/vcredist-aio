<#
.SYNOPSIS
    VCRedist AIO Offline Installer - Installation Engine
.DESCRIPTION
    Installs Microsoft Visual C++ Redistributables with comprehensive logging and validation.
.PARAMETER PackageDir
    Directory containing the redistributable executables
.PARAMETER LogDir
    Directory for installation logs (default: current directory)
.PARAMETER Silent
    Suppress console output during installation
.PARAMETER SkipValidation
    Skip pre-installation validation checks
#>

param(
    [Parameter(Mandatory = $false)]
    [string] $PackageDir,
    
    [Parameter(Mandatory = $false)]
    [string] $LogDir,
    
    [switch] $Silent = $false,
    
    [switch] $SkipValidation = $false
)

$ErrorActionPreference = "Continue"
$WarningPreference = "Continue"

# Resolve script directory for default paths
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Get-Location
}

# Set default paths if not provided
if ([string]::IsNullOrWhiteSpace($PackageDir)) {
    $PackageDir = Join-Path $scriptDir "packages"
}

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = $scriptDir
}

# ============================================================================
# LOGGING INFRASTRUCTURE
# ============================================================================

# Ensure log directory exists
if (-not (Test-Path $LogDir)) {
    try {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    } catch {
        # Fallback to temp directory if log dir creation fails
        $LogDir = $env:TEMP
    }
}

$script:LogFile = Join-Path $LogDir "vcredist-install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$script:InstallStartTime = Get-Date
$script:RebootRequired = $false

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string] $Level = 'INFO',
        
        [switch] $NoConsole
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to log file
    Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    
    # Write to console unless suppressed
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

function Write-LogHeader {
    param([string] $Title)
    
    $separator = "=" * 80
    Write-Log $separator -Level INFO
    Write-Log $Title -Level INFO
    Write-Log $separator -Level INFO
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
        
        $computerInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($computerInfo) {
            Write-Log "  Computer: $($computerInfo.Name)" -Level INFO
        }
        
        Write-Log "  PowerShell: $($PSVersionTable.PSVersion)" -Level INFO
        Write-Log "  Script Mode: $(if ($Silent) { 'Silent' } else { 'Interactive' })" -Level INFO
    } catch {
        Write-Log "Failed to retrieve system information: $($_.Exception.Message)" -Level DEBUG
    }
}

function Test-AdministratorPrivileges {
    Write-Log "Checking administrator privileges..." -Level DEBUG
    
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
    param(
        [string] $Path,
        [int] $RequiredMB = 500
    )
    
    Write-Log "Checking disk space for: $Path" -Level DEBUG
    
    try {
        $drive = (Get-Item $Path).PSDrive
        $freeSpaceMB = [math]::Round($drive.Free / 1MB, 2)
        
        Write-Log "Available space: $freeSpaceMB MB (Required: $RequiredMB MB)" -Level DEBUG
        
        if ($freeSpaceMB -lt $RequiredMB) {
            Write-Log "Insufficient disk space: $freeSpaceMB MB available, $RequiredMB MB required" -Level ERROR
            return $false
        }
        
        Write-Log "Disk space check: PASSED" -Level SUCCESS
        return $true
    } catch {
        Write-Log "Failed to check disk space: $($_.Exception.Message)" -Level WARN
        return $true  # Don't block installation
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
    
    Write-Log "Found $($exeFiles.Count) package(s)" -Level INFO
    
    $manifest = @()
    foreach ($file in $exeFiles) {
        # Parse package ID from filename (e.g., Microsoft_VCRedist_2015Plus_x64_14.40.33816.0.exe)
        $fileName = $file.BaseName
        $packageId = $fileName -replace '_(\d+\.)+\d+$', ''  # Remove version suffix
        $packageId = $packageId -replace '_', '.'  # Convert underscores to dots
        
        # Extract year and architecture for sorting
        $year = 0
        $arch = 0  # x86=0, x64=1 for sorting
        
        if ($fileName -match '(\d{4})|(2015Plus)') {
            $yearStr = $matches[0]
            $year = switch ($yearStr) {
                '2015Plus' { 2015 }
                default { [int]$yearStr }
            }
        }
        
        if ($fileName -match 'x64') { $arch = 1 }
        
        $manifest += @{
            PackageId = $packageId
            FileName = $file.Name
            FilePath = $file.FullName
            Size = [math]::Round($file.Length / 1MB, 2)
            Year = $year
            Architecture = $arch
        }
        
        Write-Log "  - $($file.Name) ($([math]::Round($file.Length / 1MB, 2)) MB)" -Level DEBUG
    }
    
    # Sort by year (ascending), then architecture (x86 before x64)
    $manifest = $manifest | Sort-Object -Property Year, Architecture
    
    return $manifest
}

function Test-PackageIntegrity {
    param(
        [Parameter(Mandatory = $true)]
        [array] $Packages
    )
    
    Write-Log "Validating package integrity..." -Level INFO
    
    $valid = $true
    foreach ($pkg in $Packages) {
        if (-not (Test-Path $pkg.FilePath)) {
            Write-Log "Package file missing: $($pkg.FileName)" -Level ERROR
            $valid = $false
            continue
        }
        
        # Verify file is not corrupted (basic check: file size > 0)
        $fileInfo = Get-Item $pkg.FilePath
        if ($fileInfo.Length -eq 0) {
            Write-Log "Package file corrupted (0 bytes): $($pkg.FileName)" -Level ERROR
            $valid = $false
        }
    }
    
    if ($valid) {
        Write-Log "Package integrity check: PASSED" -Level SUCCESS
    } else {
        Write-Log "Package integrity check: FAILED" -Level ERROR
    }
    
    return $valid
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

function Install-Package {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Package
    )
    
    Write-Log "Installing: $($Package.PackageId)" -Level INFO
    Write-Log "  File: $($Package.FileName)" -Level DEBUG
    Write-Log "  Path: $($Package.FilePath)" -Level DEBUG
    
    $installArgs = @("/install", "/quiet", "/norestart")
    
    try {
        $startTime = Get-Date
        
        Write-Log "  Executing: $($Package.FilePath) $($installArgs -join ' ')" -Level DEBUG
        
        $process = Start-Process -FilePath $Package.FilePath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        
        $duration = (Get-Date) - $startTime
        $exitCode = $process.ExitCode
        
        Write-Log "  Exit Code: $exitCode | Duration: $($duration.TotalSeconds)s" -Level DEBUG
        
        # Interpret exit codes
        # 0 = Success
        # 3010 = Success, reboot required
        # 1641 = Success, reboot initiated
        # 1638 = Already installed (newer version)
        # 5100 = System requirements not met
        
        $result = @{
            PackageId = $Package.PackageId
            ExitCode = $exitCode
            Duration = $duration.TotalSeconds
            Success = $false
            Message = ""
            RebootRequired = $false
        }
        
        switch ($exitCode) {
            0 {
                $result.Success = $true
                $result.Message = "Installed successfully"
                Write-Log "  [OK] SUCCESS: Installed" -Level SUCCESS
            }
            3010 {
                $result.Success = $true
                $result.RebootRequired = $true
                $script:RebootRequired = $true
                $result.Message = "Installed successfully (reboot required)"
                Write-Log "  [OK] SUCCESS: Installed (reboot required)" -Level SUCCESS
            }
            1641 {
                $result.Success = $true
                $result.RebootRequired = $true
                $script:RebootRequired = $true
                $result.Message = "Installed successfully (reboot initiated)"
                Write-Log "  [OK] SUCCESS: Installed (reboot initiated)" -Level SUCCESS
            }
            1638 {
                $result.Success = $true
                $result.Message = "Already installed (newer or same version)"
                Write-Log "  [INFO] Already installed (newer/same version)" -Level INFO
            }
            5100 {
                $result.Success = $false
                $result.Message = "System requirements not met"
                Write-Log "  [FAIL] FAILED: System requirements not met" -Level ERROR
            }
            default {
                $result.Success = $false
                $result.Message = "Installation failed (exit code: $exitCode)"
                Write-Log "  [FAIL] FAILED: Exit code $exitCode" -Level WARN
            }
        }
        
        return $result
        
    } catch {
        Write-Log "  [FAIL] EXCEPTION: $($_.Exception.Message)" -Level ERROR
        
        return @{
            PackageId = $Package.PackageId
            ExitCode = -1
            Duration = 0
            Success = $false
            Message = "Exception: $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# MAIN INSTALLATION WORKFLOW
# ============================================================================

Write-LogHeader "VCRedist AIO Offline Installer - Starting Installation"

Write-Log "Installation started at: $script:InstallStartTime" -Level INFO
Write-Log "Package directory: $PackageDir" -Level INFO
Write-Log "Log directory: $LogDir" -Level INFO
Write-Log "Log file: $script:LogFile" -Level INFO

# Log system information
Write-SystemInfo

# Phase 1: Validation
Write-LogHeader "Phase 1: Pre-Installation Validation"

if (-not $SkipValidation) {
    # Check administrator privileges
    if (-not (Test-AdministratorPrivileges)) {
        Write-Log "Installation requires administrator privileges. Please run as Administrator." -Level ERROR
        exit 1
    }
    
    # Check disk space
    if (-not (Test-DiskSpace -Path $PackageDir -RequiredMB 500)) {
        Write-Log "Insufficient disk space for installation." -Level ERROR
        exit 1
    }
} else {
    Write-Log "Validation skipped (SkipValidation flag set)" -Level WARN
}

# Phase 2: Package Discovery
Write-LogHeader "Phase 2: Package Discovery"

$packages = Get-PackageManifest -PackageDir $PackageDir

if (-not $packages -or $packages.Count -eq 0) {
    Write-Log "No packages found for installation." -Level ERROR
    exit 1
}

Write-Log "Discovered $($packages.Count) package(s) for installation" -Level SUCCESS

# Phase 3: Package Integrity Check
Write-LogHeader "Phase 3: Package Integrity Validation"

if (-not (Test-PackageIntegrity -Packages $packages)) {
    Write-Log "Package integrity validation failed. Aborting installation." -Level ERROR
    exit 1
}

# Phase 4: Installation
Write-LogHeader "Phase 4: Installing Packages"

$results = @()
$successCount = 0
$failCount = 0
$currentPackage = 0
$totalPackages = $packages.Count

foreach ($pkg in $packages) {
    $currentPackage++
    
    Write-Log "" -Level INFO  # Blank line for readability
    Write-Log "Progress: [$currentPackage/$totalPackages] Installing package $currentPackage of $totalPackages" -Level INFO
    
    $result = Install-Package -Package $pkg
    $results += $result
    
    if ($result.Success) {
        $successCount++
    } else {
        $failCount++
    }
}

# Phase 5: Summary
Write-LogHeader "Phase 5: Installation Summary"

$totalDuration = (Get-Date) - $script:InstallStartTime

Write-Log "Total packages: $($packages.Count)" -Level INFO
Write-Log "Successful: $successCount" -Level SUCCESS
Write-Log "Failed: $failCount" -Level $(if ($failCount -gt 0) { 'WARN' } else { 'INFO' })
Write-Log "Total duration: $([math]::Round($totalDuration.TotalSeconds, 2))s" -Level INFO

if ($script:RebootRequired) {
    Write-Log "" -Level INFO
    Write-Log "[!] REBOOT REQUIRED - One or more packages require a system restart" -Level WARN
    Write-Log "Please restart your computer to complete the installation" -Level WARN
}

# Detailed results
Write-Log "`nDetailed Results:" -Level INFO
foreach ($result in $results) {
    $status = if ($result.Success) { "[OK]" } else { "[FAIL]" }
    Write-Log "  $status $($result.PackageId) - $($result.Message)" -Level $(if ($result.Success) { 'INFO' } else { 'WARN' })
}

Write-Log "`nLog file saved to: $script:LogFile" -Level INFO

# Exit with appropriate code
if ($failCount -gt 0) {
    Write-Log "Installation completed with errors." -Level WARN
    exit 1
} else {
    Write-Log "Installation completed successfully!" -Level SUCCESS
    exit 0
}