# Helper to regenerate bootstrap without requiring ps2exe and without cleanup
function ps2exe { param($Args) Write-Host "stub: ps2exe present" }
function Invoke-ps2exe { param($Params) Write-Host "stub: Invoke-ps2exe called"; return }
function Remove-Item { param($Path, [switch]$Recurse, [switch]$Force, $ErrorAction) Write-Host "stub: Remove-Item called for: $Path" }

# Dot-source the main builder to run its logic in this session
$builder = Join-Path $PSScriptRoot 'build-ps2exe.ps1'
. $builder -VerboseBuild
