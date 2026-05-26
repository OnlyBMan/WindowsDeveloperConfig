<#
.SYNOPSIS
  Apply the Comfort Shell setup and run the WSL bootstrap.
.DESCRIPTION
  Ensures WSL + an Ubuntu distro, runs the bootstrap inside it, and registers
  a Windows Terminal profile. Interactive by default: prompts to confirm each
  step and lets you pick the distro. Pass -NonInteractive to accept all
  defaults (auto-pick distro, forward --non-interactive to the bootstrap).
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$Distro,
    [string[]]$BootstrapArgs = @(),
    [string]$ResumeEncodedArgs
)

$ErrorActionPreference = 'Stop'

# PS 7.4+ may throw on native non-zero exits; we check $LASTEXITCODE manually.
$PSNativeCommandUseErrorActionPreference = $false

# Bootstrap and WT banners are UTF-8; OEM code page produces mojibake.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# Restore params from the previous (pre-reboot) invocation if RunOnce armed us.
if ($ResumeEncodedArgs) {
    try {
        $resumeJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ResumeEncodedArgs))
        $resume     = $resumeJson | ConvertFrom-Json
        if ($resume.PSObject.Properties.Match('NonInteractive').Count -gt 0 -and $resume.NonInteractive) {
            $script:NonInteractive = $true
        }
        if ($resume.PSObject.Properties.Match('Distro').Count -gt 0 -and $resume.Distro) {
            $script:Distro = [string]$resume.Distro
        }
        if ($resume.PSObject.Properties.Match('BootstrapArgs').Count -gt 0 -and $resume.BootstrapArgs) {
            $script:BootstrapArgs = @($resume.BootstrapArgs | ForEach-Object { [string]$_ })
        }
        Write-Host "  (Resumed from reboot; restored original arguments.)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  (Could not decode resume state: $_)" -ForegroundColor DarkYellow
    }
}

$script:CurrentStep = 0
$script:TotalSteps  = 5

function Set-ConsoleTitle {
    param([string]$Title)
    try { $Host.UI.RawUI.WindowTitle = $Title } catch { }
}

function Step {
    param([string]$Message)
    $script:CurrentStep++
    Write-Host ''
    Write-Host "▶ [$script:CurrentStep/$script:TotalSteps] $Message" -ForegroundColor Cyan
    Set-ConsoleTitle "Comfort Shell · $script:CurrentStep/$script:TotalSteps · $Message"
}

# --- Helpers -----------------------------------------------------------------

function Reset-TerminalInputMode {
    # Disable Win32 Input Mode and focus reporting, then drain queued key events.
    $esc = [char]27
    [Console]::Out.Write("$esc[?9001l$esc[?1004l")
    [Console]::Out.Flush()
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    if ($script:NonInteractive) {
        $auto = if ($Default) { 'yes' } else { 'no' }
        Write-Host "$Prompt $hint $auto (auto; -NonInteractive in effect)" -ForegroundColor DarkGray
        return $Default
    }
    Reset-TerminalInputMode
    while ($true) {
        $answer = (Read-Host "$Prompt $hint").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch -Regex ($answer) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default      { Write-Host '  Please enter y or n.' -ForegroundColor Yellow }
        }
    }
}

function Get-WslSupportedDistros {
    # Installed Ubuntu distros on this machine. `wsl -l -q` emits UTF-16LE with NUL bytes.
    $raw = (& wsl.exe --list --quiet) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    return @($raw |
        ForEach-Object { ($_ -replace "`0", '').Trim() } |
        Where-Object { $_ -like 'Ubuntu*' })
}

function Invoke-NativeConsole {
    # Run a native exe attached to the parent console so /dev/tty works in the child.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    # Pre-quote args per CommandLineToArgvW so Start-Process forwards them verbatim on PS 5.1.
    $quoted = foreach ($a in $ArgumentList) {
        if ($a -match '[\s"]') {
            '"' + ($a -replace '\\+(?=")', '$0$0' -replace '"', '\"') + '"'
        } else {
            $a
        }
    }

    $startArgs = @{
        FilePath    = $FilePath
        NoNewWindow = $true
        Wait        = $true
        PassThru    = $true
    }
    if ($quoted.Count -gt 0) {
        $startArgs['ArgumentList'] = (($quoted) -join ' ')
    }

    $proc = Start-Process @startArgs
    Reset-TerminalInputMode
    return $proc.ExitCode
}

