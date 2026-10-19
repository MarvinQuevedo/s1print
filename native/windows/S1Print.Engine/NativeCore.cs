using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace S1Print.Engine;

public sealed record GrayPageData(int Width, int Height, int Dpi, byte[] Pixels);
public sealed record PreparedJob(byte[][] Chunks, int Width, int Height, byte[] PreviewRows);
public static class NativeCore
{
    [DllImport("s1_native", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr s1_process_json(byte[] input, nuint length);
    [DllImport("s1_native", CallingConvention = CallingConvention.Cdecl)]
    private static extern void s1_free_string(IntPtr value);
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public static JsonElement Call(object request)
    {
        byte[] input = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(request, JsonOptions));
        IntPtr output = s1_process_json(input, (nuint)input.Length);
        if (output == IntPtr.Zero) throw new InvalidOperationException("Native library returned no response");
        try
        {
            using var document = JsonDocument.Parse(Marshal.PtrToStringUTF8(output) ?? throw new InvalidOperationException("Invalid native response"));
            var root = document.RootElement;
            if (!root.GetProperty("ok").GetBoolean()) throw new InvalidOperationException(root.GetProperty("error").GetString());
            if (root.GetProperty("apiVersion").GetInt32() != 1) throw new InvalidOperationException("Unsupported native API version");
            return root.Clone();
        }
        finally { s1_free_string(output); }
    }
    private static object Options(PrintSettings settings) => new { settings.Density, settings.FitContentWidth, settings.LabelPaper, TrimBottom = !settings.LabelPaper };
    private static PreparedJob Prepared(JsonElement result)
    {
        var p = result.GetProperty("preview");
        return new(result.GetProperty("chunks").EnumerateArray().Select(x => x.GetBytesFromBase64()).ToArray(),
            p.GetProperty("width").GetInt32(), p.GetProperty("height").GetInt32(), p.GetProperty("rows").GetBytesFromBase64());
    }
    public static PreparedJob Build(IReadOnlyList<GrayPageData> pages, PrintSettings settings) => Prepared(Call(new { Op = "build", Pages = pages, Options = Options(settings) }));
    public static PreparedJob Raster(byte[] data, PrintSettings settings) => Prepared(Call(new { Op = "raster", Data = data, Options = Options(settings) }));
    public static byte[] Command(string name) => Call(new { Op = "commands" }).GetProperty(name).GetBytesFromBase64();
    public static JsonElement Status(byte raw) => Call(new { Op = "status", Raw = raw });
}
