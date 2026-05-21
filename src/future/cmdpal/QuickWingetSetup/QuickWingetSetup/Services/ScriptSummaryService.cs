using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace QuickWingetSetup.Services;

/// <summary>
/// Parses WinGet DSC YAML and WSL shell scripts into human-readable markdown summaries.
/// Uses lightweight line-based parsing — no YAML library needed since DSC files follow
/// a strict, predictable schema.
/// </summary>
public static class ScriptSummaryService
{
    public static string Summarize(string filePath)
    {
        if (!File.Exists(filePath))
        {
            return "*Script file not found.*";
        }

        var content = File.ReadAllText(filePath);
        var ext = Path.GetExtension(filePath).ToLowerInvariant();

        return ext switch
        {
            ".winget" => SummarizeWinGetDsc(content),
            ".sh" => SummarizeShellScript(content),
            _ => $"```\n{content}\n```",
        };
    }

    private static string SummarizeWinGetDsc(string yaml)
    {
        var lines = yaml.Split('\n');
        var resources = ParseDscResources(lines);

        if (resources.Count == 0)
        {
            return "*No resources found in this configuration.*";
        }

        var sb = new StringBuilder();

        var packages = resources.FindAll(r =>
            r.ResourceType.Contains("WinGetPackage", StringComparison.OrdinalIgnoreCase));
        var envVars = resources.FindAll(r =>
            r.ResourceType.Contains("Environment", StringComparison.OrdinalIgnoreCase));
        var settings = resources.FindAll(r =>
            !r.ResourceType.Contains("WinGetPackage", StringComparison.OrdinalIgnoreCase) &&
            !r.ResourceType.Contains("Environment", StringComparison.OrdinalIgnoreCase) &&
            !r.ResourceType.Contains("OsVersion", StringComparison.OrdinalIgnoreCase));

        if (packages.Count > 0)
        {
            sb.AppendLine("### 📦 Packages");
            sb.AppendLine();
            sb.AppendLine("| Package | ID |");
            sb.AppendLine("|---|---|");
            foreach (var pkg in packages)
            {
                var desc = pkg.Description;
                var id = pkg.Settings.GetValueOrDefault("id", "—");
                if (desc.StartsWith("Install ", StringComparison.OrdinalIgnoreCase))
                {
                    desc = desc["Install ".Length..];
                }
                sb.Append("| ").Append(desc).Append(" | `").Append(id).AppendLine("` |");
            }
            sb.AppendLine();
        }

        if (envVars.Count > 0)
        {
            sb.AppendLine("### 🔧 Environment Variables");
            sb.AppendLine();
            foreach (var env in envVars)
            {
                var name = env.Settings.GetValueOrDefault("Name", "?");
                var value = env.Settings.GetValueOrDefault("Value", "?");
                var isPath = env.Settings.GetValueOrDefault("Path", "").Equals("true", StringComparison.OrdinalIgnoreCase);
                if (isPath)
                {
                    sb.Append("- **PATH** += `").Append(value).AppendLine("`");
                }
                else
                {
                    sb.Append("- **").Append(name).Append("** = `").Append(value).AppendLine("`");
                }
            }
            sb.AppendLine();
        }

        if (settings.Count > 0)
        {
            sb.AppendLine("### ⚙️ System Settings");
            sb.AppendLine();
            foreach (var s in settings)
            {
                sb.Append("- ").AppendLine(s.Description);
                foreach (var kvp in s.Settings)
                {
                    if (!kvp.Key.Equals("Ensure", StringComparison.OrdinalIgnoreCase))
                    {
                        sb.Append("  - ").Append(kvp.Key).Append(": `").Append(kvp.Value).AppendLine("`");
                    }
                }
            }
            sb.AppendLine();
        }

        var elevated = packages.Exists(p => p.Elevated) || settings.Exists(s => s.Elevated);
        if (elevated)
        {
            sb.AppendLine("---");
            sb.AppendLine("🛡️ *Requires administrator privileges*");
        }

        return sb.ToString().TrimEnd();
    }

