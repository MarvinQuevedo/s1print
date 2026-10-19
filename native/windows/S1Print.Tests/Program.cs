using System.Buffers.Binary;
using System.Net.Http.Headers;
using S1Print.Engine;

static void Require(bool value, string message) { if (!value) throw new Exception(message); }
static byte[] Raster()
{
    var b = new byte[12 + 32 + 3]; "UNIRAST\0"u8.CopyTo(b); BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(8), 1);
    b[12] = 8; b[13] = 1; BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(24), 8); BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(28), 1);
    BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(32), 406); b[44] = 0; b[45] = 7; b[46] = 0; return b;
}
static byte[] Request(ushort op, Action<IppWriter>? attributes = null, byte[]? data = null)
{
    var w = new IppWriter(op, 456); w.Text(0x45, "printer-uri", "ipp://127.0.0.1:18631/ipp/print"); attributes?.Invoke(w);
    return [.. w.Finish(), .. data ?? []];
}
static ushort Status(byte[] result) => BinaryPrimitives.ReadUInt16BigEndian(result.AsSpan(2));
static async Task WaitUntil(Func<bool> predicate)
{
    for (int i = 0; i < 200; i++) { if (predicate()) return; await Task.Delay(10); }
    throw new Exception("Timed out waiting for job state");
}
var backend = new FakeBackend(); await using var queue = new PrintQueue(backend); await using var server = new IppServer(queue, () => new PrintSettings(), 18631);
var commands = NativeCore.Call(new { Op = "commands" }); Require(commands.GetProperty("stop").GetBytesFromBase64().SequenceEqual(new byte[] { 0x10, 0xff, 0xf1, 0x45 }), "C ABI command response");
var result = NativeCore.Raster(Raster(), new()); Require(result.Width == 384 && result.Height >= 1, "Rust raster path via P/Invoke");
Console.WriteLine("PASS native C ABI and raster processing");
var attributes = server.Handle(Request(11)); Require(Status(attributes) == 0, "Get-Printer-Attributes");
var parsed = IppCodec.Parse(attributes); Require(parsed.Number("queued-job-count") == 0, "Initial queue count");
Require(parsed.Text("printer-name") == "S1 Bluetooth", "Printer name"); Require(parsed.Attributes.Count(a => a.Name == "media-col-database") == 6, "Media collections");
Require(parsed.Attributes.Any(a => a.Name == "y-dimension" && BinaryPrimitives.ReadInt32BigEndian(a.Value) == 60000), "600 mm roll advertised");
var filtered=IppCodec.Parse(server.Handle(Request(11,w=>w.Text(0x44,"requested-attributes","printer-name"))));
Require(filtered.Attributes.Count==3 && filtered.Text("printer-name")=="S1 Bluetooth","Requested printer attributes only");
var badVersion=Request(11);badVersion[0]=0;badVersion[1]=0;Require(Status(server.Handle(badVersion))==0x0503,"Unsupported IPP version");
Console.WriteLine("PASS IPP capabilities, attribute filtering and nested media collections");
Require(Status(server.Handle(Request(4, w => w.Text(0x49, "document-format", "application/pdf")))) == 0x040a, "Reject unsupported PDF over IPP");
Require(Status(server.Handle(Request(4, w => w.Number(0x21, "copies", 0)))) == 0x040b, "Reject invalid copies");
Require(Status(server.Handle(Request(4, w => w.Text(0x44, "sides", "two-sided-long-edge")))) == 0x040b, "Reject unsupported duplex");
Require(Status(server.Handle(Request(4, w => w.Text(0x44, "media", "iso_a4_210x297mm")))) == 0x040b, "Reject unsupported media");
Require(Status(server.Handle(Request(0x1234))) == 0x0501, "Reject unsupported operation");
Console.WriteLine("PASS IPP unsupported attributes and formats");
var print = IppCodec.Parse(server.Handle(Request(2, w => w.Text(0x49, "document-format", "image/urf"), Raster())));
int id = print.Number("job-id"); Require(id > 0, "Print-Job id"); await WaitUntil(() => queue.Find(id)!.Terminal);
Require(queue.Find(id)!.State == 9 && backend.Completed == 1, "Job completes only after backend completion"); Require(queue.Find(id)!.Document is null, "Completed document released");
var create = IppCodec.Parse(server.Handle(Request(5))); int held = create.Number("job-id"); Require(queue.Find(held)!.State == 4, "Create-Job held");
Require(Status(server.Handle(Request(6, w => { w.Number(0x21, "job-id", held); w.Boolean("last-document", false); }, Raster()))) == 0x040b, "Reject unsupported multi-document stream");
Require(Status(server.Handle(Request(6, w => { w.Number(0x21, "job-id", held); w.Boolean("last-document", true); w.Text(0x49, "document-format", "image/urf"); }, Raster()))) == 0, "Send-Document accepted");
await WaitUntil(() => queue.Find(held)!.Terminal); Require(queue.Find(held)!.State == 9, "Send-Document completed");
var cancel = IppCodec.Parse(server.Handle(Request(5))); int canceled = cancel.Number("job-id");
Require(Status(server.Handle(Request(8, w => w.Number(0x21, "job-id", canceled)))) == 0 && queue.Find(canceled)!.State == 7, "Cancel held job");
var broken = IppCodec.Parse(server.Handle(Request(2, data: [1, 2, 3]))); int failed = broken.Number("job-id"); await WaitUntil(() => queue.Find(failed)!.Terminal); Require(queue.Find(failed)!.State == 8, "Malformed raster aborts job");
backend.Block = true; var pending = IppCodec.Parse(server.Handle(Request(2, data: Raster()))); int active = pending.Number("job-id"); await WaitUntil(() => queue.Find(active)!.State == 5);
server.Handle(Request(8, w => w.Number(0x21, "job-id", active))); await WaitUntil(() => queue.Find(active)!.Document is null); Require(queue.Find(active)!.State == 7, "Cancel active job"); backend.Block = false;
Console.WriteLine("PASS print lifecycle, errors, held documents and cancellation");
foreach (int n in Enumerable.Range(0, attributes.Length)) { if (n > 80) break; _ = server.Handle(attributes[..n]); }
Console.WriteLine("PASS malformed IPP requests return structured errors");
await server.StartAsync(); using var client = new HttpClient(); var content = new ByteArrayContent(Request(11)); content.Headers.ContentType = new MediaTypeHeaderValue("application/ipp");
var http = await client.PostAsync("http://127.0.0.1:18631/ipp/print", content); Require(http.IsSuccessStatusCode && Status(await http.Content.ReadAsByteArrayAsync()) == 0, "HTTP IPP round trip");
using var foreign = new HttpRequestMessage(HttpMethod.Post, "http://127.0.0.1:18631/ipp/print") { Content = new ByteArrayContent(Request(11)) }; foreign.Content.Headers.ContentType = new MediaTypeHeaderValue("application/ipp"); foreign.Headers.Add("Origin", "https://example.com");
Require((int)(await client.SendAsync(foreign)).StatusCode == 403, "Reject browser cross-origin request"); var query=new ByteArrayContent(Request(9,w=>w.Number(0x21,"job-id",id)));query.Headers.ContentType=new MediaTypeHeaderValue("application/ipp");
Require(Status(await (await client.PostAsync($"http://127.0.0.1:18631/ipp/print/{id}",query)).Content.ReadAsByteArrayAsync())==0,"Job URI HTTP endpoint");
Console.WriteLine("PASS loopback HTTP endpoint and job URI");
if (args.Contains("--serve")) { Console.WriteLine("Dry-run IPP server: http://127.0.0.1:18631/ipp/print"); await Task.Delay(Timeout.Infinite); }
Console.WriteLine("All native bridge tests passed.");
sealed class FakeBackend : IPrinterBackend
{
    public int Completed; public bool Block;
    public async Task PrintAsync(byte[] document, string format, PrintSettings settings, int copies, CancellationToken token)
    {
        _ = NativeCore.Raster(document, settings); await Task.Delay(Block ? Timeout.Infinite : 5, token); Interlocked.Increment(ref Completed);
    }
}
