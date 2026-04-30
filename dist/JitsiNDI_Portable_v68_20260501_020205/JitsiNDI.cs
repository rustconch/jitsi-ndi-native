using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace JitsiNDIPortableLauncher {
    internal static class Program {
        [STAThread]
        private static void Main(string[] args) {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string ps1 = Path.Combine(baseDir, "JitsiNdiGui.ps1");
            if (!File.Exists(ps1)) {
                MessageBox.Show(
                    "JitsiNdiGui.ps1 was not found near JitsiNDI.exe.",
                    "Jitsi NDI",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32\\WindowsPowerShell\\v1.0\\powershell.exe");
            if (!File.Exists(powershell)) {
                powershell = "powershell.exe";
            }

            string argLine = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + ps1 + "\"";

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = powershell;
            psi.Arguments = argLine;
            psi.WorkingDirectory = baseDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;

            try {
                Process.Start(psi);
            } catch (Exception ex) {
                MessageBox.Show(
                    "Failed to start Jitsi NDI GUI.\r\n\r\n" + ex.Message,
                    "Jitsi NDI",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }
    }
}
