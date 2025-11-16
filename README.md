# VC Redist AIO — Winget-based Offline Installer

**VC Redist AIO** is a modern, automated project that downloads official Microsoft Visual C++ Redistributable installers via **Winget**, bundles them into a single offline installer, and produces a standalone EXE. This project is inspired by [abbodi1406's VC++ AIO](https://github.com/abbodi1406/vcredist) and focuses on a **Winget-based approach** with full automation, transparency, and modern tooling optimized for **Windows 10/11**.

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

**Note**: This project covers **modern runtimes** (VC++ 2005-2022, VSTOR) and does **not** include legacy components (VC++ 2002/2003, VB runtimes) that are rarely needed on modern systems.

---

## Key Features

- **Automated Downloads**: Downloads official Microsoft VC++ Redistributables using Winget manifests
- **Offline Bundle**: Packages all installers into a single offline bundle
- **Standalone EXE**: Produces a single EXE using `ps2exe` that works offline
- **Comprehensive Logging**: Timestamped installation logs with detailed exit code interpretation
- **Pre-Installation Validation**: Admin privilege checks, disk space verification, package integrity validation
- **Silent Installation**: Supports silent/unattended modes with proper exit code handling
- **GitHub Actions**: Automated Winget update checks and release builds
- **Modular Architecture**: Separate installation engine (`install.ps1`) for testing and maintenance

---

## Repo Layout

```
├── automation/
│   ├── install.ps1         # Standalone installation engine with logging & validation
│   ├── update-check.ps1    # Checks Winget for newer package versions
│   └── build.ps1           # Downloads packages, bundles, builds EXE
├── .github/workflows/
│   ├── check-updates.yml   # Scheduled Winget update checks
│   └── build-release.yml   # Builds offline EXE and publishes releases
├── packages.json           # List of Winget package IDs and versions
├── powershell-to-exe.json  # ps2exe configuration
└── README.md
```

## Usage (Developer / Maintainer)

### Requirements
- Windows 10/11 (or runner `windows-latest` on GitHub Actions)
- PowerShell 7.2+
- `winget` (Windows package manager)
- `ps2exe` module (`Install-Module ps2exe -Scope CurrentUser`)

### Local Build Steps

1. **Clone the repository:**
   ```powershell
   git clone https://github.com/michalokulski/vcredist-aio.git
   cd vcredist-aio
   ```

2. **Install prerequisites** (one-time):
   ```powershell
   pwsh -Command "Install-Module ps2exe -Force -Scope CurrentUser"
   ```

3. **Run the build script** (downloads packages, bundles, builds EXE):
   ```powershell
   pwsh automation/build.ps1 `
     -PackagesFile packages.json `
     -OutputDir dist `
     -PSEXEPath powershell-to-exe.json
   ```

#### Build Output

The `dist/` directory will contain:
- `VC_Redist_AIO_Offline.exe` - Standalone installer
- `packages/` - Downloaded redistributables
- `SHA256.txt` - Checksum for verification
- `installer.ps1` - PowerShell source (before EXE conversion)

Test the EXE on a clean VM before deployment.

## Usage (End-User)

1. **Download** the latest Release from GitHub (the offline EXE or ZIP)

2. **Run as Administrator:**
   ```powershell
   .\VC_Redist_AIO_Offline.exe
   ```

3. **Installation Features:**
   - ✅ Pre-installation validation (admin rights, disk space)
   - ✅ Package integrity checks
   - ✅ Silent installation (`/quiet /norestart`)
   - ✅ Detailed logging to timestamped log files
   - ✅ Exit code interpretation (0=success, 3010=reboot required, 1638=already installed)
   - ✅ Installation summary with statistics

4. **Log Files:**
   Installation logs are saved to: `vcredist-install-YYYYMMDD-HHMMSS.log`

### Command-Line Options

You can also run the PowerShell script directly:
```powershell
.\installer.ps1 [-Silent] [-SkipValidation]
```

- `-Silent`: Suppress console output
- `-SkipValidation`: Skip pre-installation checks (not recommended)

## Automation (GitHub Actions)

- **`check-updates.yml`**: Runs on schedule, checks Winget for package updates, updates `packages.json`, and creates update branches
- **`build-release.yml`**: Builds the offline EXE and publishes a GitHub Release when an `update/*` branch is pushed or on manual dispatch

## Installation Engine Architecture

The project uses a modular architecture:

- **`automation/install.ps1`**: Standalone installation engine that can be tested independently
  - Logging infrastructure with color-coded output
  - Pre-installation validation (admin, disk space)
  - Package discovery and integrity checks
  - Exit code interpretation and error handling
  - Installation statistics and summary

- **`automation/build.ps1`**: Build orchestration
  - Downloads packages from Winget manifests
  - Embeds `install.ps1` into installer wrapper
  - Creates package bundle
  - Converts to EXE using ps2exe

This separation allows for:
- Independent testing of installation logic
- Easier debugging and maintenance
- Full audit trail via log files
- Flexible deployment options (EXE or PowerShell script)

## Security & Compliance

⚠️ **Important Notes:**

- This project bundles **official Microsoft installers** downloaded via Winget
- Verify organizational policies before redistributing
- Consider **code-signing** the generated EXE
- **SHA256 checksums** are published with each release
- Review the generated `installer.ps1` before converting to EXE
- All downloads are from official Microsoft URLs extracted from Winget manifests

## Troubleshooting

### Installation Issues

1. **Check the log file**: `vcredist-install-YYYYMMDD-HHMMSS.log`
2. **Verify admin privileges**: Right-click → "Run as Administrator"
3. **Check disk space**: Minimum 500MB required
4. **Review exit codes**:
   - `0` = Success
   - `3010` = Success (reboot required)
   - `1638` = Already installed (newer/same version)
   - `5100` = System requirements not met

### Build Issues

1. **Ensure ps2exe is installed**: `Install-Module ps2exe -Scope CurrentUser`
2. **Check GitHub token** for API rate limiting (set `GITHUB_TOKEN` environment variable)
3. **Verify package versions** in `packages.json` are available in Winget

## License

This project is provided as-is for educational and automation purposes. Microsoft Visual C++ Redistributables are subject to Microsoft's licensing terms.

---

## Credits & Inspiration

- **[abbodi1406](https://github.com/abbodi1406)** - Original creator of [VC++ Redistributables AIO](https://github.com/abbodi1406/vcredist), which inspired this project
- **Microsoft** - For providing Visual C++ Redistributables and the Winget package manager
- **Community** - For feedback and contributions

This project represents a **modern, automated alternative** that complements abbodi1406's excellent work by focusing on transparency, automation, and integration with Windows 10/11 ecosystems.
