using System.Buffers.Binary;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.Logging;

namespace S1Print.Engine;

public sealed class IppServer(PrintQueue queue, Func<PrintSettings> defaults, int port = 8631) : IAsyncDisposable
{
    private WebApplication? app;
    private readonly DateTime started = DateTime.UtcNow;
    public string Uri => $"ipp://127.0.0.1:{port}/ipp/print";
    public static readonly (string Name, int Width, int Height)[] Media = [
        ("custom_s1-roll-58mm_58x600mm",5800,60000), ("custom_s1-roll-80mm_80x600mm",8000,60000),
        ("custom_s1-58x30mm_58x30mm",5800,3000), ("custom_s1-58x40mm_58x40mm",5800,4000),
        ("custom_s1-58x50mm_58x50mm",5800,5000), ("custom_s1-58x80mm_58x80mm",5800,8000)];
    public async Task StartAsync(CancellationToken token = default)
    {
        var builder = WebApplication.CreateSlimBuilder(); builder.Logging.ClearProviders();
        builder.WebHost.UseKestrel(o => { o.ListenLocalhost(port); o.Limits.MaxRequestBodySize = 64 * 1024 * 1024; o.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(15); });
        app = builder.Build();
        app.MapGet("/", () => Results.Text("S1Print local IPP bridge. Print endpoint: /ipp/print"));
        async Task HandleHttp(HttpContext context)
        {
            if (!context.Request.ContentType?.StartsWith("application/ipp", StringComparison.OrdinalIgnoreCase) ?? true) { context.Response.StatusCode = 415; return; }
            if (context.Request.Headers.ContainsKey("Origin")) { context.Response.StatusCode = 403; return; }
            using var body = new MemoryStream();
            await context.Request.Body.CopyToAsync(body, context.RequestAborted);
            var response = Handle(body.ToArray()); context.Response.ContentType = "application/ipp";
            await context.Response.Body.WriteAsync(response, context.RequestAborted);
        }
        app.MapPost("/ipp/print", HandleHttp);
        app.MapPost("/ipp/print/{id:int}", HandleHttp);
        await app.StartAsync(token);
    }
    public byte[] Handle(byte[] bytes)
    {
        var result = HandleInternal(bytes);
        if (bytes.Length >= 2 && bytes[0] is 1 or 2) { result[0] = bytes[0]; result[1] = bytes[1]; }
        return result;
    }
    private byte[] HandleInternal(byte[] bytes)
    {
        int id = bytes.Length >= 8 ? BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(4)) : 0;
        try
        {
            if (bytes.Length >= 2 && !((bytes[0] == 1 && bytes[1] == 1) || (bytes[0] == 2 && bytes[1] == 0))) return new IppWriter(0x0503, id).Finish();
            var r = IppCodec.Parse(bytes);
            if (r.Id <= 0 || r.Attributes.Count < 2 || r.Attributes[0].Name != "attributes-charset" || r.Attributes[0].Tag != 0x47 || r.Attributes[1].Name != "attributes-natural-language" || r.Attributes[1].Tag != 0x48) return new IppWriter(0x0400, r.Id).Finish();
            if (r.Text("attributes-charset") != "utf-8") return new IppWriter(0x040d, r.Id).Finish();
            if (r.Text("printer-uri") == "" && r.Text("job-uri") == "") return new IppWriter(0x0400, r.Id).Finish();
            if (r.Operation == 0x0b) { var w = new IppWriter(0, r.Id) { Filter = Requested(r) }; PrinterAttributes(w); return w.Finish(); }
            if (r.Operation is 0x02 or 0x04 or 0x05 or 0x06)
            {
                string format = r.Text("document-format", "application/octet-stream");
                if (r.Text("compression", "none") != "none") return new IppWriter(0x040b, r.Id).Finish();
                if (format is not ("application/octet-stream" or "image/pwg-raster" or "image/urf")) return new IppWriter(0x040a, r.Id).Finish();
                int copies = r.Number("copies", 1);
                if (copies is < 1 or > 99) return new IppWriter(0x040b, r.Id).Finish();
                if (r.Text("sides", "one-sided") != "one-sided" || r.Number("orientation-requested", 3) is not (3 or 4 or 5 or 6)) return new IppWriter(0x040b, r.Id).Finish();
                string media = r.Text("media", r.Text("media-size-name", Media[0].Name));
                if (!Media.Any(m => m.Name == media)) return new IppWriter(0x040b, r.Id).Finish();
                bool label = Media.First(m => m.Name == media).Height <= 8000;
                var settings = defaults() with { LabelPaper = label };
                if (r.Operation == 0x04) return new IppWriter(0, r.Id).Finish();
                QueuedJob job;
                if (r.Operation == 0x06)
                {
                    job = queue.Find(r.Number("job-id")) ?? throw new KeyNotFoundException();
                    if (!r.Attributes.Any(a => a.Name == "last-document")) return new IppWriter(0x0400, r.Id).Finish();
                    if (!r.Boolean("last-document")) return new IppWriter(0x040b, r.Id).Finish();
                    if (job.State != 4) return new IppWriter(0x0404, r.Id).Finish();
                    job.Format = format;
                }
                else job = queue.Create(r.Text("job-name", "Document"), r.Text("requesting-user-name", "local"), format, settings, copies);
                if (r.Operation != 0x05)
                {
                    try { queue.Submit(job, r.Document); }
                    catch { queue.Cancel(job); throw; }
                }
                var w = new IppWriter(0, r.Id); JobAttributes(w, job); return w.Finish();
            }
            if (r.Operation is 0x08 or 0x09)
            {
                int jobId = r.Number("job-id");
                if (jobId == 0 && int.TryParse(r.Text("job-uri").Split('/').LastOrDefault(), out int parsed)) jobId = parsed;
                var job = queue.Find(jobId) ?? throw new KeyNotFoundException();
                if (r.Operation == 0x08) { if (job.Terminal) return new IppWriter(0x0404, r.Id).Finish(); queue.Cancel(job); }
                var w = new IppWriter(0, r.Id) { Filter = Requested(r) }; JobAttributes(w, job); return w.Finish();
            }
            if (r.Operation == 0x0a)
            {
                var w = new IppWriter(0, r.Id) { Filter = Requested(r) }; string which = r.Text("which-jobs", "not-completed");
                foreach (var job in queue.Jobs.Where(j => !r.Boolean("my-jobs") || j.User == r.Text("requesting-user-name")).Where(j => which == "all" || (which == "completed" ? j.Terminal : !j.Terminal)).Take(Math.Clamp(r.Number("limit", 100), 1, 100))) JobAttributes(w, job);
                return w.Finish();
            }
            return new IppWriter(0x0501, r.Id).Finish();
        }
        catch (KeyNotFoundException) { return new IppWriter(0x0406, id).Finish(); }
        catch (InvalidDataException) { return new IppWriter(0x0400, id).Finish(); }
        catch (InvalidOperationException) { return new IppWriter(0x0507, id).Finish(); }
        catch { return new IppWriter(0x0500, id).Finish(); }
    }
    private static HashSet<string>? Requested(IppRequest request)
    {
        var names = request.Attributes.Where(a => a.Name == "requested-attributes").Select(a => System.Text.Encoding.UTF8.GetString(a.Value)).ToHashSet();
        return names.Count == 0 || names.Overlaps(new[] { "all", "printer-description", "printer-status", "job-template", "job-description" }) ? null : names;
    }
    private void JobAttributes(IppWriter w, QueuedJob j)
    {
        w.Group(2); w.Number(0x21, "job-id", j.Id); w.Text(0x45, "job-uri", $"{Uri}/{j.Id}");
        w.Text(0x45, "job-printer-uri", Uri); w.Text(0x42, "job-name", j.Name); w.Text(0x42, "job-originating-user-name", j.User);
        w.Number(0x23, "job-state", j.State); w.Text(0x41, "job-state-message", j.Message);
        w.Text(0x44, "job-state-reasons", j.State switch { 4 => "job-data-insufficient", 7 => "job-canceled-by-user", 8 => "aborted-by-system", 9 => "job-completed-successfully", _ => "none" });
    }
    private static void MediaCollection(IppWriter w, string name, (string Name, int Width, int Height) media)
    {
        w.Begin(name); w.Member("media-size"); w.Begin(""); w.Member("x-dimension"); w.Number(0x21, "", media.Width);
        w.Member("y-dimension"); w.Number(0x21, "", media.Height); w.End();
        foreach (var margin in new[] { "media-left-margin", "media-right-margin", "media-top-margin", "media-bottom-margin" }) { w.Member(margin); w.Number(0x21, "", 0); }
        w.Member("media-size-name"); w.Text(0x44, "", media.Name); w.End();
    }
    private void PrinterAttributes(IppWriter w)
    {
        w.Group(4); w.Text(0x45, "printer-uri-supported", Uri); w.Text(0x44, "uri-authentication-supported", "none"); w.Text(0x44, "uri-security-supported", "none");
        w.Text(0x45, "printer-more-info", $"http://127.0.0.1:{port}/");
        w.Text(0x42, "printer-name", "S1 Bluetooth"); w.Text(0x41, "printer-info", "S1Print Bluetooth bridge"); w.Text(0x41, "printer-location", "Local Bluetooth");
        w.Text(0x41, "printer-make-and-model", "Luck Jingle S1"); w.Text(0x45, "printer-uuid", "urn:uuid:beee5766-316b-43aa-b82d-34cb005c1b7c");
        w.Numbers(0x23, "operations-supported", 2, 4, 5, 6, 8, 9, 10, 11);
        w.Texts(0x44, "ipp-versions-supported", "1.1", "2.0");
        w.Text(0x47, "charset-configured", "utf-8"); w.Text(0x47, "charset-supported", "utf-8"); w.Text(0x48, "natural-language-configured", "en"); w.Text(0x48, "generated-natural-language-supported", "en");
        w.Texts(0x49, "document-format-supported", "image/pwg-raster", "image/urf", "application/octet-stream"); w.Text(0x49, "document-format-default", "application/octet-stream");
        w.Text(0x44, "output-bin-default", "face-up"); w.Text(0x44, "output-bin-supported", "face-up"); w.Number(0x21, "pages-per-minute", 5);
        w.Text(0x44, "compression-supported", "none"); w.Text(0x44, "sides-supported", "one-sided"); w.Text(0x44, "sides-default", "one-sided");
        w.Number(0x23, "print-quality-default", 4); w.Numbers(0x23, "print-quality-supported", 3, 4, 5);
        w.Text(0x44, "print-color-mode-supported", "monochrome"); w.Text(0x44, "print-color-mode-default", "monochrome"); w.Boolean("color-supported", false);
        w.Number(0x23, "orientation-requested-default", 3); w.Numbers(0x23, "orientation-requested-supported", 3, 4, 5, 6);
        w.Number(0x21, "copies-default", 1); w.Range("copies-supported", 1, 99); w.Number(0x21, "job-priority-default", 50); w.Number(0x21, "job-priority-supported", 1);
        w.Text(0x44, "job-hold-until-default", "no-hold"); w.Text(0x44, "job-hold-until-supported", "no-hold");
        w.Boolean("multiple-document-jobs-supported", false); w.Text(0x44, "multiple-document-handling-default", "separate-documents-collated-copies"); w.Text(0x44, "multiple-document-handling-supported", "separate-documents-collated-copies");
        w.Number(0x23, "finishings-default", 3); w.Number(0x23, "finishings-supported", 3); w.Number(0x21, "number-up-default", 1); w.Number(0x21, "number-up-supported", 1);
        w.Number(0x23, "printer-state", queue.Jobs.Any(j => j.State == 5) ? 4 : 3); w.Text(0x44, "printer-state-reasons", "none"); w.Boolean("printer-is-accepting-jobs", true);
        w.Number(0x21, "queued-job-count", queue.Jobs.Count(j => !j.Terminal)); w.Number(0x21, "printer-up-time", (int)(DateTime.UtcNow - started).TotalSeconds);
        w.Number(0x21, "printer-config-change-time", 0); w.Number(0x21, "printer-state-change-time", 0); w.Text(0x44, "pdl-override-supported", "attempted");
        foreach (var name in new[] { "printer-resolution-default", "printer-resolution-supported", "pwg-raster-document-resolution-supported" }) w.Resolution(name, 406);
        w.Texts(0x44, "pwg-raster-document-type-supported", "black_1", "sgray_8"); w.Texts(0x44, "urf-supported", "V1.4", "W8", "DM1", "RS406", "CP1", "IS1", "MT1-3-10-12");
        w.Texts(0x44, "media-supported", Media.Select(m => m.Name).ToArray()); w.Text(0x44, "media-default", Media[0].Name); w.Text(0x44, "media-ready", Media[0].Name);
        w.Texts(0x44, "media-col-supported", "media-size", "media-size-name", "media-left-margin", "media-right-margin", "media-top-margin", "media-bottom-margin");
        foreach (var margin in new[] { "media-left-margin-supported", "media-right-margin-supported", "media-top-margin-supported", "media-bottom-margin-supported" }) w.Number(0x21, margin, 0);
        for (int i = 0; i < Media.Length; i++) MediaCollection(w, i == 0 ? "media-col-database" : "", Media[i]);
        MediaCollection(w, "media-col-default", Media[0]); MediaCollection(w, "media-col-ready", Media[0]);
        foreach (var media in Media) { w.Begin(media == Media[0] ? "media-size-supported" : ""); w.Member("x-dimension"); w.Number(0x21, "", media.Width); w.Member("y-dimension"); w.Number(0x21, "", media.Height); w.End(); }
    }
    public async ValueTask DisposeAsync() { if (app is not null) await app.DisposeAsync(); }
}