function Get-SupportedUbuntuDistros {
    return @(
        [pscustomobject]@{ Name = 'Ubuntu';       FriendlyName = 'Ubuntu (latest LTS)' }
        [pscustomobject]@{ Name = 'Ubuntu-24.04'; FriendlyName = 'Ubuntu 24.04 LTS' }
        [pscustomobject]@{ Name = 'Ubuntu-22.04'; FriendlyName = 'Ubuntu 22.04 LTS' }
        [pscustomobject]@{ Name = 'Ubuntu-20.04'; FriendlyName = 'Ubuntu 20.04 LTS' }
    )
}

function Select-WslDistro {
    param([string]$DefaultName = 'Ubuntu')

    $online = @(Get-SupportedUbuntuDistros)

    Write-Host ''
    Write-Host 'Available Ubuntu distros:' -ForegroundColor Cyan
    Write-Host ''
    $i = 1
    foreach ($d in $online) {
        $marker = if ($d.Name -eq $DefaultName) { ' (default)' } else { '' }
        Write-Host ("  {0,2}) {1,-30} {2}{3}" -f $i, $d.Name, $d.FriendlyName, $marker)
        $i++
    }
    Write-Host ''

    if ($script:NonInteractive) {
        Write-Host "Using default distro: $DefaultName (auto; -NonInteractive in effect)" -ForegroundColor DarkGray
        return $DefaultName
    }

    Reset-TerminalInputMode
    while ($true) {
        $answer = (Read-Host "Pick a distro [$DefaultName]").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultName }

        if ($answer -match '^\d+$') {
            $idx = [int]$answer
            if ($idx -ge 1 -and $idx -le $online.Count) {
                return $online[$idx - 1].Name
            }
        }

        $match = $online | Where-Object { $_.Name -eq $answer }
        if ($match) { return $match.Name }

        Write-Host "  Invalid choice. Enter a number (1-$($online.Count)) or distro name." -ForegroundColor Yellow
    }
}

# --- Step functions -----------------------------------------------------------

function Assert-WindowsTerminal {
    # wt.exe is required: we install a WT profile and resume in wt after reboot.
    if (Get-Command 'wt.exe' -ErrorAction SilentlyContinue) { return }

    Write-Host ''
    Write-Host '---------------------------------------------------------------' -ForegroundColor Red
    Write-Host '  Windows Terminal is required but not available on PATH.' -ForegroundColor Red
    Write-Host '---------------------------------------------------------------' -ForegroundColor Red
    Write-Host ''
    Write-Host '  The Comfort Shell flow installs a Windows Terminal profile' -ForegroundColor Yellow
    Write-Host '  fragment, so wt.exe must be installed before we proceed.' -ForegroundColor Yellow
    Write-Host ''
    throw 'Windows Terminal (wt.exe) is a required prerequisite for the Comfort Shell flow.'
}

