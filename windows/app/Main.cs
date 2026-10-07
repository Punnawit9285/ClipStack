// The entry point of ClipStack.exe. The app itself is the C# inside
// windows/ClipStack.ps1; this file only makes it a one-click download:
// the first run installs it for the current user and starts it with Windows.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ClipStack {

public static class AppMain {
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    static string InstallDir {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "ClipStack"); }
    }
    static string InstalledExe { get { return Path.Combine(InstallDir, "ClipStack.exe"); } }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool DeleteFile(string path);

    [STAThread]
    public static void Main(string[] args) {
        string me = Application.ExecutablePath;
        bool installed = string.Equals(Path.GetFullPath(me), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);
        if (!installed && !args.Contains("--portable") && Install(me)) {
            Process.Start(InstalledExe);
            return;
        }
        TrayApp.TrayIcon = Icon.ExtractAssociatedIcon(me);
        TrayApp.ExtendMenu = AddMenuItems;
        Program.Run();
    }

    /// Copies this exe to %LOCALAPPDATA%\Programs\ClipStack (no admin rights
    /// needed), replacing a running older copy, and starts it with Windows.
    static bool Install(string source) {
        try {
            StopInstalledCopy();
            Directory.CreateDirectory(InstallDir);
            File.Copy(source, InstalledExe, true);
            // The download's "came from the internet" mark would make Windows ask again at every login.
            DeleteFile(InstalledExe + ":Zone.Identifier");
            StartWithWindows(true);
            RemoveOldStartupScript();
            return true;
        } catch {
            return false;   // run from where it is instead
        }
    }

    static void StopInstalledCopy() {
        foreach (Process p in Process.GetProcessesByName("ClipStack")) {
            try {
                if (p.Id == Process.GetCurrentProcess().Id) continue;
                if (!string.Equals(p.MainModule.FileName, InstalledExe, StringComparison.OrdinalIgnoreCase)) continue;
                p.Kill();
                p.WaitForExit(3000);
            } catch { }
        }
    }

    static bool StartsWithWindows() {
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKey)) {
            return key != null && key.GetValue("ClipStack") != null;
        }
    }

    static void StartWithWindows(bool on) {
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey)) {
            if (on) key.SetValue("ClipStack", "\"" + InstalledExe + "\"");
            else if (key.GetValue("ClipStack") != null) key.DeleteValue("ClipStack");
        }
    }

    /// Install-ClipStack.cmd (the PowerShell version) starts from a .vbs in Startup.
    static void RemoveOldStartupScript() {
        string vbs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "ClipStack.vbs");
        if (File.Exists(vbs)) File.Delete(vbs);
    }

    static void AddMenuItems(ContextMenuStrip menu) {
        menu.Items.Add(new ToolStripSeparator());
        ToolStripMenuItem startup = new ToolStripMenuItem("Start with Windows");
        startup.Checked = StartsWithWindows();
        startup.Click += delegate {
            StartWithWindows(!startup.Checked);
            startup.Checked = StartsWithWindows();
        };
        menu.Items.Add(startup);
        menu.Items.Add("Uninstall ClipStack...", null, delegate { Uninstall(); });
    }

    static void Uninstall() {
        DialogResult answer = MessageBox.Show(
            "Remove ClipStack from this computer?\n\nYour clipboard history stays in " + Store.Dir +
            " until you delete it.", "Uninstall ClipStack", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
        if (answer != DialogResult.OK) return;
        StartWithWindows(false);
        // The exe can't delete itself while running; a short-lived cmd does it once we exit.
        ProcessStartInfo cleanup = new ProcessStartInfo("cmd.exe",
            "/c timeout /t 2 /nobreak >nul & rmdir /s /q \"" + InstallDir + "\"");
        cleanup.WindowStyle = ProcessWindowStyle.Hidden;
        cleanup.CreateNoWindow = true;
        Process.Start(cleanup);
        Application.Exit();
    }
}

}
