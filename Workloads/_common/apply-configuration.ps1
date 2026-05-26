<#
.SYNOPSIS
  Apply a winget DSC configuration file with retry, refresh PATH in the current
  session, verify a list of expected commands, and emit the CI sentinel.

.DESCRIPTION
  Flow-level `install.ps1` files are thin shims: the real install logic lives
  in each flow's `configuration.winget`. This helper centralizes the glue
  that CI needs around `winget configure`:

    1. `winget configure --file <ConfigFile>` with exponential-backoff retry
       (shared helper; flaky network is common on hosted runners). Always
       passes `--accept-configuration-agreements` and `--disable-interactivity`.
       Note: `--accept-package-agreements` is NOT a valid flag on
       `winget configure` (only on `winget install`). Package-agreement
       consent for packages installed by DSC resources flows through
       `--accept-configuration-agreements`.
    2. Re-read machine+user PATH from the registry into `$env:Path` so the
       caller's *current* PowerShell session can see freshly installed
       executables (winget updates the registry but not running processes).
    3. Assert each command in `-RequireCommands` resolves on PATH.
    4. Print `INSTALL_OK: <Id>` as the final line; CI asserts on this.

.PARAMETER Id
  Flow id, only used in log prefixes and the final sentinel line.

.PARAMETER ConfigFile
  Path to the winget DSC YAML config for the flow.

.PARAMETER RequireCommands
  Commands that must resolve on PATH after configuration has been applied.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $Id,
    [Parameter(Mandatory)] [string]   $ConfigFile,
    # AllowEmptyCollection: Windows PowerShell 5.1 rejects empty arrays
    # bound to Mandatory parameters. Some flows (e.g. mac-comfort-shell)
    # have no post-install CLI to verify - the DSC only installs a font
    # and pwsh - so they legitimately pass @() here.
    [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RequireCommands
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Fix #15: force UTF-8 on this process's console + external-program
# pipes. Windows PowerShell 5.1 defaults to the ANSI code page (1252 on
# en-US) for `[Console]::OutputEncoding`, which mangles winget's
# braille-pattern spinner glyphs into scrolling mojibake. winget writes
# UTF-8; matching it up front lets the carriage-return overwrites in
# the spinner work as intended and gives readable progress output.
# Safe no-op on pwsh 7 where UTF-8 is already the default.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding           = $utf8NoBom
} catch {
    # Some hosts (e.g. certain CI agents with redirected stdout) reject
    # the assignment. Not worth failing the whole flow over cosmetics.
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

$common = Split-Path -Parent $PSCommandPath
. (Join-Path $common 'invoke-retry.ps1')

# Hard-fail fast if `winget configure` isn't available on this host. Every
# flow in this repo -- and the CmdPal extension that launches them -- uses
# `winget configure` as its only install path, so this is a stop-the-world
# prerequisite, not a warn-and-continue diagnostic.
#
# Fix #16: if the assert fails on first try, auto-invoke the canonical
# remediation (`enable-winget-configure.ps1`) once and then re-assert.
# The remediation runs `winget configure --enable` and installs
# Microsoft.VCRedist.2015+.x64, which covers the two failure modes a
# fresh VM actually hits. The remediation script itself self-elevates
# via UAC when needed; when we're already elevated (the install.ps1
# entry point in practice) it runs in-process and does not pause.
$assertScript = Join-Path $common 'assert-winget-configure.ps1'
$enableScript = Join-Path $common 'enable-winget-configure.ps1'
try {
    & $assertScript
}
catch {
    Write-Host ''
    Write-Host "--- winget configure not available; auto-remediating via $enableScript ---" -ForegroundColor Yellow
    Write-Host "    (reason: $($_.Exception.Message.Split([Environment]::NewLine)[0]))" -ForegroundColor DarkGray
    Write-Host ''
    & $enableScript
    # Re-assert; surface the original failure mode if remediation did
    # not actually fix it.
    & $assertScript
}

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    throw "DSC config file not found: $ConfigFile"
}

Write-Host "--- $Id flow: winget configure --file $ConfigFile ---"

Invoke-Retry -Name "winget configure $Id" -ScriptBlock {
    winget configure `
        --file $ConfigFile `
        --accept-configuration-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "winget configure failed with exit code $LASTEXITCODE"
    }
}

# winget updates the registry copy of PATH but not the PATH of this already
# running PowerShell process. Rehydrate so subsequent CI steps see new tools.
& (Join-Path $common 'refresh-path.ps1')

foreach ($cmd in $RequireCommands) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "$cmd not found on PATH after applying $ConfigFile"
    }
    Write-Host "$cmd : $(& $cmd --version 2>&1 | Select-Object -First 1)"
}

Write-Host "INSTALL_OK: $Id"

