using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Launcher {
    [STAThread]
    private static void Main(string[] args) {
        try {
            string folder = AppDomain.CurrentDomain.BaseDirectory;
            string runtime = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"EliteStudioWindows\venv\Scripts\pythonw.exe");
            if (!File.Exists(runtime)) {
                var setup = Process.Start(new ProcessStartInfo(Path.Combine(folder, "Ripara Elite Studio.bat")) { UseShellExecute = true, WorkingDirectory = folder });
                setup.WaitForExit();
                if (!File.Exists(runtime)) throw new Exception("Installazione incompleta. Esegui Ripara Elite Studio.bat.");
            }
            string script = Path.Combine(folder, @"Windows\launcher.py");
            string arguments = Quote(script);
            foreach (string arg in args) arguments += " " + Quote(arg);
            Process.Start(new ProcessStartInfo(runtime, arguments) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = folder });
        } catch (Exception error) {
            MessageBox.Show(error.Message, "Elite Studio - Avvio", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
    private static string Quote(string value) {
        var result = new System.Text.StringBuilder("\"");
        int slashes = 0;
        foreach (char letter in value) {
            if (letter == '\\') { slashes++; continue; }
            result.Append('\\', letter == '"' ? slashes * 2 + 1 : slashes);
            result.Append(letter); slashes = 0;
        }
        result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
    }
}
