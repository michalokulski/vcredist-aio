# VC Redist AIO — Winget-based Offline Installer (Prototype)

**VC Redist AIO** is a prototype project that automates downloading official Microsoft Visual C++ Redistributable installers via **Winget**, bundles them into a single offline installer, and produces a standalone EXE using PowerShell→EXE tooling. The goal is a legal, auditable, and reproducible offline installer for environments that need all VC++ runtimes.

---

## Key Features

- Downloads official Microsoft VC++ Redistributables using `winget`.
- Packages all downloaded installers into an offline bundle.
- Produces a single EXE (PowerShell script compiled with `ps2exe`) that extracts and runs installers offline.
- Maintains compatibility with common AIO flags (e.g. silent/unattended modes).
- GitHub Actions workflows to check for Winget updates and automatically build releases.

---

## Repo layout

```
├── automation/
│ ├── update-check.ps1 # checks Winget for newer package versions
│ └── build.ps1 # downloads packages, prepares payload, builds EXE
├── .github/workflows/
│ ├── check-updates.yml # scheduled Winget checks
│ └── build-release.yml # builds offline EXE and publishes release
├── packages.json # list of winget package IDs and recorded versions
├── powershell-to-exe.json # ps2exe config for building the EXE
└── README.md
```

## Usage (Developer / Maintainer)

### Requirements
- Windows 10/11 (or runner `windows-latest` on GitHub Actions)
- PowerShell 7.2+
- `winget` (Windows package manager)
- `ps2exe` module (`Install-Module ps2exe -Scope CurrentUser`)

### Local build steps
1. Clone the repository:
```powershell
git clone https://github.com/michalokulski/vc-redist-aio.git
cd vc-redist-aio
```
Install prerequisites (one-time):

```powershell
pwsh -Command "Install-Module ps2exe -Force -Scope CurrentUser"
```

Run the build script (downloads packages, bundles, builds EXE):
```
pwsh automation/build.ps1 -PackagesFile packages.json -OutputDir dist -PSEXEPath powershell-to-exe.json
```

#### Result:

dist/ will contain downloaded installers and the generated VC_Redist_AIO_Offline.exe (or equivalent).

Test the EXE on a clean VM before broad deployment.

#### Usage (End-user)

Download the latest Release from GitHub (the offline EXE or ZIP).

Run the EXE as Administrator.

The installer will extract the bundled redistributables and run installers silently (/quiet /norestart when possible).

#### Automation (GitHub Actions)

check-updates.yml runs on a schedule, inspects Winget package versions, updates packages.json and opens update branches when versions change.

build-release.yml builds the offline EXE and publishes a GitHub Release when an update/* branch is pushed or on manual dispatch.

###  Security note: This project bundles official Microsoft installers downloaded via Winget. Verify policies in your organization before redistributing. Consider signing the generated EXE and publishing checksums (SHA256) in Release notes.
