// The entry point of ClipStack.exe. The app itself is the C# inside
// windows/ClipStack.ps1; this file only makes it a one-click download:
// the first run installs it for the current user, starts it with Windows,
// and lists it in the Start menu and in Settings > Apps.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ClipStack {

public static class AppMain {
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipStack";

    static string InstallDir {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "ClipStack"); }
    }
    static string InstalledExe { get { return Path.Combine(InstallDir, "ClipStack.exe"); } }
    static string StartMenuShortcut {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "ClipStack.lnk"); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool DeleteFile(string path);

    [STAThread]
    public static void Main(string[] args) {
        if (args.Contains("--uninstall")) {   // from Settings > Apps
            Application.EnableVisualStyles();
            Uninstall();
            return;
        }
        string me = Application.ExecutablePath;
        bool installed = string.Equals(Path.GetFullPath(me), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);
        if (!installed && !args.Contains("--portable") && Install(me)) {
            Process.Start(InstalledExe, "--installed");
            return;
        }
        TrayApp.TrayIcon = Icon.ExtractAssociatedIcon(me);
        TrayApp.ExtendMenu = AddMenuItems;
        // Say so plainly: a tray icon alone is easy to miss, as Windows 11 tucks
        // new ones away and notifications may be off.
        if (args.Contains("--installed")) TrayApp.Welcome =
            "ClipStack is installed and running.\n\n" +
            "Press Ctrl+Shift+V anywhere to open your clipboard history. Tick clips with Tab, then press " +
            "Enter to paste them together, or Alt+Enter to queue them and paste one at a time with Ctrl+Shift+N.\n\n" +
            "Its icon is in the notification area (click ^ next to the clock if you don't see it). " +
            "ClipStack starts with Windows. It's in the Start menu, and you can remove it in Settings > Apps.";
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
        } catch {
            return false;   // run from where it is instead
        }
        // ClipStack works without these, so a failure here doesn't stop it.
        try { CreateStartMenuShortcut(); } catch { }
        try { RegisterUninstaller(); } catch { }
        return true;
    }

    /// Late-bound WScript.Shell, so no COM interop assembly is needed.
    static void CreateStartMenuShortcut() {
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        object shell = Activator.CreateInstance(shellType);
        try {
            object link = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell,
                                                 new object[] { StartMenuShortcut });
            try {
                Type linkType = link.GetType();
                linkType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { InstalledExe });
                linkType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, link, new object[] { InstallDir });
                linkType.InvokeMember("Description", BindingFlags.SetProperty, null, link,
                                      new object[] { "Clipboard history with multi-clip paste" });
                linkType.InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
            } finally { Marshal.FinalReleaseComObject(link); }
        } finally { Marshal.FinalReleaseComObject(shell); }
    }

    /// Lists ClipStack in Settings > Apps, whose Uninstall runs "ClipStack.exe --uninstall".
    static void RegisterUninstaller() {
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(UninstallKey)) {
            key.SetValue("DisplayName", "ClipStack");
            key.SetValue("DisplayVersion", Assembly.GetExecutingAssembly().GetName().Version.ToString(3));
            key.SetValue("DisplayIcon", InstalledExe);
            key.SetValue("InstallLocation", InstallDir);
            key.SetValue("UninstallString", "\"" + InstalledExe + "\" --uninstall");
            key.SetValue("EstimatedSize", (int)(new FileInfo(InstalledExe).Length / 1024), RegistryValueKind.DWord);
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
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
        StopInstalledCopy();   // the one in the tray, when this runs from Settings > Apps
        StartWithWindows(false);
        try { File.Delete(StartMenuShortcut); } catch { }
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }
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
