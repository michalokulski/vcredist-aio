
# Encoding: UTF-8
<#
.SYNOPSIS
    VCRedist AIO Uninstaller - Removes Microsoft Visual C++ Redistributables
.DESCRIPTION
    Detects and uninstalls all Microsoft Visual C++ Redistributable packages.
    WARNING: Uninstalling VC++ runtimes may break applications that depend on them.
.PARAMETER Force
    Skip confirmation prompts (required for non-interactive execution)
.PARAMETER LogDir
    Directory for uninstallation logs (default: script directory)
.PARAMETER Silent
    Suppress console output during uninstallation
.PARAMETER WhatIf
    Show what would be uninstalled without actually doing it
.EXAMPLE
    .\uninstall.ps1
    # Interactive mode with confirmation (only works in console)
.EXAMPLE
    .\uninstall.ps1 -WhatIf
    # Preview what would be uninstalled
.EXAMPLE
    .\uninstall.ps1 -Force -Silent
    # Uninstall everything without prompts (for automation/NSIS)
#>

param(
    [Parameter(Mandatory = $false)]
    [switch] $Force,
    
    [Parameter(Mandatory = $false)]
    [string] $LogDir,
    
    [Parameter(Mandatory = $false)]
    [switch] $Silent,
    
    [Parameter(Mandatory = $false)]
    [switch] $WhatIf,
    # By default, hide uninstaller windows for all packages. Use -ShowUninstallerWindows to opt-in to visible UI.
    [Parameter(Mandatory = $false)]
    [switch] $ShowUninstallerWindows
)


$ErrorActionPreference = "Continue"
$WarningPreference = "Continue"

# Track uninstalled package identifiers to detect duplicate registry entries
$script:processedPackages = @{}

# Resolve script directory for logging paths
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Get-Location
}

# Strip surrounding quotes from LogDir if present
if ($LogDir -match '^("|)(.*)(\1)$') {
    $LogDir = $Matches[2]
}
# Handle log directory with proper fallback chain
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    # No custom log directory specified - use defaults
    if (-not [string]::IsNullOrWhiteSpace($scriptDir) -and (Test-Path $scriptDir)) {
        $LogDir = $scriptDir
    } else {
        # Script directory is invalid/missing - use TEMP
        $LogDir = $env:TEMP
        Write-Warning "Script directory unavailable, using TEMP for logs: $LogDir"
    }
} else {
    # Custom log directory specified - validate and create if needed
    if (-not (Test-Path $LogDir)) {
        try {
            New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
            Write-Host "✔ Created log directory: $LogDir" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to create custom log directory: $($_.Exception.Message)"
            Write-Warning "Falling back to TEMP: $env:TEMP"
            $LogDir = $env:TEMP
        }
    }
}

# ============================================================================
# LOGGING INFRASTRUCTURE
# ============================================================================

$script:LogFile = Join-Path $LogDir "vcredist-uninstall-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$script:UninstallStartTime = Get-Date

# Validate log file can be created
try {
    # Test write to log file
    "Uninstallation started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFile -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-Error "CRITICAL: Cannot create log file at: $script:LogFile"
    Write-Error "Error: $($_.Exception.Message)"
    Write-Host "Log directory: $LogDir" -ForegroundColor Yellow
    Write-Host "Attempting emergency fallback to TEMP..." -ForegroundColor Yellow
    
    # Emergency fallback
    $LogDir = $env:TEMP
    $script:LogFile = Join-Path $LogDir "vcredist-uninstall-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    
    try {
        "Uninstallation started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $script:LogFile -Encoding UTF8 -ErrorAction Stop
        Write-Host "Emergency fallback successful. Log file: $script:LogFile" -ForegroundColor Green
    } catch {
        Write-Error "FATAL: Cannot create log file even in TEMP directory!"
        Write-Error "Uninstallation cannot proceed without logging capability."
        exit 1
    }
}

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
    
    # Write to log file with error handling
    try {
        Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction Stop
    } catch {
        # If log writing fails, try to write to console at least
        if (-not $Silent) {
            Write-Host "[LOG ERROR] Failed to write to log file: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "[LOG ERROR] Log path was: $script:LogFile" -ForegroundColor Red
        }
    }
    
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
# DETECTION FUNCTIONS
# ============================================================================

