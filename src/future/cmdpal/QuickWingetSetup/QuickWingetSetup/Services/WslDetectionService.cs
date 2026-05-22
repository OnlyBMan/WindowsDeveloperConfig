// Copyright (c) Microsoft Corporation
// The Microsoft Corporation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using System;
using System.Diagnostics;
using System.Linq;

namespace QuickWingetSetup.Services;

public enum WslStatus
{
    Available,
    NoWsl,
    NoDistro,
}

public static class WslDetectionService
{
    private static WslStatus? _cached;

    public static WslStatus Status => _cached ??= Detect();

    public static WslStatus RefreshStatus()
    {
        _cached = null;
        _cached = Detect();
        return _cached.Value;
    }

    private static WslStatus Detect()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "wsl.exe",
                Arguments = "--list --quiet",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };

            using var proc = Process.Start(psi);
            if (proc == null)
            {
                return WslStatus.NoWsl;
            }

            var output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(5000);

            // --list --quiet prints one distro name per line.
            // Filter out empty lines and the null characters WSL sometimes emits.
            var distros = output
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Select(l => l.Trim().Trim('\0', '\r'))
                .Where(l => l.Length > 0)
                .ToArray();

            return distros.Length > 0 ? WslStatus.Available : WslStatus.NoDistro;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // wsl.exe not found on PATH
            return WslStatus.NoWsl;
        }
        catch
        {
            return WslStatus.NoWsl;
        }
    }
}
