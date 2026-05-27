<#
.SYNOPSIS
  One-shot "fix it" script: turn on `winget configure` on a machine where
  it isn't working yet.

.DESCRIPTION
  This is the single remediation path for the three failure modes that
  `assert-winget-configure.ps1` detects. The CmdPal extension's red
  "winget configure is unavailable" banner launches this script; humans
  can also run it by hand. Keeping the logic here (not duplicated in C#)
  means any future tweak -- e.g. dropping the VCRedist install once
  AppInstaller ships it transitively -- only has to happen in one place.

  What it does, in order:

    1. Self-elevates via `Start-Process -Verb RunAs` if not already admin.
       `winget configure --enable` flips a machine-wide flag and needs
       elevation; `Microsoft.VCRedist.2015+.x64` likewise.
    2. Runs `winget configure --enable` -- the supported first-party way
       to turn the `configure` subcommand on. Ignores "already enabled"
       errors so re-runs are a safe no-op.
    3. Installs `Microsoft.VCRedist.2015+.x64` -- the PackageManager
       configure path transitively depends on the 2015+ x64 redistributable
       (AppInstaller does not always pull it in on its own). Skipped when
       already present.
    4. Re-runs the assert to confirm the fix took.

.PARAMETER NoElevate
  Internal switch used by the self-elevation path to avoid infinite
  re-elevation loops. Do not set by hand.

.PARAMETER SkipVCRedist
  Skip step (3). Useful once Microsoft ships a configure path that no
  longer needs VCRedist -- flip this on and we keep the rest of the
  remediation.

.EXAMPLE
  # From a normal PowerShell -- triggers a UAC prompt, then runs.
  .\enable-winget-configure.ps1

.EXAMPLE
  # From an already-elevated PowerShell (e.g. inside a VM bootstrap).
  .\enable-winget-configure.ps1 -NoElevate
#>

[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $SkipVCRedist,

    # Internal: set only by the self-elevation path below so the exit
    # pause fires only when we're running in a fresh window that would
    # otherwise close. Not part of the public surface; users running the
    # script themselves (elevated or not) should not pass this.
    [switch] $FromRelaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Force UTF-8 on the console + external pipe encodings. Windows
# PowerShell 5.1 defaults to the ANSI code page (1252) which mangles
# winget's braille-pattern spinner glyphs into scrolling mojibake.
# Safe no-op on pwsh 7. See issue #15.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

# Also force the OS-level console code page to 65001 (UTF-8) via chcp.
# [Console]::OutputEncoding alone is not always sufficient under Windows
# PowerShell 5.1 -- particularly in a freshly-spawned elevated conhost,
# where winget's own stdout goes through the OS console code page (1252
# by default on en-US). That causes the VCRedist download progress bar's
# block glyphs (U+2588) to render as "ûÆ" mojibake. See issue #22.
try {
    $null = cmd /c 'chcp 65001 >nul 2>&1'
} catch { }

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    if ($NoElevate) {
        throw 'Not running as Administrator and -NoElevate was passed. Re-launch from an elevated PowerShell.'
    }

    Write-Host ''
    Write-Host 'This fix needs to run elevated (UAC prompt will appear).' -ForegroundColor Yellow
    Write-Host 'Launching an elevated PowerShell...' -ForegroundColor Yellow
    Write-Host ''

    $forwardedArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-NoElevate', '-FromRelaunch')
    if ($SkipVCRedist) { $forwardedArgs += '-SkipVCRedist' }

    try {
        Start-Process -FilePath 'pwsh.exe' -ArgumentList $forwardedArgs -Verb RunAs -Wait
    } catch {
        # Fall back to Windows PowerShell 5.1 if pwsh isn't installed.
        Start-Process -FilePath 'powershell.exe' -ArgumentList $forwardedArgs -Verb RunAs -Wait
    }
    return
}

Write-Host ''
Write-Host '=== enable-winget-configure ===' -ForegroundColor Cyan
Write-Host ''

# --- Step 1: winget configure --enable ----------------------------------
Write-Host 'Step 1/3: winget configure --enable' -ForegroundColor Cyan
try {
    & winget configure --enable --disable-interactivity --accept-source-agreements 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        # Some winget builds return non-zero on "already enabled" -- inspect
        # stderr instead of hard-failing on the exit code alone.
        Write-Host "  (exit=$LASTEXITCODE -- if already enabled this is benign)" -ForegroundColor DarkYellow
    }
} catch {
    Write-Warning "winget configure --enable raised: $($_.Exception.Message)"
}

