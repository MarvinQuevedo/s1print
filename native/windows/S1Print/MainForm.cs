using System.Diagnostics;
using Microsoft.Win32;
using S1Print.Engine;

namespace S1Print.Windows;
public sealed class MainForm : Form
{
    private Settings settings = Settings.Load();
    private readonly BluetoothPrinter printer;
    private readonly PrintQueue queue;
    private readonly IppServer server;
    private readonly NotifyIcon tray;
    private readonly ComboBox devices = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 420 };
    private readonly ComboBox density = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 130 };
    private readonly CheckBox fit = new() { Text = "Fit content to printhead width", AutoSize = true };
    private readonly CheckBox label = new() { Text = "Label paper (gap feed)", AutoSize = true };
    private readonly Label status = new() { Text = "Starting…", AutoSize = true, MaximumSize = new Size(650, 0) };
    private readonly PictureBox preview = new() { SizeMode = PictureBoxSizeMode.AutoSize, BackColor = Color.White };
    private readonly Button print = new() { Text = "Print preview", AutoSize = true, Enabled = false };
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? operation;
    private PreparedJob? prepared;
    private bool busy;
    private bool refreshing;
    private bool exit;
    public MainForm()
    {
        Text = "S1Print"; Width = 740; Height = 820; MinimumSize = new Size(580, 600);
        printer = new(() => settings); queue = new(printer); server = new(queue, () => settings.Print);
        queue.StatusChanged += message => { Settings.Log(message); if (!IsDisposed && IsHandleCreated) BeginInvoke(() => SetStatus(message)); };
        var layout = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(16) };
        var viewport = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Color.DarkGray }; viewport.Controls.Add(preview);
        Controls.Add(viewport); Controls.Add(layout);
        void Row(params Control[] controls) { var row = new FlowLayoutPanel { AutoSize = true, WrapContents = true }; row.Controls.AddRange(controls); layout.Controls.Add(row); }
        Button Button(string text, Func<Task> action) { var b = new Button { Text = text, AutoSize = true }; b.Click += async (_, _) => { if (text == "Cancel") await action(); else await Run(action); }; return b; }
        Row(new Label { Text = "S1Print", Font = new Font("Segoe UI", 20), AutoSize = true });
        Row(devices, Button("Refresh", RefreshDevices));
        density.Items.AddRange(["Light", "Medium", "Dark"]); density.SelectedIndex = Math.Clamp(settings.Density, 0, 2); fit.Checked = settings.FitContentWidth; label.Checked = settings.LabelPaper;
        Row(new Label { Text = "Darkness", AutoSize = true }, density); Row(fit, label);
        void Save() { if (refreshing) return; settings = settings with { DeviceId = (devices.SelectedItem as PairedPrinter)?.Id ?? settings.DeviceId, Density = density.SelectedIndex, FitContentWidth = fit.Checked, LabelPaper = label.Checked }; settings.Save(); prepared = null; print.Enabled = false; }
        devices.SelectedIndexChanged += (_, _) => Save(); density.SelectedIndexChanged += (_, _) => Save(); fit.CheckedChanged += (_, _) => Save(); label.CheckedChanged += (_, _) => Save();
        Row(Button("Bluetooth settings", () => { Process.Start(new ProcessStartInfo("ms-settings:bluetooth") { UseShellExecute = true }); return Task.CompletedTask; }), Button("Check status", async () => SetStatus(await printer.StatusAsync(Token))));
        Row(Button("Open PDF or image", async () =>
        {
            using var dialog = new OpenFileDialog { Filter = "Documents|*.pdf;*.png;*.jpg;*.jpeg;*.bmp|All files|*.*" }; if (dialog.ShowDialog() != DialogResult.OK) return;
            var pages = await Documents.ReadAsync(dialog.FileName, Token); await Prepare(pages);
        }), Button("Prepare test page", () => Prepare(Documents.TestPage())));
        print.Click += async (_, _) => await Run(async () => { if (prepared is not null) { SetStatus("Printing…"); await printer.SendAsync(prepared, 1, Token); SetStatus("Printing completed"); } });
        Row(print, Button("Cancel", () => { operation?.Cancel(); foreach (var job in queue.Jobs.Where(j => !j.Terminal)) queue.Cancel(job); return Task.CompletedTask; }));
        Row(Button("Add system printer", () => PrinterRegistration(false)), Button("Remove system printer", () => PrinterRegistration(true)));
        var login = new CheckBox { Text = "Open at login", AutoSize = true, Checked = IsLoginEnabled() }; login.CheckedChanged += (_, _) => { using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); if (login.Checked) key.SetValue("S1Print", $"\"{Environment.ProcessPath}\""); else key.DeleteValue("S1Print", false); }; Row(login);
        Row(Button("Open logs", () => { Directory.CreateDirectory(Settings.DirectoryPath); Process.Start(new ProcessStartInfo(Settings.DirectoryPath) { UseShellExecute = true }); return Task.CompletedTask; }));
        Row(status);
        var menu = new ContextMenuStrip(); menu.Items.Add("Open S1Print", null, (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); });
        menu.Items.Add("Exit", null, async (_, _) => await Shutdown());
        tray = new NotifyIcon { Icon = SystemIcons.Application, Text = "S1Print", Visible = true, ContextMenuStrip = menu }; tray.DoubleClick += (_, _) => { Show(); Activate(); };
        FormClosing += (_, e) => { if (!exit) { e.Cancel = true; Hide(); } };
        Shown += async (_, _) => { await Run(async () => { await server.StartAsync(lifetime.Token); await RefreshDevices(); SetStatus("Ready. Closing this window keeps the printer bridge running in the tray."); }); };
    }
    private CancellationToken Token => operation?.Token ?? lifetime.Token;
    private void SetStatus(string message) { status.Text = message; Settings.Log(message); }
    private async Task Run(Func<Task> action)
    {
        // Cancel remains available while another operation is in progress.
        if (busy) { SetStatus("Wait for the current operation or press Cancel."); return; }
        busy = true; operation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        try { await action(); }
        catch (OperationCanceledException) { SetStatus("Canceled"); }
        catch (Exception e) { SetStatus(e.Message); Settings.Log(e.ToString()); }
        finally { operation.Dispose(); operation = null; busy = false; }
    }
    private async Task RefreshDevices()
    {
        var paired = await BluetoothPrinter.PairedAsync(); string? selected = settings.DeviceId;
        refreshing = true;
        try { devices.DataSource = paired.ToList(); devices.SelectedItem = paired.FirstOrDefault(d => d.Id == selected) ?? paired.FirstOrDefault(d => d.Name.StartsWith("PPS1") || d.Name.StartsWith("S1_")); }
        finally { refreshing = false; }
        settings = settings with { DeviceId = (devices.SelectedItem as PairedPrinter)?.Id }; settings.Save();
        if (paired.Count == 0) SetStatus("No paired devices. Pair the S1 in Windows Bluetooth settings.");
    }
    private async Task Prepare(IReadOnlyList<GrayPageData> pages)
    {
        var options = settings.Print; prepared = await Task.Run(() => NativeCore.Build(pages, options), Token);
        var image = Documents.Preview(prepared); var old = preview.Image; preview.Image = image; old?.Dispose(); print.Enabled = true; SetStatus("Preview ready");
    }
    private async Task PrinterRegistration(bool remove)
    {
        string script = remove ? "Remove-Printer -Name 'S1 Bluetooth' -ErrorAction Stop" : "Add-Printer -Name 'S1 Bluetooth' -IppURL 'http://127.0.0.1:8631/ipp/print' -ErrorAction Stop";
        string encoded = Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(script));
        // Only printer registration elevates; the Bluetooth app and IPP server run as the user.
        using var process = Process.Start(new ProcessStartInfo("powershell.exe", $"-NoProfile -NonInteractive -EncodedCommand {encoded}") { UseShellExecute = true, Verb = "runas" }) ?? throw new IOException("Cannot start printer setup");
        await process.WaitForExitAsync(Token); if (process.ExitCode != 0) throw new IOException("Windows printer setup failed. Check that the IPP bridge is running and consult the native setup guide.");
        SetStatus(remove ? "System printer removed" : "System printer added");
    }
    private static bool IsLoginEnabled() { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); return key?.GetValue("S1Print") is not null; }
    private async Task Shutdown()
    {
        lifetime.Cancel(); operation?.Cancel(); await server.DisposeAsync(); await queue.DisposeAsync(); exit = true; tray.Visible = false; tray.Dispose(); preview.Image?.Dispose(); Close();
    }
}
