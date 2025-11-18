# NSIS Installer Debugging Guide

## Log Files

### Installation Logs

**Location:** `%TEMP%\vcredist-install-YYYYMMDD-HHMMSS.log` (or custom path via `/LOGFILE`)

```powershell
# View latest installation log
$latestLog = Get-ChildItem $env:TEMP -Filter "vcredist-install-*.log" | 
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content $latestLog.FullName
```

### Uninstallation Logs

**Location:** Script directory or custom path via `-LogDir` parameter

**File naming:** `vcredist-uninstall-YYYYMMDD-HHMMSS.log`

```powershell
# Run uninstaller with custom log directory
.\automation\uninstall.ps1 -Force -Silent -LogDir "C:\Logs"

# View latest uninstall log from custom directory
$latestLog = Get-ChildItem "C:\Logs" -Filter "vcredist-uninstall-*.log" | 
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content $latestLog.FullName

# View latest uninstall log from script directory (default)
$latestLog = Get-ChildItem ".\automation" -Filter "vcredist-uninstall-*.log" | 
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content $latestLog.FullName
```

**Log fallback behavior:**
1. First tries: Custom `-LogDir` path (if specified)
2. Then tries: Script directory (`$PSScriptRoot`)
3. Finally: `%TEMP%` directory (if directory creation fails)

---

## Quick Diagnosis

### 1. Check Build Logs

After running `build-nsis.ps1`, check these files in the `dist/` directory:

```powershell
# View NSIS compilation log
Get-Content dist/nsis-build.log

# View NSIS script that was generated
Get-Content dist/installer.nsi
```

### 2. Common NSIS Errors

#### Error: "Can't open script file"
**Cause:** NSIS script path has issues  
**Solution:**
```powershell
# Check if script exists
Test-Path dist/installer.nsi

# Check for special characters in path
Get-Content dist/installer.nsi -Encoding ASCII
```

#### Error: "File: ... does not exist"
**Cause:** Package files referenced in NSIS script are missing  
**Solution:**
```powershell
# Verify all packages exist
Get-ChildItem dist/packages/*.exe

# Check NSIS script for file references
Select-String 'File "packages\\' dist/installer.nsi
```

#### Error: "Invalid command SetCompressor"
**Cause:** NSIS version too old  
**Solution:**
```powershell
# Check NSIS version
& "C:\Program Files (x86)\NSIS\makensis.exe" /VERSION

# Should be 3.0 or higher
# Reinstall if needed:
choco upgrade nsis -y
```

### 3. Manual NSIS Compilation Test

```powershell
# Navigate to dist directory
cd dist

# Run NSIS manually with maximum verbosity
& "C:\Program Files (x86)\NSIS\makensis.exe" /V4 installer.nsi

# Check output for errors
```

### 4. Test Generated NSIS Script Syntax

```powershell
# Create minimal test script
$testScript = @'
!define PRODUCT_NAME "Test"
OutFile "test.exe"
Section "MainSection"
  DetailPrint "Test"
SectionEnd
'@

$testScript | Out-File test.nsi -Encoding ASCII

# Try compiling it
& "C:\Program Files (x86)\NSIS\makensis.exe" /V4 test.nsi

# If this works, issue is in your installer.nsi
```

## Advanced Debugging

### 5. Enable NSIS Debug Mode in Generated Script

Edit `automation/build-nsis.ps1` and add to NSIS script:

```powershell
# Add at the beginning of $nsisContent
!verbose 4
!echo "Debug: Starting NSIS compilation"
```

### 6. Test Installer Execution

```powershell
# Run installer in silent mode with logging
dist/VC_Redist_AIO_Offline.exe /S /D=C:\temp\vcredist_test

# Check Windows Event Viewer
Get-EventLog -LogName Application -Source "Application" -Newest 10

# Check temp directory
Get-ChildItem $env:TEMP -Filter "vcredist*"
```

### 7. Extract Files Without Installation

```powershell
# Use 7-Zip to extract NSIS installer
& "C:\Program Files\7-Zip\7z.exe" x dist/VC_Redist_AIO_Offline.exe -odist/extracted

# Inspect extracted files
Get-ChildItem dist/extracted -Recurse
```

### 8. Check PowerShell Script Execution

