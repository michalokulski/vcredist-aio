# VC Redist AIO — Winget-based Offline Installer

![Latest Release](https://img.shields.io/github/v/release/michalokulski/vcredist-aio)
![Build Status](https://github.com/michalokulski/vcredist-aio/actions/workflows/build-release.yml/badge.svg)
![License](https://img.shields.io/github/license/michalokulski/vcredist-aio)

**VC Redist AIO** is a modern, automated project that downloads official Microsoft Visual C++ Redistributable installers via **Winget**, bundles them into a single offline installer, and produces both an **NSIS installer** and **ZIP package**. This project is inspired by [abbodi1406's VC++ AIO](https://github.com/abbodi1406/vcredist) and focuses on a **Winget-based approach** with full automation, transparency, and modern tooling optimized for **Windows 10/11**.

> **Acknowledgment**: Special thanks to [abbodi1406](https://github.com/abbodi1406) for the original VC++ Redistributables AIO project, which inspired this modern, automated alternative.

---

## Project Focus

This project takes a **different approach** from traditional repacks:

- 🎯 **Modern Windows Focus**: Optimized for Windows 10/11 environments
- 🤖 **Fully Automated**: GitHub Actions handle updates and builds
- 📦 **Winget-based**: Uses official Microsoft package manifests
- 🔍 **Transparent & Auditable**: All sources verifiable via Winget
- 🔄 **Self-updating**: Automatic version checks and releases
- 🛠️ **Developer-friendly**: Modular PowerShell scripts, not pre-compiled bundles
- 🛡️ **No AV False Positives**: Uses industry-standard NSIS installer

**Note**: This project covers **modern runtimes** (VC++ 2005-2022, VSTOR) and does **not** include legacy components (VC++ 2002/2003, VB runtimes) that are rarely needed on modern systems.

---

## Key Features

- **Automated Downloads**: Downloads official Microsoft VC++ Redistributables using Winget manifests
- **Offline Bundle**: Packages all installers into both NSIS EXE and ZIP formats
- **NSIS Installer**: Professional installer using the same technology as Firefox, VLC, and 7-Zip
- **Advanced Parameters**: Extract-only mode, package filtering, custom logging, validation controls
- **Uninstaller Integration**: Registers in Windows Apps & Features with full uninstaller support
- **Comprehensive Uninstaller**: Dedicated script to remove all VC++ redistributables safely
- **Comprehensive Logging**: Timestamped installation logs with detailed exit code interpretation
- **Pre-Installation Validation**: Admin privilege checks, disk space verification, package integrity validation
- **Silent Installation**: Supports silent/unattended modes with proper exit code handling
- **GitHub Actions**: Automated Winget update checks and release builds
- **Modular Architecture**: Separate installation/uninstallation engines for testing and maintenance

---

## Download Options

Each release includes two formats:

1. **VC_Redist_AIO_Offline.exe** (Recommended)
   - NSIS-based installer
   - One-click installation
   - Professional installer UI
   - Trusted by Windows Defender

2. **vc_redist_aio_offline.zip**
   - PowerShell script + packages
   - Maximum control and transparency
   - Perfect for automation/deployment
   - Extract and run `install.ps1`

---

## Installation Instructions

### Option 1: NSIS Installer (Recommended)

1. Download `VC_Redist_AIO_Offline.exe` from the latest release
2. Run as Administrator
3. The installer will automatically extract and install all packages
4. Check log file in `%TEMP%`: `vcredist-install-YYYYMMDD-HHMMSS.log`

**Silent Installation:**
```cmd
VC_Redist_AIO_Offline.exe /S
```

**Advanced Command-Line Parameters:**

The NSIS installer supports several advanced parameters for automation and customization:

```cmd
# Extract files only (no installation)
VC_Redist_AIO_Offline.exe /EXTRACT="C:\ExtractPath"

# Install specific packages only (comma-separated)
VC_Redist_AIO_Offline.exe /PACKAGES="2022,2019"

# Custom log directory (preferred)
VC_Redist_AIO_Offline.exe /LOGDIR="C:\Logs"

# Legacy alias (treated as directory):
VC_Redist_AIO_Offline.exe /LOGFILE="C:\Logs"

# Skip pre-installation validation (admin/disk checks)
VC_Redist_AIO_Offline.exe /SKIPVALIDATION

# Prevent reboot flag even if exit code is 3010
VC_Redist_AIO_Offline.exe /NOREBOOT

# Combine parameters
VC_Redist_AIO_Offline.exe /S /PACKAGES="2019,2022" /LOGFILE="C:\Logs\install.log"
```

**Parameter Details:**
- `/S` - Silent mode (no UI)
- `/EXTRACT="path"` - Extract files to specified directory without installing
- `/PACKAGES="list"` - Install only specified package years (comma-separated: 2005,2008,2010,2012,2013,2015,2017,2019,2022). Note: 2015-2022 all use the unified "2015Plus" runtime, so filtering by 2015, 2017, 2019, or 2022 will install the same 2015+ packages.
- `/LOGDIR="path"` - Save installation logs to a custom directory (default: `%TEMP%`)
- `/LOGFILE="path"` - Legacy alias for log directory (treated as directory)
- `/SKIPVALIDATION` - Skip pre-installation validation (admin and disk space checks)
- `/NOREBOOT` - Don't set reboot flag even if installer returns exit code 3010

### Option 2: PowerShell Script (Advanced)

1. Download and extract `vc_redist_aio_offline.zip`
2. Right-click `install.ps1` → Run with PowerShell (as Administrator)
3. Optional command-line flags:

```powershell
# Silent installation (no console output)
.\install.ps1 -Silent

# Filter packages by year (e.g., only 2022 runtime)
.\install.ps1 -PackageFilter "2022"

# Filter multiple years
.\install.ps1 -PackageFilter "2019","2022"

# Skip pre-installation validation (not recommended)
.\install.ps1 -SkipValidation

# Both flags
.\install.ps1 -Silent -SkipValidation
```

**Silent Installation:**
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Silent
```

### Option 3: Uninstaller (Removal)

The project includes a comprehensive uninstaller script that can remove all installed Visual C++ Redistributables.

#### Uninstalling via NSIS (Windows Apps)

If you installed using the NSIS installer:

1. Open **Settings** → **Apps** → **Installed apps** (or **Control Panel** → **Programs and Features**)
2. Search for "VCRedist AIO"
3. Click **Uninstall**

Or use command line:
```cmd
# Silent uninstall via NSIS
"C:\Program Files\VCRedist_AIO\uninstall.exe" /S
```

#### Uninstalling via PowerShell Script

**Important**: When running non-interactively (from scripts, NSIS, scheduled tasks), you **must** use the `-Force` parameter.

```powershell
# Interactive mode
.\automation\uninstall.ps1

# Non-interactive mode (REQUIRED for scripts/automation)
.\automation\uninstall.ps1 -Force

# Silent mode (no console output, logs only)
.\automation\uninstall.ps1 -Force -Silent

# WhatIf mode (preview without making changes)
.\automation\uninstall.ps1 -WhatIf

# Custom log directory
.\automation\uninstall.ps1 -Force -Silent -LogDir "C:\Logs"

# Combine parameters
.\automation\uninstall.ps1 -Force -LogDir "C:\CustomPath\Logs"
```

**Parameters:**
- `-Force` - **Required for non-interactive execution** (scripts, NSIS, automation). Skips interactive confirmation prompt.
- `-Silent` - Suppress console output (logs still written to file)
- `-WhatIf` - Preview what would be removed without making changes
- `-LogDir` - Custom directory for log files (default: script directory)

**Execution Contexts:**
- **Interactive Console**: Can run with or without `-Force` (will prompt for confirmation)
- **NSIS Uninstaller**: **Must** use `-Force` (no interactive prompt possible)
- **Scripts/Automation**: **Must** use `-Force` (non-interactive by default)
- **Scheduled Tasks**: **Must** use `-Force` (no user session)

**Logging:**
- Log files are automatically created with timestamp: `vcredist-uninstall-YYYYMMDD-HHMMSS.log`
- Example: `vcredist-uninstall-20251117-133129.log`
- If `-LogDir` not specified, logs are saved to script directory
- If script directory is unavailable, falls back to `%TEMP%`
- Creates log directory automatically if it doesn't exist

**Safety Features:**
 - No confirmation prompt; use `-WhatIf` to preview actions
 - Detects architecture (x86/x64) from display names
- Deduplicates registry entries (x86 packages appear in both registry hives on 64-bit systems)
- Handles both MSI and EXE-based uninstallers
- Comprehensive logging with exit code interpretation
- `-WhatIf` mode for preview without changes

**Note:** If you installed using the NSIS installer, the uninstaller is also registered in Windows Apps & Features ("Add or Remove Programs").

---

## Repo Layout

```
├── automation/
│   ├── install.ps1         # Standalone installation engine with logging & validation
│   ├── uninstall.ps1       # Comprehensive uninstaller for all VC++ redistributables
│   ├── update-check.ps1    # Checks Winget for newer package versions
│   ├── build-nsis.ps1      # NSIS installer builder
│   └── diagnose-build.ps1  # Build diagnostics and testing
├── .github/workflows/
│   ├── check-updates.yml   # Scheduled Winget update checks
│   └── build-release.yml   # Builds NSIS installer and publishes releases
├── packages.json           # List of Winget package IDs and versions
├── README.md
└── DEBUG-NSIS.md           # NSIS troubleshooting guide
```

---

## Developer / Maintainer Guide

### Requirements
- Windows 10/11 (or runner `windows-latest` on GitHub Actions)
- PowerShell 7.2+
- NSIS 3.x (`choco install nsis -y`)
- `winget` (Windows package manager)

### Local Build Steps

1. **Clone the repository:**
   ```powershell
   git clone https://github.com/michalokulski/vcredist-aio.git
   cd vcredist-aio
   ```

2. **Install NSIS** (one-time):
   ```powershell
   choco install nsis -y
   ```

3. **Run the NSIS build script**:
   ```powershell
   pwsh automation/build-nsis.ps1 `
     -PackagesFile packages.json `
     -OutputDir dist
   ```

#### Build Output

The `dist/` directory will contain:
- `VC_Redist_AIO_Offline.exe` - NSIS installer
- `packages/` - Downloaded redistributables
- `SHA256.txt` - Checksum for verification
- `install.ps1` - Standalone PowerShell script

Test the installer on a clean VM before deployment.

---

## Automation (GitHub Actions)

- **`check-updates.yml`**: Runs on schedule, checks Winget for package updates, updates `packages.json`, and creates update branches
- **`build-release.yml`**: Builds the NSIS installer and ZIP package, publishes a GitHub Release when an `update/*` branch is pushed or on manual dispatch

---

## Installation Engine Architecture

The project uses a modular architecture:

- **`automation/install.ps1`**: Standalone installation engine that can be tested independently
  - Logging infrastructure with color-coded output
  - Pre-installation validation (admin, disk space)
  - Package discovery and integrity checks
  - Exit code interpretation and error handling
  - Installation statistics and summary
  - Supports package filtering and custom log locations

- **`automation/uninstall.ps1`**: Comprehensive uninstaller for all VC++ redistributables
  - Registry scanning for installed packages
  - Architecture detection from display names
  - Handles both MSI and EXE-based uninstallers
  - Safety confirmation (requires typing "UNINSTALL")
  - WhatIf mode for preview
  - Detailed logging with exit code interpretation

- **`automation/build-nsis.ps1`**: NSIS installer build orchestration
  - Downloads packages from Winget manifests
  - Creates NSIS installer script with parameter parsing
  - Compiles to professional EXE
  - Generates checksums
  - Embeds both install.ps1 and uninstall.ps1
  - Registers uninstaller in Windows Apps & Features

This separation allows for:
- Independent testing of installation/uninstallation logic
- Easier debugging and maintenance
- Full audit trail via log files
- Flexible deployment options (NSIS EXE, PowerShell script, or manual uninstall)
- Advanced automation with command-line parameters

---

## Security & Compliance

⚠️ **Important Notes:**

- This project bundles **official Microsoft installers** downloaded via Winget
- Verify organizational policies before redistributing
- Consider **code-signing** the NSIS installer for maximum trust
- **SHA256 checksums** are published with each release
- All downloads are from official Microsoft URLs extracted from Winget manifests
- NSIS installers can be inspected with NSIS decompilers for transparency

---

## Troubleshooting

### Installation Issues

1. **Check the log file**: `vcredist-install-YYYYMMDD-HHMMSS.log` (in `%TEMP%` or custom location if `/LOGFILE` was used)
2. **Verify admin privileges**: Right-click → "Run as Administrator"
3. **Check disk space**: Minimum 500MB required
4. **Review exit codes**:
   - `0` = Success
   - `3010` = Success (reboot required)
   - `1638` = Already installed (newer/same version)
   - `5100` = System requirements not met
5. **Extract and inspect**: Use `/EXTRACT="C:\Temp"` to extract files without installing
6. **Test specific packages**: Use `/PACKAGES="2022"` to test installation of a single package version
7. **Skip validation**: Use `/SKIPVALIDATION` to bypass admin/disk checks for quick tests (not recommended)

### Build Issues

1. **Ensure NSIS is installed**: `choco install nsis -y`
2. **Check GitHub token** for API rate limiting (set `GITHUB_TOKEN` environment variable)
3. **Verify package versions** in `packages.json` are available in Winget

---

## License

This project is provided as-is for educational and automation purposes. Microsoft Visual C++ Redistributables are subject to Microsoft's licensing terms.

---

## Roadmap / TODO

- Smarter installation (skip already-installed components)
   - Detect installed VC++ redistributables via registry (HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall and Wow6432Node).
   - Match by product/year/architecture (or known product/upgrade codes) and skip execution when present.
   - Log clear reason per package: "Already installed (skipped)" with detected version.
   - Add `-ForceReinstall` switch to override and always run installers.
   - Keep behavior consistent in NSIS and PowerShell flows.

Contributions welcome; see Developer Guide for local testing.

---

## Credits & Inspiration

- **[abbodi1406](https://github.com/abbodi1406)** - Original creator of [VC++ Redistributables AIO](https://github.com/abbodi1406/vcredist), which inspired this project
- **Microsoft** - For providing Visual C++ Redistributables and the Winget package manager
- **NSIS** - For the excellent open-source installer framework
- **Community** - For feedback and contributions

This project represents a **modern, automated alternative** that complements abbodi1406's excellent work by focusing on transparency, automation, and integration with Windows 10/11 ecosystems using industry-standard tooling.