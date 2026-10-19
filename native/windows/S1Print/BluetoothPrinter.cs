using System.Threading.Channels;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;
using S1Print.Engine;

namespace S1Print.Windows;
public sealed record PairedPrinter(string Id, string Name) { public override string ToString() => Name; }
public sealed class BluetoothPrinter(Func<Settings> settings) : IPrinterBackend
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public static async Task<IReadOnlyList<PairedPrinter>> PairedAsync()
    {
        var devices = await DeviceInformation.FindAllAsync(BluetoothDevice.GetDeviceSelectorFromPairingState(true));
        return devices.Select(d => new PairedPrinter(d.Id, d.Name)).OrderByDescending(d => d.Name.StartsWith("PPS1") || d.Name.StartsWith("S1_")).ThenBy(d => d.Name).ToArray();
    }
    private sealed class Connection : IAsyncDisposable
    {
        private readonly BluetoothDevice device;
        private readonly RfcommDeviceService service;
        private readonly StreamSocket socket;
        private readonly DataReader reader;
        private readonly DataWriter writer;
        private readonly CancellationTokenSource stopping;
        private readonly Channel<byte> received = Channel.CreateUnbounded<byte>();
        private readonly Task readTask;
        private Connection(BluetoothDevice device, RfcommDeviceService service, StreamSocket socket, CancellationToken token)
        {
            this.device = device; this.service = service; this.socket = socket;
            stopping = CancellationTokenSource.CreateLinkedTokenSource(token);
            reader = new DataReader(socket.InputStream) { InputStreamOptions = InputStreamOptions.Partial };
            writer = new DataWriter(socket.OutputStream);
            readTask = ReadLoop();
        }
        public static async Task<Connection> Open(string id, CancellationToken token)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(8));
            var device = await BluetoothDevice.FromIdAsync(id).AsTask(timeout.Token) ?? throw new IOException("Cannot access printer. Pair it in Windows Bluetooth settings.");
            RfcommDeviceService? service = null; var socket = new StreamSocket();
            try
            {
                var result = await device.GetRfcommServicesForIdAsync(RfcommServiceId.SerialPort, BluetoothCacheMode.Uncached).AsTask(timeout.Token);
                service = result.Services.FirstOrDefault() ?? throw new IOException("Printer has no Bluetooth SPP service");
                await socket.ConnectAsync(service.ConnectionHostName, service.ConnectionServiceName, SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication).AsTask(timeout.Token);
                return new(device, service, socket, token);
            }
            catch { socket.Dispose(); service?.Dispose(); device.Dispose(); throw; }
        }
        private async Task ReadLoop()
        {
            try
            {
                while (!stopping.IsCancellationRequested)
                {
                    uint n = await reader.LoadAsync(1024).AsTask(stopping.Token); if (n == 0) break;
                    var bytes = new byte[n]; reader.ReadBytes(bytes); foreach (byte b in bytes) await received.Writer.WriteAsync(b, stopping.Token);
                }
                received.Writer.TryComplete(new IOException("Printer disconnected"));
            }
            catch (Exception e) { received.Writer.TryComplete(e); }
        }
        public void Clear() { while (received.Reader.TryRead(out _)) { } }
        public async Task Write(byte[] bytes, CancellationToken token)
        {
            for (int offset = 0; offset < bytes.Length; offset += 240)
            {
                token.ThrowIfCancellationRequested(); writer.WriteBytes(bytes.AsSpan(offset, Math.Min(240, bytes.Length - offset)).ToArray());
                await writer.StoreAsync().AsTask(token);
            }
        }
        public async Task<byte[]> Query(byte[] command, int minimum, CancellationToken token)
        {
            Clear(); await Write(command, token);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(3));
            var response = new List<byte>();
            try
            {
                while (true)
                {
                    using var quiet = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);
                    if (response.Count >= minimum) quiet.CancelAfter(TimeSpan.FromMilliseconds(250));
                    response.Add(await received.Reader.ReadAsync(quiet.Token));
                }
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested && response.Count >= minimum) { return response.ToArray(); }
        }
        public async Task WaitOK(int seconds, CancellationToken token)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(seconds));
            int previous = -1;
            try
            {
                while (true) { byte next = await received.Reader.ReadAsync(timeout.Token); if (previous == 0x4f && next == 0x4b) return; previous = next; }
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested) { throw new IOException("Printer did not confirm completion. Check the printed receipt before retrying."); }
        }
        public async ValueTask DisposeAsync()
        {
            stopping.Cancel(); socket.Dispose(); try { await readTask; } catch { }
            reader.Dispose(); writer.Dispose(); service.Dispose(); device.Dispose(); stopping.Dispose();
        }
    }
    private async Task<Connection> Open(CancellationToken token) => await Connection.Open(settings().DeviceId ?? throw new IOException("Select a paired printer first"), token);
    public async Task<string> StatusAsync(CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            await using var connection = await Open(token);
            var status = await connection.Query(NativeCore.Command("status"), 1, token);
            var battery = await connection.Query(NativeCore.Command("battery"), 2, token);
            var model = await connection.Query(NativeCore.Command("model"), 1, token);
            return $"{System.Text.Encoding.UTF8.GetString(model).Trim()}: {NativeCore.Status(status[0]).GetProperty("description").GetString()}, battery {battery[^1]}%";
        }
        finally { gate.Release(); }
    }
    public async Task PrintAsync(byte[] document, string format, PrintSettings options, int copies, CancellationToken token)
    {
        var job = await Task.Run(() => NativeCore.Raster(document, options), token);
        await SendAsync(job, copies, token, options.DeviceId);
    }
    public async Task SendAsync(PreparedJob job, int copies, CancellationToken token, string? deviceId = null)
    {
        if (copies is < 1 or > 99) throw new ArgumentOutOfRangeException(nameof(copies));
        await gate.WaitAsync(token);
        try
        {
            await using var connection = deviceId is null ? await Open(token) : await Connection.Open(deviceId, token);
            var raw = await connection.Query(NativeCore.Command("status"), 1, token); var state = NativeCore.Status(raw[0]);
            if (!state.GetProperty("ready").GetBoolean() || state.GetProperty("printing").GetBoolean()) throw new IOException(state.GetProperty("description").GetString());
            for (int copy = 0; copy < copies; copy++)
            {
                connection.Clear(); await connection.Write(job.Chunks[0], token); await connection.WaitOK(3, token);
                for (int i = 1; i < job.Chunks.Length; i++)
                {
                    if (i == job.Chunks.Length - 1) connection.Clear(); await connection.Write(job.Chunks[i], token);
                }
                await connection.WaitOK(90, token); await Task.Delay(1500, token);
            }
        }
        finally { gate.Release(); }
    }
}
