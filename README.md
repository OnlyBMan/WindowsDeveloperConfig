<p align="center">
  <img src="./doc/images/devconfigs.svg" alt="Windows Developer Config logo" width="96" />
</p>

<h1 align="center">Windows Developer Config</h1>

<p align="center">
  Opinionated setups for Windows dev boxes. Idempotent. CI-tested.
</p>

<p align="center">
  <a href="https://github.com/microsoft/WindowsDeveloperConfig/actions/workflows/ci.yml"><img src="https://github.com/microsoft/WindowsDeveloperConfig/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT" /></a>
</p>

<h3 align="center">
  <a href="#%EF%B8%8F-windows-dev-config">Windows Dev Config</a>
  <span> · </span>
  <a href="#-wsl-comfort">WSL Comfort</a>
  <span> · </span>
  <a href="#-single-language-workloads">Workloads</a>
  <span> · </span>
  <a href="#-troubleshooting">Troubleshooting</a>
</h3>

---

Go from a fresh Windows install to a fully configured dev box in one command. These declarative, CI-tested configs set up your tools, settings, and shells the same way every time — so any machine can be your machine in minutes.

## 🎯 Pick your setup

Three different things live in this repo. Pick the one that matches what you actually want:

| You want... | Go to |
| --- | --- |
| A full Windows dev workstation: tools, settings, WSL, the works. One command, may reboot. | [Windows Dev Config](#%EF%B8%8F-windows-dev-config) |
| A nicer shell inside WSL (zsh/bash, Starship, modern CLI bits), plus a themed Windows Terminal profile. Interactive. | [WSL Comfort](#-wsl-comfort) |
| Just one language toolchain (Node, Python, .NET, Rust, Go, Java, PHP, WinForms, WinUI 3). | [Workloads](#-single-language-workloads) |

Most of them use `winget configure`. If you've never used it before, turn it on once:

```powershell
winget configure --enable
```

If that fails or `winget configure` still acts like it doesn't exist, see [Troubleshooting](#-troubleshooting).

<br/>

## 🖥️ Windows Dev Config

*Turns a fresh Windows 11 box into a clean, distraction-free dev workstation in one shot.*

A single DSC config that installs the usual dev tools, applies our standard Windows settings, and bootstraps WSL + Ubuntu through the required reboot. Non-interactive. Idempotent. Safe to re-run on an existing machine.

```powershell
winget configure -f .\windows-dev-config\dev-config.winget --accept-configuration-agreements --disable-interactivity
```

> ⚠️ **May reboot.** Enabling WSL needs a Windows optional feature that wants a restart. A `RunOnce` task picks the configuration back up after you sign in, installs Ubuntu, and finishes the run. Expect one hard reboot plus about a minute of post-login work. Close other stuff first.

<details>
<summary><strong>What you get</strong></summary>

- **Dev tools:** PowerShell 7, Git, GitHub CLI, VS Code, .NET SDK 10, Python 3.13 + uv, Node.js, Oh My Posh, and PowerToys.
- **Terminal:** PowerShell 7 is the default, Oh My Posh enabled and Cascadia Mono NF set as the default font.
- **Windows settings:** Dark theme, developer mode, long paths, File Explorer defaults, Start/Search cleanup, Edge policies, and the usual workstation hygiene.
- **WSL:** WSL platform + Ubuntu, including the reboot and the `RunOnce` resume step.

</details>

Full details: [`windows-dev-config/README.md`](./windows-dev-config/README.md).

<br/>

## 🐧 WSL Comfort

*aka Comfort Shell. An interactive setup for a nicer Windows + WSL shell environment.*

WSL Comfort is a different beast. Beyond interactive and non-interactive, you can actually pick and choose options. The Windows side handles WSL, the distro, the JetBrainsMono Nerd Font, and a themed Windows Terminal profile. The Linux side runs inside the distro and configures the shell itself.

```powershell
.\wsl-comfort\install.ps1
```

Interactive by default. Use `-NonInteractive` for unattended runs; the bootstrap also takes `--minimal` for a smaller setup. The Linux half is standalone, so you can copy `comfort-shell-bootstrap.sh` onto any Ubuntu host and run it directly.

<details>
<summary><strong>What you can pick</strong></summary>

- Your choice of shell: **zsh** or **bash**.
- Optional **Starship** prompt.
- Optional modern CLI tools: `fzf`, `rg`, `fd`, `bat`, `eza`, `zoxide`, `jq`.
- Optional clipboard and `open` shims (`pbcopy`, `pbpaste`, `open`).
- Optional **Homebrew**.
- Optional Git defaults.
- A themed **Windows Terminal** profile using JetBrainsMono Nerd Font.

</details>

Full details: [`wsl-comfort/readme.md`](./wsl-comfort/readme.md).

<br/>

## 🧪 Single-language workloads

Just want one toolchain? Pick a row. Each flow ships a `configuration.winget` file plus a matching `install.ps1` shim that applies it and refreshes PATH in the current session.

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

Want the PATH refresh in your current shell? Use the matching shim instead of calling `winget configure` directly:

```powershell
.\Workloads\python\install.ps1
```

> **Heads up:** WinForms and WinUI 3 pull down several gigabytes of Visual Studio components. Fine on a real workstation, painful on a small VM.

<br/>

## 🎨 Command Palette extension coming soon

A [PowerToys Command Palette](https://learn.microsoft.com/windows/powertoys/command-palette/overview) extension lives under [`src/future/cmdpal/`](./src/future/cmdpal/). It reads the same flow list as the rest of the repo and surfaces every flow as a launchable entry, so you don't have to remember which `configuration.winget` to point `winget` at.

See [`src/future/cmdpal/README.md`](./src/future/cmdpal/README.md) for build and install instructions.

<br/>

## 🩺 Troubleshooting

<details>
<summary><strong>"Unrecognized command: configure"</strong></summary>

Run `winget configure --enable`. If `winget configure` still acts like it doesn't exist after that, [`Workloads/_common/assert-winget-configure.ps1`](./Workloads/_common/assert-winget-configure.ps1) tells you whether App Installer is too old, policy has disabled configuration, or something else needs fixing.

</details>

<details>
<summary><strong>A workload says it succeeded but <code>python</code> / <code>node</code> / whatever isn't on PATH</strong></summary>

Open a new terminal, or run the matching `install.ps1` shim to refresh PATH in the current session.

</details>

<details>
<summary><strong>Windows Dev Config rebooted the machine and looks stuck</strong></summary>

It registered a `RunOnce` entry, so `winget configure` resumes once you sign back in. Give it a minute after login.

</details>

<details>
<summary><strong>WSL is missing when I tried to run the Comfort Shell bootstrap directly</strong></summary>

Run `.\wsl-comfort\install.ps1` on the Windows side instead. It installs WSL first.

</details>

<br/>

## 🐛 Reporting issues

Hit a bug, a stale doc, or a flow that fails on your machine? Open an issue at [github.com/microsoft/WindowsDeveloperConfig/issues](https://github.com/microsoft/WindowsDeveloperConfig/issues). Include your Windows build (`winver`), the exact command you ran, and the failing output. That makes everything faster.

<br/>

## ❤️ Contributing

Contributions of every shape are welcome: bug reports, doc fixes, new workloads, voice-and-tone tweaks. Start with [`CONTRIBUTING.md`](./CONTRIBUTING.md), then read [`src/docs/development.md`](./src/docs/development.md) for the CI matrix, the "how to add a language" walkthrough, and how the sign pipeline works.

> **Heads up on the repo layout:** the [`src/`](./src/) tree is the source of truth. The top-level `windows-dev-config/`, `Workloads/`, and `wsl-comfort/` folders are Authenticode-signed release copies regenerated by the sign pipeline, so please don't edit them directly. Full details in [`src/docs/development.md`](./src/docs/development.md#repo-layout-signed-vs-source).

The single source of truth for every flow (paths, build/run commands, ids, language metadata) is [`src/manifest.yml`](./src/manifest.yml). The Command Palette extension, the CI harness, and the per-flow shims all read from it, so keep it in sync when you add or rename a flow.
