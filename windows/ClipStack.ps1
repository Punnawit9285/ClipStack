<#
    ClipStack for Windows - clipboard history with multi-item paste.

    Run:        powershell -ExecutionPolicy Bypass -File ClipStack.ps1
    Hotkeys:    Ctrl+Shift+V  open the picker
                Ctrl+Shift+N  load the next queued clip

    No installer and no dependencies: the C# below is compiled at launch by the
    compiler that ships with .NET Framework on every Windows 10/11 machine.
#>

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ClipStack {

public class Clip {
    public string Text = "";
    public string App = "";
    public DateTime At = DateTime.Now;
    public bool Pinned = false;

    public string Label(int width) {
        string flat = Text.Replace("\r", " ").Replace("\n", "  ").Replace("\t", " ");
        while (flat.Contains("  ")) flat = flat.Replace("  ", " ");
        flat = flat.Trim();
        if (flat.Length <= width) return flat;
        return flat.Substring(0, width - 1) + "\u2026";   // ellipsis
    }

    public string Meta() {
        string age;
        TimeSpan d = DateTime.Now - At;
        if (d.TotalMinutes < 1) age = "just now";
        else if (d.TotalHours < 1) age = ((int)d.TotalMinutes) + "m ago";
        else if (d.TotalDays < 1) age = ((int)d.TotalHours) + "h ago";
        else age = ((int)d.TotalDays) + "d ago";
        return string.IsNullOrEmpty(App) ? age : App + " \u00B7 " + age;   // middle dot
    }
}

public static class Store {
    public static string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClipStack");
    static string HistoryFile { get { return Path.Combine(Dir, "history.txt"); } }
    static string QueueFile { get { return Path.Combine(Dir, "queue.txt"); } }

    public static List<Clip> Items = new List<Clip>();
    public static int MaxItems = 500;
    public static int MaxChars = 1000000;

    static string Enc(string s) {
        return string.IsNullOrEmpty(s) ? "" : Convert.ToBase64String(Encoding.UTF8.GetBytes(s));
    }
    static string Dec(string s) {
        if (string.IsNullOrEmpty(s)) return "";
        try { return Encoding.UTF8.GetString(Convert.FromBase64String(s)); } catch { return ""; }
    }

    public static void Load() {
        Items.Clear();
        try {
            Directory.CreateDirectory(Dir);
            if (!File.Exists(HistoryFile)) return;
            foreach (string line in File.ReadAllLines(HistoryFile, Encoding.UTF8)) {
                string[] p = line.Split('|');
                if (p.Length < 4) continue;
                long ticks;
                if (!long.TryParse(p[0], out ticks)) continue;
                Clip c = new Clip();
                c.At = new DateTime(ticks);
                c.Pinned = p[1] == "1";
                c.App = Dec(p[2]);
                c.Text = Dec(p[3]);
                if (c.Text.Length > 0) Items.Add(c);
            }
        } catch { }
    }

    public static void Save() {
        try {
            Directory.CreateDirectory(Dir);
            StringBuilder sb = new StringBuilder();
            foreach (Clip c in Items) {
                sb.Append(c.At.Ticks).Append('|')
                  .Append(c.Pinned ? '1' : '0').Append('|')
                  .Append(Enc(c.App)).Append('|')
                  .Append(Enc(c.Text)).Append('\n');
            }
            string tmp = HistoryFile + ".tmp";
            File.WriteAllText(tmp, sb.ToString(), Encoding.UTF8);
            if (File.Exists(HistoryFile)) File.Delete(HistoryFile);
            File.Move(tmp, HistoryFile);
        } catch { }
    }

    /// Adds a clip, promoting an existing identical one instead of duplicating.
    public static bool Add(string text, string app) {
        if (string.IsNullOrEmpty(text) || text.Trim().Length == 0) return false;
        if (text.Length > MaxChars) return false;
        if (Items.Count > 0 && Items[0].Text == text) return false;

        int idx = Items.FindIndex(c => c.Text == text);
        if (idx >= 0) {
            Clip existing = Items[idx];
            Items.RemoveAt(idx);
            existing.At = DateTime.Now;
            if (!string.IsNullOrEmpty(app)) existing.App = app;
            Items.Insert(0, existing);
        } else {
            Clip c = new Clip();
            c.Text = text; c.App = app ?? ""; c.At = DateTime.Now;
            Items.Insert(0, c);
        }
        Trim();
        Save();
        return true;
    }

    static void Trim() {
        if (Items.Count <= MaxItems) return;
        List<Clip> kept = new List<Clip>();
        int unpinned = 0;
        foreach (Clip c in Items) {
            if (c.Pinned) { kept.Add(c); continue; }
            if (unpinned < MaxItems) { kept.Add(c); unpinned++; }
        }
        Items = kept;
    }

    /// Most recent first, with pinned clips hoisted to the top.
    public static List<Clip> Ordered() {
        List<Clip> pinned = new List<Clip>();
        List<Clip> rest = new List<Clip>();
        foreach (Clip c in Items) { if (c.Pinned) pinned.Add(c); else rest.Add(c); }
        pinned.AddRange(rest);
        return pinned;
    }

    public static void ClearUnpinned() {
        Items = Items.Where(c => c.Pinned).ToList();
        Save();
        SaveQueue(new List<string>(), 0);
    }

    // ---- paste queue ----

    public static void SaveQueue(List<string> items, int index) {
        try {
            Directory.CreateDirectory(Dir);
            StringBuilder sb = new StringBuilder();
            sb.Append(index).Append('\n');
            foreach (string s in items) sb.Append(Enc(s)).Append('\n');
            File.WriteAllText(QueueFile, sb.ToString(), Encoding.UTF8);
        } catch { }
    }

    public static List<string> LoadQueue(out int index) {
        index = 0;
        List<string> items = new List<string>();
        try {
            if (!File.Exists(QueueFile)) return items;
            string[] lines = File.ReadAllLines(QueueFile, Encoding.UTF8);
            if (lines.Length == 0) return items;
            int.TryParse(lines[0], out index);
            for (int i = 1; i < lines.Length; i++)
                if (lines[i].Length > 0) items.Add(Dec(lines[i]));
        } catch { }
        return items;
    }
}

public static class Native {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    public const uint MOD_CONTROL = 0x0002, MOD_SHIFT = 0x0004, MOD_NOREPEAT = 0x4000;
    public const uint VK_V = 0x56, VK_N = 0x4E;
    public const byte VK_CONTROL_B = 0x11, VK_SHIFT_B = 0x10;
    public const uint KEYEVENTF_KEYUP = 0x0002;

    public static string ForegroundAppName() {
        try {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return "";
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return Process.GetProcessById((int)pid).ProcessName;
        } catch { return ""; }
    }
}

public static class Clip2 {
    /// Clipboard calls fail if another app holds the clipboard open, so retry.
    public static string GetText() {
        for (int i = 0; i < 6; i++) {
            try { return Clipboard.ContainsText() ? Clipboard.GetText() : null; }
            catch { Thread.Sleep(40); }
        }
        return null;
    }

    public static void SetText(string s) {
        if (string.IsNullOrEmpty(s)) return;
        for (int i = 0; i < 6; i++) {
            try { Clipboard.SetText(s); return; }
            catch { Thread.Sleep(40); }
        }
    }
}

public class PickerForm : Form {
    public static string Separator = "\r\n";
    public static PickerForm Open_ = null;

    ListView list;
    TextBox search;
    List<Clip> shown = new List<Clip>();
    List<string> marks = new List<string>();   // marked clip texts, in the order ticked
    IntPtr prevWindow;
    bool building = false;

    public PickerForm(IntPtr prev) {
        prevWindow = prev;

        Text = "ClipStack";
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        Size = new Size(780, 540);
        BackColor = Color.FromArgb(32, 32, 34);
        Padding = new Padding(1);

        Screen scr = Screen.FromPoint(Cursor.Position);
        StartPosition = FormStartPosition.Manual;
        Location = new Point(
            scr.WorkingArea.X + (scr.WorkingArea.Width - Width) / 2,
            scr.WorkingArea.Y + (scr.WorkingArea.Height - Height) / 3);

        search = new TextBox();
        search.Dock = DockStyle.Top;
        search.BorderStyle = BorderStyle.None;
        search.Font = new Font("Segoe UI", 13F);
        search.BackColor = Color.FromArgb(45, 45, 48);
        search.ForeColor = Color.White;
        search.Margin = new Padding(0);
        search.TextChanged += delegate { Rebuild(); };

        Panel searchPad = new Panel();
        searchPad.Dock = DockStyle.Top;
        searchPad.Height = 40;
        searchPad.BackColor = Color.FromArgb(45, 45, 48);
        searchPad.Padding = new Padding(12, 10, 12, 8);
        searchPad.Controls.Add(search);

        list = new ListView();
        list.Dock = DockStyle.Fill;
        list.View = View.Details;
        list.CheckBoxes = true;
        list.FullRowSelect = true;
        list.MultiSelect = false;
        list.HideSelection = false;
        list.HeaderStyle = ColumnHeaderStyle.None;
        list.Font = new Font("Segoe UI", 10F);
        list.BackColor = Color.FromArgb(32, 32, 34);
        list.ForeColor = Color.White;
        list.BorderStyle = BorderStyle.None;
        list.Columns.Add("Clip", 560);
        list.Columns.Add("Source", 185);
        list.ItemChecked += OnItemChecked;
        list.DoubleClick += delegate { Commit(false); };

        Label hint = new Label();
        hint.Dock = DockStyle.Bottom;
        hint.Height = 30;
        hint.TextAlign = ContentAlignment.MiddleLeft;
        hint.Padding = new Padding(12, 0, 0, 0);
        hint.BackColor = Color.FromArgb(45, 45, 48);
        hint.ForeColor = Color.FromArgb(160, 160, 165);
        hint.Font = new Font("Segoe UI", 8.5F);
        hint.Text = "Enter paste   Tab mark   Ctrl+Enter merge marked   Alt+Enter queue marked   "
                  + "Ctrl+P pin   Ctrl+D delete   Esc close";

        Controls.Add(list);
        Controls.Add(hint);
        Controls.Add(searchPad);

        Rebuild();
        Shown += delegate { search.Focus(); };
    }

    void OnItemChecked(object sender, ItemCheckedEventArgs e) {
        if (building) return;
        string text = (string)e.Item.Tag;
        if (e.Item.Checked) { if (!marks.Contains(text)) marks.Add(text); }
        else marks.Remove(text);
        RenumberMarks();
    }

    /// Shows the tick order as a prefix, so a merge/queue order is visible.
    void RenumberMarks() {
        foreach (ListViewItem item in list.Items) {
            string text = (string)item.Tag;
            int at = marks.IndexOf(text);
            Clip c = shown[item.Index];
            string prefix = at >= 0 ? (at + 1) + ". " : (c.Pinned ? "* " : "");
            item.Text = prefix + c.Label(110);
        }
    }

    void Rebuild() {
        building = true;
        list.BeginUpdate();
        list.Items.Clear();
        shown.Clear();

        string[] terms = search.Text.Trim().ToLowerInvariant()
            .Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);

        foreach (Clip c in Store.Ordered()) {
            string hay = (c.Text + " " + c.App).ToLowerInvariant();
            bool ok = true;
            foreach (string t in terms) if (!hay.Contains(t)) { ok = false; break; }
            if (!ok) continue;

            shown.Add(c);
            ListViewItem item = new ListViewItem((c.Pinned ? "* " : "") + c.Label(110));
            item.SubItems.Add(c.Meta());
            item.Tag = c.Text;
            item.Checked = marks.Contains(c.Text);
            list.Items.Add(item);
        }

        if (list.Items.Count > 0) {
            list.Items[0].Selected = true;
            list.Items[0].Focused = true;
        }
        list.EndUpdate();
        building = false;
        RenumberMarks();
    }

    Clip Current() {
        if (list.SelectedIndices.Count == 0) return null;
        int i = list.SelectedIndices[0];
        return (i >= 0 && i < shown.Count) ? shown[i] : null;
    }

    void MoveSelection(int delta) {
        if (list.Items.Count == 0) return;
        int i = list.SelectedIndices.Count > 0 ? list.SelectedIndices[0] : 0;
        i = Math.Max(0, Math.Min(list.Items.Count - 1, i + delta));
        list.Items[i].Selected = true;
        list.Items[i].Focused = true;
        list.EnsureVisible(i);
    }

    void ToggleMark() {
        if (list.SelectedIndices.Count == 0) return;
        ListViewItem item = list.Items[list.SelectedIndices[0]];
        item.Checked = !item.Checked;
    }

    /// Marked clips in tick order, or the highlighted one when nothing is marked.
    List<string> Chosen() {
        if (marks.Count > 0) return new List<string>(marks);
        List<string> one = new List<string>();
        Clip c = Current();
        if (c != null) one.Add(c.Text);
        return one;
    }

    void Commit(bool asQueue) {
        List<string> chosen = Chosen();
        if (chosen.Count == 0) return;

        if (asQueue) {
            Store.SaveQueue(chosen, 1);
            Clip2.SetText(chosen[0]);
            TrayApp.Notify("Queue started",
                "1/" + chosen.Count + " on the clipboard. Ctrl+Shift+N for the next one.");
        } else {
            Clip2.SetText(string.Join(Separator, chosen));
        }
        CloseAndPaste();
    }

    void CloseAndPaste() {
        Hide();
        if (prevWindow != IntPtr.Zero) Native.SetForegroundWindow(prevWindow);
        // The hotkey's own Ctrl+Shift may still be physically down; let go of it
        // first or the synthesized Ctrl+V turns into Ctrl+Shift+V.
        Native.keybd_event(Native.VK_CONTROL_B, 0, Native.KEYEVENTF_KEYUP, UIntPtr.Zero);
        Native.keybd_event(Native.VK_SHIFT_B, 0, Native.KEYEVENTF_KEYUP, UIntPtr.Zero);
        Thread.Sleep(140);
        try { SendKeys.SendWait("^v"); } catch { }
        Close();
    }

    // Tab, Escape and Enter are swallowed by WinForms dialog navigation before
    // OnKeyDown ever runs, so all key handling happens here instead.
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
        Keys key = keyData & Keys.KeyCode;
        bool ctrl = (keyData & Keys.Control) == Keys.Control;
        bool alt = (keyData & Keys.Alt) == Keys.Alt;

        switch (key) {
            case Keys.Escape:   Close(); return true;
            case Keys.Down:     MoveSelection(1); return true;
            case Keys.Up:       MoveSelection(-1); return true;
            case Keys.PageDown: MoveSelection(8); return true;
            case Keys.PageUp:   MoveSelection(-8); return true;
            case Keys.Tab:      ToggleMark(); return true;
            case Keys.Enter:    Commit(alt); return true;
        }

        if (ctrl && key == Keys.P) {
            Clip c = Current();
            if (c != null) { c.Pinned = !c.Pinned; Store.Save(); Rebuild(); }
            return true;
        }

        if (ctrl && key == Keys.D) {
            Clip c = Current();
            if (c != null) {
                marks.Remove(c.Text);
                Store.Items.Remove(c);
                Store.Save();
                Rebuild();
            }
            return true;
        }

        if (ctrl && key >= Keys.D1 && key <= Keys.D9) {
            int n = key - Keys.D1;
            if (n < shown.Count) { Clip2.SetText(shown[n].Text); CloseAndPaste(); }
            return true;
        }

        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnDeactivate(EventArgs e) { base.OnDeactivate(e); Close(); }
    protected override void OnFormClosed(FormClosedEventArgs e) { Open_ = null; base.OnFormClosed(e); }
}