function Test-WslReady {
    if (-not (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) { return $false }
    # try/catch covers stubs that bypass `*> $null` via WriteConsoleW.
    try {
        & wsl.exe --status *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Set-ResumeAfterReboot {
    # HKCU RunOnce: re-launches this script (elevated, in wt.exe) at next logon.
    param([Parameter(Mandatory)][string]$ScriptPath)

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Host "  (Could not register auto-resume: script path missing: $ScriptPath)" -ForegroundColor DarkYellow
        return
    }

    $escapedPath = $ScriptPath -replace "'", "''"

    # Round-trip the original args via base64-JSON so they survive RunOnce -> wt -> powershell -File.
    $resumePayload = @{}
    if ($script:NonInteractive) { $resumePayload['NonInteractive'] = $true }
    if (-not [string]::IsNullOrEmpty($script:Distro)) { $resumePayload['Distro'] = [string]$script:Distro }
    if ($script:BootstrapArgs -and @($script:BootstrapArgs).Count -gt 0) {
        $resumePayload['BootstrapArgs'] = @($script:BootstrapArgs | ForEach-Object { [string]$_ })
    }

    $resumeArgs = ''
    if ($resumePayload.Count -gt 0) {
        $resumeJson = $resumePayload | ConvertTo-Json -Compress -Depth 4
        $resumeB64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($resumeJson))
        $resumeArgs = " -ResumeEncodedArgs $resumeB64"
    }

    # Encode the launcher so it survives RunOnce -> powershell -> wt.exe.
    $launcherScript = @"
Start-Process -FilePath 'wt.exe' -ArgumentList 'new-tab --title "Comfort Shell Setup" powershell.exe -NoExit -ExecutionPolicy Bypass -File "$escapedPath"$resumeArgs'
"@
    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($launcherScript)
    $encoded = [Convert]::ToBase64String($bytes)

    $cmd = "powershell.exe -NoProfile -EncodedCommand $encoded"

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    Set-ItemProperty -Path $key -Name 'ComfortShellResume' -Value $cmd -Force

    Write-Host '  Auto-resume registered: this script will re-launch in Windows Terminal at next login.' -ForegroundColor DarkGray
}

function Clear-ResumeAfterReboot {
    Remove-ItemProperty `
        -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
        -Name 'ComfortShellResume' `
        -ErrorAction SilentlyContinue
}

function Install-WslPlatform {
    # Installs the WSL platform only (no distro). Always requires a reboot; caller must return.
    Write-Host ''
    Write-Host 'WSL is not installed on this machine.' -ForegroundColor Yellow
    Write-Host 'WSL is required to run the Comfort Shell bootstrap.' -ForegroundColor Yellow
    Write-Host ''

    if (-not (Read-YesNo -Prompt 'Would you like to install WSL now?' -Default $true)) {
        Write-Host ''
        Write-Host 'Skipping WSL installation. The Comfort Shell flow requires WSL,' -ForegroundColor Yellow
        Write-Host 'so nothing was changed on this machine.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'To install WSL manually:  wsl --install --no-distribution' -ForegroundColor Yellow
        Write-Host 'Then re-run this script.' -ForegroundColor Yellow
        return
    }

    Write-Host 'Installing WSL platform...' -ForegroundColor Cyan
    $wslExit = Invoke-NativeConsole -FilePath 'wsl.exe' -ArgumentList @('--install', '--no-distribution')
    Write-Host ''

    if ($wslExit -ne 0) {
        # Skip auto-resume on failure so a reboot doesn't repeat the same error.
        Write-Host '---------------------------------------------------------------' -ForegroundColor Red
        Write-Host "  WSL installation failed or was cancelled (exit code $wslExit)." -ForegroundColor Red
        Write-Host ''
        Write-Host '  Review the output above for the underlying error, then re-run' -ForegroundColor Yellow
        Write-Host '  this script. To install WSL by hand:' -ForegroundColor Yellow
        Write-Host '    wsl --install --no-distribution' -ForegroundColor Yellow
        Write-Host '---------------------------------------------------------------' -ForegroundColor Red
        Write-Host ''
        return
    }

    Write-Host '---------------------------------------------------------------' -ForegroundColor Green
    Write-Host '  WSL platform installed! A reboot is required.' -ForegroundColor Green
    Write-Host '' -ForegroundColor Green
    Write-Host '  After rebooting, this script will auto-resume to pick a' -ForegroundColor Green
    Write-Host '  Linux distro and finish setup.' -ForegroundColor Green
    Write-Host '---------------------------------------------------------------' -ForegroundColor Green
    Write-Host ''

    # Arm auto-resume so a manual reboot still picks up where we left off.
    Set-ResumeAfterReboot -ScriptPath $PSCommandPath

    if (Read-YesNo -Prompt 'Reboot now?' -Default $true) {
        Write-Host 'Rebooting in 10 seconds... (Ctrl+C to cancel)' -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    } else {
        Write-Host 'Reboot when ready; the script will resume automatically after you log in.' -ForegroundColor Yellow
    }
}

function Install-NewDistro {
    param([string]$Name)

    $maxAttempts = 3

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Host ''
        if ($attempt -eq 1) {
            Write-Host "Installing $Name..." -ForegroundColor Cyan
        } else {
            Write-Host "Installing $Name (attempt $attempt of $maxAttempts)..." -ForegroundColor Cyan
        }

        $exitCode = Invoke-NativeConsole -FilePath 'wsl.exe' -ArgumentList @('--install', '-d', $Name, '--no-launch')
        Write-Host ''

        if ((@(Get-WslSupportedDistros)) -contains $Name) { return $Name }

        if ($attempt -lt $maxAttempts) {
            $delay = if ($attempt -eq 1) { 5 } else { 15 }
            Write-Host "  Install failed (exit code $exitCode). Retrying in $delay seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
        }
    }

    Write-Host ''
    Write-Host '---------------------------------------------------------------' -ForegroundColor Red
    Write-Host "  Failed to install '$Name' after $maxAttempts attempts." -ForegroundColor Red
    Write-Host '---------------------------------------------------------------' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Common causes:' -ForegroundColor Yellow
    Write-Host '    - DNS failure (Wsl/InstallDistro/WININET_E_NAME_NOT_RESOLVED)'
    Write-Host '    - Corporate proxy or firewall blocking the WSL distro download'
    Write-Host '    - VPN dropping the connection mid-transfer'
    Write-Host '    - Temporary outage on the Microsoft endpoint'
    Write-Host ''
    Write-Host '  To retry, run this script again:' -ForegroundColor Yellow
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { 'install.ps1' }
    Write-Host "    powershell.exe -File `"$scriptPath`""
    Write-Host ''
    return $null
}

function Select-ExistingOrInstallDistro {
    param([string[]]$Existing)

    Write-Host ''
    Write-Host 'Existing WSL distros:' -ForegroundColor Cyan
    Write-Host ''
    $i = 1
    foreach ($d in $Existing) {
        Write-Host ("  {0,2}) {1}" -f $i, $d)
        $i++
    }
    $newOption = $Existing.Count + 1
    Write-Host ("  {0,2}) Install a new distro" -f $newOption) -ForegroundColor DarkGray
    Write-Host ''

    if ($script:NonInteractive) {
        Write-Host "Using existing distro: $($Existing[0]) (auto; -NonInteractive in effect)" -ForegroundColor DarkGray
        return $Existing[0]
    }

    Reset-TerminalInputMode
    while ($true) {
        $answer = (Read-Host "Pick a distro [$($Existing[0])]").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Existing[0] }

        if ($answer -match '^\d+$') {
            $idx = [int]$answer
            if ($idx -ge 1 -and $idx -le $Existing.Count) {
                return $Existing[$idx - 1]
            }
            if ($idx -eq $newOption) {
                $online = Select-WslDistro -DefaultName 'Ubuntu'
                return Install-NewDistro -Name $online
            }
        }

        if ($Existing -contains $answer) { return $answer }

        Write-Host "  Invalid choice." -ForegroundColor Yellow
    }
}

function Resolve-Distro {
    $existing = @(Get-WslSupportedDistros)

    if ($Distro) {
        if (-not ($Distro -like 'Ubuntu*')) {
            throw "Comfort Shell currently supports Ubuntu only. Requested: '$Distro'."
        }
        if ($existing -contains $Distro) {
            Write-Host "Using requested distro: $Distro" -ForegroundColor Cyan
            return $Distro
        }
        Write-Host "Requested distro '$Distro' is not installed; installing it..." -ForegroundColor Cyan
        return Install-NewDistro -Name $Distro
    }

    if ($existing.Count -eq 0) {
        Write-Host ''
        Write-Host 'No Ubuntu distros found. Pick one to install:' -ForegroundColor Yellow
        $online = Select-WslDistro -DefaultName 'Ubuntu'
        return Install-NewDistro -Name $online
    }

    return Select-ExistingOrInstallDistro -Existing $existing
}

function Get-WslDefaultUser {
    # Registry probe first to avoid cold-starting WSL (and triggering OOBE) on fresh distros.
    param([string]$DistroName)

    $lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $lxssRoot)) { return '' }

    $uid = $null
    foreach ($entry in Get-ChildItem -LiteralPath $lxssRoot -ErrorAction SilentlyContinue) {
        $props = Get-ItemProperty -LiteralPath $entry.PsPath -ErrorAction SilentlyContinue
        if ($props -and $props.DistributionName -eq $DistroName) {
            if ($null -ne $props.DefaultUid) { $uid = [int]$props.DefaultUid } else { $uid = 0 }
            break
        }
    }

    if ($null -eq $uid) { return '' }
    if ($uid -eq 0) { return 'root' }

    # Resolve the non-root UID to a username.
    $raw = ((& wsl.exe -d $DistroName -- whoami) 2>$null) -replace "`0", ''
    $line = ($raw | Where-Object { $_ } | Select-Object -First 1)
    if ($line) { return $line.Trim() }
    return ''
}

