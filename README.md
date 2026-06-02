<p align="center">
  <img src="./doc/images/devconfigs.svg" alt="Windows Developer Config logo" width="96" />
</p>

<h1 align="center">Windows Developer Config</h1>

<p align="center">
  Opinionated setups for Windows dev boxes. Idempotent. CI-tested.
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

Three developer setups live in this repo. Pick the one that matches what you want:

| You want... | Go to |
| --- | --- |
| A complete dev workstation: tools, OS settings, WSL, and terminal. One command, may reboot. | [Windows Dev Config](#%EF%B8%8F-windows-dev-config) |
| A polished WSL shell: zsh/bash, Starship, CLI tools, and a themed terminal profile. Interactive or unattended. | [WSL Comfort](#-wsl-comfort) |
| A single language toolchain: Node, Python, .NET, Rust, Go, Java, PHP, WinForms, or WinUI 3. One command each. | [Workloads](#-single-language-workloads) |

Most of them use [`winget configure`](https://learn.microsoft.com/en-us/windows/package-manager/winget/configure). If you've never used it before, enable it once:

```powershell
winget configure --enable
```

If that fails or `winget configure` is still not recognized, see [Troubleshooting](#-troubleshooting).

<br/>

## 🖥️ Windows Dev Config

*Turns a fresh Windows 11 box into a clean, distraction-free dev workstation in one shot.*

A single [winget configuration](https://learn.microsoft.com/en-us/windows/package-manager/configuration/) file that installs dev tools, applies opinionated Windows settings, and bootstraps WSL + Ubuntu through the required reboot. Non-interactive. Idempotent. Safe to re-run on an existing machine.

```powershell
winget configure -f .\windows-dev-config\dev-config.winget --accept-configuration-agreements --disable-interactivity
```

> ⚠️ **May reboot.** Enabling WSL needs a Windows optional feature that requires a restart. A `RunOnce` task picks the configuration back up after you sign in, installs Ubuntu, and finishes the run. Expect one hard reboot plus about a minute of post-login work. Save your work first.

<details>
<summary><strong>What you get</strong></summary>

- **Dev tools:** PowerShell 7, Git, GitHub CLI, VS Code, .NET SDK 10, Python 3.13 + uv, Node.js, Oh My Posh, and PowerToys.
- **Terminal:** PowerShell 7 is the default profile, Oh My Posh is enabled, and Cascadia Mono NF is set as the default font.
- **Windows settings:** Dark theme, developer mode, long paths, File Explorer defaults, Start/Search cleanup, Edge policies, and other workstation defaults.
- **WSL:** WSL platform + Ubuntu, including the reboot and the `RunOnce` resume step.

</details>

Full details: [`windows-dev-config/README.md`](./windows-dev-config/README.md).

<br/>

## 🐧 WSL Comfort

*Also known as Comfort Shell. An interactive setup for a polished Windows + WSL shell environment.*

WSL Comfort stands apart. It supports both interactive and non-interactive modes, and lets you pick and choose individual components. The Windows side handles WSL, the distro, the Cascadia Code Nerd Font, and a themed Windows Terminal profile. The Linux side runs inside the distro and configures the shell itself.

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
- A themed **Windows Terminal** profile using Cascadia Code Nerd Font.

</details>

Full details: [`wsl-comfort/readme.md`](./wsl-comfort/readme.md).

<br/>

## 🧪 Single-language workloads

Just want one toolchain? Pick a row. Each workload ships a `configuration.winget` file plus a matching `install.ps1` shim that applies it and refreshes PATH in the current session.

| Workload   | Installs                                                                | Run                                                                                                                            |
| ---------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| TypeScript | Node.js LTS + global `typescript`                                       | `winget configure -f .\Workloads\typescript\configuration.winget --accept-configuration-agreements --disable-interactivity` |
| PHP        | PHP 8.5                                                                 | `winget configure -f .\Workloads\php\configuration.winget --accept-configuration-agreements --disable-interactivity`        |
| .NET       | .NET SDK 10                                                             | `winget configure -f .\Workloads\dotnet\configuration.winget --accept-configuration-agreements --disable-interactivity`     |
| Go         | Go (rolling)                                                            | `winget configure -f .\Workloads\go\configuration.winget --accept-configuration-agreements --disable-interactivity`         |
| Java       | Microsoft Build of OpenJDK 25 LTS                                       | `winget configure -f .\Workloads\java\configuration.winget --accept-configuration-agreements --disable-interactivity`       |
| Rust       | Rust stable via rustup                                                  | `winget configure -f .\Workloads\rust\configuration.winget --accept-configuration-agreements --disable-interactivity`       |
| Python     | Python 3.13 + uv                                                       | `winget configure -f .\Workloads\python\configuration.winget --accept-configuration-agreements --disable-interactivity`     |
| WinForms   | .NET SDK 10 + Windows Forms desktop workload                            | `winget configure -f .\Workloads\winforms\configuration.winget --accept-configuration-agreements --disable-interactivity`   |
| WinUI 3    | .NET SDK 10 + Visual Studio Community + Windows App SDK / WinUI 3 + WinAppCLI | `winget configure -f .\Workloads\winui\configuration.winget --accept-configuration-agreements --disable-interactivity` |

Want the PATH refresh in your current shell? Use the matching shim instead of calling `winget configure` directly:

```powershell
.\Workloads\python\install.ps1
```

> **Heads up:** WinForms and WinUI 3 pull down several gigabytes of Visual Studio components. Fine on a real workstation, painful on a small VM.

<br/>

## 🎨 Command Palette extension (coming soon)

A [PowerToys Command Palette](https://learn.microsoft.com/windows/powertoys/command-palette/overview) extension lives under [`src/future/cmdpal/`](./src/future/cmdpal/). It reads the same flow list as the rest of the repo and surfaces every flow as a launchable entry, so you don't have to remember which `configuration.winget` to point `winget` at.

See [`src/future/cmdpal/README.md`](./src/future/cmdpal/README.md) for build and install instructions.

<br/>

## 🩺 Troubleshooting

<details>
<summary><strong>"Unrecognized command: configure"</strong></summary>

Run `winget configure --enable`. If `winget configure` is still not recognized after that, [`Workloads/_common/assert-winget-configure.ps1`](./Workloads/_common/assert-winget-configure.ps1) tells you whether App Installer is too old, policy has disabled configuration, or something else needs fixing.

</details>

<details>
<summary><strong>A workload says it succeeded but <code>python</code> / <code>node</code> / the tool isn't on PATH</strong></summary>

Open a new terminal, or run the matching `install.ps1` shim to refresh PATH in the current session.

</details>

<details>
<summary><strong>Windows Dev Config rebooted the machine and looks stuck</strong></summary>

It registered a `RunOnce` entry, so `winget configure` resumes once you sign back in. Give it a minute after login.

</details>

<details>
<summary><strong>Comfort Shell bootstrap fails because WSL is missing</strong></summary>

Run `.\wsl-comfort\install.ps1` on the Windows side instead. It installs WSL first.

</details>

<br/>

## 🐛 Reporting issues

Hit a bug, a stale doc, or a setup that fails on your machine? Open an issue at [github.com/microsoft/WindowsDeveloperConfig/issues](https://github.com/microsoft/WindowsDeveloperConfig/issues). Include your Windows build (`winver`), the exact command you ran, and the failing output. This helps us triage faster.

<br/>

## ❤️ Contributing

Contributions of all kinds are welcome: bug reports, doc fixes, new workloads, voice-and-tone tweaks. Start with [`CONTRIBUTING.md`](./CONTRIBUTING.md), then read [`src/docs/development.md`](./src/docs/development.md) for the CI matrix, the "how to add a language" walkthrough, and how the sign pipeline works.

> **Note on the repo layout:** the [`src/`](./src/) tree is the source of truth. The top-level `windows-dev-config/`, `Workloads/`, and `wsl-comfort/` folders are Authenticode-signed release copies regenerated by the sign pipeline, so please don't edit them directly. Full details in [`src/docs/development.md`](./src/docs/development.md#repo-layout-signed-vs-source).

The single source of truth for every flow (paths, build/run commands, ids, language metadata) is [`src/manifest.yml`](./src/manifest.yml). The Command Palette extension, the CI harness, and the per-flow shims all read from it, so keep it in sync when you add or rename a flow.
