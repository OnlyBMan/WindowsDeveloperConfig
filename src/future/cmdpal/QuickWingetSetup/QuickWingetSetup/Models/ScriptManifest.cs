using System.Text.Json.Serialization;

namespace QuickWingetSetup.Models;

public class ScriptManifest
{
    [JsonPropertyName("version")]
    public string Version { get; set; } = "1.0";

    // Renamed from "scripts" → "flows" to match WindowsDevSetupScripts manifest.yml.
    [JsonPropertyName("flows")]
    public ScriptEntry[] Flows { get; set; } = [];

    [JsonPropertyName("combos")]
    public ScriptEntry[]? Combos { get; set; }

    [JsonPropertyName("personas")]
    public ScriptEntry[]? Personas { get; set; }
}