function Invoke-ComfortShellBootstrap {
    param([string]$DistroName)

    $bootstrapScript = Join-Path $PSScriptRoot 'comfort-shell-bootstrap.sh'
    if (-not (Test-Path -LiteralPath $bootstrapScript)) {
        throw "Bootstrap script not found: $bootstrapScript"
    }

    # Stage to local temp so WSL can read the script regardless of source drive.
    $stagedScript = Join-Path $env:TEMP ("comfort-shell-bootstrap-" + [guid]::NewGuid().ToString('N') + ".sh")
    Copy-Item -LiteralPath $bootstrapScript -Destination $stagedScript -Force

    try {
        $escapedForBash = $stagedScript -replace "'", "'\''"
        $wslpathCmd = "wslpath -u '$escapedForBash'"
        $rawWslPath = ((& wsl.exe -d $DistroName bash -c $wslpathCmd) 2>$null) -replace "`0", ''
        $wslScriptPath = $rawWslPath | Where-Object { $_ } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($wslScriptPath)) {
            throw "wslpath could not convert '$stagedScript' inside '$DistroName'."
        }
        $wslScriptPath = $wslScriptPath.Trim()

        $bsArgs = @()
        if ($NonInteractive) { $bsArgs += '--non-interactive' }
        $bsArgs += $BootstrapArgs
        $quotedArgs = ($bsArgs | ForEach-Object { "'$($_ -replace "'", "'\''")'" }) -join ' '

        Write-Host ''
        Write-Host '--- Running Comfort Shell bootstrap in WSL... ---' -ForegroundColor Cyan
        Write-Host ''

        $wslScriptPathQuoted = "'" + ($wslScriptPath -replace "'", "'\''") + "'"

        $bashCmd = "set -euo pipefail; cp $wslScriptPathQuoted ~/comfort-shell-bootstrap.sh && sed -i 's/\r$//' ~/comfort-shell-bootstrap.sh && chmod +x ~/comfort-shell-bootstrap.sh && ~/comfort-shell-bootstrap.sh $quotedArgs"
        $bootstrapExit = Invoke-NativeConsole -FilePath 'wsl.exe' `
            -ArgumentList @('-d', $DistroName, '--', 'bash', '-lc', $bashCmd)
        if ($bootstrapExit -ne 0) {
            throw "Comfort Shell bootstrap failed inside '$DistroName' (exit code $bootstrapExit). Review the output above and re-run this script."
        }
    }
    finally {
        Remove-Item -LiteralPath $stagedScript -Force -ErrorAction SilentlyContinue
    }
}

function Install-NerdFont {
    $ErrorActionPreference = 'Stop'

    $Version     = '2407.24'
    $WantedFonts = @('CascadiaCodeNF.ttf', 'CascadiaMonoNF.ttf')
    $zipUrl      = "https://github.com/microsoft/cascadia-code/releases/download/v$Version/CascadiaCode-$Version.zip"
    $workDir     = Join-Path $env:TEMP "CascadiaCode-$Version"
    $zipPath     = Join-Path $workDir 'CascadiaCode.zip'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    $fontsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $regPath  = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    New-Item -ItemType Directory -Path $fontsDir -Force | Out-Null

    Write-Host "Downloading $zipUrl ..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Drawing

    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($name in $WantedFonts) {
            $entry = $zip.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $entry) { Write-Warning "Not found in archive: $name"; continue }

            $dest = Join-Path $fontsDir $name
            Write-Host "Installing $name -> $dest"
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)

            $pfc = New-Object System.Drawing.Text.PrivateFontCollection
            try {
                $pfc.AddFontFile($dest)
                $family = $pfc.Families[0].Name
            } finally { $pfc.Dispose() }

            $regName = "$family (TrueType)"
            New-ItemProperty -Path $regPath -Name $regName -Value $dest -PropertyType String -Force | Out-Null
            Write-Host "  registered as '$regName'"
        }
    }
    finally {
        $zip.Dispose()
    }

    Remove-Item $zipPath -Force
    Write-Host "`nDone. Restart any running apps (terminal, editors) to pick up the new fonts."
}

