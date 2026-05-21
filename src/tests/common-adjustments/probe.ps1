# Smoke-test probe for the common-adjustments user-experience flow.
#
# After the flow's DSC config has been applied, the LongPaths resource
# should have set
#   HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled = 1
# This script reads that DWORD and prints it to stdout so the harness's
# build-run-diff pipeline can compare against tests/common-adjustments/expected.txt.
#
# Why a script file instead of inlining the readback in the manifest's
# `run`: PowerShell's single-quote string syntax (used for the registry
# path here) ended up unquoting itself inside the bash single-quoted
# echo that the discover step uses, which collapsed `\\` to `\` and
# produced invalid JSON escapes (\S etc.). Putting the body in a .ps1
# file means the manifest's `run` is `pwsh -File <path>` with no
# embedded quotes, sidestepping that interaction entirely.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$value = (Get-ItemProperty `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
    -Name 'LongPathsEnabled').LongPathsEnabled

# Single-line stdout, no trailing whitespace beyond the newline
# Write-Output adds. Harness normalizes CR/LF and trailing blanks.
Write-Output $value