```powershell
# Test install.ps1 separately
powershell.exe -ExecutionPolicy Bypass -NoProfile -File dist/install.ps1 -PackageDir dist/packages -LogDir dist

# Check log output
Get-Content dist/vcredist-install-*.log -Tail 50
```

## Common Issues and Solutions

### Issue: "ps1 file not found" during NSIS execution

**Diagnosis:**
```powershell
# Check if install.ps1 is in the right place
Get-ChildItem dist/install.ps1
```

**Solution:** Ensure `automation/build-nsis.ps1` copies install.ps1:
```powershell
Copy-Item -Path $installScriptPath -Destination $OutputDir -Force
```

### Issue: Packages not extracted

**Diagnosis:**
```powershell
# Check NSIS script section
Select-String 'File "packages\\' dist/installer.nsi | Measure-Object

# Should match number of packages
(Get-ChildItem dist/packages/*.exe).Count
```

**Solution:** Verify package list generation in build script

### Issue: PowerShell execution policy blocks script

**Diagnosis:**
```powershell
# Check current policy
Get-ExecutionPolicy -Scope LocalMachine
Get-ExecutionPolicy -Scope CurrentUser
```

**Solution:** NSIS script already uses `-ExecutionPolicy Bypass`

### Issue: Installer fails silently

**Diagnosis:**
```powershell
# Run with visible console and detail
& dist/VC_Redist_AIO_Offline.exe

# Or extract and run manually
Expand-Archive dist/VC_Redist_AIO_Offline.exe -DestinationPath temp
powershell -File temp/install.ps1 -PackageDir temp/packages
```

## Build Script Debug Mode

### Enable verbose output in build-nsis.ps1

Add at the beginning:
```powershell
$VerbosePreference = 'Continue'
$DebugPreference = 'Continue'
```

### Disable cleanup to inspect files

Comment out cleanup section:
```powershell
# if (Test-Path $downloadDir) {
#     Remove-Item -Path $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
# }
```

## Silent Mode Testing

### Test Silent Installation

```powershell
# Test NSIS silent mode
dist/VC_Redist_AIO_Offline.exe /S

# Check exit code
$exitCode = $LASTEXITCODE
Write-Host "Exit code: $exitCode"

# Check log file
$logFile = Get-ChildItem $env:TEMP -Filter "vcredist-install-*.log" | 
    Sort-Object LastWriteTime -Descending | 
    Select-Object -First 1

if ($logFile) {
    Write-Host "Log file: $($logFile.FullName)"
    Get-Content $logFile.FullName -Tail 20
}
```

### Verify Silent Mode Behavior

```powershell
# Test that no console windows appear
Start-Process -FilePath "dist/VC_Redist_AIO_Offline.exe" -ArgumentList "/S" -Wait

# Should complete without any visible windows
```

### Silent Mode Troubleshooting

If silent installation fails:

1. **Check log file**: Silent mode still creates logs in `%TEMP%`
   ```powershell
   Get-ChildItem $env:TEMP -Filter "vcredist-install-*.log" | 
       Sort-Object LastWriteTime -Descending | 
       Select-Object -First 1 | 
       Get-Content -Tail 50
   ```

2. **Test PowerShell script separately**:
   ```powershell
   powershell -ExecutionPolicy Bypass -File dist/install.ps1 -Silent
   ```

3. **Verify NSIS silent detection**:
   - Check `dist/installer.nsi` for `\${If} \${Silent}` block
   - Ensure `-Silent` flag is passed to PowerShell

## Testing Workflow

### 1. Test Individual Components

```powershell
# Test package download
pwsh automation/build-nsis.ps1 -PackagesFile packages.json -OutputDir test-dist
# Stop after download, inspect test-dist/packages/

# Test NSIS script generation
# Check test-dist/installer.nsi manually

# Test NSIS compilation
& "C:\Program Files (x86)\NSIS\makensis.exe" /V4 test-dist/installer.nsi

# Test installer execution
test-dist/VC_Redist_AIO_Offline.exe
```

### 2. Clean Build Test

```powershell
# Remove all previous builds
Remove-Item dist -Recurse -Force -ErrorAction SilentlyContinue

# Fresh build
pwsh automation/build-nsis.ps1 -PackagesFile packages.json -OutputDir dist

# Check all outputs
Get-ChildItem dist -Recurse
```