function Install-TerminalProfile {
    param([string]$DistroName)

    $fragmentsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\ComfortShell'
    New-Item -ItemType Directory -Path $fragmentsDir -Force | Out-Null

    # Per-distro file + GUID so multiple distros produce coexisting profiles.
    $slug = (($DistroName -replace '[^a-zA-Z0-9]+', '-').Trim('-')).ToLower()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'default' }
    $fragmentFile = Join-Path $fragmentsDir "comfort-shell-$slug.fragment.json"

    $sunglasses = [string]::new(@([char]0xD83D, [char]0xDE0E))

    # Deterministic GUID per distro: re-runs update in place, different distros coexist.
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hashBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("comfort-shell:$DistroName"))
    } finally {
        $md5.Dispose()
    }
    $profileGuid = "{$([guid]::new($hashBytes).ToString().ToLower())}"

    $fragment = @{
        profiles = @(
            @{
                guid            = $profileGuid
                name            = "Comfort Shell - $DistroName"
                icon            = $sunglasses
                commandline     = "wsl.exe -d $DistroName"
                startingDirectory = '~'
                colorScheme     = 'Comfort Shell Dark'
                cursorShape     = 'bar'
                hidden          = $false
                font            = @{
                    face = 'JetBrainsMono Nerd Font'
                    size = 13
                }
            }
        )
        schemes = @(
            @{
                name            = 'Comfort Shell Dark'
                background      = '#1E1E2E'
                foreground      = '#CDD6F4'
                cursorColor     = '#A6E3A1'
                selectionBackground = '#45475A'
                black           = '#45475A'
                red             = '#F38BA8'
                green           = '#A6E3A1'
                yellow          = '#F9E2AF'
                blue            = '#89B4FA'
                purple          = '#CBA6F7'
                cyan            = '#94E2D5'
                white           = '#BAC2DE'
                brightBlack     = '#585B70'
                brightRed       = '#F38BA8'
                brightGreen     = '#A6E3A1'
                brightYellow    = '#F9E2AF'
                brightBlue      = '#89B4FA'
                brightPurple    = '#CBA6F7'
                brightCyan      = '#94E2D5'
                brightWhite     = '#A6ADC8'
            }
        )
    }

    $fragment | ConvertTo-Json -Depth 8 | Out-File -FilePath $fragmentFile -Encoding Utf8

    # Touch settings.json to trigger WT's hot-reload (re-scans Fragments\*.json).
    $settingsCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    $nudged = $false
    foreach ($settingsPath in $settingsCandidates) {
        if (Test-Path -LiteralPath $settingsPath) {
            try {
                (Get-Item -LiteralPath $settingsPath).LastWriteTime = Get-Date
                $nudged = $true
            } catch {
            }

        }
    }

    Write-Host ''
    Write-Host '--- Windows Terminal profile installed ---' -ForegroundColor Cyan
    Write-Host "  Profile: Comfort Shell - $DistroName" -ForegroundColor Green
    Write-Host "  Distro:  $DistroName"
    Write-Host "  File:    $fragmentFile" -ForegroundColor DarkGray
    Write-Host ''
    if ($nudged) {
        Write-Host '  Open Windows Terminal: the new profile is available in the dropdown.' -ForegroundColor Green
    } else {
        Write-Host '  Restart Windows Terminal to see the new profile.' -ForegroundColor Yellow
    }
}

