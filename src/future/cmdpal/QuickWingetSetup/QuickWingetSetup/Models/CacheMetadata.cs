using System;
using System.Text.Json.Serialization;

namespace QuickWingetSetup.Models;

public class CacheMetadata
{
    [JsonPropertyName("lastFetched")]
    public DateTime LastFetched { get; set; }

    [JsonPropertyName("ttlDays")]
    public int TtlDays { get; set; } = 7;
}
