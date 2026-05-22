// Copyright (c) Microsoft Corporation
// The Microsoft Corporation licenses this file to you under the MIT license.

using System;
using System.Diagnostics;
using System.Linq;
using Microsoft.Win32;

namespace QuickWingetSetup.Services;

public enum WingetConfigureStatus
{
    /// <summary>`winget configure` is wired up and usable.</summary>
    Available,

    /// <summary>winget itself is not installed or not on PATH.</summary>
    WingetMissing,

    /// <summary>`winget configure` subcommand isn't exposed (stale App Installer,
    /// or experimental flag off).</summary>
    ConfigureDisabled,

    /// <summary>GPO `EnableWindowsPackageManagerConfiguration = 0` blocks it.</summary>
    BlockedByPolicy,
}

/// <summary>
/// Detects whether `winget configure` is usable on this host. Mirrors the
/// logic in <c>scripts/windows/_common/assert-winget-configure.ps1</c>, so
/// the three entry points (CI, hand-apply shim, CmdPal) all surface the
/// same diagnosis. Remediation is a separate concern — see
/// <c>enable-winget-configure.ps1</c>.
/// </summary>
public static class WingetConfigureHealthService
{
    private static WingetConfigureStatus? _cached;

    public static WingetConfigureStatus Status => _cached ??= Detect();

    public static WingetConfigureStatus RefreshStatus()
    {
        _cached = null;
        _cached = Detect();
        return _cached.Value;
    }

    /// <summary>
    /// Human-readable description of the current status. Used for the
    /// banner subtitle and the detail page body.
    /// </summary>
    public static string DescribeStatus(WingetConfigureStatus status) => status switch
    {
        WingetConfigureStatus.Available =>
            "`winget configure` is available on this machine.",
        WingetConfigureStatus.WingetMissing =>
            "winget (App Installer) is not installed. Install 'App Installer' from the Microsoft Store.",
        WingetConfigureStatus.ConfigureDisabled =>
            "winget is installed but `winget configure` is not available — usually a stale App Installer.",
        WingetConfigureStatus.BlockedByPolicy =>
            "`winget configure` is disabled by Group Policy (EnableWindowsPackageManagerConfiguration=0). Ask IT.",
        _ => "Unknown status.",
    };

    private static WingetConfigureStatus Detect()
    {
        // 1. Cheapest check first: GPO. Its remediation is "talk to IT",
        //    so surface it before we shell out to a subprocess.
        if (IsBlockedByPolicy())
        {
            return WingetConfigureStatus.BlockedByPolicy;
        }

        // 2. winget on PATH?
        try
        {
            var probe = new ProcessStartInfo
            {
                FileName = "winget",
                Arguments = "--version",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var p = Process.Start(probe);
            if (p == null) return WingetConfigureStatus.WingetMissing;
            p.WaitForExit(3000);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return WingetConfigureStatus.WingetMissing;
        }
        catch
        {
            return WingetConfigureStatus.WingetMissing;
        }

        // 3. Probe `winget configure --help`. Exit 0 + help text containing
        //    "configure" / "configuration" means the subcommand is wired up.
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "winget",
                Arguments = "configure --help",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var proc = Process.Start(psi);
            if (proc == null) return WingetConfigureStatus.ConfigureDisabled;

            var stdout = proc.StandardOutput.ReadToEnd();
            var stderr = proc.StandardError.ReadToEnd();
            proc.WaitForExit(5000);

            if (proc.ExitCode != 0)
            {
                return WingetConfigureStatus.ConfigureDisabled;
            }

            var combined = (stdout + "\n" + stderr).ToLowerInvariant();
            if (combined.Contains("configure") || combined.Contains("configuration"))
            {
                return WingetConfigureStatus.Available;
            }

            return WingetConfigureStatus.ConfigureDisabled;
        }
        catch
        {
            return WingetConfigureStatus.ConfigureDisabled;
        }
    }

    private static bool IsBlockedByPolicy()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(
                @"SOFTWARE\Policies\Microsoft\Windows\AppInstaller");
            if (key == null) return false;

            var raw = key.GetValue("EnableWindowsPackageManagerConfiguration");
            if (raw == null) return false;

            return Convert.ToInt32(raw, System.Globalization.CultureInfo.InvariantCulture) == 0;
        }
        catch
        {
            return false;
        }
    }
}
