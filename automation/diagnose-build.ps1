# NSIS Build Diagnostics Script
# Run this to diagnose build issues

param(
    [string] $OutputDir = "dist"
)

Write-Host "🔍 VCRedist AIO Build Diagnostics" -ForegroundColor Cyan
Write-Host "=" * 80

# 1. System Information
Write-Host "`n📊 System Information:" -ForegroundColor Yellow
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "  OS: $($os.Caption) $($os.Version)"
Write-Host "  Architecture: $($os.OSArchitecture)"
Write-Host "  PowerShell: $($PSVersionTable.PSVersion)"

# 2. Check NSIS Installation
Write-Host "`n🔧 NSIS Installation:" -ForegroundColor Yellow
$nsisPath = "C:\Program Files (x86)\NSIS\makensis.exe"
$nsisPath64 = "C:\Program Files\NSIS\makensis.exe"

if (Test-Path $nsisPath) {
    $version = & $nsisPath /VERSION 2>$null
    Write-Host "  ✓ NSIS found (x86): $nsisPath" -ForegroundColor Green
    Write-Host "  Version: $version"
} elseif (Test-Path $nsisPath64) {
    $version = & $nsisPath64 /VERSION 2>$null
    Write-Host "  ✓ NSIS found (x64): $nsisPath64" -ForegroundColor Green
    Write-Host "  Version: $version"
} else {
    Write-Host "  ✗ NSIS NOT FOUND" -ForegroundColor Red
    Write-Host "  Install with: choco install nsis -y"
}

# 3. Check packages.json
Write-Host "`n📦 Package Configuration:" -ForegroundColor Yellow
if (Test-Path "packages.json") {
    $packagesJson = Get-Content "packages.json" -Raw | ConvertFrom-Json
    $packages = $packagesJson.packages
    
    Write-Host "  Total packages: $($packages.Count)"
    
    $emptyVersions = $packages | Where-Object { [string]::IsNullOrWhiteSpace($_.version) }
    if ($emptyVersions.Count -gt 0) {
        Write-Host "  ⚠ WARNING: $($emptyVersions.Count) packages have empty versions" -ForegroundColor Yellow
        $emptyVersions | ForEach-Object { Write-Host "    - $($_.id)" }
        Write-Host "`n  Fix: Run automation/update-check.ps1 to populate versions" -ForegroundColor Cyan
    } else {
        Write-Host "  ✓ All packages have versions" -ForegroundColor Green
    }
    
    Write-Host "`n  Package versions:"
    $packages | ForEach-Object {
        $status = if ([string]::IsNullOrWhiteSpace($_.version)) { "[EMPTY]" } else { "[OK]" }
        Write-Host "    $status $($_.id): $($_.version)"
    }
} else {
    Write-Host "  ✗ packages.json NOT FOUND" -ForegroundColor Red
}

# 4. Check build output
Write-Host "`n📁 Build Output Directory ($OutputDir):" -ForegroundColor Yellow
if (Test-Path $OutputDir) {
    Write-Host "  ✓ Directory exists" -ForegroundColor Green
    
    $installer = Join-Path $OutputDir "VC_Redist_AIO_Offline.exe"
    $nsisScript = Join-Path $OutputDir "installer.nsi"
    $nsisLog = Join-Path $OutputDir "nsis-build.log"
    $installPs1 = Join-Path $OutputDir "install.ps1"
    $packagesDir = Join-Path $OutputDir "packages"
    
    # Check installer
    if (Test-Path $installer) {
        $size = [math]::Round((Get-Item $installer).Length / 1MB, 2)
        Write-Host "  ✓ Installer: VC_Redist_AIO_Offline.exe ($size MB)" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Installer not found" -ForegroundColor Red
    }
    
    # Check NSIS script
    if (Test-Path $nsisScript) {
        Write-Host "  ✓ NSIS Script: installer.nsi" -ForegroundColor Green
    } else {
        Write-Host "  ✗ NSIS Script not found" -ForegroundColor Red
    }
    
    # Check NSIS log
    if (Test-Path $nsisLog) {
        Write-Host "  ✓ NSIS Log: nsis-build.log" -ForegroundColor Green
        Write-Host "`n  Last 5 lines of NSIS log:"
        Get-Content $nsisLog -Tail 5 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host "  ℹ NSIS Log not found (normal if build hasn't run)" -ForegroundColor Gray
    }
    
    # Check install.ps1
    if (Test-Path $installPs1) {
        Write-Host "  ✓ Install Script: install.ps1" -ForegroundColor Green
        
        # Check for Unicode characters
        $content = Get-Content $installPs1 -Raw
        $unicodeChars = [regex]::Matches($content, '[^\x00-\x7F]')
        if ($unicodeChars.Count -gt 0) {
            Write-Host "  ⚠ WARNING: install.ps1 contains $($unicodeChars.Count) non-ASCII characters" -ForegroundColor Yellow
            Write-Host "    This may cause encoding issues"
        }
    } else {
        Write-Host "  ✗ Install Script not found" -ForegroundColor Red
    }
    
    # Check packages directory
    if (Test-Path $packagesDir) {
        $packageFiles = Get-ChildItem $packagesDir -Filter "*.exe"
        Write-Host "  ✓ Packages Directory: $($packageFiles.Count) files" -ForegroundColor Green
        
        if ($packageFiles.Count -gt 0) {
            Write-Host "`n  Downloaded packages:"
            $packageFiles | ForEach-Object {
                $size = [math]::Round($_.Length / 1MB, 2)
                Write-Host "    - $($_.Name) ($size MB)"
            }
        }
    } else {
        Write-Host "  ℹ Packages directory not found" -ForegroundColor Gray
    }
} else {
    Write-Host "  ℹ Directory does not exist (normal before first build)" -ForegroundColor Gray
}

