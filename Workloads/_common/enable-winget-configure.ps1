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
# MIInRQYJKoZIhvcNAQcCoIInNjCCJzICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAWEoj76p2bgZRE
# qT0f5FvcbwY8rLJ+0CpJ6RaaM8Ufp6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnhMIIZ3QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIJ7B5HUf
# ahl3nIJLuaopCYuoCdMJAeoNBBEvp0MDx/juMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAgsvPnCsY+1wo4F8CddM3qE/QLXOwevcwy3azK4mz
# zLbg7GI/NzR2JIVpX0IgHKplJOWJCUYX7xpKdxJkghn0l/aVSDOfMpjOdg8H+y/s
# ZsDYqXEebfDJlXciQoZd0IZ9IsPFee9gcGSRWrkee7fl4Du+DrLcOHvlufCmL1BE
# 1LA8VZMa0BbmixNPeiTzT+w/+RVouP3JBVQNYOkJXurRuFE7dxaL2ysdbBYVpCUo
# woyabQxGiZzUeblnC2jQVAgjMnJyK+7uncLxzzdm4x7HBvFUtKhiL5/45WkFlziT
# eQsif6PdoZrF4hXqnO2tLnfjhUHTqz9nw4SN/aHVEivQ+KGCF5MwghePBgorBgEE
# AYI3AwMBMYIXfzCCF3sGCSqGSIb3DQEHAqCCF2wwghdoAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFRBgsqhkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCDw2FPB8wmJCtHxSERpcnwXRzYeetbcmVNmuttz
# BM/RpgIGagyGVpgNGBIyMDI2MDUyMzAxMDMyNC43MlowBIACAfSggdGkgc4wgcsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjpEQzAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZaCCEeowggcgMIIFCKADAgECAhMzAAACJDuEIbAsrGQiAAEAAAIk
# MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4X
# DTI2MDIxOTE5Mzk1OVoXDTI3MDUxNzE5Mzk1OVowgcsxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNh
# IE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpEQzAwLTA1RTAt
# RDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKPpbdRpDZmviE29LLuPtQw8VXKz
# toTEYH4kXDKTPNeDeNrJib2A4tcnu02FTZ6aGstAI5lyAu/PoWSqaCHNDHOaSAq0
# tiIpoTOGiA79x7SVOF0s11W0zBA5iCj5e1cBlxWIFfgtweTfxG6xmIXvDFJrm38v
# GJzTj5n+GXLWAlCkh4UOqnhr0+4u3yux8fTm9b2lT26uIZ0PF8lef+Vzj0LFteoD
# cRfXsvbhtzq36YW48MAkoqlqLddeoXacmWlM992sDb2xZNI0qKD0K0ELm3NCPR+V
# uxr/jCo7275GS7CllvdvuqdbkV0WsNHW9CZd+OXJQ/1k7fzzf03BK6Ie2+wUI2RM
# 0hfw4vldWrWewrK7/8Z4hn1i7Gx8sF52obTbg8MRHKsCzSm99RY4tqlVBqMc+gKe
# 41Iq9sSHuzkhDRiC6kaOL4fusgPHb+YgQj7pDxbAG2TdjHKGOPQZfD3T2LQSRORX
# LL7XIAOPBILxvDaozj4xziHLK2VnNJzQg9QGrVgadjAKMjBrn+UxbSkWf8ekl0Hp
# d4y5O1hM6lo+ijrgWNCvItdaN3ii+nDmU7Dtf6/cT2TA31UEL7AkRIEQILWBkwJL
# lNpXB8TXDimdddvWpP1uOBGw+Dh2SWu5RN2if/dI23RrRDk1zZSX6syVDFeg/2Kx
# fAw2co7kkmSpENFVAgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQUcx+RfW7/MksIx7SC
# piK3HW0Ad6gwHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0f
# BFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsG
# AQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAD7AdJuaEikzwJFVni2T
# rbiFD4t1lcTiqh5C6LvsJ41reOrUU7OLsxEqSSjp2IQMdc81a8BqDFqy0J7A/Obl
# MI2HWzioIeHhHYb+vjzBT8ylzrz9YOYnLkIhCf8XCmzWxs1QS7sHODTTipQshUn3
# reOj9qbjHAqDCH69JUvv92Gx9Pt2+GlF11tgtBMdmDC40HpCFwQSyCiAtXA1GPft
# URZkOLCgx3HILthitC7owJW2LMec62RJfsWoiiLqOVx+p+jrX24Mf2vyTaoA4cJ4
# QCopcrKYhcMxwYaUR0MVtiINmA8IEzQgeAB6KVRKifTvCMe7R7SywGa0Fp89vgZ3
# 7kW5GdYbdcZ73U0KksqqYVr/gaRXP04zNlSDyhzPEL/glPcd/jkkS2zNOhfA2yRX
# ck0Jy7Ygi2vpIkeaLcQNUAMNFI2F3MVGliamUYSU+XkZGg+0mIMS9Ehu/kwUojDb
# H2Cd6F/ki8GMLhmQGD7gZOmoYTeaafMXech6Q6Rfi6DT/SY3YJJquG5KL02Ycg6l
# Q3Z5AdS2BNv/4aaruCS0IzAir8k4JgiJNiqm/WhuMAYp1Yw8KuVLI0CzSNljOSFr
# nfnXnw0zH7AEa+x8WhWwIwbk5ynq9boJfK5ZFtRWoxTU6tBsd93LMmluEkLU9sBk
# jIkJs35UGANMDNMpjzDghJLBMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAA
# AAAAFTANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUg
# QXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAOThpkzntHIhC3miy9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2
# AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+uDZnhUYjDLWNE893MsAQGOhgfWpS
# g0S3po5GawcU88V29YZQ3MFEyHFcUTE3oAo4bo3t1w/YJlN8OWECesSq/XJprx2r
# rPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k
# 45GPsjksUZzpcGkNyjYtcI4xyDUoveO0hyTD4MmPfrVUj9z6BVWYbWg7mka97aSu
# eik3rMvrg0XnRm7KMtXAhjBcTyziYrLNueKNiOSWrAFKu75xqRdbZ2De+JKRHh09
# /SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXftnIv231fgLrbqn427DZM9ituqBJR
# 6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8P0zbr17C89XYcz1DTsEzOUyOArxC
# aC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMYctenIPDC+hIK12NvDMk2ZItboKaD
# IV1fMHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9stQcxWv2XFJRXRLbJbqvUAV6bMUR
# HXLvjflSxIUXk8A8FdsaN8cIFRg/eKtFtvUeh17aj54WcmnGrnu3tz5q4i6tAgMB
# AAGjggHdMIIB2TASBgkrBgEEAYI3FQEEBQIDAQABMCMGCSsGAQQBgjcVAgQWBBQq
# p1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ
# 6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRt
# MBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBB
# MAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP
# 6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWlj
# cm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2
# LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMu
# Y3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38Kq3hLB9nATEkW+Geckv8qW/qXBS2
# Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQdTltuw8x5MKP+2zRoZQYIu7pZmc6U03d
# mLq2HnjYNi6cqYJWAAOwBb6J6Gngugnue99qb74py27YP0h1AdkY3m2CDPVtI1Tk
# eFN1JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQJL1AoL8ZthISEV09J+BAljis9/kp
# icO8F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKp
# W99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP9pEB9s7GdP32THJvEKt1MMU0sHrY
# UP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QB
# jloZkWsNn6Qo3GcZKCS6OEuabvshVGtqRRFHqfG3rsjoiV5PndLQTHa1V1QJsWkB
# RH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0V
# iY1w/ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq
# 0Z4+7X6gMTN9vMvpe784cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1V
# M1izoXBm8qGCA00wggI1AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5
# NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAH
# BgUrDgMCGgMVAKYI8duax4BJ97/9sa1f15Ab7T7joIGDMIGApH4wfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDtuviCMCIYDzIw
# MjYwNTIyMTU0NTA2WhgPMjAyNjA1MjMxNTQ1MDZaMHQwOgYKKwYBBAGEWQoEATEs
# MCowCgIFAO26+IICAQAwBwIBAAICN9wwBwIBAAICFCcwCgIFAO28SgICAQAwNgYK
# KwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQAC
# AwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAQ4OTmbbUkythZdWNxmKuP1Xe8lNKLElo
# O/PQBmGy9aSEmeCDnfLG2xilSkQuYUwxbVnnzRPc9jSIJ8b++P6rKsLViyV9g88c
# CoNpyQQ7YmD+1VYeW2cFurEbB4BcaviR9300Ee3kh5a83t/0p8hQ6UjdiHHir01U
# NkC6TUA8sc+c5nAgGxPjjZFLfqw7SHpyllMB0IAb6WwHH3rp7LUSaQqC67QCGDjE
# TmmyeHcemHLCSBlCapFcKkrafsLcpWk92tWju4H0kBVGTz3QFDKbBWf5nFzYSWpe
# jSiOgkqfgmnGlNSdliyFBZQyc1gV0CGR5Xz9lyHwzgX3wU8ZSNuG1zGCBA0wggQJ
# AgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAk
# BgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACJDuEIbAs
# rGQiAAEAAAIkMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZI
# hvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIFh0xZXzKI9Pbj8YkMMgTmDvOA09KRy/
# ZP+6w3VmpieZMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgSCE9N2qb91HJ
# nQFzNdx2WhUSogJ1yalU1sf0IRXNZI4wgZgwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMAITMwAAAiQ7hCGwLKxkIgABAAACJDAiBCAU/4Nlg9J3qV0C
# 8QNt4r44UW1gaCufoxUSxKQhqJKf8zANBgkqhkiG9w0BAQsFAASCAgBpmah19/Jj
# rbAfMlT0CINMvOvuJYifS9BJ5QYQ0a0EPl1F+QwQYSIv9N6XUBRn2JuzfKBnZXZK
# xGYje9FmPvBpx77t81vnyDgue4vGeAS57OmbHn7uRMDPg3ca+XUU6ow+L04z+x9e
# xdVWBcJHrg5jbI+5L9aTFU0+ZSQ4zuRl8UY40lwQVc93kSaOAJd4qNV33YrSn+K/
# 5NC4I3M5G2wD68XgbX+AjKrESPOZdyAH9k2UwHV7NWvcyd21swedof3ice8JDoOz
# FIPlhdyH2t9xbD/4GdY092UKMgdK9k7fSHP0QTndXfn1qDDI53LruXn/FGdQ/N1c
# 1PgDPTq9HK/sqvzz0+dMvW94OPXEvunE7duDs93/fvnNpaxTnytLI2US+KAsfwyo
# T/rRfKKftWXXX0hW6g4vvsOwRZVYw2R9vcLy2LeKjTvok7CMj5NR4yfFqVlvMGHt
# qc/czBfbuDy3mUof7kU7A6jZcFSxRCHD952tS4a9Fjayqic35EsmzOOH+5GCoINS
# z/4IgcLaq2QgDQX3JSNOZ1mtU0aRG3GuY4WZepkWQ3LjCe4h4oJqghlwlzNF8WB+
# /rVFxnwXTkulTyGqmXvHVVnMET/Emsb86CzYL75ra5MJPj4r4MnGQNtnxISJM0zp
# XdpB2C1a+056aXVvGUKKLy39H+mYcVX/IQ==
# SIG # End signature block
