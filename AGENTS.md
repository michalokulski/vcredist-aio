# AGENTS.md — VC Redist AIO

AI coding agent instructions for this repository.

## Project

VC Redist AIO — Winget-based offline installer for Microsoft Visual C++ Redistributables (2005–2022 + VSTOR). Downloads official MS installers via Winget manifests, bundles into PS2EXE-compiled EXE + ZIP.

## Tech Stack

- **PowerShell 5.1+** — all scripts
- **PS2EXE** — compiles bootstrap.ps1 → vcredist-aio.exe
- **GitHub Actions** — CI/CD (update checks, build, lint, release)
- **Winget manifests** (microsoft/winget-pkgs) — source of truth for download URLs

## Key Files

| File | Purpose |
|------|---------|
| `packages.json` | Package manifest — list of Winget IDs + versions |
| `automation/install.ps1` | Standalone install engine (admin, smart-skip, logging) |
| `automation/uninstall.ps1` | Standalone uninstall engine (MSI product codes, registry scan) |
| `automation/build-ps2exe.ps1` | Downloads packages, encodes payload, compiles EXE via PS2EXE |
| `automation/update-check.ps1` | Queries Winget API for latest versions, updates packages.json |
| `automation/diagnose-build.ps1` | Build diagnostics (PS2EXE check, packages, disk space) |
| `automation/tester.ps1` | Automated install/uninstall test harness |
| `automation/regenerate-bootstrap.ps1` | Dev helper — regenerates bootstrap without full build |
| `.github/workflows/lint.yml` | PSScriptAnalyzer + PowerShell-Beautifier |
| `.github/workflows/check-updates.yml` | Scheduled Winget update check → auto-PR |
| `.github/workflows/build-ps2exe.yml` | Build EXE + ZIP + GitHub Release |

## Conventions

- **PowerShell**: `Verb-Noun` functions, `$script:` for module-scoped vars, `Write-Log` for all output
- **Encoding**: UTF-8 (no BOM) for .ps1, ASCII for checksum files
- **Error handling**: `$ErrorActionPreference = "Stop"` in build scripts, `"Continue"` in install/uninstall
- **Logging**: Timestamped `[LEVEL]` format, dual console+file output
- **Parameters**: PascalCase, `[switch]` for flags, `[string[]]` for arrays
- **Exit codes**: 0 = success, 1 = failure, 3010 = reboot required

## Build Pipeline

1. `check-updates.yml` runs daily — queries Winget API, updates `packages.json`, force-pushes to single `update/auto` branch, opens/updates PR
2. Merge PR → `build-ps2exe.yml` triggers on push to main — auto-populates versions via Winget API, downloads packages, encodes into bootstrap, compiles EXE, creates ZIP, publishes GitHub Release
3. `lint.yml` runs on PR/push — PSScriptAnalyzer + formatter check

## Do NOT

- Add NSIS references — project migrated to PS2EXE
- Use `Write-Host` in install.ps1/uninstall.ps1 (use `Write-Log`)
- Hardcode paths — use `Join-Path`, `$PSScriptRoot`, `$env:TEMP`
- Change `packages.json` schema without updating all consumers
- Remove `-ErrorAction` / `-WarningAction` from registry scans