# --- Main flow ---------------------------------------------------------------

Assert-WindowsTerminal
Clear-ResumeAfterReboot

Step "Ensuring WSL platform"
if (-not (Test-WslReady)) {
    Install-WslPlatform
    return
}

Step "Choosing Ubuntu distro"
$Distro = Resolve-Distro
if (-not $Distro) { return }

# Capture BEFORE bootstrap so the final message reflects the original state.
$preBootstrapUser = Get-WslDefaultUser -DistroName $Distro

Step "Running Comfort Shell bootstrap in $Distro"
Invoke-ComfortShellBootstrap -DistroName $Distro

Step "Installing JetBrainsMono Nerd Font"
Install-NerdFont

Step "Installing Windows Terminal profile"
Install-TerminalProfile     -DistroName $Distro

Set-ConsoleTitle "Comfort Shell · ready"

Write-Host ''
Write-Host '---------------------------------------------------------------' -ForegroundColor Green
$sun = [string]::new(@([char]0xD83D, [char]0xDE0E))
Write-Host "  $sun Comfort Shell install complete" -ForegroundColor Green
Write-Host '---------------------------------------------------------------' -ForegroundColor Green
if ($preBootstrapUser -eq 'root' -or [string]::IsNullOrWhiteSpace($preBootstrapUser)) {
    Write-Host ''
    Write-Host '  First Terminal launch will:' -ForegroundColor Cyan
    Write-Host "    1. Prompt you to create a UNIX username and password for $Distro"
    Write-Host '    2. Drop you into zsh with your dotfiles already in place'
    Write-Host '    3. Install Homebrew (a few minutes, one-time)'
    Write-Host ''
    Write-Host "  Open the 'Comfort Shell $sun ($Distro)' profile in Windows Terminal to begin." -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host "  Open the 'Comfort Shell $sun ($Distro)' profile in Windows Terminal." -ForegroundColor Yellow
    Write-Host "  You're already a regular user ($preBootstrapUser); no further setup needed." -ForegroundColor DarkGray
}
Write-Host ''


