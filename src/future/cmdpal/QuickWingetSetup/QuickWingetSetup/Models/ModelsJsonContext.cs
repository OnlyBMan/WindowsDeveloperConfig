using System.Text.Json.Serialization;

namespace QuickWingetSetup.Models;

[JsonSerializable(typeof(ScriptManifest))]
[JsonSerializable(typeof(ScriptEntry))]
[JsonSerializable(typeof(WindowsTarget))]
[JsonSerializable(typeof(PostConfigureStep))]
[JsonSerializable(typeof(LinuxTarget))]
[JsonSerializable(typeof(ExtensionConfig))]
[JsonSerializable(typeof(CacheMetadata))]
internal sealed partial class ModelsJsonContext : JsonSerializerContext
{
}
