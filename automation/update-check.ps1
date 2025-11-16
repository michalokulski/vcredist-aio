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
            return $result
        } catch {
            $msg = $_.Exception.Message
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

        # Build path to architecture folder (where version subdirectories live)
        $archPath = "manifests/m/$vendor/$product/$folderYear/$arch"
        $archUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$archPath"

        Write-Host "  Querying: $archPath" -ForegroundColor DarkGray

        # Get list of version folders
        $versionDirs = Invoke-WithRetry -Script { 
            Invoke-RestMethod -Uri $archUrl -Headers $Headers -ErrorAction Stop 
        } -Attempts 3 -DelaySeconds 2

        if (-not $versionDirs) { 
            Write-Host "  ⚠ No version directories found at: $archPath" -ForegroundColor DarkGray
            return $null 
        }

        # Ensure we're working with an array
        if ($versionDirs -isnot [array]) {
            $versionDirs = @($versionDirs)
        }

        # Extract and sort version folders
        $versions = @()
        foreach ($vd in $versionDirs) {
            if ($vd.type -eq 'dir' -and -not [string]::IsNullOrWhiteSpace($vd.name)) {
                $versions += $vd.name
            }
        }

        if ($versions.Count -eq 0) { 
            Write-Host "  ⚠ No versions found" -ForegroundColor DarkGray
            return $null 
        }

        # Sort by semantic version (descending)
        $parsed = @()
        foreach ($v in $versions) {
            try {
                $ver = [version]$v
                $parsed += @{name=$v; ver=$ver}
            } catch {
                # Fallback: treat as string if not semver, compare lexicographically
                $parsed += @{name=$v; ver=[version]"0.0.0.0"}
            }
        }

        # Sort versions: highest first
        Write-Host "  DEBUG: Before sort - parsed count: $($parsed.Count)" -ForegroundColor DarkGray
        $sorted = @($parsed | Sort-Object -Property @{Expression={$_.ver}; Descending=$true}) | Where-Object { $_ }
        Write-Host "  DEBUG: After sort - sorted count: $($sorted.Count)" -ForegroundColor DarkGray
        
        if ($sorted.Count -eq 0) {
            Write-Host "  DEBUG: sorted is empty after filter" -ForegroundColor DarkRed
            Write-Host "  DEBUG: raw sorted before filter: $((@($parsed | Sort-Object -Property @{Expression={$_.ver}; Descending=$true})).Count)" -ForegroundColor DarkRed
            Write-Host "  ⚠ Failed to sort versions" -ForegroundColor DarkGray
            return $null
        }

        Write-Host "  DEBUG: sorted[0] = $($sorted[0] | ConvertTo-Json)" -ForegroundColor DarkGray
        $chosenVersion = $sorted[0].name

        if ([string]::IsNullOrWhiteSpace($chosenVersion)) { 
            Write-Host "  DEBUG: chosenVersion is empty/null" -ForegroundColor DarkRed
            return $null 
        }

        Write-Host "  Latest version: $chosenVersion" -ForegroundColor DarkGray
        return $chosenVersion
    } catch {
        Write-Host "  ❌ Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  StackTrace: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
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