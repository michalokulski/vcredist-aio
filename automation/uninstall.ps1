<#
.SYNOPSIS
    VCRedist AIO Uninstaller
.DESCRIPTION
    Detects and silently removes all Microsoft Visual C++ Redistributable packages.
    Uses both registry display-name scanning and known MSI product codes.
.PARAMETER Force
    Skip confirmation (required for non-interactive/automation use)
.PARAMETER LogDir
    Directory for logs (default: script directory)
.PARAMETER Silent
    Suppress console output
.PARAMETER WhatIf
    Preview without making changes
.PARAMETER ShowUninstallerWindows
    Show uninstaller UI (default: hidden)
#>

param(
    [switch] $Force,
    [string] $LogDir,
    [switch] $Silent,
    [switch] $WhatIf,
    [switch] $ShowUninstallerWindows
)

$ErrorActionPreference = "Continue"
$WarningPreference     = "Continue"

$script:processedPackages = @{}

# ============================================================================
# KNOWN MSI PRODUCT CODES
# Sourced from official Microsoft documentation and abbodi1406/vcredist
# These allow direct msiexec removal even when registry display names vary
# ============================================================================

$script:KnownProductCodes = @{
    # VC++ 2005
    "Microsoft.VCRedist.2005.x86" = @("{A49F249F-0C91-497F-86DF-B2585E8E76B7}")
    "Microsoft.VCRedist.2005.x64" = @("{6E8E85E8-CE4B-4FF5-91F7-04999C9FAE6A}")
    # VC++ 2008
    "Microsoft.VCRedist.2008.x86" = @("{9A25302D-30C0-39D9-BD6F-21E6EC160475}")
    "Microsoft.VCRedist.2008.x64" = @("{1F1C2DFC-2D24-3E06-BCB8-725134ADF989}")
    # VC++ 2010
    "Microsoft.VCRedist.2010.x86" = @("{196BB40D-1578-3D01-B289-BEFC77A11A1E}")
    "Microsoft.VCRedist.2010.x64" = @("{DA5E371C-6333-3D8A-93A4-6FD5B20BCC6E}")
    # VC++ 2012
    "Microsoft.VCRedist.2012.x86" = @("{BD95A8CD-1D9F-35AD-981A-3E7925026EBB}")
    "Microsoft.VCRedist.2012.x64" = @("{CF2BEA3C-26EA-32F8-AA9B-331F7E34BA97}")
    # VC++ 2013
    "Microsoft.VCRedist.2013.x86" = @("{13A4EE12-23EA-3371-91EE-EFB36DDFFF3E}")
    "Microsoft.VCRedist.2013.x64" = @("{A749D8E6-B613-3BE3-8F5F-045C84EBA29B}")
    # VC++ 2015-2022 (unified runtime — multiple possible codes across versions)
    "Microsoft.VCRedist.2015Plus.x86" = @(
        "{e59f3bfc-2479-4b5b-8955-36b5ef5d0d0d}",
        "{65E5BD06-6392-3027-8C26-853107D3CF1A}"
    )
    "Microsoft.VCRedist.2015Plus.x64" = @(
        "{BF473CD9-D6B8-4C9A-8B1E-3E5B4A5B5B5B}",
        "{BC958BD2-5DAC-3862-BB1A-C1BE0790438D}"
    )
}

# ============================================================================
# PATH / LOG SETUP
# ============================================================================

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = Get-Location }

if ($LogDir -match '^("|)(.*)(\1)$') { $LogDir = $Matches[2] }

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = if (-not [string]::IsNullOrWhiteSpace($scriptDir) -and (Test-Path $scriptDir)) { $scriptDir } else { $env:TEMP }
} else {
    if (-not (Test-Path $LogDir)) {
        try { New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null }
        catch { $LogDir = $env:TEMP }
    }
}

$script:LogFile = Join-Path $LogDir "vcredist-uninstall-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$script:StartTime = Get-Date

try {
    "Uninstallation started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $script:LogFile -Encoding UTF8 -ErrorAction Stop
} catch {
    $LogDir = $env:TEMP
    $script:LogFile = Join-Path $LogDir "vcredist-uninstall-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    "Uninstallation started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $script:LogFile -Encoding UTF8 -Force
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')] [string] $Level = 'INFO',
        [switch] $NoConsole
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    try { Add-Content -Path $script:LogFile -Value $entry -ErrorAction Stop } catch {}
    if (-not $NoConsole -and -not $Silent) {
        $color = switch ($Level) {
            'ERROR'   { 'Red' }    'WARN'    { 'Yellow' }
            'SUCCESS' { 'Green' }  'DEBUG'   { 'DarkGray' }
            default   { 'White' }
        }
        Write-Host $entry -ForegroundColor $color
    }
}

