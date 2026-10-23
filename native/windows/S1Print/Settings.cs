using System.Text.Json;
using S1Print.Engine;

namespace S1Print.Windows;
public sealed record Settings(string? DeviceId = null, int Density = 1, bool FitContentWidth = true, bool LabelPaper = false)
{
    public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "S1Print");
    public static string FilePath => Path.Combine(DirectoryPath, "settings.json");
    public PrintSettings Print => new(Density, FitContentWidth, LabelPaper, DeviceId);
    public static Settings Load() { try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new(); } catch { return new(); } }
    public void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        string temporary = FilePath + ".tmp"; File.WriteAllText(temporary, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true })); File.Move(temporary, FilePath, true);
    }
    public static void Log(string message)
    {
        Directory.CreateDirectory(DirectoryPath);
        string file = Path.Combine(DirectoryPath, "s1print.log");
        lock (typeof(Settings))
        {
            if (File.Exists(file) && new FileInfo(file).Length > 2 * 1024 * 1024) File.Move(file, file + ".1", true);
            File.AppendAllText(file, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
    }
}