public class MessageWindow : Form {
    const int WM_CLIPBOARDUPDATE = 0x031D;
    const int WM_HOTKEY = 0x0312;
    public const int HK_PICK = 1, HK_NEXT = 2;
    public static MessageWindow Instance;

    static readonly string[] SkipApps = {
        "1password", "keepass", "keepassxc", "bitwarden", "lastpass", "dashlane", "enpass"
    };

    public bool HotkeysOk = true;

    public MessageWindow() {
        Instance = this;
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.None;
        Size = new Size(1, 1);

        IntPtr h = Handle;   // force the handle so messages can arrive
        Native.AddClipboardFormatListener(h);
        if (!Native.RegisterHotKey(h, HK_PICK, Native.MOD_CONTROL | Native.MOD_SHIFT | Native.MOD_NOREPEAT, Native.VK_V))
            HotkeysOk = false;
        if (!Native.RegisterHotKey(h, HK_NEXT, Native.MOD_CONTROL | Native.MOD_SHIFT | Native.MOD_NOREPEAT, Native.VK_N))
            HotkeysOk = false;
    }

    protected override void SetVisibleCore(bool value) { base.SetVisibleCore(false); }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_CLIPBOARDUPDATE) { CaptureClipboard(); }
        else if (m.Msg == WM_HOTKEY) {
            int id = m.WParam.ToInt32();
            if (id == HK_PICK) OpenPicker();
            else if (id == HK_NEXT) AdvanceQueue();
        }
        base.WndProc(ref m);
    }

    void CaptureClipboard() {
        try {
            // Password managers mark their clips with this format; honour it.
            if (Clipboard.ContainsData("ExcludeClipboardContentFromMonitorProcessing")) return;
        } catch { }

        string app = Native.ForegroundAppName();
        string lower = (app ?? "").ToLowerInvariant();
        foreach (string s in SkipApps) if (lower.Contains(s)) return;

        string text = Clip2.GetText();
        if (text != null) Store.Add(text, app);
    }

    public static void OpenPicker() {
        if (PickerForm.Open_ != null) { PickerForm.Open_.Activate(); return; }
        IntPtr prev = Native.GetForegroundWindow();
        PickerForm f = new PickerForm(prev);
        PickerForm.Open_ = f;
        f.Show();
        f.Activate();
        Native.SetForegroundWindow(f.Handle);
    }

    public static void AdvanceQueue() {
        int index;
        List<string> items = Store.LoadQueue(out index);
        if (items.Count == 0 || index >= items.Count) {
            Store.SaveQueue(new List<string>(), 0);
            TrayApp.Notify("Queue finished", "Nothing left to paste.");
            return;
        }
        Clip2.SetText(items[index]);
        Store.SaveQueue(items, index + 1);
        TrayApp.Notify("ClipStack", (index + 1) + "/" + items.Count + " on the clipboard.");
    }

    protected override void OnFormClosing(FormClosingEventArgs e) {
        Native.RemoveClipboardFormatListener(Handle);
        Native.UnregisterHotKey(Handle, HK_PICK);
        Native.UnregisterHotKey(Handle, HK_NEXT);
        base.OnFormClosing(e);
    }
}