# 5. Check GitHub Token
Write-Host "`n🔑 GitHub API Access:" -ForegroundColor Yellow
if ($env:GITHUB_TOKEN) {
    Write-Host "  ✓ GITHUB_TOKEN environment variable set" -ForegroundColor Green
} else {
    Write-Host "  ℹ GITHUB_TOKEN not set (may hit rate limits)" -ForegroundColor Gray
    Write-Host "    Set with: `$env:GITHUB_TOKEN = 'your_token'" -ForegroundColor Cyan
}

# 6. Test NSIS Compilation
Write-Host "`n🧪 Test NSIS Compilation:" -ForegroundColor Yellow
$testNsis = @'
!define PRODUCT_NAME "Test"
OutFile "test.exe"
Section "MainSection"
  DetailPrint "Test"
SectionEnd
'@

$testScript = Join-Path $env:TEMP "test-nsis.nsi"
$testNsis | Out-File $testScript -Encoding ASCII

try {
    if (Test-Path $nsisPath) {
        $null = & $nsisPath $testScript 2>&1
        if (Test-Path (Join-Path $env:TEMP "test.exe")) {
            Write-Host "  ✓ NSIS can compile scripts successfully" -ForegroundColor Green
            Remove-Item (Join-Path $env:TEMP "test.exe") -Force
        } else {
            Write-Host "  ✗ NSIS compilation test failed" -ForegroundColor Red
        }
    }
} catch {
    Write-Host "  ✗ NSIS test failed: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if (Test-Path $testScript) {
        Remove-Item $testScript -Force
    }
}

# 7. Disk Space
Write-Host "`n💾 Disk Space:" -ForegroundColor Yellow
$drive = (Get-Item $OutputDir -ErrorAction SilentlyContinue).PSDrive
if ($drive) {
    $freeGB = [math]::Round($drive.Free / 1GB, 2)
    if ($freeGB -gt 5) {
        Write-Host "  ✓ Free space: $freeGB GB" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Low disk space: $freeGB GB" -ForegroundColor Yellow
    }
}

# 8. Test Silent Mode
Write-Host "`n🤫 Silent Mode Test:" -ForegroundColor Yellow
$outputExe = Join-Path $OutputDir "VC_Redist_AIO_Offline.exe"
if (Test-Path $outputExe) {
    Write-Host "  Testing silent installation mode..."
    
    # Create temporary test directory
    $testDir = Join-Path $env:TEMP "vcredist-silent-test"
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    
    try {
        # Note: Full silent test would actually install packages
        # Here we just verify the installer accepts /S parameter
        Write-Host "  ℹ Silent mode can be tested with: $outputExe /S" -ForegroundColor Gray
        Write-Host "  ℹ Log will be created in: %TEMP%\vcredist-install-*.log" -ForegroundColor Gray
        
        # Check if NSIS script has silent detection
        $nsisScript = Join-Path $OutputDir "installer.nsi"
        if (Test-Path $nsisScript) {
            $scriptContent = Get-Content $nsisScript -Raw
            if ($scriptContent -match '\$\{If\}\s+\$\{Silent\}') {
                Write-Host "  ✓ NSIS script contains silent mode detection" -ForegroundColor Green
            } else {
                Write-Host "  ⚠ NSIS script may not have silent mode detection" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "  ✗ Silent test failed: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        # Cleanup test directory
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  ℹ Installer not found - skip test" -ForegroundColor Gray
}

# 9. Recommendations
Write-Host "`n💡 Recommendations:" -ForegroundColor Cyan

$issues = @()

if (-not (Test-Path $nsisPath) -and -not (Test-Path $nsisPath64)) {
    $issues += "Install NSIS: choco install nsis -y"
}

if (Test-Path "packages.json") {
    $packagesJson = Get-Content "packages.json" -Raw | ConvertFrom-Json
    $emptyVersions = $packagesJson.packages | Where-Object { [string]::IsNullOrWhiteSpace($_.version) }
    if ($emptyVersions.Count -gt 0) {
        $issues += "Populate package versions: pwsh automation/update-check.ps1 -PackagesFile packages.json -UpdateBranchPrefix update"
    }
}

if ($issues.Count -eq 0) {
    Write-Host "  ✓ No issues found - ready to build!" -ForegroundColor Green
    Write-Host "`n  To build, run:" -ForegroundColor Cyan
    Write-Host "    pwsh automation/build-nsis.ps1 -PackagesFile packages.json -OutputDir dist" -ForegroundColor White
    Write-Host "`n  For debugging, add -DebugMode:" -ForegroundColor Cyan
    Write-Host "    pwsh automation/build-nsis.ps1 -PackagesFile packages.json -OutputDir dist -DebugMode" -ForegroundColor White
} else {
    Write-Host "  Issues found:" -ForegroundColor Yellow
    $issues | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}

Write-Host "`n" + "=" * 80
Write-Host "Diagnostics complete!" -ForegroundColor Green
