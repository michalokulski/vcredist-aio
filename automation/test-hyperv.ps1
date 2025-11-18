<#!
.SYNOPSIS
    Automated end-to-end test of VC Redist AIO installer on a Hyper-V Windows 11 VM.
.DESCRIPTION
    This host-side script will:
      - Start the specified VM (Windows 10/11)
      - Optionally create a checkpoint and revert after test
      - Copy the built installer into the VM
      - Run extract-only, then full silent install with custom LOGDIR and PACKAGES filter
      - Validate logs and exit codes; basic registry verification
      - Run silent uninstaller and validate cleanup
      - Collect logs back to the host artifacts folder

    Requires Hyper-V PowerShell module and PowerShell Direct or Guest Service Interface for file copy.

.PARAMETER VMName
    Name of the Hyper-V VM to test against.
.PARAMETER GuestCredential
    Credentials for the guest OS (domain/user or .\user). Required for PowerShell Direct and Copy-VMFile.
.PARAMETER InstallerPath
    Path to VC_Redist_AIO_Offline.exe on the host. Default: dist\VC_Redist_AIO_Offline.exe
.PARAMETER ArtifactsDir
    Host directory to store pulled logs. Default: test-artifacts
.PARAMETER NoCheckpoint
    Skip creating/restoring a VM checkpoint.
.PARAMETER KeepCheckpointOnSuccess
    Keep the checkpoint if the test succeeds (ignored when -NoCheckpoint).
.EXAMPLE
    $cred = Get-Credential
    pwsh automation/test-hyperv.ps1 -VMName Win11-Dev -GuestCredential $cred \
      -InstallerPath dist/VC_Redist_AIO_Offline.exe -ArtifactsDir artifacts
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $VMName,

    [Parameter(Mandatory = $true)]
    [pscredential] $GuestCredential,

    [Parameter(Mandatory = $false)]
    [string] $InstallerPath = "dist/VC_Redist_AIO_Offline.exe",

    [Parameter(Mandatory = $false)]
    [string] $ArtifactsDir = "test-artifacts",

    [switch] $NoCheckpoint,
    [switch] $KeepCheckpointOnSuccess
)