### 3. Validate Generated Files

```powershell
# Check file sizes
Get-ChildItem dist/packages/*.exe | 
    Select-Object Name, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,2)}} |
    Format-Table -AutoSize

# Verify checksums
$files = Get-ChildItem dist/packages/*.exe
foreach ($file in $files) {
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash
    Write-Host "$($file.Name): $hash"
}
```

## GitHub Actions Debugging

### View detailed logs

1. Go to GitHub Actions → Failed workflow
2. Expand each step to see output
3. Look for NSIS compilation step

### Add debug output to workflow

```yml
- name: Debug - List files before NSIS
  run: |
    Get-ChildItem dist -Recurse | Format-Table Name, Length
    Get-Content dist/installer.nsi -Head 50

- name: Build NSIS installer
  run: |
    pwsh -File automation/build-nsis.ps1 `
      -PackagesFile packages.json `
      -OutputDir dist
    
- name: Debug - Show NSIS log
  if: always()
  run: |
    if (Test-Path dist/nsis-build.log) {
      Get-Content dist/nsis-build.log
    }
```

## Useful Commands Reference

```powershell
# Check NSIS installation
Get-Command makensis.exe -ErrorAction SilentlyContinue
& "C:\Program Files (x86)\NSIS\makensis.exe" /VERSION

# Validate NSIS script syntax
& makensis.exe /PPO installer.nsi > preprocessed.nsi

# Test PowerShell script encoding
Get-Content automation/install.ps1 | 
    Where-Object { $_ -match '[^\x00-\x7F]' }  # Find non-ASCII chars

# Monitor installer execution
Get-Process | Where-Object { $_.Name -like '*vcredist*' -or $_.Name -like '*nsis*' }

# Check Windows Installer service
Get-Service msiserver

# Test package filtering
.\automation\install.ps1 -PackageFilter "2022" -WhatIf

# Test uninstaller duplicate detection
.\automation\uninstall.ps1 -WhatIf  # Should show unique count
```

## Troubleshooting Runtime Issues

### Duplicate Package Detection (Uninstaller)

**Symptom:** Uninstaller shows more packages than expected (e.g., 18 instead of 13)

**Cause:** x86 packages appear in both `HKLM:\Software\Uninstall` and `HKLM:\Software\WOW6432Node\Uninstall` on 64-bit systems due to registry redirection.

**Solution:** The uninstaller now automatically deduplicates based on `UninstallString`. Check logs for messages like:
```
Found 13 unique package(s) (18 registry entries, 5 duplicates removed)
```

### Package Filtering Not Working

**Symptom:** `/PACKAGES="2022"` parameter installs all 2015-2022 runtimes

**Explanation:** Microsoft Visual C++ 2015-2022 all use the **unified runtime** (labeled as "2015Plus" in filenames). Filtering by 2015, 2017, 2019, or 2022 will install the same x86 and x64 packages because they share the same redistributable.

**Workaround:** To install only newer runtimes, use `/PACKAGES="2015"` (which includes all 2015-2022).

## Contact & Support

If you're still stuck:

1. **Create an issue** with:
   - `dist/nsis-build.log` contents
   - `dist/installer.nsi` file
   - Error messages from console
   - Windows version and architecture

2. **Include diagnostic info**:
   ```powershell
   # Gather diagnostic information
   $diagnostics = @{
       OS = (Get-CimInstance Win32_OperatingSystem).Caption
       PSVersion = $PSVersionTable.PSVersion
       NSISVersion = & "C:\Program Files (x86)\NSIS\makensis.exe" /VERSION
       FilesInDist = Get-ChildItem dist -Recurse | Select-Object FullName, Length
   }
   $diagnostics | ConvertTo-Json -Depth 3 | Out-File diagnostics.json
   ```

## Quick Fix Checklist

- [ ] NSIS installed and version 3.0+
- [ ] All packages downloaded to `dist/packages/`
- [ ] `install.ps1` copied to `dist/`
- [ ] No special characters in file paths
- [ ] All Unicode symbols replaced with ASCII in scripts
- [ ] Enough disk space for build
- [ ] Running as Administrator
- [ ] Windows Defender not blocking NSIS
- [ ] `packages.json` has valid versions
- [ ] PowerShell execution policy allows scripts
