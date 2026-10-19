using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;
using S1Print.Engine;

namespace S1Print.Windows;
public static class Documents
{
    private const int MaxPixels = 32 * 1024 * 1024;
    public static async Task<IReadOnlyList<GrayPageData>> ReadAsync(string path, CancellationToken token)
    {
        if (new FileInfo(path).Length > 64 * 1024 * 1024) throw new IOException("Document exceeds 64 MiB");
        if (Path.GetExtension(path).Equals(".pdf", StringComparison.OrdinalIgnoreCase))
        {
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path)).AsTask(token);
            var pdf = await PdfDocument.LoadFromFileAsync(file).AsTask(token);
            if (pdf.PageCount > 100) throw new IOException("Document exceeds 100 pages");
            var pages = new List<GrayPageData>(); long total = 0;
            for (uint i = 0; i < pdf.PageCount; i++)
            {
                token.ThrowIfCancellationRequested(); using var page = pdf.GetPage(i);
                total += (long)(768 * page.Size.Height / page.Size.Width) * 768;
                if (total > MaxPixels) throw new IOException("Document exceeds 32 Mi pixels");
                using var stream = new InMemoryRandomAccessStream();
                await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = 768, BackgroundColor = new global::Windows.UI.Color { A = 255, R = 255, G = 255, B = 255 } }).AsTask(token);
                using var reader = new DataReader(stream.GetInputStreamAt(0)); await reader.LoadAsync((uint)stream.Size).AsTask(token);
                byte[] bytes = new byte[(int)stream.Size]; reader.ReadBytes(bytes);
                using var memory = new MemoryStream(bytes); using var bitmap = new Bitmap(memory); pages.Add(Gray(bitmap));
            }
            return pages;
        }
        return await Task.Run<IReadOnlyList<GrayPageData>>(() => { using var bitmap = new Bitmap(path); return [Gray(bitmap)]; }, token);
    }
    public static GrayPageData Gray(Bitmap source)
    {
        if ((long)source.Width * source.Height > MaxPixels) throw new IOException("Image exceeds 32 Mi pixels");
        using var bitmap = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap)) { g.Clear(Color.White); g.DrawImageUnscaled(source, 0, 0); }
        var rectangle = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rectangle, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            byte[] output = new byte[bitmap.Width * bitmap.Height]; byte[] row = new byte[bitmap.Width * 4];
            for (int y = 0; y < bitmap.Height; y++)
            {
                Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                for (int x = 0; x < bitmap.Width; x++) output[y * bitmap.Width + x] = (byte)((row[x * 4 + 2] * 299 + row[x * 4 + 1] * 587 + row[x * 4] * 114) / 1000);
            }
            return new(bitmap.Width, bitmap.Height, 406, output);
        }
        finally { bitmap.UnlockBits(data); }
    }
    public static IReadOnlyList<GrayPageData> TestPage()
    {
        using var bitmap = new Bitmap(768, 700); using var g = Graphics.FromImage(bitmap);
        g.Clear(Color.White); using var title = new Font("Segoe UI", 32); using var body = new Font("Segoe UI", 18);
        g.DrawString("S1Print / Rust", title, Brushes.Black, 24, 30);
        g.DrawString("Bluetooth test - 384 dots / 203 dpi", body, Brushes.Black, 24, 110);
        for (int i = 0; i < 16; i++) { using var brush = new SolidBrush(Color.FromArgb(i * 17, i * 17, i * 17)); g.FillRectangle(brush, 24 + i * 44, 190, 44, 140); }
        for (int i = 0; i < 9; i++) g.FillRectangle(Brushes.Black, 24, 380 + i * 26, 700, 3);
        return [Gray(bitmap)];
    }
    public static Bitmap Preview(PreparedJob job)
    {
        var bitmap = new Bitmap(job.Width, job.Height, PixelFormat.Format32bppArgb);
        var data = bitmap.LockBits(new Rectangle(0, 0, job.Width, job.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            byte[] row = new byte[job.Width * 4];
            for (int y = 0; y < job.Height; y++)
            {
                for (int x = 0; x < job.Width; x++)
                {
                    byte value = (job.PreviewRows[y * (job.Width / 8) + (x / 8)] & (0x80 >> (x % 8))) != 0 ? (byte)0 : (byte)255;
                    row[x * 4] = row[x * 4 + 1] = row[x * 4 + 2] = value; row[x * 4 + 3] = 255;
                }
                Marshal.Copy(row, 0, data.Scan0 + y * data.Stride, row.Length);
            }
        }
        finally { bitmap.UnlockBits(data); }
        return bitmap;
    }
}