function Get-InstalledVCRedist {
    Write-Log "Scanning for installed Visual C++ Redistributables..." -Level INFO
    
    $uninstallKeys = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    $vcRedistPackages = @()
    
    foreach ($keyPath in $uninstallKeys) {
        try {
            $items = Get-ItemProperty $keyPath -ErrorAction SilentlyContinue
            
            foreach ($item in $items) {
                $displayName = $item.DisplayName
                
                # Match Visual C++ Redistributable packages
                if ($displayName -match "Microsoft Visual C\+\+.*Redistributable" -or 
                    $displayName -match "Microsoft Visual Studio.*Runtime" -or
                    $displayName -match "Visual Studio.*Tools for Office") {
                    
                    # Determine architecture from display name first, then registry location
                    $arch = if ($displayName -match "\(x64\)|x64") {
                        "x64"
                    } elseif ($displayName -match "\(x86\)|x86") {
                        "x86"
                    } elseif ($keyPath -match "Wow6432Node") {
                        "x86"
                    } else {
                        "x64"
                    }
                    
                    $package = @{}
                    if (-not $package.ContainsKey('DisplayName')) { $package['DisplayName'] = $displayName }
                    if (-not $package.ContainsKey('DisplayVersion')) { $package['DisplayVersion'] = $item.DisplayVersion }
                    if (-not $package.ContainsKey('Publisher')) { $package['Publisher'] = $item.Publisher }
                    if (-not $package.ContainsKey('UninstallString')) { $package['UninstallString'] = $item.UninstallString }
                    if (-not $package.ContainsKey('QuietUninstallString')) { $package['QuietUninstallString'] = $item.QuietUninstallString }
                    if (-not $package.ContainsKey('PSChildName')) { $package['PSChildName'] = $item.PSChildName }
                    if (-not $package.ContainsKey('Architecture')) { $package['Architecture'] = $arch }
                    if (-not $package.ContainsKey('InstallDate')) { $package['InstallDate'] = $item.InstallDate }
                    
                    $vcRedistPackages += $package
                    Write-Log "  Found: $displayName ($($package.Architecture))" -Level DEBUG
                }
            }
        } catch {
            Write-Log "Failed to scan registry key: $keyPath - $($_.Exception.Message)" -Level DEBUG
        }
    }
    
    $totalRegistryEntries = $vcRedistPackages.Count

    # Separate packages with and without uninstall strings
    $withUninstallString = $vcRedistPackages | Where-Object { -not [string]::IsNullOrWhiteSpace($_.UninstallString) }
    $withoutUninstallString = $vcRedistPackages | Where-Object { [string]::IsNullOrWhiteSpace($_.UninstallString) }

    # Deduplicate only those with non-empty uninstall strings
    $dedupedWithUninstallString = @()
    $seenUninstallStrings = @{}
    foreach ($pkg in $withUninstallString) {
        $uninstallStr = $pkg.UninstallString
        if (-not $seenUninstallStrings.ContainsKey($uninstallStr)) {
            $dedupedWithUninstallString += $pkg
            $seenUninstallStrings[$uninstallStr] = $true
        }
    }

    # Combine back for reporting and processing, force copy to avoid duplicate key error
    $vcRedistPackages = @()
    foreach ($pkg in $dedupedWithUninstallString + $withoutUninstallString) {
        $vcRedistPackages += [hashtable]@{
            DisplayName = $pkg.DisplayName
            DisplayVersion = $pkg.DisplayVersion
            Publisher = $pkg.Publisher
            UninstallString = $pkg.UninstallString
            QuietUninstallString = $pkg.QuietUninstallString
            PSChildName = $pkg.PSChildName
            Architecture = $pkg.Architecture
            InstallDate = $pkg.InstallDate
        }
    }

    $uniquePackages = $vcRedistPackages.Count
    $duplicatesRemoved = $totalRegistryEntries - $uniquePackages

    # Sort by name and version
    $vcRedistPackages = $vcRedistPackages | Sort-Object DisplayName, DisplayVersion

    if ($duplicatesRemoved -gt 0) {
        Write-Log "Found $uniquePackages unique package(s) ($totalRegistryEntries registry entries, $duplicatesRemoved duplicates removed)" -Level SUCCESS
    } else {
        Write-Log "Found $uniquePackages Visual C++ package(s)" -Level SUCCESS
    }

    # Force return as array to prevent single-item unwrapping
    return ,$vcRedistPackages
}

# ============================================================================
# UNINSTALLATION FUNCTIONS
# ============================================================================

