# Contributing to VC Redist AIO

## Setup

```powershell
# Clone
git clone https://github.com/michalokulski/vcredist-aio.git
cd vcredist-aio

# Install PS2EXE
Install-Module ps2exe -Scope CurrentUser -Force

# Install lint tools
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Install-Module PowerShell-Beautifier -Scope CurrentUser -Force
```

## Development Workflow

1. **Update packages.json** — run `automation/update-check.ps1 -PackagesFile packages.json`
2. **Build EXE** — run `automation/build-ps2exe.ps1 -VerboseBuild`
3. **Test** — run `automation/tester.ps1` (requires admin)
4. **Lint** — run `Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1`
5. **Format** — run `Get-ChildItem -Include *.ps1 -Recurse | Edit-DTWBeautifyScript`

## Script Architecture

- `install.ps1` / `uninstall.ps1` — standalone engines, usable independently
- `build-ps2exe.ps1` — downloads packages from Winget, encodes into Base64 bootstrap, compiles via PS2EXE
- `update-check.ps1` — queries `microsoft/winget-pkgs` GitHub API for latest versions
- `tester.ps1` — automated test harness for install/uninstall scenarios
- `diagnose-build.ps1` — build environment diagnostics
- `regenerate-bootstrap.ps1` — dev helper for quick bootstrap regeneration

## Pull Requests

- Target `main` branch
- Ensure PSScriptAnalyzer passes
- Test install/uninstall on clean VM if changing engine logic
- Update `AGENTS.md` if adding new scripts or changing conventions