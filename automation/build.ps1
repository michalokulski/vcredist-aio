param(
    [Parameter(Mandatory = $true)]
    [string] $PackagesFile,

    [Parameter(Mandatory = $true)]
    [string] $OutputDir,

    [Parameter(Mandatory = $true)]
    [string] $PSEXEPath
)

Write-Host "📦 Starting offline build process..."

# Ensure output directory exists
if (Test-Path $OutputDir) {
    Remove-Item -Recurse -Force $OutputDir
}
New-Item -ItemType Directory -Path $OutputDir | Out-Null


# Load packages list
$packages = Get-Content $PackagesFile -Raw | ConvertFrom-Json

Write-Host "📥 Downloading packages via winget..."

foreach ($pkg in $packages.packages) {

    if ([string]::IsNullOrWhiteSpace($pkg.version)) {
        Write-Warning "⚠ Package '$($pkg.id)' has no version assigned — skipping"
        continue
    }

    Write-Host "`n➡ Downloading $($pkg.id) $($pkg.version)"

    # Winget download command
    $downloadDir = Join-Path $OutputDir $pkg.id.Replace(".", "_")

    & winget download `
        --id $pkg.id `
        --version $pkg.version `
        --source winget `
        --accept-source-agreements `
        --accept-package-agreements `
        --output $downloadDir

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "⚠ Failed to download: $($pkg.id)"
        continue
    }

    Write-Host "✔ Downloaded to: $downloadDir"
}

Write-Host "`n🛠 Preparing offline installer bootstrap script..."

# Use a single-quoted here-string so variables are evaluated at runtime inside the generated script
$bootstrap = @'
# Auto-install all VC++ redistributables that were downloaded
Write-Host "Installing VC++ Redistributables..."

$base = Split-Path -Parent $MyInvocation.MyCommand.Definition

Get-ChildItem $base -File -Recurse | ForEach-Object {
    $file = $_.FullName
    Write-Host "→ Running: $($_.Name)"
    if ($file.ToLower().EndsWith(".msi")) {
        Start-Process msiexec -ArgumentList "/i","`"$file`"","/qn","/norestart" -Wait
    } else {
        # Many MS redistributables support /quiet /norestart; if a package needs different switches, add mapping
        Start-Process -FilePath $file -ArgumentList "/quiet","/norestart" -Wait
    }
}

Write-Host "Done."
'@

$scriptPath = Join-Path $OutputDir "installer.ps1"
Set-Content $scriptPath $bootstrap -Encoding UTF8


Write-Host "📦 Converting installer.ps1 → EXE using PowerShell2Exe JSON config..."

# Read ps2exe config robustly
$cfg = Get-Content $PSEXEPath -Raw | ConvertFrom-Json
$inputFile = $scriptPath
$outputFile = if ($cfg.output) { $cfg.output } else { Join-Path $OutputDir "VC_Redist_AIO_Offline.exe" }
$icon = $cfg.icon
$requireAdmin = $cfg.requireAdmin
$noConsole = $cfg.noConsole

# Ensure ps2exe module present on runner (install if missing)
pwsh -Command "& {
    if (-not (Get-Module -ListAvailable -Name ps2exe)) { Install-Module -Name ps2exe -Force -Scope CurrentUser -AllowClobber }
    Import-Module ps2exe -ErrorAction Stop
    Invoke-ps2exe -InputFile `"$inputFile`" -OutputFile `"$outputFile`" -Icon `"$icon`" -RequireAdministrator:$requireAdmin -NoConsole:$noConsole
}"

# Create a SHA256 checksum for the produced EXE if present
if (Test-Path $outputFile) {
    $hash = Get-FileHash $outputFile -Algorithm SHA256
    $hash.String | Out-File (Join-Path (Split-Path $outputFile -Parent) ("$(Split-Path $outputFile -Leaf).sha256")) -Encoding ASCII
    Write-Host "🔐 SHA256: $($hash.Hash)"
}

Write-Host "🎉 Build completed. Output in: $OutputDir"