# SIG # Begin signature block
# MIInSQYJKoZIhvcNAQcCoIInOjCCJzYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDMesb0uUr3YBU9
# 2jleqZlNgw8ewN2mQOfLZq4GBSSzYKCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnlMIIZ4QIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGpoQSoP
# AQIxHNHdFmZm+r6pp1Ci8/EiIlW1gwy6/fFwMEIGCisGAQQBgjcCAQwxNDAyoBSA
# EgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20w
# DQYJKoZIhvcNAQEBBQAEggEAYetLoWK3Fuq1YmbuvUwJOeUoL9VTopbeyRFE6Bd5
# qeNV00w3AKOoGXIE80HbFUyZ3u0/o2q0YViDjVMffnH2fgfK+T/uHPhvtJNWrG4t
# bmMsjeZl2tDrSDuUiJt/epETpEoxHknTXSsfkz6b/bjO/yguci2a++oqmw7tPxzl
# +1KfsFy27KtABE9a+YDSs4Sx3Cx8iXU8ZF7AWkOoRXH4jXlVDFMovGXvN6IXB3nn
# Unk07oI9REfpTUbpNMky6XMJjqa8BsvVZ7/9Sc6iP/AXa//ZmPXZl11JJQ0c2w7a
# FRN/B59pO6sn73YRkq99F/AYc3860+z53+BTpjnnYh0dr6GCF5cwgheTBgorBgEE
# AYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUD
# BAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoD
# ATAxMA0GCWCGSAFlAwQCAQUABCARGfScQzn/vdDUSD2jDtSQEjnSdJ0n/mrsmWl9
# /j5p6AIGagyG2MYsGBMyMDI2MDUyNjA1MTE1Ny43MjhaMASAAgH0oIHRpIHOMIHL
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgITMwAAAiQ7hCGwLKxkIgABAAAC
# JDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAe
# Fw0yNjAyMTkxOTM5NTlaFw0yNzA1MTcxOTM5NTlaMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCj6W3UaQ2Zr4hNvSy7j7UMPFVy
# s7aExGB+JFwykzzXg3jayYm9gOLXJ7tNhU2emhrLQCOZcgLvz6FkqmghzQxzmkgK
# tLYiKaEzhogO/ce0lThdLNdVtMwQOYgo+XtXAZcViBX4LcHk38RusZiF7wxSa5t/
# Lxic04+Z/hly1gJQpIeFDqp4a9PuLt8rsfH05vW9pU9uriGdDxfJXn/lc49CxbXq
# A3EX17L24bc6t+mFuPDAJKKpai3XXqF2nJlpTPfdrA29sWTSNKig9CtBC5tzQj0f
# lbsa/4wqO9u+RkuwpZb3b7qnW5FdFrDR1vQmXfjlyUP9ZO38839NwSuiHtvsFCNk
# TNIX8OL5XVq1nsKyu//GeIZ9YuxsfLBedqG024PDERyrAs0pvfUWOLapVQajHPoC
# nuNSKvbEh7s5IQ0YgupGji+H7rIDx2/mIEI+6Q8WwBtk3Yxyhjj0GXw909i0EkTk
# Vyy+1yADjwSC8bw2qM4+Mc4hyytlZzSc0IPUBq1YGnYwCjIwa5/lMW0pFn/HpJdB
# 6XeMuTtYTOpaPoo64FjQryLXWjd4ovpw5lOw7X+v3E9kwN9VBC+wJESBECC1gZMC
# S5TaVwfE1w4pnXXb1qT9bjgRsPg4dklruUTdon/3SNt0a0Q5Nc2Ul+rMlQxXoP9i
# sXwMNnKO5JJkqRDRVQIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFHMfkX1u/zJLCMe0
# gqYitx1tAHeoMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1Ud
# HwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggr
# BgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# DgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQA+wHSbmhIpM8CRVZ4t
# k624hQ+LdZXE4qoeQui77CeNa3jq1FOzi7MRKkko6diEDHXPNWvAagxastCewPzm
# 5TCNh1s4qCHh4R2G/r48wU/Mpc68/WDmJy5CIQn/Fwps1sbNUEu7Bzg004qULIVJ
# 963jo/am4xwKgwh+vSVL7/dhsfT7dvhpRddbYLQTHZgwuNB6QhcEEsgogLVwNRj3
# 7VEWZDiwoMdxyC7YYrQu6MCVtizHnOtkSX7FqIoi6jlcfqfo619uDH9r8k2qAOHC
# eEAqKXKymIXDMcGGlEdDFbYiDZgPCBM0IHgAeilUSon07wjHu0e0ssBmtBafPb4G
# d+5FuRnWG3XGe91NCpLKqmFa/4GkVz9OMzZUg8oczxC/4JT3Hf45JEtszToXwNsk
# V3JNCcu2IItr6SJHmi3EDVADDRSNhdzFRpYmplGElPl5GRoPtJiDEvRIbv5MFKIw
# 2x9gnehf5IvBjC4ZkBg+4GTpqGE3mmnzF3nIekOkX4ug0/0mN2CSarhuSi9NmHIO
# pUN2eQHUtgTb/+Gmq7gktCMwIq/JOCYIiTYqpv1objAGKdWMPCrlSyNAs0jZYzkh
# a535158NMx+wBGvsfFoVsCMG5Ocp6vW6CXyuWRbUVqMU1OrQbHfdyzJpbhJC1PbA
# ZIyJCbN+VBgDTAzTKY8w4ISSwTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkA
# AAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVow
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX
# 9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1q
# UoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8d
# q6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byN
# pOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2k
# rnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4d
# Pf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgS
# Uei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8
# QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6Cm
# gyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzF
# ER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQID
# AQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQU
# KqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1
# GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0
# bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbL
# j+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1p
# Y3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0w
# Ni0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwU
# tj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN
# 3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU
# 5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5
# KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGy
# qVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB6
# 2FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltE
# AY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFp
# AUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcd
# FYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRb
# atGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQd
# VTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkRDMDAtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEw
# BwYFKw4DAhoDFQCmCPHbmseASfe//bGtX9eQG+0+46CBgzCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7b+VwjAiGA8y
# MDI2MDUyNjAzNDUwNloYDzIwMjYwNTI3MDM0NTA2WjB3MD0GCisGAQQBhFkKBAEx
# LzAtMAoCBQDtv5XCAgEAMAoCAQACAgSjAgH/MAcCAQACAhRoMAoCBQDtwOdCAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBALpqO2Hb8M2fbjg8+ZZVdZInAWE9
# 3tH0a3ujLNhtAaVxR3INcXDADs+5VKFQrUI3vOqVy6S0akA7yzDwm50w6y5VUU1B
# e95SXK10hW2w5JhwpRxXLGIgUPr7yRKIUKNuSiperuraB38LllLJgsXfkPItIA8R
# WWpb43VDTEsAswGhrcJax8ZaVkSqerSU6NaGIQS/2ESHau0EuboMYjtlA5Tfr8AM
# HTOTeKn7hY2HoCeaSdN43TkBaqvmIY3ir5wwkY2Lu36nNdd9vA412LudcYqaL0ku
# JRgNAEEMq16i9nkRCQi4jR9YPPxbU+P1GhZE/+A9jx8rbayOpakalxuoNsQxggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAiQ7
# hCGwLKxkIgABAAACJDANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBwMW7pl1jZC5IXpO6YKyh5ZhGv
# t+hYUOGskb2QfpLoQjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIEghPTdq
# m/dRyZ0BczXcdloVEqICdcmpVNbH9CEVzWSOMIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIkO4QhsCysZCIAAQAAAiQwIgQgFr1EHAnq
# WD8HmGLXwgjJ46eM8FAiiFs9SwfJzm2I/y4wDQYJKoZIhvcNAQELBQAEggIATVqe
# +sESSrmnTrLZ6ZvHsVDvR5gZpLXMdZw1jR63PpCu8VV0ZfuFLOUI+7py9Hh+/o8Y
# CV1ISip9jQYYfunGXy8BOyFKrfd95p31G928gtnn8xUV+CEhVi4f1qriTFq0eUxv
# 73mtZjYM2ZUyOfA85z8RzUUYrGYk5Yj6zP6yz1E5XNlAFyex7xjie0XmypZiuVPl
# +jcu8W4YGZ6nCEhLzeSfxso1D0N9/vcQyrE/YkaWoeDqwAWkFy4UydKH5YGC7ZoE
# BTdMEWPcULxFEUCLyIZAjcTOuOEaBsm7oZA11abdKlYjR8UvOO/aR0yaYh5DS4fn
# zK+cqrujH9oJO6XRlG5kbgoKr7lS/l2zW136s3gggQUQOzM61Qbc3ykKTTOhYoVT
# AwQly9ibSlCMFS39OeVp59xN7eyi7lApfRrgjj+0SDayc55ORGC8b9tx7pHB72Wf
# jpD6iiDKNUIYFlxKwkIl/8eq5taOI1wJR+qOZmYY+z4WKJ+pD7jPaTLH2q7I+peR
# fsNogZWlzHRa2Gn3w3Jc5sye1O2MtgxXnhsJEqFmM4Sm+qDUq547JgAOpgBiEc56
# sUtTWgKteEd+gLN+bGyKu42X31qFEVPppQEH3N0Tgrfju+xit2wobQjbku4TuK6y
# XejTxWRodwNIOuQW9hJHAJHM1q6NS+xqO/WaOgQ=
# SIG # End signature block
