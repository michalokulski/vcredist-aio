param(
    [Parameter(Mandatory = $true)]
    [string] $PackagesFile,

    [Parameter(Mandatory = $true)]
    [string] $UpdateBranchPrefix
    ,
    [switch] $UseWingetRepo
)

Write-Host "🔍 Checking for updates in Winget..."

# Utility: run a scriptblock with retries and exponential backoff
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
            # Check exit code; only fail if explicitly non-zero
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "Command failed with exit code $LASTEXITCODE"
            }
            # Allow empty results for HTTP calls (they may legitimately return $null)
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

# Try to locate a manifest by deterministic manifest path
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
        # List the vendor/product folder (avoid assuming a PackageId folder exists)
        $parentPath = "manifests/m/$vendor/$product"
        $parentApiUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$parentPath"

        # Use a single attempt for the top-level listing to avoid noisy 404 retries
        $dirList = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $parentApiUrl -Headers $Headers -ErrorAction Stop } -Attempts 1 -DelaySeconds 1
        if (-not $dirList) { return $null }

        # Look for a direct folder matching the PackageId, or files that include the PackageId
        foreach ($item in $dirList) {
            if ($item.type -eq 'dir' -and $item.name -eq $PackageId) {
                # Inspect version folders under manifests/m/vendor/product/PackageId
                $versionDirUrl = $item.url
                $versionFiles = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $versionDirUrl -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
                if ($versionFiles) {
                    $versions = @()
                    foreach ($vf in $versionFiles) {
                        if ($vf.type -eq 'dir') { $versions += $vf.name }
                        elseif ($vf.type -eq 'file' -and ($vf.name -match '\.ya?ml$')) {
                            $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $vf.url -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
                            if ($fileObj -and $fileObj.content) {
                                $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                                $m = [regex]::Match($content, '^[ \t]*Version:[ \t]*(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
                                if ($m.Success) { return $m.Groups[1].Value.Trim() }
                            }
                        }
                    }

                    if ($versions.Count -gt 0) {
                        $parsed = @()
                        foreach ($v in $versions) {
                            try { $ver = [version]$v; $parsed += @{name=$v; ver=$ver} } catch { $parsed += @{name=$v; ver=$null} }
                        }
                        $withVer = $parsed | Where-Object { $null -ne $_.ver } | Sort-Object -Property ver -Descending
                        $chosen = if ($withVer.Count -gt 0) { $withVer[0].name } else { ($versions | Sort-Object -Descending)[0] }

                        $versionPath = "manifests/m/$vendor/$product/$PackageId/$chosen"
                        $versionContentsUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$versionPath"
                        $versionFiles = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $versionContentsUrl -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
                        if ($versionFiles) {
                            foreach ($f in $versionFiles) {
                                if ($f.type -eq 'file' -and ($f.name -match '\.ya?ml$')) {
                                    $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $f.url -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
                                    if ($fileObj -and $fileObj.content) {
                                        $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                                        $regexes = @( '^[ \t]*Version:[ \t]*(.+)$', '^[ \t]*PackageVersion:[ \t]*(.+)$', '^[ \t]*packageVersion:[ \t]*(.+)$' )
                                        foreach ($r in $regexes) {
                                            $m = [regex]::Match($content, $r, [System.Text.RegularExpressions.RegexOptions]::Multiline)
                                            if ($m.Success) { return $m.Groups[1].Value.Trim() }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            # If filename contains the PackageId directly, try extracting version from that file
            if ($item.type -eq 'file' -and ($item.name -match "$([regex]::Escape($PackageId)).*\.ya?ml$")) {
                $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $item.url -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
                if ($fileObj -and $fileObj.content) {
                    $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                    $m = [regex]::Match($content, '^[ \t]*Version:[ \t]*(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
                    if ($m.Success) { return $m.Groups[1].Value.Trim() }
                }
            }

            # Try scanning reasonable subdirectories quickly for YAML that mentions the PackageId
            if ($item.type -eq 'dir') {
                try {
                    $subList = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $item.url -Headers $Headers -ErrorAction Stop } -Attempts 1 -DelaySeconds 1
                    foreach ($sub in $subList | Where-Object { $_.type -eq 'dir' }) {
                        $maybeFiles = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $sub.url -Headers $Headers -ErrorAction Stop } -Attempts 1 -DelaySeconds 1
                        if ($maybeFiles) {
                            foreach ($f2 in $maybeFiles | Where-Object { $_.type -eq 'file' -and ($_.name -match '\.ya?ml$') }) {
                                $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $f2.url -Headers $Headers -ErrorAction Stop } -Attempts 1 -DelaySeconds 1
                                if ($fileObj -and $fileObj.content) {
                                    $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                                    foreach ($r in @('^[ \t]*Version:[ \t]*(.+)$','^[ \t]*PackageVersion:[ \t]*(.+)$','^[ \t]*packageVersion:[ \t]*(.+)$')) {
                                        $m = [regex]::Match($content, $r, [System.Text.RegularExpressions.RegexOptions]::Multiline)
                                        if ($m.Success) { return $m.Groups[1].Value.Trim() }
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    # ignore and continue
                }
            }
        }

        return $null
    } catch {
        return $null
    }
}

# Recursively search under manifests/m/<vendor>/<product> for a manifest file matching the PackageId
function Search-ManifestForPackage {
    param(
        [Parameter(Mandatory=$true)][string] $Vendor,
        [Parameter(Mandatory=$true)][string] $Product,
        [Parameter(Mandatory=$true)][string] $PackageId,
        [Parameter(Mandatory=$true)][hashtable] $Headers,
        [int] $MaxDepth = 6
    )

    $startPath = "manifests/m/$Vendor/$Product"
    $queue = @([pscustomobject]@{ path = $startPath; depth = 0 })

    while ($queue.Count -gt 0) {
        $item = $queue[0]
        $queue = $queue[1..($queue.Count-1)]

        if ($item.depth -gt $MaxDepth) { continue }

        $apiUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$($item.path)"
        try {
            $list = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $apiUrl -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
        } catch {
            continue
        }

        if (-not $list) { continue }

        foreach ($entry in $list) {
            if ($entry.type -eq 'file') {
                # Quick filename match
                if ($entry.name -like "*$PackageId*.yaml" -or $entry.name -like "*$PackageId*.yml") {
                    return $entry
                }

                # Otherwise fetch small files and check content for Id: <PackageId>
                try {
                    $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $entry.url -Headers $Headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
                    if ($fileObj -and $fileObj.content) {
                        $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                        $escaped = [regex]::Escape($PackageId)
                        # Match: Id: <PackageId> (with whitespace flexibility)
                        if ($content -match ("^\s+Id:\s+" + $escaped)) {
                            return $entry
                        }
                    }
                } catch {
                    # ignore per-file fetch errors
                }
            } elseif ($entry.type -eq 'dir') {
                $queue += [pscustomobject]@{ path = $entry.path; depth = $item.depth + 1 }
            }
        }
    }

    return $null
}

# Try to get the latest version from the microsoft/winget-pkgs repository on GitHub
function Get-LatestVersionFromRepo {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageId
    )

    $token = $env:GITHUB_TOKEN
    $headers = @{ 'User-Agent' = 'vcredist-aio' }
    if ($token) { $headers.Authorization = "token $token" }

    # Try deterministic manifest-path lookup first
    $pathResult = Get-LatestVersionFromManifestPath -PackageId $PackageId -Headers $headers
    if ($pathResult) { return $pathResult }

    # If not found at the exact manifest path, attempt a recursive search under vendor/product
    try {
        $parts = $PackageId -split '\.'
        if ($parts.Length -ge 2) {
            $vendor = $parts[0]
            $product = $parts[1]
            $found = Search-ManifestForPackage -Vendor $vendor -Product $product -PackageId $PackageId -Headers $headers -MaxDepth 6
            if ($found) {
                # fetch the file and extract version from content or path
                $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $found.url -Headers $headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 1
                if ($fileObj -and $fileObj.content) {
                    $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                    $regexes = @( '^[ \t]*Version:[ \t]*(.+)$', '^[ \t]*PackageVersion:[ \t]*(.+)$', '^[ \t]*packageVersion:[ \t]*(.+)$' )
                    foreach ($r in $regexes) {
                        $m = [regex]::Match($content, $r, [System.Text.RegularExpressions.RegexOptions]::Multiline)
                        if ($m.Success) { return $m.Groups[1].Value.Trim() }
                    }

                    # Try to derive version from the path segments if content lacks it
                    $segments = $found.path -split '/'
                    # common layout: manifests/m/Vendor/Product/<year>/<arch>/<version>/<file>
                    if ($segments.Length -ge 5) {
                        # version is often the second-to-last segment
                        $candidate = $segments[-2]
                        if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
                    }
                }
            }
        }
    } catch {
        # continue to other strategies
    }

    # First, try searching for the exact Id: <PackageId> inside files (more reliable for manifests)
    $q = [System.Uri]::EscapeDataString("Id: $PackageId")
    $searchUrl = "https://api.github.com/search/code?q=repo:microsoft/winget-pkgs+$q+in:file"

    try {
        $search = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $searchUrl -Headers $headers -ErrorAction Stop } -Attempts 3 -DelaySeconds 2
        if ($search -and $search.items -and $search.total_count -ge 1) {
            # Prefer the first matching file
            $fileApiUrl = $search.items[0].url
            $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $fileApiUrl -Headers $headers -ErrorAction Stop } -Attempts 3 -DelaySeconds 2
            if ($fileObj -and $fileObj.content) {
                $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                $regexes = @( '^[ \t]*Version:[ \t]*(.+)$', '^[ \t]*PackageVersion:[ \t]*(.+)$', '^[ \t]*packageVersion:[ \t]*(.+)$' )
                foreach ($r in $regexes) {
                    $m = [regex]::Match($content, $r, [System.Text.RegularExpressions.RegexOptions]::Multiline)
                    if ($m.Success) { return $m.Groups[1].Value.Trim() }
                }
            }
        }

        # Fallback: search by path/name (older approach) if the above didn't yield results
        $q2 = [System.Uri]::EscapeDataString($PackageId)
        $searchUrl2 = "https://api.github.com/search/code?q=repo:microsoft/winget-pkgs+$q2+in:path"
        $search2 = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $searchUrl2 -Headers $headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 2
        if ($search2 -and $search2.items -and $search2.total_count -ge 1) {
            $fileApiUrl = $search2.items[0].url
            $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $fileApiUrl -Headers $headers -ErrorAction Stop } -Attempts 2 -DelaySeconds 2
            if ($fileObj -and $fileObj.content) {
                $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))
                $regexes = @( '^[ \t]*Version:[ \t]*(.+)$', '^[ \t]*PackageVersion:[ \t]*(.+)$', '^[ \t]*packageVersion:[ \t]*(.+)$' )
                foreach ($r in $regexes) {
                    $m = [regex]::Match($content, $r, [System.Text.RegularExpressions.RegexOptions]::Multiline)
                    if ($m.Success) { return $m.Groups[1].Value.Trim() }
                }
            }
        }

        return $null
    } catch {
        Write-Host ("⚠ Repo lookup failed for {0}: {1}" -f $PackageId, $_.Exception.Message) -ForegroundColor Yellow
        return $null
    }
}

# Load packages list
$packages = Get-Content $PackagesFile -Raw | ConvertFrom-Json

$updatesFound = $false
$branchName = ""

foreach ($pkg in $packages.packages) {

    Write-Host "`n➡ Checking package: $($pkg.id)"

    $latestVersion = $null

    if ($UseWingetRepo) {
        $latestVersion = Get-LatestVersionFromRepo -PackageId $pkg.id
        if ($latestVersion) {
            Write-Host "ℹ Using winget-pkgs repo version: $latestVersion"
        } else {
            Write-Host "ℹ Repo lookup returned nothing for $($pkg.id), falling back to winget" -ForegroundColor Yellow
        }
    }

    if (-not $latestVersion) {
        if ($UseWingetRepo) {
            Write-Host "⚠ No manifest found in winget-pkgs for $($pkg.id) and winget fallback disabled by -UseWingetRepo; skipping."
            continue
        }

        # Query latest version in Winget using JSON output (more robust than parsing localized text)
        # Use 2 attempts with reasonable delays for transient network issues
        $showJson = Invoke-WithRetry -Script { & winget show --id $($pkg.id) --exact --source winget --accept-source-agreements --accept-package-agreements --output json 2>$null } -Attempts 2 -DelaySeconds 2
        if (-not $showJson) {
            Write-Warning "⚠ winget show failed for: $($pkg.id) after retries"
            continue
        }

        try {
            $showObj = $showJson | ConvertFrom-Json
        } catch {
            Write-Warning "⚠ Failed to parse winget JSON for: $($pkg.id)"
            continue
        }

        # versions can be an array of objects with a 'version' property — pick the latest by semantic string
        $latestObj = $showObj.versions | Sort-Object -Property version -Descending | Select-Object -First 1
        if (-not $latestObj) {
            Write-Warning "⚠ No versions returned for: $($pkg.id)"
            continue
        }

        $latestVersion = $latestObj.version.ToString().Trim()
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
    $timestamp = (Get-Date).ToString("yyyyMMdd-HHmm")
    $branchName = "$UpdateBranchPrefix-$timestamp"

    Write-Host "🟢 Updates detected → new branch: $branchName"
    $packages | ConvertTo-Json -Depth 10 | Set-Content $PackagesFile -Encoding UTF8
    $branchName | Out-File update-branch.txt -Force -Encoding UTF8
}
else {
    Write-Host "🟡 No updates found"
}

exit 0