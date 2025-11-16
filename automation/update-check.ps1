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
        # Fallback versions for packages without current manifests in winget-pkgs
        $fallbackVersions = @{
            "Microsoft.VCRedist.2005.x86" = "8.0.61000"
            "Microsoft.VCRedist.2005.x64" = "8.0.61000"
            "Microsoft.VCRedist.2008.x86" = "9.0.30729.6161"
            "Microsoft.VCRedist.2008.x64" = "9.0.30729.6161"
            "Microsoft.VCRedist.2010.x86" = "10.0.40219"
            "Microsoft.VCRedist.2010.x64" = "10.0.40219"
            "Microsoft.VCRedist.2012.x86" = "11.0.61030.0"
            "Microsoft.VCRedist.2012.x64" = "11.0.61030.0"
            "Microsoft.VCRedist.2013.x86" = "12.0.40664.0"
            "Microsoft.VCRedist.2013.x64" = "12.0.40664.0"
            "Microsoft.VCRedist.2015Plus.x86" = "14.44.35211.0"
            "Microsoft.VCRedist.2015Plus.x64" = "14.44.35211.0"
        }

        # Parse PackageId: Microsoft.VCRedist.2005.x86 or Microsoft.VCRedist.2015Plus.x64
        $parts = $PackageId -split '\.'
        if ($parts.Length -lt 3) { 
            if ($fallbackVersions.ContainsKey($PackageId)) { return $fallbackVersions[$PackageId] }
            return $null 
        }

        $vendor = $parts[0]           # "Microsoft"
        $product = $parts[1]          # "VCRedist"
        $versionPart = $parts[2]      # "2005", "2008", "2015Plus", etc.
        $arch = if ($PackageId -match "x64") { "x64" } else { "x86" }

        # Determine folder structure
        # 2015+ uses: manifests/m/Microsoft/VCRedist/2015+/<arch>/<version>/
        # Older uses: manifests/m/Microsoft/VCRedist/<year>/<arch>/<version>/
        $folderYear = if ($versionPart -eq "2015Plus") { "2015+" } else { $versionPart }

        # Build the path to the architecture folder
        $archPath = "manifests/m/$vendor/$product/$folderYear/$arch"
        $archUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$archPath"

        Write-Host "  Trying manifest path: $archPath" -ForegroundColor DarkGray

        # Get list of version folders (single attempt to avoid rate limit)
        $versionDirs = $null
        try {
            $versionDirs = Invoke-RestMethod -Uri $archUrl -Headers $Headers -ErrorAction Stop
        } catch {
            Write-Host "  Manifest path not found, using fallback" -ForegroundColor DarkGray
            if ($fallbackVersions.ContainsKey($PackageId)) { 
                return $fallbackVersions[$PackageId] 
            }
            return $null
        }

        if (-not $versionDirs) { 
            if ($fallbackVersions.ContainsKey($PackageId)) { 
                return $fallbackVersions[$PackageId] 
            }
            return $null 
        }

        # Extract version folder names
        $versions = @()
        foreach ($vd in $versionDirs) {
            if ($vd.type -eq 'dir' -and -not [string]::IsNullOrWhiteSpace($vd.name)) {
                $versions += $vd.name
            }
        }

        if ($versions.Count -eq 0) {
            Write-Host "  No version folders found, using fallback" -ForegroundColor DarkGray
            if ($fallbackVersions.ContainsKey($PackageId)) { 
                return $fallbackVersions[$PackageId] 
            }
            return $null
        }

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

        if ([string]::IsNullOrWhiteSpace($chosenVersion)) {
            if ($fallbackVersions.ContainsKey($PackageId)) { 
                return $fallbackVersions[$PackageId] 
            }
            return $null
        }

        Write-Host "  Latest version folder: $chosenVersion" -ForegroundColor DarkGray

        # Fetch the manifest YAML file
        $manifestUrl = "$archUrl/$chosenVersion"
        $manifestFiles = $null
        try {
            $manifestFiles = Invoke-RestMethod -Uri $manifestUrl -Headers $Headers -ErrorAction Stop
        } catch {
            # If manifest folder can't be read, return folder name as version
            return $chosenVersion
        }

        if (-not $manifestFiles) { return $chosenVersion }

        # Find the YAML file and extract version
        foreach ($file in $manifestFiles) {
            if ($file.type -eq 'file' -and ($file.name -match '\.ya?ml$')) {
                try {
                    $fileObj = Invoke-RestMethod -Uri $file.url -Headers $Headers -ErrorAction Stop
                    if ($fileObj -and $fileObj.content) {
                        $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                        
                        # Try to extract version from YAML
                        foreach ($regex in @('^[ \t]*Version:[ \t]*(.+)$', '^[ \t]*PackageVersion:[ \t]*(.+)$', '^[ \t]*packageVersion:[ \t]*(.+)$')) {
                            $m = [regex]::Match($content, $regex, [System.Text.RegularExpressions.RegexOptions]::Multiline)
                            if ($m.Success) { 
                                $extractedVersion = $m.Groups[1].Value.Trim()
                                Write-Host "  Extracted version: $extractedVersion" -ForegroundColor DarkGray
                                return $extractedVersion 
                            }
                        }
                    }
                } catch {
                    # Continue to next file
                }
            }
        }

        # Fallback: return the folder name as version
        Write-Host "  Using folder name as version: $chosenVersion" -ForegroundColor DarkGray
        return $chosenVersion
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor DarkGray
        # Check if fallback exists
        if ($fallbackVersions.ContainsKey($PackageId)) { 
            return $fallbackVersions[$PackageId] 
        }
        return $null
    }
}

# Main workflow
Write-Host "🔍 Checking for updates in Winget..." -ForegroundColor Cyan

# Load packages
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
        Write-Host "ℹ Using winget-pkgs repo version: $latestVersion"
    } else {
        Write-Warning "⚠ Failed to find version for: $($pkg.id)"
        continue
    }

    # Compare versions
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

# Save updated packages and create update branch if needed
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