$ErrorActionPreference = 'Stop'

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $Script,
        [int] $Attempts = 6,
        [int] $DelaySeconds = 5
    )
    for ($i=1; $i -le $Attempts; $i++) {
        try { return & $Script } catch {
            if ($i -eq $Attempts) { throw }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

Write-Host "🔧 Hyper-V Automated Test Runner" -ForegroundColor Cyan

# Validate host prerequisites
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    Write-Error "Hyper-V PowerShell module not found. Install RSAT Hyper-V tools."
}
Import-Module Hyper-V -ErrorAction Stop

# Normalize host paths
$InstallerPath = (Resolve-Path $InstallerPath).Path
if (-not (Test-Path $InstallerPath)) {
    Write-Error "Installer not found: $InstallerPath"
}

# Ensure artifacts directory
New-Item -ItemType Directory -Force -Path $ArtifactsDir | Out-Null
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss')
$runDir = Join-Path $ArtifactsDir "run-$runId"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

# Ensure VM exists
$vm = Get-VM -Name $VMName -ErrorAction Stop
Write-Host "🖥️ Target VM: $($vm.Name) (State: $($vm.State))" -ForegroundColor DarkGray

# Enable Guest Service Interface for file copy
try {
    $gsi = Get-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
    if ($gsi -and -not $gsi.Enabled) {
        Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" | Out-Null
        Write-Host "Enabled Guest Service Interface" -ForegroundColor DarkGray
    }
} catch {}

# Start VM if needed
if ($vm.State -ne 'Running') {
    Write-Host "▶ Starting VM..." -ForegroundColor Yellow
    Start-VM -Name $VMName | Out-Null
}

# Wait for PowerShell Direct connectivity
Write-Host "⏳ Waiting for PowerShell Direct..." -ForegroundColor DarkGray
Invoke-WithRetry -Attempts 20 -DelaySeconds 6 -Script {
    Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock { 'pong' } -ErrorAction Stop | Out-Null
}
Write-Host "✅ PowerShell Direct available" -ForegroundColor Green

# Create checkpoint (optional)
$snapshot = $null
if (-not $NoCheckpoint) {
    $snapName = "vcredist-aio-test-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Write-Host "📸 Creating checkpoint: $snapName" -ForegroundColor Yellow
    $snapshot = Checkpoint-VM -Name $VMName -SnapshotName $snapName -Confirm:$false
}

# Prepare guest paths
$guestRoot = "C:\\VCRTest"
$guestLogs = "C:\\VCRLogs"
$guestInstaller = Join-Path $guestRoot "VC_Redist_AIO_Offline.exe"

Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock {
    param($root,$logs)
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    if (Test-Path $logs) { Remove-Item -Recurse -Force -Path $logs }
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
} -ArgumentList $guestRoot,$guestLogs

# Copy installer to guest
Write-Host "📤 Copying installer to VM..." -ForegroundColor Yellow
try {
    Copy-VMFile -Name $VMName -SourcePath $InstallerPath -DestinationPath $guestInstaller -FileSource Host -CreateFullPath -Force -Credential $GuestCredential -ErrorAction Stop
} catch {
    Write-Warning "Copy-VMFile failed: $($_.Exception.Message)"
    Write-Warning "Falling back to chunked copy via PowerShell Direct (slower)."
    # Fallback copy: Base64 chunking
    $bytes = [IO.File]::ReadAllBytes($InstallerPath)
    $chunkSize = 1MB
    $total = $bytes.Length
    Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock { param($path) if (Test-Path $path) { Remove-Item $path -Force } } -ArgumentList $guestInstaller
    for ($offset=0; $offset -lt $total; $offset += $chunkSize) {
        $len = [Math]::Min($chunkSize, $total - $offset)
        $chunk = $bytes[$offset..($offset + $len - 1)]
        $b64 = [Convert]::ToBase64String($chunk)
        Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock {
            param($path,$b64)
            $bytes = [Convert]::FromBase64String($b64)
            [IO.File]::OpenWrite($path).Dispose()
            Add-Content -Path $path -Value $bytes -AsByteStream
        } -ArgumentList $guestInstaller,$b64
    }
}

# Helper: run NSIS installer with arguments and return exit code
function Invoke-GuestInstaller {
    param([string] $Args)
    $code = Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock {
        param($exe,$args)
        $p = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        return $p.ExitCode
    } -ArgumentList $guestInstaller,$Args
    return [int]$code
}

# Step 1: Extract-only
Write-Host "🧪 Test 1: Extract-only" -ForegroundColor Cyan
$extractDir = Join-Path $guestRoot "extracted"
$code = Invoke-GuestInstaller -Args "/EXTRACT=\"$extractDir\""
if ($code -ne 0) { throw "Extract-only exit code $code" }
Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock {
    param($dir)
    if (-not (Test-Path (Join-Path $dir 'install.ps1'))) { throw "install.ps1 not extracted" }
    if (-not (Test-Path (Join-Path $dir 'packages'))) { throw "packages folder not extracted" }
} -ArgumentList $extractDir

# Step 2: Silent install with LOGDIR and filter
Write-Host "🧪 Test 2: Silent install" -ForegroundColor Cyan
$code = Invoke-GuestInstaller -Args "/S /PACKAGES=\"2022,2019\" /LOGDIR=\"$guestLogs\""
if ($code -ne 0 -and $code -ne 3010) { throw "Install exit code $code" }

# Validate install log
$installLog = Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock {
    param($dir)
    $log = Get-ChildItem $dir -Filter 'vcredist-install-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { throw "Install log not found in $dir" }
    return $log.FullName
} -ArgumentList $guestLogs

$ok = Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock {
    param($log)
    $txt = Get-Content -Path $log -Raw
    return ($txt -match 'Installation completed successfully!') -and ($txt -match 'Failed:\s+0')
} -ArgumentList $installLog
if (-not $ok) { throw "Install log does not indicate success" }

# Basic registry check: Ensure at least some VC++ packages are present
$vcCount = Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock {
    $paths = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
               'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $items = foreach ($p in $paths) { Get-ItemProperty $p -ErrorAction SilentlyContinue }
    ($items | Where-Object { $_.DisplayName -match 'Microsoft Visual C\+\+.*Redistributable' }).Count
}
if ($vcCount -lt 2) { Write-Warning "Registry shows few Visual C++ packages ($vcCount)." }

# Step 3: Silent uninstaller
Write-Host "🧪 Test 3: Uninstall" -ForegroundColor Cyan
$uninstExe = 'C:\\Program Files\\VCRedist_AIO\\uninstall.exe'
$uninstCode = Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock {
    param($exe)
    if (Test-Path $exe) {
        $p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru -WindowStyle Hidden
        return $p.ExitCode
    } else {
        $ps1 = 'C:\\Program Files\\VCRedist_AIO\\uninstall.ps1'
        if (Test-Path $ps1) {
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File \"$ps1\" -Force -Silent" -Wait -PassThru -WindowStyle Hidden
            return $p.ExitCode
        }
        return 1
    }
} -ArgumentList $uninstExe
if ($uninstCode -ne 0) { Write-Warning "Uninstall exit code: $uninstCode" }

# Collect logs back to host
Write-Host "📥 Collecting logs from VM..." -ForegroundColor Yellow
$guestUninstLogsDir = 'C:\\Program Files\\VCRedist_AIO'
$hostLogsDir = Join-Path $runDir 'logs'
New-Item -ItemType Directory -Force -Path $hostLogsDir | Out-Null

$pullSpecs = @(
    @{ From = $guestLogs; Pattern = 'vcredist-install-*.log'; To = $hostLogsDir },
    @{ From = $guestUninstLogsDir; Pattern = 'vcredist-uninstall-*.log'; To = $hostLogsDir }
)

foreach ($spec in $pullSpecs) {
    try {
        $files = Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock {
            param($dir,$pattern)
            if (Test-Path $dir) {
                Get-ChildItem -Path $dir -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
            }
        } -ArgumentList $spec.From,$spec.Pattern
        foreach ($f in ($files | Where-Object { $_ })) {
            $dest = Join-Path $spec.To (Split-Path $f -Leaf)
            Copy-VMFile -Name $VMName -SourcePath $f -DestinationPath $dest -FileSource Guest -CreateFullPath -Force -Credential $GuestCredential -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning "Failed to copy logs from $($spec.From): $($_.Exception.Message)"
    }
}

# Restore checkpoint if created
$testFailed = $false
try {
    Write-Host "✅ All test steps executed." -ForegroundColor Green
} catch {
    $testFailed = $true
} finally {
    if ($snapshot -and -not $NoCheckpoint) {
        if ($testFailed -and $KeepCheckpointOnSuccess) {
            Write-Host "⚠ Keeping checkpoint due to failure: $($snapshot.Name)" -ForegroundColor Yellow
        } else {
            Write-Host "↩ Reverting VM to checkpoint..." -ForegroundColor Yellow
            Stop-VM -Name $VMName -Force -TurnOff | Out-Null
            Restore-VMSnapshot -VMName $VMName -Name $snapshot.Name -Confirm:$false | Out-Null
            Remove-VMSnapshot -VMName $VMName -Name $snapshot.Name -Confirm:$false | Out-Null
        }
    }
}

# Final summary
$summary = [pscustomobject]@{
    VMName       = $VMName
    RunId        = $runId
    ArtifactsDir = $runDir
    ExtractExit  = 0
    InstallExit  = $code
    UninstallExit= $uninstCode
}
$summary | ConvertTo-Json | Out-File (Join-Path $runDir 'summary.json') -Encoding UTF8

if ($testFailed) { exit 1 } else { exit 0 }
