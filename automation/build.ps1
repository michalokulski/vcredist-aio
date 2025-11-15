param(
    [Parameter(Mandatory = $true)]
    [string] $PackagesFile,

    [Parameter(Mandatory = $true)]
    [string] $OutputDir,

    [Parameter(Mandatory = $true)]
    [string] $PSEXEPath
    ,
    [switch] $UseWingetRepo
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
    $downloadDir = Join-Path $OutputDir $pkg.id.Replace(".", "_")

    if ($UseWingetRepo) {
        Write-Host "ℹ Attempting to extract installer URLs from winget-pkgs repo"

        function Get-InstallerUrlsFromRepo {
            param(
                [Parameter(Mandatory = $true)]
                [string] $PackageId,
                [Parameter(Mandatory = $true)]
                [string] $Version
            )

            $token = $env:GITHUB_TOKEN
            $headers = @{ 'User-Agent' = 'vcredist-aio' }
            if ($token) { $headers.Authorization = "token $token" }

            $q = [System.Uri]::EscapeDataString($PackageId)
            $searchUrl = "https://api.github.com/search/code?q=repo:microsoft/winget-pkgs+$q+in:path"

            try {
                $search = Invoke-RestMethod -Uri $searchUrl -Headers $headers -ErrorAction Stop
                if (-not $search -or -not $search.items -or $search.total_count -lt 1) { return @() }

                $fileApiUrl = $search.items[0].url
                $fileObj = Invoke-RestMethod -Uri $fileApiUrl -Headers $headers -ErrorAction Stop
                if (-not $fileObj.content) { return @() }

                $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))

                # Find Installer Urls under Installers: blocks
                $urls = @()
                $matches = [regex]::Matches($content, '^[ \t]*Url:[ \t]*(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
                foreach ($m in $matches) { $urls += $m.Groups[1].Value.Trim() }

                # Filter by version if present nearby (best-effort)
                if ($Version -and $urls.Count -gt 0) {
                    return $urls
                }

                return $urls
            } catch {
                Write-Host ("⚠ Repo installer lookup failed for {0}: {1}" -f $PackageId, $_.Exception.Message) -ForegroundColor Yellow
                return @()
            }
        }

        $urls = Get-InstallerUrlsFromRepo -PackageId $pkg.id -Version $pkg.version
        if ($urls -and $urls.Count -gt 0) {
            New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
            foreach ($u in $urls) {
                try {
                    $fileName = [System.IO.Path]::GetFileName([Uri]$u).Trim()
                    if ([string]::IsNullOrWhiteSpace($fileName)) {
                        $fileName = "installer_$(Get-Random).bin"
                    }
                    $outPath = Join-Path $downloadDir $fileName
                    Write-Host "→ Downloading $u → $outPath"
                    Invoke-WebRequest -Uri $u -OutFile $outPath -UseBasicParsing -ErrorAction Stop
                } catch {
                    Write-Warning ("⚠ Failed to download {0}: {1}" -f $u, $_.Exception.Message)
                }
            }
            Write-Host "✔ Downloaded manifest installers to: $downloadDir"
            continue
        }
        else {
            Write-Host "ℹ Repo did not provide installer URLs for $($pkg.id); falling back to winget download"
        }
    }

    # Winget download command (fallback)
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

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

# Ensure ps2exe module present and functional
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
        Write-Error \"ps2exe setup failed: `\$_\"
        exit 1
    }
"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to initialize ps2exe. Aborting build."
    exit 1
}

# Now invoke ps2exe with proper error handling
$ps2exeResult = pwsh -Command "
    Import-Module ps2exe -ErrorAction Stop
    Invoke-ps2exe -InputFile \"$inputFile\" -OutputFile \"$outputFile\" -Icon \"$icon\" -RequireAdministrator:\$$requireAdmin -NoConsole:\$$noConsole -ErrorAction Stop
"

if ($LASTEXITCODE -ne 0) {
    Write-Error "ps2exe conversion failed. Output: $ps2exeResult"
    exit 1
}

# Create a SHA256 checksum for the produced EXE if present
if (Test-Path $outputFile) {
    $hash = Get-FileHash $outputFile -Algorithm SHA256
    $checksumFile = Join-Path (Split-Path $outputFile -Parent) "SHA256.txt"
    "$($hash.Hash)  $(Split-Path $outputFile -Leaf)" | Out-File $checksumFile -Encoding ASCII
    Write-Host "🔐 SHA256: $($hash.Hash)"
    Write-Host "📄 Checksum saved to: $checksumFile"
}

Write-Host "🎉 Build completed. Output in: $OutputDir"