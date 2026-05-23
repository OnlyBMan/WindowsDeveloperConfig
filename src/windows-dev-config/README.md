# Calm OS

A WinGet Configuration (DSC) file that sets up a clean, lightweight, distraction-free developer workstation. The goal is a PC state that devs actually love using: no clutter, no noise, just the tools and settings that matter.

This mirrors the curated environment currently provided by Cloud PC, so developers get a consistent experience regardless of device.

The flow is a single DSC document (`dev-config.winget`) that handles everything end-to-end: elevation, the OS tweaks, the apps, and the WSL platform + Ubuntu install (including the reboot dance).

> **Author:** Hamza Usmani.

## Table of Contents

- [Goals](#goals)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [What this configures](#what-this-configures)
- [Configuration details](#configuration-details)
  - [Phase resources (elevation + WSL)](#phase-resources-elevation--wsl)
  - [Apps](#apps)
  - [Theme and OS](#theme-and-os)
  - [File Explorer](#file-explorer)
  - [Taskbar](#taskbar)
  - [Start, Search, Notifications](#start-search-notifications)
  - [Services and features](#services-and-features)
  - [Edge](#edge)
  - [Windows Terminal](#windows-terminal)
- [Customization](#customization)
- [Design decisions](#design-decisions)
- [Known caveats](#known-caveats)

---

## Goals

- **A PC devs actually want to use.** Clean Explorer, dark theme, no pop-ups, no recommendations, no widgets. Just your code and your tools.
- **Cloud PC parity.** Same tooling, OS settings, and policies as the current Cloud PC image.
- **One command.** `winget configure -f dev-config.winget --accept-configuration-agreements --disable-interactivity` takes a fresh Windows machine to fully ready, including WSL + Ubuntu (with an auto-resume across the WSL reboot).
- **Idempotent.** Safe to re-run on existing machines to apply updates or fix drift. Every resource has a `testScript` or DSC-native idempotency.

## Prerequisites

- Windows 11 (latest).
- `winget` with the DSC v3 processor available (the file uses `Microsoft.WinGet/Package`, `Microsoft.Windows/Registry`, and `Microsoft.DSC.Transitional/*`).
- Administrator rights — the `ElevationCheck` resource will auto-relaunch winget elevated via `Start-Process -Verb RunAs` if you started in an unelevated session, but you'll need to consent at the UAC prompt.

## Usage

**Full setup (recommended):**

```powershell
winget configure -f dev-config.winget --accept-configuration-agreements --disable-interactivity
```

This is the canonical invocation documented in the header of `dev-config.winget`.

**What to expect:**

1. The first phase applies all OS tweaks and installs apps.
2. WSL platform components install; the DSC reboots the machine and registers a `RunOnce` resume.
3. After login, winget configure resumes automatically and installs the default Ubuntu distro.
4. Open Ubuntu from the Start menu to complete its first-launch setup (create a UNIX username and password).

The configuration is idempotent, so it is safe to re-run after reboot or at any later point.

## What this configures

- **10 apps** via winget (PowerShell 7, Git, GitHub CLI, VS Code, .NET SDK 10, Python 3.13, UV, Node.js, plus optional Oh My Posh and PowerToys).
- **WSL + Ubuntu**, installed via 3 transitional script resources that bracket a reboot (Phase 2/3/4 below).
- **~24 registry settings** for theme, Explorer, Taskbar, Search, Start, Edge, Notifications, Sudo, Recall, Click To Do, and the Widget service.
- **2 script resources** beyond the WSL phases: an elevation gate that re-launches winget as admin if needed, and a Windows Terminal post-install that sets PowerShell 7 as the default profile.

---

## Configuration details

All resources are dscv3 (`$schema: .../DSC/main/schemas/2023/08/config/document.json`, `metadata.winget.processor.identifier: dscv3`). Every resource that touches HKLM or runs elevated tools depends on `ElevationCheck` to guarantee the rest of the document runs admin-side.

Package resources use `Microsoft.WinGet/Package` with `source: winget` and `useLatest: true` (except `Python.Python.3.13` and `Microsoft.dotnet.SDK.10`, which are pinned by id).

### Phase resources (elevation + WSL)

| Name | Type | What it does |
|------|------|--------------|
| `ElevationCheck` | `Microsoft.DSC.Transitional/WindowsPowerShellScript` | `testScript` checks `IsInRole(Administrator)`. If false, `setScript` re-invokes `winget configure --file <this> --accept-configuration-agreements --disable-interactivity --wait` via `Start-Process -Verb RunAs` and throws so the unelevated run terminates. |
| `InstallWslComponents` | `Microsoft.DSC.Transitional/WindowsPowerShellScript` | `testScript` probes for the `vmcompute` service (presence ⇒ Virtual Machine Platform is active). `setScript` runs `wsl --install --no-distribution`. |
| `RebootForVmp` | `Microsoft.DSC.Transitional/WindowsPowerShellScript` | Same `vmcompute` test. `setScript` registers `HKCU:\...\RunOnce\DSCConfigureResume` with the same `winget configure --file <this>` command, then `Restart-Computer -Force` + `Start-Sleep 30` + `throw`. The throw ensures DSC marks the run failed so it doesn't proceed past this resource before the reboot starts. |
| `InstallUbuntu` | `Microsoft.DSC.Transitional/WindowsPowerShellScript` | `testScript` checks for any subkey under `HKCU:\...\Lxss`. `setScript` runs `wsl --install -d Ubuntu --no-launch`. |

All app and registry resources that need WSL present (i.e. effectively all of them) depend on `InstallUbuntu` so the OS work happens before the reboot — but the WSL install is still part of the same DSC document.

### Apps

| Resource name | Package id | Notes |
|---------------|-----------|-------|
| `PowerShell` | `Microsoft.PowerShell` | Direct dependency on `ElevationCheck`. |
| `Git` | `Git.Git` | Depends on `ElevationCheck` + `InstallUbuntu`. |
| `GitHubCLI` | `GitHub.Cli` | Depends on `Git` + `InstallUbuntu`. |
| `VSCode` | `Microsoft.VisualStudioCode` | |
| `DotnetSdk` | `Microsoft.dotnet.SDK.10` | Pinned to v10. |
| `Python` | `Python.Python.3.13` | Pinned to 3.13. |
| `UV` | `astral-sh.uv` | |
| `NodeJS` | `OpenJS.NodeJS` | |
| `OhMyPosh` | `JanDeDobbeleer.OhMyPosh` | Marked Optional in the comments. |
| `PowerToys` | `Microsoft.PowerToys` | Marked Optional. Followed by `PowerToysAOT` which disables AOT notifications via registry. |

### Theme and OS

All entries below are `Microsoft.Windows/Registry`.

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Sudo enabled (inline mode) | `HKLM\...\Sudo\Enabled` | DWord `3` |
| Developer Mode | `HKLM\...\AppModelUnlock\AllowDevelopmentWithoutDevLicense` | DWord `1` |
| Dark theme (apps) | `HKCU\...\Themes\Personalize\AppsUseLightTheme` | DWord `0` |
| Dark theme (system chrome) | `HKCU\...\Themes\Personalize\SystemUsesLightTheme` | DWord `0` |
| Long path support | `HKLM\...\FileSystem\LongPathsEnabled` | DWord `1` |
| Remote Desktop on | `HKLM\...\Terminal Server\fDenyTSConnections` | DWord `0` |

### File Explorer

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Show file extensions | `HKCU\...\Advanced\HideFileExt` | DWord `0` |
| Show hidden files | `HKCU\...\Advanced\Hidden` | DWord `1` |
| Full path in titlebar | `HKCU\...\Advanced\FullPathAddress` | DWord `1` |
| Open to This PC | `HKCU\...\Advanced\LaunchTo` | DWord `1` |
| Account insights off | `HKCU\...\AccountNotifications\EnableAccountNotifications` | DWord `0` |
| Frequent folders off | `HKCU\...\Advanced\ShowFrequent` | DWord `0` |
| Frequent files off | `HKCU\...\Explorer\ShowRecent` | DWord `0` |
| Recommended/cloud files off | `HKCU\...\Explorer\ShowCloudFilesInQuickAccess` | DWord `0` |
| Git integration in Explorer | `HKCU\...\Advanced\NavPaneShowVersionControl` | DWord `1` |
| Tips/sync-provider notifications off | `HKCU\...\Advanced\ShowSyncProviderNotifications` | DWord `0` |

### Taskbar

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Widgets button hidden | `HKCU\...\Advanced\TaskbarDa` | DWord `0` |
| Bluetooth notification icon off | `HKCU\Control Panel\Bluetooth\Notification Area Icon` | DWord `0` |
| End Task on right-click | `HKCU\...\Advanced\TaskbarEndTask` | DWord `1` |

### Start, Search, Notifications

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Web search suggestions off | `HKCU\...\Policies\Explorer\DisableSearchBoxSuggestions` | DWord `1` |
| Start menu recommendations off | `HKCU\...\Advanced\Start_Layout` | DWord `1` |
| Do Not Disturb (toasts off) | `HKCU\...\Notifications\Settings\NOC_GLOBAL_SETTING_TOASTS_ENABLED` | DWord `0` |

### Services and features

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| Click To Do off | `HKCU\...\ClickToDoAndScreenCapture\Enabled` | DWord `0` |
| Recall off | `HKCU\...\Recall\Enabled` | DWord `0` |
| Widget service off (HKLM policy) | `HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests` | DWord `0` |
| PowerToys AOT notifications off | `HKCU\...\Notifications\Settings\PowerToys\Enabled` | DWord `0` |

### Edge

HKLM policies, applied via `Microsoft.Windows/Registry`:

| Item | Hive\Key\Value | Value |
|------|----------------|-------|
| New tab blank | `HKLM\SOFTWARE\Policies\Microsoft\Edge\NewTabPageLocation` | String `about:blank` |
| First-run experience off | `HKLM\SOFTWARE\Policies\Microsoft\Edge\HideFirstRunExperience` | DWord `1` |

### Windows Terminal

| Resource | Type | What it does |
|----------|------|--------------|
| `ps7default` | `Microsoft.DSC.Transitional/RunCommandOnSet` | Invokes `pwsh.exe -NoProfile -NoLogo -Command ...` which reads `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json`, finds the PowerShell 7 profile (`Windows.Terminal.PowershellCore` source), and sets it as `defaultProfile`. Depends on `PowerShell`. |

---

## Customization

- **Pick and choose packages.** Comment out any `Microsoft.WinGet/Package` block to skip that install — they have no `dependsOn` chain beyond `InstallUbuntu` (except `GitHubCLI`, which depends on `Git`).
- **Pin or unpin versions.** Switch `id: Python.Python.3.13` (pinned) to `id: Python.Python.3` if you want to drift forward, or vice versa for the unpinned packages.
- **Toggle registry values.** Most settings are `DWord: 0` or `DWord: 1`; flip the value to invert the behavior.
- **Re-enable commented-out tweaks.** The file ships with three settings commented out — `HideDesktopIcons`, `TaskbarHideSearch`, and `SpotlightOff` — because they over-fire on some user setups. Uncomment if you want them.
- **Change the WSL distro.** Edit the `wsl --install -d Ubuntu --no-launch` line inside the `InstallUbuntu` resource.

## Design decisions

| Decision | Rationale |
|----------|-----------|
| Single dscv3 document, no modules | Easier to reason about and easier to re-run. The whole flow is one `winget configure` call. |
| `Microsoft.Windows/Registry` everywhere instead of `Microsoft.Windows.Developer/*` or `Microsoft.Windows.Settings/WindowsSettings` | Direct registry control is reliable across Windows 11 builds and easy to audit. The dedicated resources have been flaky on 23H2+. |
| `Microsoft.DSC.Transitional/WindowsPowerShellScript` (not `PSDscResources/Script`) | The dscv3 transitional resource is the supported equivalent under the new processor. |
| Self-relaunch elevated from `ElevationCheck` | Means a user can double-click into an unelevated shell and the DSC will UAC-prompt itself rather than failing. |
| Reboot + RunOnce inside the DSC | The DSC owns the reboot and the resume, so the user only invokes `winget configure` once. The throw after `Restart-Computer -Force` is required because `Restart-Computer` returns immediately. |
| `useLatest: true` on most packages | Cloud PC parity tracks "current" tools. Pinned ids (`Python.Python.3.13`, `Microsoft.dotnet.SDK.10`) are used where a major-version line matters. |
| `RunCommandOnSet` to mutate `settings.json` | Windows Terminal's settings are JSON-based and not registry-mapped; a small pwsh fragment is the cleanest way. |

## Known caveats

| Area | Caveat |
|------|--------|
| **`acceptAgreements` not on packages** | None of the `Microsoft.WinGet/Package` resources set `acceptAgreements: true`. The header comment compensates by passing `--accept-configuration-agreements` to the CLI invocation, but `--accept-package-agreements` is **not** in the documented command — first-time installs may prompt. Pass it explicitly if you want fully silent. |
| **WSL reboot** | `RebootForVmp` will hard-reboot the machine via `Restart-Computer -Force`. Save your work before running. The RunOnce key resumes the config on next login. |
| **Ubuntu first-launch** | After `InstallUbuntu`, you still need to open Ubuntu from the Start menu once to create a UNIX user. Nothing inside the distro is configured by this flow. |
| **`useLatest: true`** | Each run grabs the latest available version. Builds may differ between machines applying the config on different days. |
| **HKLM registry keys** | Sudo, the Widget service policy, Edge policies, Remote Desktop, Long Paths, and Developer Mode all live in HKLM. The `ElevationCheck` gate guarantees the run is elevated; without it those would silently fail. |
| **PowerToys AOT path** | `HKCU\...\Notifications\Settings\PowerToys\Enabled` targets a specific registry path that may change across PowerToys versions. |
| **Idempotency of WSL phases** | `InstallWslComponents` and `RebootForVmp` both test for `vmcompute`. Re-running after the reboot is a no-op for those resources. `InstallUbuntu` tests for any `Lxss` subkey, so adding a second distro is also a no-op. |
| **Currently commented out** | `HideDesktopIcons`, `TaskbarHideSearch`, and `SpotlightOff` blocks live in the file but are commented out. If you re-enable them, expect the listed Explorer/Taskbar/Lock-screen behavior to flip. |
