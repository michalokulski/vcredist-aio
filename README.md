// filepath: README.md
# VC Redist AIO — Winget-based Offline Installer

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
- **No AV False Positives**: Unlike ps2exe, NSIS is trusted by all major antivirus software
- **Comprehensive Logging**: Timestamped installation logs with detailed exit code interpretation
- **Pre-Installation Validation**: Admin privilege checks, disk space verification, package integrity validation
- **Silent Installation**: Supports silent/unattended modes with proper exit code handling
- **GitHub Actions**: Automated Winget update checks and release builds
- **Modular Architecture**: Separate installation engine (`install.ps1`) for testing and maintenance

---

## Download Options

Each release includes two formats:

1. **VC_Redist_AIO_Offline.exe** (Recommended)
   - NSIS-based installer
   - One-click installation
   - Professional installer UI
   - Trusted by Windows Defender
   - Smaller file size than ps2exe

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

### Option 2: PowerShell Script (Advanced)

1. Download and extract `vc_redist_aio_offline.zip`
2. Right-click `install.ps1` → Run with PowerShell (as Administrator)
3. Optional command-line flags:

```powershell
# Silent installation
.\install.ps1 -Silent

# Skip pre-installation validation (not recommended)
.\install.ps1 -SkipValidation

# Both flags
.\install.ps1 -Silent -SkipValidation
```

---

## Repo Layout

```
├── automation/
│   ├── install.ps1         # Standalone installation engine with logging & validation
│   ├── update-check.ps1    # Checks Winget for newer package versions
│   ├── build.ps1           # Legacy ps2exe builder (deprecated)
│   └── build-nsis.ps1      # NSIS installer builder (recommended)
├── .github/workflows/
│   ├── check-updates.yml   # Scheduled Winget update checks
│   └── build-release.yml   # Builds NSIS installer and publishes releases
├── packages.json           # List of Winget package IDs and versions
├── powershell-to-exe.json  # ps2exe configuration (deprecated)
└── README.md
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

## Why NSIS Over ps2exe?

Previous versions of this project used **ps2exe** to create self-extracting executables. While functional, ps2exe has significant drawbacks:

### Problems with ps2exe:
- ❌ High false positive rate with antivirus software
- ❌ Looks like malware to heuristic scanners
- ❌ No digital signature support
- ❌ Poor compression
- ❌ Not trusted by enterprise environments

### Benefits of NSIS:
- ✅ Industry-standard installer (used by Firefox, VLC, 7-Zip)
- ✅ Trusted by Windows Defender and all major AV vendors
- ✅ Supports digital code signing
- ✅ Professional installer UI
- ✅ Excellent LZMA compression
- ✅ Enterprise-friendly

**Result**: The NSIS installer is typically **smaller** and has **zero false positives** compared to ps2exe.

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

- **`automation/build-nsis.ps1`**: NSIS installer build orchestration
  - Downloads packages from Winget manifests
  - Creates NSIS installer script
  - Compiles to professional EXE
  - Generates checksums

This separation allows for:
- Independent testing of installation logic
- Easier debugging and maintenance
- Full audit trail via log files
- Flexible deployment options (NSIS EXE or PowerShell script)

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

1. **Check the log file**: `vcredist-install-YYYYMMDD-HHMMSS.log` (in `%TEMP%`)
2. **Verify admin privileges**: Right-click → "Run as Administrator"
3. **Check disk space**: Minimum 500MB required
4. **Review exit codes**:
   - `0` = Success
   - `3010` = Success (reboot required)
   - `1638` = Already installed (newer/same version)
   - `5100` = System requirements not met

### Build Issues

1. **Ensure NSIS is installed**: `choco install nsis -y`
2. **Check GitHub token** for API rate limiting (set `GITHUB_TOKEN` environment variable)
3. **Verify package versions** in `packages.json` are available in Winget

### Antivirus False Positives

If you're still using the old ps2exe-based build:
- Switch to the NSIS build using `build-nsis.ps1`
- NSIS installers have near-zero false positive rates
- Consider code-signing for maximum trust

---

## License

This project is provided as-is for educational and automation purposes. Microsoft Visual C++ Redistributables are subject to Microsoft's licensing terms.

---

## Credits & Inspiration

- **[abbodi1406](https://github.com/abbodi1406)** - Original creator of [VC++ Redistributables AIO](https://github.com/abbodi1406/vcredist), which inspired this project
- **Microsoft** - For providing Visual C++ Redistributables and the Winget package manager
- **NSIS** - For the excellent open-source installer framework
- **Community** - For feedback and contributions

This project represents a **modern, automated alternative** that complements abbodi1406's excellent work by focusing on transparency, automation, and integration with Windows 10/11 ecosystems using industry-standard tooling.