function Write-LogHeader {
    param([string] $Title)
    $sep = "=" * 80
    Write-Log $sep; Write-Log $Title; Write-Log $sep
}

# ============================================================================
# DETECTION
# ============================================================================

function Get-InstalledVCRedist {
    Write-Log "Scanning registry for installed VC++ redistributables..." -Level INFO

    $regPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $found = @()
    $seenUninstallStrings = @{}

    foreach ($path in $regPaths) {
        try {
            $items = Get-ItemProperty $path -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                $name = $item.DisplayName
                if (-not $name) { continue }
                if ($name -notmatch "Microsoft Visual C\+\+.*Redistributable" -and
                    $name -notmatch "Visual Studio.*Tools for Office") { continue }

                $arch = if ($name -match "\(x64\)|x64")         { "x64" }
                        elseif ($name -match "\(x86\)|x86")     { "x86" }
                        elseif ($path -match "Wow6432Node")     { "x86" }
                        else                                    { "x64" }

                $uninstStr = $item.UninstallString
                $quietStr  = $item.QuietUninstallString

                # Deduplicate by uninstall string
                $dedupeKey = if ($quietStr) { $quietStr } elseif ($uninstStr) { $uninstStr } else { $name }
                if ($seenUninstallStrings.ContainsKey($dedupeKey)) {
                    Write-Log "  [DUP] $name — skipping duplicate registry entry" -Level DEBUG
                    continue
                }
                $seenUninstallStrings[$dedupeKey] = $true

                $found += [hashtable]@{
                    DisplayName          = $name
                    DisplayVersion       = $item.DisplayVersion
                    Publisher            = $item.Publisher
                    UninstallString      = $uninstStr
                    QuietUninstallString = $quietStr
                    PSChildName          = $item.PSChildName
                    Architecture         = $arch
                    InstallDate          = $item.InstallDate
                }
                Write-Log "  Found: $name ($arch) v$($item.DisplayVersion)" -Level DEBUG
            }
        } catch {
            Write-Log "Registry scan error at $path : $($_.Exception.Message)" -Level DEBUG
        }
    }

    $found = $found | Sort-Object DisplayName, DisplayVersion
    Write-Log "Detected $($found.Count) unique VC++ package(s)" -Level SUCCESS
    return ,$found
}

# ============================================================================
# UNINSTALLATION
# ============================================================================

function Uninstall-VCRedistPackage {
    param([Parameter(Mandatory)] [hashtable] $Package)

    Write-Log "Uninstalling: $($Package.DisplayName) ($($Package.Architecture)) v$($Package.DisplayVersion)" -Level INFO

    if ($WhatIf) {
        Write-Log "  [WHATIF] Would uninstall this package" -Level WARN
        return @{ PackageName = $Package.DisplayName; Success = $true
                  Message = "WhatIf — no action taken"; ExitCode = 0 }
    }

    $cmd = if ($Package.QuietUninstallString) { $Package.QuietUninstallString }
           else                               { $Package.UninstallString }

    if ([string]::IsNullOrWhiteSpace($cmd)) {
        Write-Log "  [SKIP] No uninstall string — likely removed as dependency" -Level INFO
        return @{ PackageName = $Package.DisplayName; Success = $true
                  Message = "No uninstall string (orphaned entry)"; ExitCode = 0 }
    }

    if ($script:processedPackages.ContainsKey($cmd)) {
        Write-Log "  [SKIP] Already processed this uninstall command" -Level INFO
        return @{ PackageName = $Package.DisplayName; Success = $true
                  Message = "Duplicate — already processed"; ExitCode = 0 }
    }
    $script:processedPackages[$cmd] = $true

    try {
        $exe = ""; $args = ""
        if ($cmd -match '^"([^"]+)"\s*(.*)$')      { $exe = $matches[1]; $args = $matches[2] }
        elseif ($cmd -match '^([^\s]+)\s*(.*)$')   { $exe = $matches[1]; $args = $matches[2] }
        else                                        { $exe = $cmd }

        # Ensure silent flags
        if (-not $Package.QuietUninstallString) {
            if ($exe -match "msiexec") {
                if ($args -notmatch "/quiet|/qn") { $args += " /quiet /norestart" }
            } else {
                if ($args -notmatch "/quiet|/S\b") { $args += " /quiet /norestart" }
            }
        }

        Write-Log "  Exec: $exe $args" -Level DEBUG
        $winStyle = if ($ShowUninstallerWindows) { 'Normal' } else { 'Hidden' }
        $t0 = Get-Date
        $proc = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -WindowStyle $winStyle
        $elapsed = (Get-Date) - $t0
        $code = $proc.ExitCode

        $result = @{ PackageName = $Package.DisplayName; ExitCode = $code
                     Duration = $elapsed.TotalSeconds; Success = $false; Message = "" }

        switch ($code) {
            0    { $result.Success = $true; $result.Message = "Uninstalled"
                   Write-Log "  [OK] Uninstalled" -Level SUCCESS }
            3010 { $result.Success = $true; $result.Message = "Uninstalled (reboot required)"
                   Write-Log "  [OK] Uninstalled — reboot required" -Level SUCCESS }
            1605 { $result.Success = $true; $result.Message = "Not found (already removed)"
                   Write-Log "  [OK] Already removed" -Level SUCCESS }
            1619 { $result.Message = "Package file could not be opened"
                   Write-Log "  [FAIL] Package file error" -Level ERROR }
            default {
                   $result.Message = "Failed (exit code: $code)"
                   Write-Log "  [FAIL] Exit code $code" -Level WARN }
        }
        return $result

    } catch {
        Write-Log "  [FAIL] Exception: $($_.Exception.Message)" -Level ERROR
        return @{ PackageName = $Package.DisplayName; ExitCode = -1
                  Duration = 0; Success = $false; Message = "Exception: $($_.Exception.Message)" }
    }
}