function Uninstall-VCRedistPackage {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Package
    )
    
    Write-Log "Uninstalling: $($Package.DisplayName)" -Level INFO
    Write-Log "  Version: $($Package.DisplayVersion)" -Level DEBUG
    Write-Log "  Architecture: $($Package.Architecture)" -Level DEBUG
    
    if ($WhatIf) {
        Write-Log "  [WHATIF] Would uninstall this package" -Level WARN
        return @{
            PackageName = $Package.DisplayName
            Success = $true
            Message = "WhatIf mode - no action taken"
            ExitCode = 0
        }
    }
    
    # Prefer QuietUninstallString for silent uninstallation
    $uninstallCommand = if ($Package.QuietUninstallString) {
        $Package.QuietUninstallString
    } else {
        $Package.UninstallString
    }
    
    if ([string]::IsNullOrWhiteSpace($uninstallCommand)) {
        Write-Log "  [SKIP] No uninstall string found (likely removed as dependency)" -Level INFO
        return @{
            PackageName = $Package.DisplayName
            Success = $true  # Changed to true - this is not really a failure
            Message = "No uninstall string (removed as dependency or orphaned registry entry)"
            ExitCode = 0
        }
    }
    
    # Check if we already processed this exact uninstall command (duplicate registry entry)
    if ($script:processedPackages.ContainsKey($uninstallCommand)) {
        Write-Log "  [SKIP] Duplicate registry entry (already processed)" -Level INFO
        return @{
            PackageName = $Package.DisplayName
            Success = $true
            Message = "Duplicate registry entry - package already uninstalled"
            ExitCode = 0
        }
    }
    
    # Mark this package as processed
    $script:processedPackages[$uninstallCommand] = $true
    
    Write-Log "  Uninstall command: $uninstallCommand" -Level DEBUG
    
    try {
        $startTime = Get-Date
        
        # Parse command and arguments
        if ($uninstallCommand -match '^"([^"]+)"\s*(.*)$') {
            $executable = $matches[1]
            $arguments = $matches[2]
        } elseif ($uninstallCommand -match '^([^\s]+)\s*(.*)$') {
            $executable = $matches[1]
            $arguments = $matches[2]
        } else {
            $executable = $uninstallCommand
            $arguments = ""
        }
        
        # Add silent flags if not using QuietUninstallString
        if (-not $Package.QuietUninstallString) {
            if ($executable -match "msiexec") {
                # MSI-based uninstaller
                if ($arguments -notmatch "/quiet" -and $arguments -notmatch "/qn") {
                    $arguments += " /quiet /norestart"
                }
            } else {
                # EXE-based uninstaller
                if ($arguments -notmatch "/quiet" -and $arguments -notmatch "/S") {
                    $arguments += " /quiet /norestart"
                }
            }
        }
        
        Write-Log "  Executing: $executable $arguments" -Level DEBUG
        
        $windowStyle = if ($ShowUninstallerWindows) { 'Normal' } else { 'Hidden' }
        Write-Log "  WindowStyle: $windowStyle" -Level DEBUG
        $process = Start-Process -FilePath $executable -ArgumentList $arguments -Wait -PassThru -WindowStyle $windowStyle
        
        $duration = (Get-Date) - $startTime
        $exitCode = $process.ExitCode
        
        Write-Log "  Exit Code: $exitCode | Duration: $($duration.TotalSeconds)s" -Level DEBUG
        
        # Interpret exit codes
        $result = @{
            PackageName = $Package.DisplayName
            ExitCode = $exitCode
            Duration = $duration.TotalSeconds
            Success = $false
            Message = ""
        }
        
        switch ($exitCode) {
            0 {
                $result.Success = $true
                $result.Message = "Uninstalled successfully"
                Write-Log "  [OK] SUCCESS: Uninstalled" -Level SUCCESS
            }
            3010 {
                $result.Success = $true
                $result.Message = "Uninstalled successfully (reboot required)"
                Write-Log "  [OK] SUCCESS: Uninstalled (reboot required)" -Level SUCCESS
            }
            1605 {
                $result.Success = $true
                $result.Message = "Package not found (already uninstalled or removed as dependency)"
                Write-Log "  [OK] Package already removed" -Level SUCCESS
            }
            1619 {
                $result.Success = $false
                $result.Message = "Installation package could not be opened"
                Write-Log "  [FAIL] Installation package error" -Level ERROR
            }
            default {
                $result.Success = $false
                $result.Message = "Uninstallation failed (exit code: $exitCode)"
                Write-Log "  [FAIL] FAILED: Exit code $exitCode" -Level WARN
            }
        }
        
        return $result
        
    } catch {
        Write-Log "  [FAIL] EXCEPTION: $($_.Exception.Message)" -Level ERROR
        
        return @{
            PackageName = $Package.DisplayName
            ExitCode = -1
            Duration = 0
            Success = $false
            Message = "Exception: $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# MAIN UNINSTALLATION WORKFLOW
# ============================================================================

Write-LogHeader "VCRedist AIO Uninstaller - Starting"

Write-Log "Uninstallation started at: $script:UninstallStartTime" -Level INFO
Write-Log "Log directory: $LogDir" -Level INFO
Write-Log "Log file: $script:LogFile" -Level INFO
Write-Log "WhatIf mode: $WhatIf" -Level INFO
Write-Log "Force mode: $Force" -Level INFO

# Check administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Log "WARNING: Not running as Administrator. Some uninstallations may fail." -Level WARN
    
    if (-not $Force -and -not $WhatIf) {
        # Only try interactive prompt if NOT running from NSIS
        try {
            if ([Environment]::UserInteractive) {
                $response = Read-Host "Continue anyway? (yes/no)"
                if ($response -ne "yes") {
                    Write-Log "Uninstallation cancelled by user" -Level INFO
                    exit 0
                }
            } else {
                Write-Log "Non-interactive mode without Force flag - aborting" -Level ERROR
                exit 1
            }
        } catch {
            Write-Log "Cannot prompt for confirmation in this context - aborting" -Level ERROR
            exit 1
        }
    }
}

# Phase 1: Detection

Write-LogHeader "Phase 1: Package Detection"

# Classic robust idiom: assign directly, function always returns array
$packages = Get-InstalledVCRedist
Write-Log "Detected package count snapshot: $($packages.Count) [Type: $($packages.GetType().FullName)]" -Level DEBUG

if ($packages.Count -eq 0) {
    Write-Log "No Visual C++ Redistributable packages found." -Level INFO
    Write-Log "System is already clean or packages are not registered in the registry." -Level INFO
    exit 0
}

# Display found packages
Write-Log "Packages to be uninstalled:" -Level INFO
Write-Log " " -Level INFO
$index = 1
foreach ($pkg in $packages) {
    Write-Log "  [$index] $($pkg.DisplayName)" -Level INFO
    Write-Log "      Version: $($pkg.DisplayVersion) | Arch: $($pkg.Architecture)" -Level DEBUG
    $index++
}

# Note: No interactive confirmation prompt. Use -WhatIf to preview, or -Force for automation.

# Phase 3: Uninstallation
Write-LogHeader "Phase 3: Uninstalling Packages"

$results = @()
$successCount = 0
$failCount = 0
$currentPackage = 0
$totalPackages = $packages.Count

foreach ($pkg in $packages) {
    $currentPackage++
    
    Write-Log " " -Level INFO  # Blank line for readability
    Write-Log "Progress: [$currentPackage/$totalPackages] Uninstalling package $currentPackage of $totalPackages" -Level INFO
    
    $result = Uninstall-VCRedistPackage -Package $pkg
    $results += $result
    
    if ($result.Success) {
        $successCount++
    } else {
        $failCount++
    }
}

# Phase 4: Summary
Write-LogHeader "Phase 4: Uninstallation Summary"

$totalDuration = (Get-Date) - $script:UninstallStartTime

Write-Log "Total packages processed: $($packages.Count)" -Level INFO
Write-Log "Successful: $successCount" -Level SUCCESS
Write-Log "Failed: $failCount" -Level $(if ($failCount -gt 0) { 'WARN' } else { 'INFO' })
Write-Log "Total duration: $([math]::Round($totalDuration.TotalSeconds, 2))s" -Level INFO

# Detailed results
Write-Log " " -Level INFO
Write-Log "Detailed Results:" -Level INFO
foreach ($result in $results) {
    $status = if ($result.Success) { "[OK]" } else { "[FAIL]" }
    Write-Log "  $status $($result.PackageName) - $($result.Message)" -Level $(if ($result.Success) { 'INFO' } else { 'WARN' })
}

Write-Log " " -Level INFO
Write-Log "Log file saved to: $script:LogFile" -Level INFO

# Check if reboot is needed
$rebootNeeded = $results | Where-Object { $_.ExitCode -eq 3010 }
if ($rebootNeeded.Count -gt 0) {
    Write-Log " " -Level INFO
    Write-Log "[!] REBOOT REQUIRED - Some packages require a system restart" -Level WARN
    Write-Log "Please restart your computer to complete the uninstallation" -Level WARN
}

if (-not $WhatIf) {
    Write-Log " " -Level INFO
    Write-Log "💡 Tip: Run this script again to verify all packages were removed" -Level INFO
}

# Exit with appropriate code
if ($failCount -gt 0 -and -not $WhatIf) {
    Write-Log "Uninstallation completed with errors." -Level WARN
    exit 1
} else {
    if ($WhatIf) {
        Write-Log "WhatIf mode completed - no changes were made." -Level SUCCESS
    } else {
        Write-Log "Uninstallation completed successfully!" -Level SUCCESS
    }
    exit 0
}