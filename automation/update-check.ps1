param(
    [Parameter(Mandatory = $true)]
    [string] $PackagesFile,

    [Parameter(Mandatory = $true)]
    [string] $UpdateBranchPrefix
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
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "Command failed with exit code $LASTEXITCODE"
            }
            return $result
        } catch {
            $msg = $_.Exception.Message
            # Check for GitHub API rate limit (HTTP 403)
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

function Get-LatestVersionFromManifestPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageId,
        [Parameter(Mandatory = $true)]
        [hashtable] $Headers
    )

    try {
        $parts = $PackageId -split '\.'
        if ($parts.Length -lt 3) { return $null }

        $vendor = $parts[0]
        $product = $parts[1]
        $versionPart = $parts[2]
        $arch = if ($PackageId -match "x64") { "x64" } else { "x86" }

        # Determine folder structure
        $folderYear = if ($versionPart -eq "2015Plus") { "2015+" } else { $versionPart }

        # Build path to architecture folder
        $archPath = "manifests/m/$vendor/$product/$folderYear/$arch"
        $archUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$archPath"

        Write-Host "  Querying: $archPath" -ForegroundColor DarkGray

        # Get list of version folders
        $versionDirs = Invoke-WithRetry -Script { 
            Invoke-RestMethod -Uri $archUrl -Headers $Headers -ErrorAction Stop 
        } -Attempts 1 -DelaySeconds 1

        if (-not $versionDirs) { return $null }

        # Extract and sort version folders
        $versions = @()
        foreach ($vd in $versionDirs) {
            if ($vd.type -eq 'dir' -and -not [string]::IsNullOrWhiteSpace($vd.name)) {
                $versions += $vd.name
            }
        }

        if ($versions.Count -eq 0) { return $null }

        # Sort by semantic version (descending)
        $parsed = @()
        foreach ($v in $versions) {
            try {
                $ver = [version]$v
                $parsed += @{name=$v; ver=$ver}
            } catch {
                $parsed += @{name=$v; ver=$null}
            }
        }

        $withVer = $parsed | Where-Object { $_.ver -ne $null } | Sort-Object -Property ver -Descending
        $chosenVersion = if ($withVer.Count -gt 0) { $withVer[0].name } else { ($versions | Sort-Object -Descending)[0] }

        if ([string]::IsNullOrWhiteSpace($chosenVersion)) { return $null }

        Write-Host "  Latest version: $chosenVersion" -ForegroundColor DarkGray
        return $chosenVersion
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor DarkGray
        return $null
    }
}

# Main workflow
Write-Host "🔍 Checking for updates in Winget..." -ForegroundColor Cyan

$packagesJson = Get-Content $PackagesFile -Raw | ConvertFrom-Json
$packages = $packagesJson.packages

$token = $env:GITHUB_TOKEN
$headers = @{ 'User-Agent' = 'vcredist-aio-bot' }
if ($token) { $headers.Authorization = "token $token" }

$updatesFound = $false

foreach ($pkg in $packages) {
    Write-Host "`n➡ Checking package: $($pkg.id)"

    $latestVersion = Get-LatestVersionFromManifestPath -PackageId $pkg.id -Headers $headers

    if ($latestVersion) {
        Write-Host "ℹ Latest version: $latestVersion"
    } else {
        Write-Warning "⚠ Failed to find version for: $($pkg.id)"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($pkg.version)) {
        Write-Host "📌 Local version empty → marking as outdated"
        $pkg.version = $latestVersion
        $updatesFound = $true
        continue
    }

    if ($pkg.version -ne $latestVersion) {
        Write-Host "⬆ Update available: $($pkg.version) → $latestVersion"
        $pkg.version = $latestVersion
        $updatesFound = $true
    }
    else {
        Write-Host "✔ Up to date"
    }
}

if ($updatesFound) {
    Write-Host "`n📝 Updates found, saving packages.json..." -ForegroundColor Green
    $packagesJson | ConvertTo-Json -Depth 10 | Out-File $PackagesFile -Encoding UTF8

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $branchName = "$UpdateBranchPrefix-$timestamp"
    Write-Host "🌿 Update branch: $branchName"
    $branchName | Out-File "update-branch.txt" -Encoding UTF8

    Write-Host "✅ Ready for commit and release" -ForegroundColor Green
}
else {
    Write-Host "`n✔ No updates found." -ForegroundColor Green
}

exit 0