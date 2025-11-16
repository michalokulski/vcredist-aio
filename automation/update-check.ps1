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
        if ($parts.Length -lt 2) { return $null }

        $vendor = $parts[0]
        $product = $parts[1]

        # Special handling for 2015+ (which uses a different folder structure in the repo)
        $productPath = $product
        $is2015Plus = $false
        if ($product -eq "VCRedist" -and $parts.Length -gt 2 -and $parts[2] -eq "2015Plus") {
            $productPath = "VCRedist/2015+"
            $is2015Plus = $true
        }

        # List the vendor/product folder (avoid assuming a PackageId folder exists)
        $parentPath = "manifests/m/$vendor/$productPath"
        $parentApiUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$parentPath"

        # Use a single attempt for the top-level listing to avoid noisy 404 retries
        $dirList = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $parentApiUrl -Headers $Headers -ErrorAction Stop } -Attempts 1 -DelaySeconds 1
        if (-not $dirList) { return $null }

        # For 2015+, look for x86/x64 folders; for older versions, look for PackageId or version folders
        $targetFolder = $null

        if ($is2015Plus) {
            # 2015+ structure: manifests/m/Microsoft/VCRedist/2015+/x86 or x64
            $arch = if ($PackageId -match "x64") { "x64" } else { "x86" }
            $targetFolder = $dirList | Where-Object { $_.type -eq 'dir' -and $_.name -eq $arch } | Select-Object -First 1
        } else {
            # Older structure: manifests/m/Microsoft/VCRedist/2005/x86, etc.
            $targetFolder = $dirList | Where-Object { $_.type -eq 'dir' -and $_.name -eq $PackageId } | Select-Object -First 1
            if (-not $targetFolder) {
                # Fallback: look for any folder matching the product year
                $year = $parts[2]
                $targetFolder = $dirList | Where-Object { $_.type -eq 'dir' -and $_.name -eq $year } | Select-Object -First 1
            }
        }

        if (-not $targetFolder) { return $null }

        $versionDirUrl = $targetFolder.url
        $versionFolders = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $versionDirUrl -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
        if (-not $versionFolders) { return $null }

        # For 2015+: versionFolders should contain version directories directly
        # For older: versionFolders should contain architecture folders
        $archDirUrl = $null
        if ($is2015Plus) {
            $archDirUrl = $versionDirUrl
        } else {
            $arch = if ($PackageId -match "x64") { "x64" } else { "x86" }
            $archDir = $versionFolders | Where-Object { $_.type -eq 'dir' -and $_.name -eq $arch } | Select-Object -First 1
            if ($archDir) { $archDirUrl = $archDir.url }
        }

        if (-not $archDirUrl) { return $null }

        $versionDirs = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $archDirUrl -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
        if (-not $versionDirs) { return $null }

        # Extract version folder names and sort by semantic version
        $versions = @()
        $directYamlVersion = $null

        foreach ($vd in $versionDirs) {
            if ($vd.type -eq 'dir') {
                $versions += $vd.name
            }
            elseif ($vd.type -eq 'file' -and ($vd.name -match '\.ya?ml$')) {
                # Try extracting version directly from file at this level (fallback)
                $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $vd.url -Headers $Headers -ErrorAction Stop } -Attempts 1 -DelaySeconds 1
                if ($fileObj -and $fileObj.content) {
                    $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                    foreach ($regex in @('^[ \t]*Version:[ \t]*(.+)$', '^[ \t]*PackageVersion:[ \t]*(.+)$')) {
                        $m = [regex]::Match($content, $regex, [System.Text.RegularExpressions.RegexOptions]::Multiline)
                        if ($m.Success) {
                            $directYamlVersion = $m.Groups[1].Value.Trim()
                            break
                        }
                    }
                }
            }
        }

        if ($directYamlVersion) { return $directYamlVersion }

        if ($versions.Count -gt 0) {
            # Sort by semantic version, then alphabetically as fallback
            $parsed = @()
            foreach ($v in $versions) {
                try {
                    $ver = [version]$v
                    $parsed += @{name=$v; ver=$ver; valid=$true}
                } catch {
                    $parsed += @{name=$v; ver=$null; valid=$false}
                }
            }
            $withVer = $parsed | Where-Object { $_.valid } | Sort-Object -Property ver -Descending
            $chosen = if ($withVer.Count -gt 0) { $withVer[0].name } else { ($parsed | Sort-Object -Property name -Descending)[0].name }

            $versionPath = "$archDirUrl/$chosen"
            $versionContentsUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$versionPath"
            $versionFiles = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $versionContentsUrl -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
            if ($versionFiles) {
                foreach ($f in $versionFiles) {
                    if ($f.type -eq 'file' -and ($f.name -match '\.ya?ml$')) {
                        $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $f.url -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
                        if ($fileObj -and $fileObj.content) {
                            $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                            foreach ($regex in @('^[ \t]*Version:[ \t]*(.+)$', '^[ \t]*PackageVersion:[ \t]*(.+)$', '^[ \t]*packageVersion:[ \t]*(.+)$')) {
                                $m = [regex]::Match($content, $regex, [System.Text.RegularExpressions.RegexOptions]::Multiline)
                                if ($m.Success) { return $m.Groups[1].Value.Trim() }
                            }
                        }
                    }
                }
            }
        }

        return $null
    } catch {
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