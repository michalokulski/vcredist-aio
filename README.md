# VC Redist AIO — Winget-based Offline Installer

![Latest Release](https://img.shields.io/github/v/release/michalokulski/vcredist-aio)
![Build Status](https://github.com/michalokulski/vcredist-aio/actions/workflows/build-release.yml/badge.svg)
![License](https://img.shields.io/github/license/michalokulski/vcredist-aio)

**VC Redist AIO** is an automated project that downloads official Microsoft Visual C++ Redistributable installers via **Winget**, bundles them into offline artifacts, and provides a standalone PowerShell installation engine plus a compiled EXE and ZIP package for distribution. The project focuses on automation, transparency, and modern tooling optimized for Windows 10/11.

> **Acknowledgment**: Special thanks to [abbodi1406](https://github.com/abbodi1406) for the original VC++ Redistributables AIO project, which inspired this effort.

---

## Project Focus

This project emphasizes:

- 🎯 **Modern Windows Focus**: Optimized for Windows 10/11 environments
- 🤖 **Fully Automated**: GitHub Actions handle updates and builds
- 📦 **Winget-based**: Uses official Microsoft package manifests
- 🔍 **Transparent & Auditable**: All sources verifiable via Winget
- 🔄 **Self-updating**: Automatic version checks and releases
- 🛠️ **Developer-friendly**: Modular PowerShell scripts and reproducible builds

**Note**: This project covers modern runtimes (VC++ 2005–2022, VSTOR) and does not include legacy components that are rarely needed on modern systems.

---

## Key Features

- **Automated Downloads**: Downloads official Microsoft VC++ Redistributables using Winget manifests
- **Offline Bundle**: Packages all installers into an EXE (compiled from PowerShell) and a ZIP archive
- **Standalone Installation Engine**: `automation/install.ps1` is usable alone for scripted deployments
- **Advanced Parameters**: Extract-only mode, package filtering, custom logging, validation controls
- **Uninstaller Integration**: Standalone uninstaller script available as `automation/uninstall.ps1`
- **Comprehensive Logging**: Timestamped installation logs with exit code interpretation
- **Pre-Installation Validation**: Admin privilege checks, disk space verification, package integrity validation
- **Silent Installation**: Supports silent/unattended modes with proper exit code handling
- **GitHub Actions**: Automated Winget update checks and release builds
- **Modular Architecture**: Separate installation/uninstallation engines for testing and maintenance

---

## Download Options

Each release includes two formats:

1. **VC_Redist_AIO_Offline.exe** (Recommended)
   - Compiled EXE installer (built from the project's PowerShell bootstrap)
   - One-click installation
   - Recommended for end users and automated deployments

2. **vc_redist_aio_offline.zip**
   - PowerShell script + packages
   - Maximum control and transparency for demonstrations or automation
   - Extract and run `install.ps1`

---

## Installation Instructions

### Option 1: EXE Installer (Recommended)

1. Download `VC_Redist_AIO_Offline.exe` from the latest release
2. Run as Administrator
3. The installer will automatically extract and install all packages
4. Check log file in `%TEMP%`: `vcredist-install-YYYYMMDD-HHMMSS.log`

**Silent Installation:**
```cmd
VC_Redist_AIO_Offline.exe /S
```

**Advanced Command-Line Parameters:**

```cmd
# Extract files only (no installation)
VC_Redist_AIO_Offline.exe /EXTRACT="C:\ExtractPath"

# Install specific packages only (comma-separated)
VC_Redist_AIO_Offline.exe /PACKAGES="2022,2019"

# Custom log directory (preferred)
VC_Redist_AIO_Offline.exe /LOGDIR="C:\Logs"

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
- `/PACKAGES="list"` - Install only specified package years (comma-separated: 2005,2008,2010,2012,2013,2015,2017,2019,2022). Note: 2015–2022 all use the unified "2015Plus" runtime, so filtering by 2015, 2017, 2019, or 2022 will install the same 2015+ packages.
- `/LOGDIR="path"` - Save installation logs to a custom directory (default: `%TEMP%`)
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

The project includes a comprehensive uninstaller script that can remove installed Visual C++ Redistributables.

#### Uninstalling via GUI (Installed App)

If you installed using the EXE installer, the uninstaller is registered in Windows Apps & Features. Use the Apps settings to remove it.

#### Uninstalling via PowerShell Script

**Important**: When running non-interactively (from scripts or scheduled tasks), use the `-Force` parameter.

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
- `-Force` - Required for non-interactive execution (scripts, automation). Skips interactive confirmation prompt.
- `-Silent` - Suppress console output (logs still written to file)
- `-WhatIf` - Preview what would be removed without making changes
- `-LogDir` - Custom directory for log files (default: script directory)

---

## Repo Layout

```
├── automation/
│   ├── install.ps1         # Standalone installation engine with logging & validation
│   ├── uninstall.ps1       # Comprehensive uninstaller for all VC++ redistributables
│   ├── update-check.ps1    # Checks Winget for newer package versions
│   ├── build-ps2exe.ps1    # EXE builder (compiles PowerShell bootstrap to single EXE)
│   └── diagnose-build.ps1  # Build diagnostics and testing
├── .github/workflows/
│   ├── check-updates.yml   # Scheduled Winget update checks
│   └── build-ps2exe.yml    # Builds EXE installer and publishes releases
├── packages.json           # List of Winget package IDs and versions
├── README.md
└── CHANGELOG.md            # (optional) Manual changelog or release notes
```

---

## Developer / Maintainer Guide

### Requirements
- Windows 10/11 (or runner `windows-latest` on GitHub Actions)
- PowerShell 7.2+
- `winget` (Windows package manager)

### Local Build Steps

1. **Clone the repository:**
   ```powershell
   git clone https://github.com/michalokulski/vcredist-aio.git
   cd vcredist-aio
   ```

2. **Run the EXE build script (PS2EXE)**:
   ```powershell
   pwsh automation/build-ps2exe.ps1 `
     -PackagesFile packages.json `
     -OutputDir dist
   ```

3. **Optional: Create ZIP package for distribution** (packaging is also performed by CI):
   ```powershell
   # create 'artifact/vc_redist_aio_offline.zip' containing install.ps1 + packages
   pwsh -Command "Compress-Archive -Path 'dist/packages/*','automation/install.ps1','automation/uninstall.ps1' -DestinationPath 'artifact/vc_redist_aio_offline.zip' -Force"
   ```

#### Build Output

The `dist/` directory will contain:
- `vcredist-aio.exe` - Compiled EXE installer (from PowerShell bootstrap)
- `packages/` - Downloaded redistributables
- `SHA256SUMS.txt` - Checksums for verification (artifact/)
- `install.ps1` - Standalone PowerShell script

Test the installer on a clean VM before deployment.

---

## Automation (GitHub Actions)

- **`check-updates.yml`**: Runs on schedule, checks Winget for package updates, updates `packages.json`, and creates update branches
- **`build-ps2exe.yml`**: Builds the EXE installer and ZIP package, publishes a GitHub Release when an update branch is pushed or on manual dispatch

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

- **`automation/uninstall.ps1`**: Comprehensive uninstaller for VC++ redistributables
  - Registry scanning for installed packages
  - Architecture detection from display names
  - Handles both MSI and EXE-based uninstallers
  - WhatIf mode for preview
  - Detailed logging with exit code interpretation

- **`automation/build-ps2exe.ps1`**: EXE build orchestration
  - Downloads packages from Winget manifests as needed
  - Creates a PowerShell bootstrap that embeds packages
  - Compiles to a single EXE
  - Generates checksums and release artifacts

This separation allows for:
- Independent testing of installation/uninstallation logic
- Easier debugging and maintenance
- Full audit trail via log files
- Flexible deployment options (EXE, PowerShell script, or manual uninstall)
- Advanced automation with command-line parameters

---

## Security & Compliance

⚠️ **Important Notes:**

- This project bundles **official Microsoft installers** downloaded via Winget
- Verify organizational policies before redistributing
- Consider **code-signing** the EXE installer for maximum trust
- **SHA256 checksums** are published with each release
- All downloads are from official Microsoft URLs extracted from Winget manifests

---

## Troubleshooting

### Installation Issues

1. **Check the log file**: `vcredist-install-YYYYMMDD-HHMMSS.log` (in `%TEMP%` or custom location if `/LOGDIR` was used)
2. **Verify admin privileges**: Right-click → "Run as Administrator"
3. **Check disk space**: Minimum ~500 MB required
4. **Review exit codes**:
   - `0` = Success
   - `3010` = Success (reboot required)
   - `1638` = Already installed (newer/same version)
   - `5100` = System requirements not met
5. **Extract and inspect**: Use `/EXTRACT="C:\Temp"` to extract files without installing
6. **Test specific packages**: Use `/PACKAGES="2022"` to test installation of a single package version
7. **Skip validation**: Use `/SKIPVALIDATION` to bypass admin/disk checks for quick tests (not recommended)

### Build Issues

1. **Check GitHub token** for API rate limiting (set `GITHUB_TOKEN` environment variable)
2. **Verify package versions** in `packages.json` are available in Winget

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

Contributions welcome; see Developer Guide for local testing.

---

## Credits & Inspiration

- **[abbodi1406](https://github.com/abbodi1406)** - Original creator of [VC++ Redistributables AIO](https://github.com/abbodi1406/vcredist), which inspired this project
- **Microsoft** - For providing Visual C++ Redistributables and the Winget package manager
- **Community** - For feedback and contributions

This project represents a modern, automated alternative that focuses on transparency, automation, and integration with Windows 10/11 ecosystems using reproducible tooling.