# --- Step 2: VCRedist 2015+ x64 -----------------------------------------
if ($SkipVCRedist) {
    Write-Host ''
    Write-Host 'Step 2/3: SKIPPED (via -SkipVCRedist)' -ForegroundColor DarkYellow
} else {
    Write-Host ''
    Write-Host 'Step 2/3: winget install Microsoft.VCRedist.2015+.x64' -ForegroundColor Cyan
    & winget install `
        --source winget `
        --id 'Microsoft.VCRedist.2015+.x64' `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  (exit=$LASTEXITCODE -- if already installed this is benign)" -ForegroundColor DarkYellow
    }
}

# --- Step 3: re-run the assert to confirm the fix took ------------------
Write-Host ''
Write-Host 'Step 3/3: verifying winget configure is now available' -ForegroundColor Cyan
$assert = Join-Path $PSScriptRoot 'assert-winget-configure.ps1'
if (Test-Path -LiteralPath $assert) {
    & $assert
} else {
    Write-Warning "assert-winget-configure.ps1 not found next to this script; skipping verify."
}

Write-Host ''
Write-Host 'All done. You can close this window.' -ForegroundColor Green
Write-Host ''

# Pause only if we self-elevated into a fresh window that would
# otherwise close before the user could read the output. When invoked
# directly from the user's own shell (elevated or not), the window is
# under the user's control and the pause is pure friction.
if ($FromRelaunch -and $Host.Name -eq 'ConsoleHost') {
    Write-Host 'Press any key to exit...' -ForegroundColor DarkGray
    try { [void][System.Console]::ReadKey($true) } catch { Start-Sleep -Seconds 5 }
}

# SIG # Begin signature block
# MIInUAYJKoZIhvcNAQcCoIInQTCCJz0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAWEoj76p2bgZRE
# qT0f5FvcbwY8rLJ+0CpJ6RaaM8Ufp6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
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
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghndMIIZ2QIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIJ7B5HUfahl3nIJLuaopCYuoCdMJ
# AeoNBBEvp0MDx/juMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAgSfrDwKm93lr8x1z2JqJkmsscXsTkVRsupsfeoMnqMF64+huiSnnWjTpZuVI
# 8DB+K371FsgsxAiD2HZQRWyr0tfvNujg1x6puI4bFd8fTmN1hvEWBpFbO8Ka/Bxl
# HggFc23ApZWOUa2FvVhRcQ7zVmH+bt1Gbo9R+bJ64MDe9l9s/2FwgHBG42iqgwmw
# cKmCNPT22nW1qxEdPJab8fH/sh63Cm0Ubi0tgsy3a5Xjz3/8iu7wOCkifPLTDfPW
# 6oV1gxjeIIOrGD8I1YrwhXiZlkWi9OT8AtMvzQinXBXAcBJgsTjK1vvShXicUYOA
# 7qDTbScWR8F7Ch+56DvfrSghQKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UG
# CSqGSIb3DQEHAqCCF4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCDF/9RWEZ4pSsTN2RAP1Ew+C0ZRq5icp4UXK5VAKM8EcAIGahF0z9TCGBMy
# MDI2MDUyNzIyMTY0Ny45NTdaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1
# NTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEfswggcoMIIFEKADAgECAhMzAAACG9CyuAJn93LPAAEAAAIbMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgx
# NDE4NDgzMFoXDTI2MTExMzE4NDgzMFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjU1MUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjsWd52ZZkzB5Xe5g/l2GsOjA
# z30sg6jVxfFJV+w4xIDVyaI3LO8bIpmzYul3AZHg50UIQ8PrSRZGpQqFkRNu+o3Y
# KJ4g2uGYBRksHnHYR0uVSCQg58ThkYyeplGX3oAvGRVuPIpQtAiTsR76A/gdoU7H
# DwEbb73bJwTyrbKHhR+WaMy9DQHI4k5Qo4+bZDs0kj76bvhJvdGU+S8zxQBp7UAh
# jJnFqKxIusSITE7zCCR422ELhkhVVOFqK2w6h1MAvILe76hxRIcPj0SBL2r8O9tx
# 5njU4+tg2rAdU153pmyhqazdpUccYBE9wDRFUd/e9CoWx7TdnUicB+Mai7RT6qse
# 7e5aGqX1B7bnj/ZHvrrfF+BJEIlS9iDXAUgekvXZ+FZmjvLwP+dN+0/crh++r4e8
# FknF7EX6IJfnmNeDN/68Z59kbaJ1f+P5mnKYfydCeZmxrGpS0taWkDk36D3jPVZf
# lvxrc+1rhCIlM5v9agLEFI12QiBTfpOBOBr3AGCPk+eH0+latjQajug+2/BD12qb
# 82500LQytUWT2ota/HYnRgSv1jvZ0/dml1FsxWYzOnCrjfdB/7N6pNySt4vn+PGN
# 6dFLim7kxos+B9WfQPezJi3fuKyyDAB9zSHPj1Zu8nZfecZJ9um4zj7DFgvJXTDT
# nG5qlG4ZdbFRa/rrfzkCAwEAAaOCAUkwggFFMB0GA1UdDgQWBBS2vp93/lxLppNK
# 8OkauJ2AvNmIUDAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAZkU1XxQD4OTM3GTh
# t32TXShIfPBoMfSsFsBQqFOZqLJOxyJOllIBFpmpvOtGNPkC5Z8ldG8aCpvgFNo/
# jDWeT5FiW53dAj9KnZxpsQ3Pf5fRzSGHRcxEMOdXIVzDJwcZUX0cjfxna7ydNv8e
# XB/Xk6G6SyrR2OH6S1LHMW11m3UvKF+eLjIPl45rximuDCoEd+ad0lOAXA5/vZOK
# N5n/ePYeP0LRchZX0Q6H8n/ZmSPMlbli3MO851Q09RmT/ZGHa+/Fdy+WLDrwcYyk
# V9mUy/4TbwKw6FtdR6ZPHxMdIi1pk8Y2mC/GzCq0LCsH0uTFeQ6Q7Nc3MRmER/3m
# LWUhbaWHgX1FbYchvR22b+Bup+YPR5Q/0BhaaAN6AIBfcGs+u/nJoIByyZKA8cTy
# CmnUI/4vW6D4vywg3XBFf4f2DwFHy/evsC+58KMl+k2wa05X2kK0T/bCPLhaov9Z
# XyobawfNOLYGiauKT2FWvbwZzHIFCTxjBww6Pt5uRvCE/jnUcf/xhlOGMn6iKO9X
# t49vZTE2SfIBk/34iLTRBJ6H7aGPTTQnza3OfWu1/dRycC6Wl5ons3PjnGXTSKSx
# XllJPmg6R/ulGonP/UCYoJ6mN+EXjfyDLPXLqsr91+VTG1rYzRCjPwBFAHv4EIwa
# E0ajCrf75eUGI3+oXU0UP6rloZ8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
# AAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVa
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1
# V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9
# alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmv
# Haus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928
# jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3t
# pK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEe
# HT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26o
# ElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4C
# vEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ug
# poMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXps
# xREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0C
# AwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYE
# FCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtT
# NRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBD
# AEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZW
# y4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAt
# MDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0y
# My5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pc
# FLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpT
# Td2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0j
# VOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3
# +SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmR
# sqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSw
# ethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5b
# RAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmx
# aQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsX
# HRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0
# W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0
# HVUzWLOhcGbyoYIDVjCCAj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo1
# NTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAhoV6r49M4GBd41K1RYB1Z0f4zuCggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO3B4ZswIhgPMjAyNjA1MjcyMTMzMTVaGA8yMDI2MDUyODIxMzMxNVowdDA6Bgor
# BgEEAYRZCgQBMSwwKjAKAgUA7cHhmwIBADAHAgEAAgIpKDAHAgEAAgIR+zAKAgUA
# 7cMzGwIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQAd8PPUx537G7BE4hUv
# HG3RiZN/7HR4b8foyUUaWnt2yZl+Jadp4EPP9hD3WOpmxUWr/DZ/YmpyjjmoO03k
# G8jwR3LanWRJ5YQVsRmmeJWLOzTBytcGNKIA6Kb0W57jarBCxYFafbui0gVDntDz
# AVg5eS7s0kQSgF+kCVBuT0FAdhtacqeWElSaXTClFQNxkpIuTSgc0vciPiGOrPS7
# sPSmvuW51DSqzN6GHLal9ZhQuzi4Zb7YCzUOpDgH/ZoDKYwVmd9am7NRNjPr05sz
# Js83aItrt42z9u7TDONYxRwJ7tRm6oMT1pF10mIx3ZalOaAs4AfcZ/bN2O+KdrQu
# dvqzMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIb0LK4Amf3cs8AAQAAAhswDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgOINWkvrlSwvLtAw/
# /PCWeogWtRLiqmRLKhqdvJ0Z6WswgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCAwJRSVuD2jmMcQCFXdLuJAwDpUVNZ6bc6dfJU83Q2LgDCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACG9CyuAJn93LPAAEAAAIbMCIE
# IPM4rjaXR7ZdNSwK7ejQDuR11Ko9LhrTRkYk7iV+A1AEMA0GCSqGSIb3DQEBCwUA
# BIICABSLFnvO/ZEKMwXg7qOvyvwe2aqh0neDxYIFyoXiGrX7wYauYiMzIFWs3U5Z
# IE+Ux3WJPpmDSwY2ak+yatmwocfD/rhtnxK3IpPHm/VcVT+UdQXBLWPyf9UkUFjm
# dWOduF/6KuSWB2Hva3ycTeXO4+yYzfKZHI1VG0EkdSCVtJWYqCT3Klhw55PUO0Hf
# If5LqHKgZQUm4dYpfclcAiJzH5b9CT083EPX7t9rQxLIBUKYL0cEtfcfxBMT/bfA
# 4yE4mE95rxxyLiSeA0OK3CzXfq1RQz/MASmyC+slq52Ah9GUsVqjmg5ju0vtP2Hh
# A2Qzo8qdmmnnn/qdcipeF6UlTvcIjhQ0ikrXaNytpWVgofXWdJXsQBHaQQLa5VeH
# gcnlBctFvYCFxxIngsI303NoBwbRHMdGDIf/k32gJht4W1zX+Ne9IBobQ0jx9F4J
# neitfs4FAPshzUh5mu8sVC/q9xB0wrXJIw8Nm0z47+aWjUD3Fl2PfxHewPaoXT2d
# wTJTaJVvI1uV7oL7wnJmKpw1i23cAt8BPEAJIfqUwB81pLXcM6kDefGMOOAH5M/p
# ZITUcwD8gnbeKZF44HzJb5deah4+ckyEuQpkI5vVtiftRfJS71Hcw06QXCIIGFwg
# nImDXtuEV7P8cs2+ODYc28Qcyjk1Kgcg2O5uyY6UmITwHYxv
# SIG # End signature block
