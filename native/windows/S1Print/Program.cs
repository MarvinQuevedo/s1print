namespace S1Print.Windows;
internal static class Program
{
    [STAThread]
    static void Main()
    {
        using var mutex = new Mutex(true, @"Local\S1Print-Native", out bool first);
        ApplicationConfiguration.Initialize();
        if (!first) { MessageBox.Show("S1Print is already running. Open it from the system tray.", "S1Print"); return; }
        Application.ThreadException += (_, e) => Settings.Log(e.Exception.ToString());
        Application.Run(new MainForm());
    }
}
