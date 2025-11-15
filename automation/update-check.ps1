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
            $code = $LASTEXITCODE

            if ($code -ne 0 -or -not $result) {
                throw "Command failed with exit code $code"
            }

            return $result
        } catch {
            if ($i -lt $Attempts) {
                $wait = [math]::Min(30, $DelaySeconds * [math]::Pow(2, $i - 1))
                # small jitter
                $wait = $wait + (Get-Random -Minimum 0 -Maximum 3)
                Write-Host ("Retry {0}/{1} failed: {2}. Waiting {3} seconds before retry..." -f $i, $Attempts, $_.Exception.Message, $wait)
                Start-Sleep -Seconds $wait
            }
            else {
                Write-Warning ("Operation failed after {0} attempts: {1}" -f $Attempts, $_.Exception.Message)
                return $null
            }
        }
    }
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

    $q = [System.Uri]::EscapeDataString($PackageId)
    $searchUrl = "https://api.github.com/search/code?q=repo:microsoft/winget-pkgs+$q+in:path"

    try {
        $search = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $searchUrl -Headers $headers -ErrorAction Stop } -Attempts 3 -DelaySeconds 2
        if (-not $search -or -not $search.items -or $search.total_count -lt 1) { return $null }

        $fileApiUrl = $search.items[0].url
        $fileObj = Invoke-WithRetry -Script { Invoke-RestMethod -Uri $fileApiUrl -Headers $headers -ErrorAction Stop } -Attempts 3 -DelaySeconds 2

        if (-not $fileObj.content) { return $null }

        $content = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($fileObj.content))

        $regexes = @(
            '^[ \t]*Version:[ \t]*(.+)$',
            '^[ \t]*PackageVersion:[ \t]*(.+)$',
            '^[ \t]*packageVersion:[ \t]*(.+)$'
        )

        foreach ($r in $regexes) {
            $m = [regex]::Match($content, $r, [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if ($m.Success) { return $m.Groups[1].Value.Trim() }
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
        # Query latest version in Winget using JSON output (more robust than parsing localized text)
        $showJson = Invoke-WithRetry -Script { & winget show --id $($pkg.id) --exact --source winget --accept-source-agreements --accept-package-agreements --output json 2>$null } -Attempts 4 -DelaySeconds 2
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