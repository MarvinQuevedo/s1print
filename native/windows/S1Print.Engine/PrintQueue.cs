using System.Collections.Concurrent;
using System.Threading.Channels;

namespace S1Print.Engine;

public sealed record PrintSettings(int Density = 1, bool FitContentWidth = true, bool LabelPaper = false, string? DeviceId = null);
public interface IPrinterBackend
{
    Task PrintAsync(byte[] document, string format, PrintSettings settings, int copies, CancellationToken token);
}
public sealed class QueuedJob(int id, string name, string user, string format, PrintSettings settings, int copies)
{
    public int Id { get; } = id;
    public string Name { get; } = name;
    public string User { get; } = user;
    public string Format { get; set; } = format;
    public PrintSettings Settings { get; } = settings;
    public int Copies { get; } = copies;
    public int State { get; set; } = 4;
    public string Message { get; set; } = "Waiting for document";
    public CancellationTokenSource Cancellation { get; } = new();
    public byte[]? Document { get; set; }
    public bool Terminal => State is 7 or 8 or 9;
}
public sealed class PrintQueue : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly ConcurrentDictionary<int, QueuedJob> jobs = new();
    private readonly Channel<QueuedJob> channel = Channel.CreateUnbounded<QueuedJob>(new() { SingleReader = true });
    private readonly CancellationTokenSource stopping = new();
    private readonly Task worker;
    private int next;
    private long bytesQueued;
    public event Action<string>? StatusChanged;
    private void Notify(string message) { try { StatusChanged?.Invoke(message); } catch { /* UI/log failures must not stop the queue. */ } }
    public PrintQueue(IPrinterBackend backend) { worker = Task.Run(() => Work(backend)); }
    public IReadOnlyList<QueuedJob> Jobs => jobs.Values.OrderBy(j => j.Id).ToArray();
    public QueuedJob? Find(int id) => jobs.GetValueOrDefault(id);
    public QueuedJob Create(string name, string user, string format, PrintSettings settings, int copies)
    {
        lock (gate)
        {
            foreach (var old in jobs.Values.Where(j => j.Terminal).OrderByDescending(j => j.Id).Skip(50)) { jobs.TryRemove(old.Id, out _); old.Cancellation.Dispose(); }
            if (jobs.Values.Count(j => !j.Terminal) >= 32) throw new InvalidOperationException("Print queue is full");
            var job = new QueuedJob(++next, name[..Math.Min(name.Length, 255)], user[..Math.Min(user.Length, 255)], format, settings, copies);
            jobs[job.Id] = job; return job;
        }
    }
    public void Submit(QueuedJob job, byte[] document)
    {
        lock (gate)
        {
            if (job.State != 4) throw new InvalidOperationException("Job is not awaiting a document");
            if (document.Length == 0 || document.Length > 64 * 1024 * 1024 || bytesQueued + document.Length > 128L * 1024 * 1024) throw new InvalidOperationException("Document or queue exceeds memory limit");
            bytesQueued += document.Length; job.Document = document; job.State = 3; job.Message = "Queued";
            if (!channel.Writer.TryWrite(job)) throw new InvalidOperationException("Queue is stopping");
        }
    }
    public void Cancel(QueuedJob job)
    {
        lock (gate) { if (job.Terminal) return; job.Cancellation.Cancel(); job.State = 7; job.Message = "Canceled"; }
    }
    private async Task Work(IPrinterBackend backend)
    {
        try
        {
            await foreach (var job in channel.Reader.ReadAllAsync(stopping.Token))
            {
                using var linked = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token, job.Cancellation.Token);
                try
                {
                    linked.Token.ThrowIfCancellationRequested(); job.State = 5; job.Message = "Printing"; Notify($"{job.Name}: printing");
                    await backend.PrintAsync(job.Document!, job.Format, job.Settings, job.Copies, linked.Token);
                    linked.Token.ThrowIfCancellationRequested(); job.State = 9; job.Message = "Completed";
                }
                catch (OperationCanceledException) { job.State = 7; job.Message = "Canceled"; }
                catch (Exception e) { job.State = 8; job.Message = e.Message; }
                finally
                {
                    lock (gate) { bytesQueued -= job.Document?.Length ?? 0; job.Document = null; }
                    Notify($"{job.Name}: {job.Message}");
                }
            }
        }
        catch (OperationCanceledException) { }
    }
    public async ValueTask DisposeAsync()
    {
        stopping.Cancel(); channel.Writer.TryComplete(); await worker;
        foreach (var job in jobs.Values) job.Cancellation.Dispose(); stopping.Dispose();
    }
}