public class TrayApp : ApplicationContext {
    static NotifyIcon icon;
    MessageWindow win;

    public TrayApp() {
        Store.Load();
        win = new MessageWindow();

        icon = new NotifyIcon();
        icon.Icon = SystemIcons.Application;
        icon.Text = "ClipStack - Ctrl+Shift+V";
        icon.Visible = true;
        icon.DoubleClick += delegate { MessageWindow.OpenPicker(); };

        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("Open picker  (Ctrl+Shift+V)", null, delegate { MessageWindow.OpenPicker(); });
        menu.Items.Add("Paste next in queue  (Ctrl+Shift+N)", null, delegate { MessageWindow.AdvanceQueue(); });
        menu.Items.Add(new ToolStripSeparator());

        ToolStripMenuItem sep = new ToolStripMenuItem("Merge separator");
        AddSep(sep, "New line", "\r\n");
        AddSep(sep, "Blank line", "\r\n\r\n");
        AddSep(sep, "Comma + space", ", ");
        AddSep(sep, "Space", " ");
        AddSep(sep, "Tab", "\t");
        menu.Items.Add(sep);

        menu.Items.Add("Clear history (keeps pinned)", null, delegate { Store.ClearUnpinned(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, delegate { Shutdown(); });
        icon.ContextMenuStrip = menu;

        if (!win.HotkeysOk)
            Notify("Hotkey unavailable",
                   "Ctrl+Shift+V or Ctrl+Shift+N is taken by another app. Use the tray icon instead.");
        else
            Notify("ClipStack running", "Ctrl+Shift+V opens your clipboard history.");
    }

    void AddSep(ToolStripMenuItem parent, string label, string value) {
        ToolStripMenuItem mi = new ToolStripMenuItem(label);
        mi.Checked = (PickerForm.Separator == value);
        mi.Click += delegate {
            PickerForm.Separator = value;
            foreach (ToolStripMenuItem other in parent.DropDownItems) other.Checked = false;
            mi.Checked = true;
        };
        parent.DropDownItems.Add(mi);
    }

    public static void Notify(string title, string body) {
        try {
            if (icon == null) return;
            icon.BalloonTipTitle = title;
            icon.BalloonTipText = body;
            icon.ShowBalloonTip(2500);
        } catch { }
    }

    void Shutdown() {
        try { icon.Visible = false; icon.Dispose(); } catch { }
        try { win.Close(); } catch { }
        Application.Exit();
    }
}

public static class Program {
    public static void Run() {
        // A second copy would fight the first over the hotkeys and the history
        // file, so only one runs per user session.
        bool first;
        using (Mutex single = new Mutex(true, "Local\\ClipStack.SingleInstance", out first)) {
            if (!first) {
                MessageBox.Show("ClipStack is already running. Look for its icon in the notification area.",
                                "ClipStack", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayApp());
        }
    }

    /// WinForms clipboard access needs a single-threaded apartment, and PowerShell
    /// cannot run a scriptblock on a thread it did not create ("There is no
    /// Runspace available"), so the STA thread is started from here instead.
    public static void RunOnStaThread() {
        Thread t = new Thread(Run);
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
    }
}

}
'@

Add-Type -TypeDefinition $source `
    -ReferencedAssemblies System.Windows.Forms, System.Drawing `
    -ErrorAction Stop

# WinForms clipboard access requires a single-threaded apartment. PowerShell 7
# defaults to MTA, so run on a thread we control rather than trusting the host.
[ClipStack.Program]::RunOnStaThread()