    private static string SummarizeShellScript(string script)
    {
        var lines = script.Split('\n');
        var sb = new StringBuilder();

        var aptPackages = new List<string>();
        var npmPackages = new List<string>();
        var cargoPackages = new List<string>();
        var pipPackages = new List<string>();
        var curlInstalls = new List<string>();
        var configSteps = new List<string>();
        var needsSudo = false;

        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i].Trim();

            // apt-get install (may span multiple lines with \)
            if (line.Contains("apt-get install", StringComparison.Ordinal) && !line.Contains("remove", StringComparison.Ordinal))
            {
                needsSudo = true;
                var fullCmd = CollectContinuationLines(lines, ref i);
                foreach (var pkg in ExtractPackageArgs(fullCmd, "install"))
                {
                    if (!pkg.StartsWith('-'))
                    {
                        aptPackages.Add(pkg);
                    }
                }
            }
            // npm install -g
            else if (line.Contains("npm install -g", StringComparison.Ordinal))
            {
                var fullCmd = CollectContinuationLines(lines, ref i);
                foreach (var pkg in ExtractPackageArgs(fullCmd, "-g"))
                {
                    npmPackages.Add(pkg);
                }
            }
            // cargo install
            else if (line.Contains("cargo install", StringComparison.Ordinal))
            {
                var fullCmd = CollectContinuationLines(lines, ref i);
                foreach (var pkg in ExtractPackageArgs(fullCmd, "install"))
                {
                    if (!pkg.StartsWith('-'))
                    {
                        cargoPackages.Add(pkg);
                    }
                }
            }
            // pip/pipx install
            else if (line.Contains("pip install", StringComparison.Ordinal) || line.Contains("pipx install", StringComparison.Ordinal))
            {
                var fullCmd = CollectContinuationLines(lines, ref i);
                var keyword = fullCmd.Contains("pipx", StringComparison.Ordinal) ? "install" : "install";
                foreach (var pkg in ExtractPackageArgs(fullCmd, keyword))
                {
                    if (!pkg.StartsWith('-'))
                    {
                        pipPackages.Add(pkg);
                    }
                }
            }
            // curl | bash/sh installs (version managers, toolchains)
            else if (line.Contains("curl", StringComparison.Ordinal) &&
                     (line.Contains("| bash", StringComparison.Ordinal) ||
                      line.Contains("| sh", StringComparison.Ordinal)))
            {
                // Look at the preceding echo line for a description
                var desc = FindPrecedingEcho(lines, i);
                if (!string.IsNullOrEmpty(desc))
                {
                    curlInstalls.Add(desc);
                }
                else
                {
                    curlInstalls.Add(ExtractToolFromUrl(line));
                }
            }
            // Shell config changes
            else if ((line.Contains(">> ~/.", StringComparison.Ordinal) ||
                      line.Contains("sed -i", StringComparison.Ordinal) ||
                      line.Contains("chsh", StringComparison.Ordinal)) &&
                     !line.StartsWith('#'))
            {
                var desc = FindPrecedingEcho(lines, i);
                if (!string.IsNullOrEmpty(desc))
                {
                    configSteps.Add(desc);
                }
            }
            // usermod (group management)
            else if (line.Contains("usermod -aG", StringComparison.Ordinal))
            {
                needsSudo = true;
                var desc = FindPrecedingEcho(lines, i);
                configSteps.Add(desc ?? "Add user to group");
            }
        }

        // Build output matching the Windows summary style
        var hasPackages = aptPackages.Count > 0 || curlInstalls.Count > 0;
        if (hasPackages)
        {
            sb.AppendLine("### 📦 Packages");
            sb.AppendLine();
            sb.AppendLine("| Package | Source |");
            sb.AppendLine("|---|---|");
            foreach (var pkg in curlInstalls)
            {
                sb.Append("| ").Append(pkg).AppendLine(" | installer |");
            }
            foreach (var pkg in aptPackages)
            {
                sb.Append("| ").Append(pkg).AppendLine(" | `apt` |");
            }
            sb.AppendLine();
        }

        if (npmPackages.Count > 0)
        {
            sb.AppendLine("### 📦 npm Global Packages");
            sb.AppendLine();
            sb.AppendLine("| Package | Source |");
            sb.AppendLine("|---|---|");
            foreach (var pkg in npmPackages)
            {
                sb.Append("| ").Append(pkg).AppendLine(" | `npm -g` |");
            }
            sb.AppendLine();
        }

        if (cargoPackages.Count > 0)
        {
            sb.AppendLine("### 📦 Cargo Packages");
            sb.AppendLine();
            sb.AppendLine("| Package | Source |");
            sb.AppendLine("|---|---|");
            foreach (var pkg in cargoPackages)
            {
                sb.Append("| ").Append(pkg).AppendLine(" | `cargo` |");
            }
            sb.AppendLine();
        }

        if (pipPackages.Count > 0)
        {
            sb.AppendLine("### 📦 Python Packages");
            sb.AppendLine();
            sb.AppendLine("| Package | Source |");
            sb.AppendLine("|---|---|");
            foreach (var pkg in pipPackages)
            {
                sb.Append("| ").Append(pkg).AppendLine(" | `pip` |");
            }
            sb.AppendLine();
        }

        if (configSteps.Count > 0)
        {
            sb.AppendLine("### ⚙️ Configuration");
            sb.AppendLine();
            foreach (var step in configSteps)
            {
                sb.Append("- ").AppendLine(step);
            }
            sb.AppendLine();
        }

        if (needsSudo)
        {
            sb.AppendLine("---");
            sb.AppendLine("🛡️ *Requires sudo privileges*");
        }

        // Fallback if nothing was parsed
        if (sb.Length == 0)
        {
            sb.Append("```bash\n").Append(script).AppendLine("\n```");
        }

        return sb.ToString().TrimEnd();
    }

    /// <summary>
    /// Collects a command that may span multiple lines via trailing backslashes.
    /// </summary>
    private static string CollectContinuationLines(string[] lines, ref int i)
    {
        var sb = new StringBuilder(lines[i].Trim());
        while (sb.Length > 0 && sb[sb.Length - 1] == '\\' && i + 1 < lines.Length)
        {
            sb.Length--; // remove trailing backslash
            i++;
            sb.Append(' ').Append(lines[i].Trim());
        }
        return sb.ToString();
    }

    /// <summary>
    /// Extracts package names that appear after a keyword (e.g. "install", "-g") in a command string.
    /// </summary>
    private static List<string> ExtractPackageArgs(string command, string afterKeyword)
    {
        var result = new List<string>();
        var parts = command.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var found = false;
        foreach (var part in parts)
        {
            if (!found)
            {
                if (part.Equals(afterKeyword, StringComparison.OrdinalIgnoreCase))
                {
                    found = true;
                }
                continue;
            }
            // Skip flags
            if (part.StartsWith('-'))
            {
                continue;
            }
            // Skip redirects and pipes
            if (part is "|" or ">" or ">>" or "2>/dev/null" or "||" or "true")
            {
                break;
            }
            result.Add(part);
        }
        return result;
    }

    /// <summary>
    /// Looks backwards from the current line to find the nearest echo "==> ..." or echo "=== ..." message.
    /// </summary>
    private static string? FindPrecedingEcho(string[] lines, int currentIndex)
    {
        for (int j = currentIndex - 1; j >= 0 && j >= currentIndex - 3; j--)
        {
            var prev = lines[j].Trim();
            if (prev.StartsWith("echo", StringComparison.Ordinal) &&
                (prev.Contains("==>", StringComparison.Ordinal) || prev.Contains("===", StringComparison.Ordinal)))
            {
                // Extract the message, stripping echo, quotes, and arrow prefixes
                var msg = prev;
                msg = msg.Replace("echo ", "", StringComparison.Ordinal).Trim('"', '\'', ' ');
                msg = msg.TrimStart('=', '>', ' ');
                return msg;
            }
        }
        return null;
    }

    /// <summary>
    /// Extracts a tool name from a curl URL (best-effort).
    /// </summary>
    private static string ExtractToolFromUrl(string curlLine)
    {
        // Try to find a recognizable tool name in the URL
        var parts = curlLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        foreach (var part in parts)
        {
            if (part.StartsWith("http", StringComparison.OrdinalIgnoreCase))
            {
                // Extract domain or path segment
                var segments = part.Split('/');
                foreach (var seg in segments)
                {
                    if (seg.Contains("nvm", StringComparison.OrdinalIgnoreCase)) return "nvm (Node Version Manager)";
                    if (seg.Contains("rustup", StringComparison.OrdinalIgnoreCase)) return "Rustup";
                    if (seg.Contains("starship", StringComparison.OrdinalIgnoreCase)) return "Starship prompt";
                    if (seg.Contains("ohmyzsh", StringComparison.OrdinalIgnoreCase)) return "Oh My Zsh";
                    if (seg.Contains("pyenv", StringComparison.OrdinalIgnoreCase)) return "pyenv";
                    if (seg.Contains("sdkman", StringComparison.OrdinalIgnoreCase)) return "SDKMAN";
                    if (seg.Contains("rbenv", StringComparison.OrdinalIgnoreCase)) return "rbenv";
                }
                break;
            }
        }
        return "Installer script";
    }

    private static List<DscResource> ParseDscResources(string[] lines)
    {
        var resources = new List<DscResource>();
        var inResources = false;

        int i = 0;
        while (i < lines.Length)
        {
            var line = lines[i];
            var trimmed = line.TrimStart();

            if (trimmed.StartsWith("resources:", StringComparison.Ordinal))
            {
                inResources = true;
                i++;
                continue;
            }

            if (inResources && trimmed.StartsWith("- resource:", StringComparison.Ordinal))
            {
                var resource = ParseSingleResource(lines, ref i);
                if (resource != null)
                {
                    resources.Add(resource);
                }
                continue;
            }

            i++;
        }

        return resources;
    }

    private static DscResource? ParseSingleResource(string[] lines, ref int i)
    {
        var resourceLine = lines[i].TrimStart();
        var resourceType = resourceLine.Replace("- resource:", "").Trim();
        var resource = new DscResource { ResourceType = resourceType };

        // Determine the indent level of this resource entry (the "- resource:" line)
        var baseIndent = lines[i].Length - lines[i].TrimStart().Length;
        i++;

        while (i < lines.Length)
        {
            var line = lines[i];
            if (string.IsNullOrWhiteSpace(line))
            {
                i++;
                continue;
            }

            var indent = line.Length - line.TrimStart().Length;
            var trimmed = line.TrimStart();

            // If we've backed out to the same or lesser indent as our base, this resource is done
            // But we need to check if it's a new "- resource:" at the same level
            if (indent <= baseIndent && !string.IsNullOrWhiteSpace(trimmed))
            {
                break;
            }

            if (trimmed.StartsWith("description:", StringComparison.Ordinal))
            {
                resource.Description = ExtractValue(trimmed, "description:");
            }
            else if (trimmed.StartsWith("securityContext:", StringComparison.Ordinal))
            {
                resource.Elevated = ExtractValue(trimmed, "securityContext:")
                    .Equals("elevated", StringComparison.OrdinalIgnoreCase);
            }
            else if (trimmed.StartsWith("settings:", StringComparison.Ordinal))
            {
                i++;
                ParseSettings(lines, ref i, indent, resource.Settings);
                continue;
            }

            i++;
        }

        return resource;
    }

    private static void ParseSettings(string[] lines, ref int i, int parentIndent, Dictionary<string, string> settings)
    {
        while (i < lines.Length)
        {
            var line = lines[i];
            if (string.IsNullOrWhiteSpace(line))
            {
                i++;
                continue;
            }

            var indent = line.Length - line.TrimStart().Length;
            if (indent <= parentIndent)
            {
                break;
            }

            var trimmed = line.TrimStart();
            var colonIdx = trimmed.IndexOf(':');
            if (colonIdx > 0 && colonIdx < trimmed.Length - 1)
            {
                var key = trimmed[..colonIdx].Trim();
                var value = trimmed[(colonIdx + 1)..].Trim().Trim('\'', '"');
                settings[key] = value;
            }

            i++;
        }
    }

    private static string ExtractValue(string line, string prefix)
    {
        return line[prefix.Length..].Trim().Trim('\'', '"');
    }

    private sealed class DscResource
    {
        public string ResourceType { get; set; } = "";
        public string Description { get; set; } = "";
        public bool Elevated { get; set; }
        public Dictionary<string, string> Settings { get; } = new(StringComparer.OrdinalIgnoreCase);
    }
}
