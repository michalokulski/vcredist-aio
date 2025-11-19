# VCRedist AIO Installer Automated Test Script
# Set these paths as needed
$InstallerExe = "C:\Users\admin\Downloads\VC_Redist_AIO_Offline.exe"  # <-- Set to your actual built EXE
$TestDir = "C:\VCRedistTest"
$LogDir = "$TestDir\\logs"
$ReportFile = "$TestDir\\test-report.txt"

param(
    [switch]$Auto
)

# Ensure test directories
New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

if (!(Test-Path $InstallerExe)) {
    Write-Error "Installer EXE not found: $InstallerExe"
    exit 1
}

function Run-Test {
    param(
        [string]$Name,
        [string]$InstallerArgs = "",
        [string]$Desc
    )
    $log = "$LogDir\$Name-install.log"
    Write-Host "Running: $Name ($Desc)"
    $installResult = $null
    $uninstallResult = $null
    try {
        $process = Start-Process -FilePath $InstallerExe -ArgumentList $InstallerArgs -Wait -NoNewWindow -PassThru
        $exitCode = $process.ExitCode
        $output = @("NSIS installer does not produce console output. See log files in $LogDir or install location.")
        $installResult = [PSCustomObject]@{
            Name = $Name
            Args = $InstallerArgs
            Desc = $Desc
            ExitCode = $exitCode
            Log = $log
            Output = $output
        }
    } catch {
        $output = $_.Exception.Message
        $exitCode = -999
        $installResult = [PSCustomObject]@{
            Name = $Name
            Args = $InstallerArgs
            Desc = $Desc
            ExitCode = $exitCode
            Log = $log
            Output = $output -split "`r?`n"
        }
    }
    # If install was successful (exit code 0), run uninstall.ps1 directly from install path
    $uninstallLog = "$LogDir\$Name-uninstall.log"
    $uninstallScript = "$env:ProgramFiles\VCRedist_AIO\uninstall.ps1"
    if ($installResult.ExitCode -eq 0 -and (Test-Path $uninstallScript)) {
        Write-Host "  Running uninstall.ps1 (silent) from $uninstallScript"
        try {
            $uninstallProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$uninstallScript`" -Silent" -Wait -NoNewWindow -PassThru
            $uninstallExit = $uninstallProc.ExitCode
            $uninstallOutput = @("See uninstall log in $LogDir or install location.")
            $uninstallResult = [PSCustomObject]@{
                Name = "$Name-uninstall"
                Args = "-Silent"
                Desc = "Uninstall after $Name"
                ExitCode = $uninstallExit
                Log = $uninstallLog
                Output = $uninstallOutput
            }
        } catch {
            $uninstallResult = [PSCustomObject]@{
                Name = "$Name-uninstall"
                Args = "-Silent"
                Desc = "Uninstall after $Name"
                ExitCode = -999
                Log = $uninstallLog
                Output = $_.Exception.Message -split "`r?`n"
            }
        }
    }
    return @($installResult, $uninstallResult) | Where-Object { $_ -ne $null }
}

$results = @()

# Always run silent install/uninstall tests
$results += Run-Test -Name "install_silent" -InstallerArgs "/S /LOGDIR=`"$LogDir`"" -Desc "Silent install, all packages"
$results += Run-Test -Name "install_silent-uninstall" -InstallerArgs "-Silent" -Desc "Uninstall after install_silent"

$results += Run-Test -Name "install_filter" -InstallerArgs "/S /PACKAGES=2015+ /LOGDIR=`"$LogDir`"" -Desc "Silent install, 2015+ only"
$results += Run-Test -Name "install_filter-uninstall" -InstallerArgs "-Silent" -Desc "Uninstall after install_filter"

$results += Run-Test -Name "install_customlog" -InstallerArgs "/S /LOGDIR=`"$LogDir`"" -Desc "Silent install, custom log dir"
$results += Run-Test -Name "install_customlog-uninstall" -InstallerArgs "-Silent" -Desc "Uninstall after install_customlog"

if (-not $Auto) {
    # Only run interactive/manual tests if not in auto mode
    $results += Run-Test -Name "install_interactive" -InstallerArgs "/LOGDIR=`"$LogDir`"" -Desc "Interactive install, all packages"
    $results += Run-Test -Name "install_interactive-uninstall" -InstallerArgs "-Silent" -Desc "Uninstall after install_interactive"
}

# Generate summary report
$summary = @()
$summary += "VCRedist AIO Installer Automated Test Report"
$summary += "Date: $(Get-Date)"
$summary += "Installer: $InstallerExe"
$summary += "Test Directory: $TestDir"
$summary += ""
foreach ($r in $results) {
    $summary += "Test: $($r.Name)"
    $summary += "  Desc: $($r.Desc)"
    $summary += "  Args: $($r.Args)"
    $summary += "  ExitCode: $($r.ExitCode)"
    $summary += "  Log: $($r.Log)"
    $summary += "  --- First 10 lines of output ---"
    $summary += ($r.Output -split "`n" | Select-Object -First 10)
    $summary += ""
}
$summary -join "`n" | Set-Content $ReportFile -Encoding UTF8

Write-Host "Test report generated: $ReportFile"