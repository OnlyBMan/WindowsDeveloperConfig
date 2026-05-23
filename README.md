# Windows Dev Setup Scripts

[![CI](https://github.com/microsoft/WindowsDeveloperConfig/actions/workflows/ci.yml/badge.svg)](https://github.com/microsoft/WindowsDeveloperConfig/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

This repository packages a small set of idempotent `winget configure` flows for setting up Windows developer machines. Its two primary flows are Windows Dev Config, which applies a curated workstation setup with developer tools, Windows settings, and WSL + Ubuntu, and WSL Comfort, which provisions a configurable WSL shell environment and a matching Windows Terminal profile. The same manifest also drives the single-language workloads and the Command Palette extension.

## Prerequisites

Every flow in this repository depends on `winget configure`. Enable that subcommand once:

```powershell
winget configure --enable
```

This is the canonical one-line remediation used by the repo's `_common` scripts. If it still fails, [`Workloads/_common/assert-winget-configure.ps1`](./Workloads/_common/assert-winget-configure.ps1) explains whether App Installer is too old, policy has disabled configuration, or additional remediation is required.

## Windows Dev Config (Calm OS)

Windows Dev Config is a single DSC configuration that turns a fresh Windows 11 machine into a clean, distraction-free developer workstation. It installs the core developer tools, applies the Windows settings this repo standardizes on, and provisions WSL + Ubuntu with automatic resume across the required reboot.

**What you get:**

- Dev tools: PowerShell 7, Git, GitHub CLI, VS Code, .NET SDK 10, Python 3.13 + uv, Node.js, Oh My Posh, and PowerToys.
- A `ps7default` Windows Terminal profile so PowerShell 7 becomes the default tab.
- Registry changes for dark theme, developer mode, long paths, File Explorer defaults, Start/Search cleanup, Edge policies, and related workstation settings.
- WSL platform + Ubuntu installation, including the reboot and `RunOnce` resume step.

**Run it:**

```powershell
winget configure -f .\windows-dev-config\dev-config.winget `
    --accept-configuration-agreements `
    --disable-interactivity
```

The flow is idempotent and safe to re-run on an existing machine to apply updates or correct drift.

Full details: [`windows-dev-config/README.md`](./windows-dev-config/README.md)

## WSL Comfort (Comfort Shell)

WSL Comfort is a two-part installer for a Windows + WSL shell environment. The Windows side handles WSL, distro selection, JetBrainsMono Nerd Font, and the Windows Terminal profile. The Linux side runs inside the distro and configures the shell itself.

**What you get:**

- Your choice of shell: zsh or bash.
- Optional Starship prompt.
- Optional modern CLI tools such as `fzf`, `rg`, `fd`, `bat`, `eza`, and `zoxide`.
- Optional clipboard and `open` shims (`pbcopy`, `pbpaste`, `open`).
- Optional Homebrew.
- Optional Git defaults.
- A themed Windows Terminal profile using JetBrainsMono Nerd Font.

**Run it:**

```powershell
.\wsl-comfort\install.ps1
```

Interactive by default. Use `-NonInteractive` for unattended runs; the bootstrap also accepts `--minimal` for a smaller setup.

The Linux half remains standalone: you can copy `comfort-shell-bootstrap.sh` onto any Ubuntu host and run it independently.

Full details: [`wsl-comfort/readme.md`](./wsl-comfort/readme.md)

## Single-language workloads

If you only want a language toolchain, use one of these flows. Each ships a `configuration.winget` file and a matching `install.ps1` shim that applies it and refreshes PATH in the current session.

| Workload   | Installs                                                                | Run                                                                                                                            |
| ---------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| TypeScript | Node.js LTS + global `typescript`                                       | `winget configure -f .\Workloads\typescript\configuration.winget --accept-configuration-agreements --disable-interactivity` |
| PHP        | PHP 8.5                                                                 | `winget configure -f .\Workloads\php\configuration.winget --accept-configuration-agreements --disable-interactivity`        |
| .NET       | .NET SDK 10                                                             | `winget configure -f .\Workloads\dotnet\configuration.winget --accept-configuration-agreements --disable-interactivity`     |
| Go         | Go (rolling)                                                            | `winget configure -f .\Workloads\go\configuration.winget --accept-configuration-agreements --disable-interactivity`         |
| Java       | Microsoft Build of OpenJDK 21 LTS                                       | `winget configure -f .\Workloads\java\configuration.winget --accept-configuration-agreements --disable-interactivity`       |
| Rust       | Rust stable via rustup                                                  | `winget configure -f .\Workloads\rust\configuration.winget --accept-configuration-agreements --disable-interactivity`       |
| Python     | CPython 3.13 + uv                                                       | `winget configure -f .\Workloads\python\configuration.winget --accept-configuration-agreements --disable-interactivity`     |
| WinForms   | .NET SDK 10 + Windows Forms desktop workload                            | `winget configure -f .\Workloads\winforms\configuration.winget --accept-configuration-agreements --disable-interactivity`   |
| WinUI 3    | .NET SDK 10 + Visual Studio Community + Windows App SDK / WinUI 3 + WinAppCLI | `winget configure -f .\Workloads\winui\configuration.winget --accept-configuration-agreements --disable-interactivity` |

Each workload also has a shim if you want the PATH refresh in the current shell:

```powershell
.\Workloads\python\install.ps1
```

> **Note:** WinForms and WinUI 3 install several gigabytes of Visual Studio components. They are appropriate for a full workstation, but slow on a small VM.

## Command Palette extension

A [PowerToys Command Palette](https://learn.microsoft.com/en-us/windows/powertoys/command-palette/overview) extension lives under [`src/future/cmdpal/`](./src/future/cmdpal/). It reads the same flow list as the rest of the repository and surfaces every flow as a launchable entry.

See [`src/future/cmdpal/README.md`](./src/future/cmdpal/README.md) for build and install instructions.

## Troubleshooting

- **"Unrecognized command: configure"** - run `winget configure --enable`. If `winget configure` is still unavailable, see [`Workloads/_common/assert-winget-configure.ps1`](./Workloads/_common/assert-winget-configure.ps1).
- **A workload says it succeeded but `python` / `node` / similar commands are not on PATH in this window.** Open a new terminal, or use the matching `install.ps1` shim to refresh PATH in the current session.
- **Windows Dev Config rebooted the machine and appears to have stopped.** It registers a `RunOnce` entry so `winget configure` resumes after you sign back in.
- **WSL is missing when you tried to run the Comfort Shell bootstrap directly.** Use `.\wsl-comfort\install.ps1` on Windows so the flow can install WSL first.

## Repo layout: signed vs source

This repo carries **two parallel copies** of every flow:

| Path                          | What it is                                                        | Edit it? | Run it?  |
| ----------------------------- | ----------------------------------------------------------------- | -------- | -------- |
| `Windows Dev Config/`         | **Signed release copy** (Authenticode).                           | No       | **Yes**  |
| `Workloads/`                  | **Signed release copy** of every single-language workload.        | No       | **Yes**  |
| `Wsl Comfort/`                | **Signed release copy**.                                          | No       | **Yes**  |
| `src/Windows Dev Config/`     | Source. CI runs from here.                                        | **Yes**  | Yes      |
| `src/Workloads/`              | Source. CI runs from here.                                        | **Yes**  | Yes      |
| `src/Wsl Comfort/`            | Source. CI runs from here.                                        | **Yes**  | Yes      |
| `src/manifest.yml`            | Single source-of-truth for every flow (paths, build/run, ids).    | **Yes**  | n/a      |
| `src/future/cmdpal/`          | Command Palette extension. C# project. Reads `src/manifest.yml`.  | **Yes**  | n/a      |
| `src/docs/development.md`     | Contributor docs (CI, validation, how to add a language).         | **Yes**  | n/a      |
| `src/tests/`                  | Hello-world programs + expected stdout used by the CI harness.    | **Yes**  | CI only  |

**End users**: the commands in this README point at the **top-level signed copies** on purpose. If you're following the README on a Windows box you don't need to know `src/` exists — every `winget configure -f ".\Windows Dev Config\dev-config.winget"`-style invocation in this README is correct as written.

**Contributors**: edit `src/`. The top-level paths are **regenerated** by [`.pipelines/OneBranch.SignAndPackage.yml`](./.pipelines/OneBranch.SignAndPackage.yml), which Authenticode-signs every `src/**/*.ps1` and ships them (plus the `.winget` configs and the manifest) as the release artifact. The signed copies were merged into `main` from the `signed` branch in [PR #6](https://github.com/microsoft/WindowsDeveloperConfig/pull/6). A change to a `src/` script becomes a new signed top-level copy on the next sign cycle, not at PR merge — so the two can briefly disagree on a script's body until that cycle runs.

**CI**: GitHub Actions ([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) runs the **unsigned `src/` copies** (e.g. `./src/Workloads/_common/preflight.ps1`). This is intentional — CI exercises what contributors edit; signing is a release-time concern, not a build-time one.

**Don't**:

- Don't edit a top-level signed copy directly. The next sign cycle will overwrite it, and the cycle signs `src/`, not the top level.
- Don't expect the two trees to be byte-identical. The signed copies carry an Authenticode signature block (`# SIG # Begin signature block` … `# SIG # End signature block`); the bodies above that marker should match what's in `src/`. They will diverge for the window between a `src/` change landing on `main` and the next sign cycle catching up.
- Don't add a third copy of anything. Both copies exist for one reason only — to ship signed PS1s without losing the unsigned source — and any new flow or shared script lives only in `src/` until the sign pipeline mirrors it.
- 
## Reporting issues

Found a bug, a stale doc, or a flow that fails on your machine? File an issue at [github.com/microsoft/WindowsDeveloperConfig/issues](https://github.com/microsoft/WindowsDeveloperConfig/issues). Please include your Windows build (`winver`), the exact command you ran, and the failing output.

## License

[MIT](./LICENSE).

## Contributing

For repository layout, CI, and instructions for adding or validating flows, see [`src/docs/development.md`](./src/docs/development.md).