# SIG # Begin signature block
# MIIncAYJKoZIhvcNAQcCoIInYTCCJ10CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAl2R/WuguAGspB
# kPiRAxVpnv+2qIofscJzzI5JNeNcvKCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghn9MIIZ+QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZI
# hvcNAQkEMSIEIJEeiIvYYWH9NrtKez0H6put4V3EbZ6KwT1GgRSWXSxGMEIGCisG
# AQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAdvG/W6/vX1MIpq2AR/ub
# y8y3Os8ORcnpvsNvvG7vlK0+mxqkqZ8mxBwm3CmuT1ok/tkAGIPjdvFbolLNK7NJ
# +EDSE3rZPBgg9iw4fSO0DXln5IGRHpFlMlqjvB4+OZxQQQ1Eb4iizR1q+mRs++Os
# CgVubEQP8yIT4Ms6+BFbMJijSmuRF8Ny3W5+S08xGKUhILEIf14sDTOYyLklmmJv
# cSMOBUPqDShukU7GPAAbujPmkeMnfsRyL2vOR/47xsgfl5ZzOBuZQvfWsiWWYb12
# puIsW2ImCPpsBLnkWXvpyGit9rZ1oUn+p+w9VN2ivNLOU8no7bb01BbvkbZAZaxW
# wKGCF68wgherBgorBgEEAYI3AwMBMYIXmzCCF5cGCSqGSIb3DQEHAqCCF4gwgheE
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCC+SKtG04MT6P9XLCHB
# N7S2fyUq47JcIBG4FMdc5Dh+1QIGahDtiXSRGBMyMDI2MDUyMzAxMDMyNS4wNTFa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0QzFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf0wggcoMIIFEKAD
# AgECAhMzAAACGCXZkgXi5+XkAAEAAAIYMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyNVoXDTI2MTExMzE4
# NDgyNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjRDMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAsdzo6uuQJqAfxLnvEBfIvj6knK+p6bnMXEFZ/QjPOFywlcjD
# fzI8Dg1nzDlxm7/pqbvjWhyvazKmFyO6qbPwClfRnI57h5OCixgpOOCGJJQIZSTi
# Mgui3B8DPiFtJPcfzRt3FsnxjLXwBIjGgnjGfmQl7zejA1WoYL/qBmQhw/FDFTWe
# bxfo4m0RCCOxf2qwj31aOjc2aYUePtLMXHsXKPFH0tp5SKIF/9tJxRSg0NYEvQqV
# ilje8aQkPd3qzAux2Mc5HMSK4NMTtVVCYAWDUZ4p+6iDI9t5BNCBIsf5ooFNUWtx
# CqnpFYiLYkHfFfxhVUBZ8LGGxYsA36snD65s2Hf4t86k0e8WelH/usfhYqOM3z2y
# aI8rg08631IkwqUzyQoEPqMsHgBem1xpmOGSIUnVvTsAv+lmECL2RqrcOZlZax8K
# 0aiij8h6UkWBN2IA/ikackTSGVRBQmWWZuLFWV/T4xuNzscC0X7xo4fetgpsqaEA
# 0jY/QevkTvLv4OlNN9eOL8LNh7Vm0R65P7oabOQDqtUFAwCgjgPJ0iV/jQCaMAcO
# 3SYpG5wSAYiJkk4XLjNSlNxU2Idjs1sORhl7s7LC6hOb7bVAHVwON74GxfFNiEIA
# 6BfudANjpQJ0nUc/ppEXpT4pgDBHsYtV8OyKSjKsIxOdFR7fIJIjDc8DvUkCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBQkLqHEXDobY7dHuoQCBa4sX7aL0TAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAnkjRhjwPgdoIpvt4YioT/j0LWuBxF3ARBKXDENgg
# raKvC0oRPwbjAmsXnPEmtuo5MD8uJ9Xw9eYrxqqkK4DF9snZMrHMfooxCa++1irL
# z8YoozC4tci+a4N37Sbke1pt1xs9qZtvkPgZGWn5BcwVfmAwSZLHi2CuZ06Y0/X+
# t6fNBnrbMVovNaDX4WPdyI9GEzxfIggDsck2Ipo4VXL/Arcz7p2F7bEZGRuyxjgM
# C+woCkDJaH/yk/wcZpAsixe4POdN0DW6Zb35O3Dg3+a6prANMc3WIdvfKDl75P0a
# qcQbQAR7b0f4gH4NMkUct0Wm4GN5KhsE1YK7V/wAqDKmK4jx3zLz3a8Hsxa9HB3G
# yitlmC5sDhOl4QTGN5kRi6oCoV4hK+kIFgnkWjHhSRNomz36QnbCSG/BHLEm2GRU
# 9u3/I4zUd9E1AC97IJEGfwb+0NWb3QEcrkypdGdWwl0LEObhrQR9B1V7+edcyNms
# X0p2BX0rFpd1PkXJSbxf8IcEiw/bkNgagZE+VlDtxXeruLdo5k3lGOv7rPYuOEao
# ZYxDvZtpHP9P36wmW4INjR6NInn2UM+krP/xeLnRbDBkm9RslnoDhVraliKDH62B
# xhcgL9tiRgOHlcI0wqvVWLdv8yW8rxkawOlhCRqT3EKECW8ktUAPwNbBULkT+oWc
# vBcwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
# CwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYD
# VQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAe
# Fw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA5OGm
# TOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/XE/H
# ZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1hlDc
# wUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7M62A
# W36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3KNi1w
# jjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy1cCG
# MFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF803RKJ
# 1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQcNIIP
# 8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahhaYQFz
# ymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkLiWHz
# NgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV2xo3
# xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIGCSsG
# AQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUpzxD/
# LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBTMFEG
# DCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8G
# A1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQw
# VgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9j
# cmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUF
# BwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQEL
# BQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1OdfC
# cTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYAA7AF
# vonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbzaN9l
# 9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6LGYnn
# 8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3mSj5m
# O0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0SCyx
# TkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxkoJLo4
# S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFmPWn9
# y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC4822rpM
# +Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7vzhw
# RNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWDCCAkAC
# AQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0QzFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAnWtGrXWiuNE8QrKfm4CtGr57z+mggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO27bAwwIhgPMjAyNjA1MjIy
# MzU4MDRaGA8yMDI2MDUyMzIzNTgwNFowdjA8BgorBgEEAYRZCgQBMS4wLDAKAgUA
# 7btsDAIBADAJAgEAAgEJAgH/MAcCAQACAhJgMAoCBQDtvL2MAgEAMDYGCisGAQQB
# hFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAw
# DQYJKoZIhvcNAQELBQADggEBAIdr508XuAztA+vpoJwGbUU00inNpQN8y67r7Ajq
# mEAGQ9pgnlXMipAP7EXygCf8BfPYGKYb9ZdfsfT6ydhXoBuqx8XpzvFZyesYvnWl
# iudgYuKk6glC3mt7t0n1tvnUno1z6ov7XRzVUwgpG9LEC1UuZJngtBTt34mK9viq
# GMzm6Ul0kj9Q97ZEhv5MFmMMKIB2qydPACTXXfacICIA/85y29yiuSNrIiTU0mcF
# QaC5k9VAfQrTPvjLetX1lv5WiEtPVKeHfzILLZLMI03/uAFCgbDPlXfDLYwVvJGx
# ccDKJlqsKta4LGs5XoVz+yS+SZdwDG+9DsPdJSzSl7SfuVgxggQNMIIECQIBATCB
# kzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAhgl2ZIF4ufl5AAB
# AAACGDANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJ
# EAEEMC8GCSqGSIb3DQEJBDEiBCAApG2+5+0dMU7BTawpnhgl1vV6j0zMiDhS3zis
# lInmGTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIJkT3Im45Mi0jBZoRLqX
# MYorVdxKjPXKdHNo5XPH14VqMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# UENBIDIwMTACEzMAAAIYJdmSBeLn5eQAAQAAAhgwIgQgdLZLxgwIuTn1XEA+zF10
# LWPRbDvdQu5QnFfEKQbZYWgwDQYJKoZIhvcNAQELBQAEggIAgj0VK6KhPIGLVocF
# Hwy+cWliRtVmkoikm59v/p+IchGj/pDu9bzJeDlMKVFdW1jyy3EMc3Nfm6mFfsSw
# eotC7DAVQcVtemsfcGYk3acj7Cj1HwIcMllKbLybY/JkgY/e3MuIJcdHNmiDJHbM
# 4sehHmJIGgJMLVXY8iZ7/c9vqeNdn1+hFIKrkmE2xkPEMPy63+EcPN4oUWcRK2Q5
# PSQp9naIecc6RR8nred3Exc+OXzHyvjWXEifIP30JJIT/DOO8rqJhTgkrQidbAau
# 5tBsd2nurqiAoXO9IfdlzFxYxAkb3V81ABYMjwiVwgr7mOh9kd2KdyOayLHcX/ZE
# NOW/PjgRex8n0A+Mj5FJ2TNan1cRJk6FRG3QIz+gp7U76VdDNXjJlxvUbWW7333+
# ipXY+cQF2rLG37PF0WZ9MEnsnJYFBBrX4HzXcm9VCZUIim5sKzoBaN/ukzYFo+g/
# wTBiW4GX4BH/zFi0y2uZJO+21dD4RkCoGOglV/McbUYXP/kX2cp4lkirTEsqeL1t
# DkuQu5xz4LboCnK8KuiJ4QSzGBN1KzGIo/p3XHx97sbyxeVhIBoyiw7QvVRXlEyb
# nDT14ogw5fvy00v59TbrxAniOEjl+6985XUqEQ3M3BuXADLzNErURA1qcCPWuOL/
# gHlab7bZ5P0SCHCEw3i86uWlf40=
# SIG # End signature block