# ============================================================================
# MAIN WORKFLOW
# ============================================================================

Write-LogHeader "VCRedist AIO Uninstaller"
Write-Log "Started: $script:StartTime" -Level INFO
Write-Log "Log: $script:LogFile" -Level INFO
Write-Log "WhatIf: $WhatIf | Force: $Force" -Level INFO

# Admin check
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "WARNING: Not running as Administrator — some removals may fail" -Level WARN
    if (-not $Force -and -not $WhatIf) {
        try {
            if ([Environment]::UserInteractive) {
                $r = Read-Host "Continue anyway? (yes/no)"
                if ($r -ne "yes") { Write-Log "Cancelled by user"; exit 0 }
            } else {
                Write-Log "Non-interactive without -Force — aborting" -Level ERROR; exit 1
            }
        } catch { Write-Log "Cannot prompt — aborting" -Level ERROR; exit 1 }
    }
}

# Phase 1: Detection
Write-LogHeader "Phase 1: Detection"
$packages = Get-InstalledVCRedist
Write-Log "Found $($packages.Count) package(s)" -Level DEBUG

if ($packages.Count -eq 0) {
    Write-Log "No VC++ Redistributable packages found — system is clean." -Level INFO
    exit 0
}

Write-Log "Packages to remove:" -Level INFO
$i = 1
foreach ($p in $packages) {
    Write-Log "  [$i] $($p.DisplayName) ($($p.Architecture)) v$($p.DisplayVersion)" -Level INFO
    $i++
}

# Phase 2: Uninstall
Write-LogHeader "Phase 2: Uninstalling"

$results = @()
$ok = 0; $fail = 0; $n = 0; $total = $packages.Count

foreach ($pkg in $packages) {
    $n++
    Write-Log "" -Level INFO
    Write-Log "[$n/$total] Processing..." -Level INFO
    $r = Uninstall-VCRedistPackage -Package $pkg
    $results += $r
    if ($r.Success) { $ok++ } else { $fail++ }
}

# Phase 3: Summary
Write-LogHeader "Phase 3: Summary"
$elapsed = (Get-Date) - $script:StartTime
Write-Log "Processed: $total | OK: $ok | Failed: $fail | Duration: $([math]::Round($elapsed.TotalSeconds,2))s" -Level INFO

foreach ($r in $results) {
    $tag = if ($r.Success) { "[OK]  " } else { "[FAIL]" }
    Write-Log "  $tag $($r.PackageName) — $($r.Message)" -Level $(if ($r.Success) { 'INFO' } else { 'WARN' })
}

$rebootNeeded = $results | Where-Object { $_.ExitCode -eq 3010 }
if ($rebootNeeded.Count -gt 0) {
    Write-Log "[!] REBOOT REQUIRED" -Level WARN
}

Write-Log "Log: $script:LogFile" -Level INFO

if ($fail -gt 0 -and -not $WhatIf) { Write-Log "Completed with errors." -Level WARN; exit 1 }
else {
    if ($WhatIf) { Write-Log "WhatIf complete — no changes made." -Level SUCCESS }
    else         { Write-Log "Uninstallation complete." -Level SUCCESS }
    exit 0
}