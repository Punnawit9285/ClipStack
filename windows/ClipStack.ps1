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
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ClipStack {

public class Clip {
    public string Text = "";
    public string App = "";
    public DateTime At = DateTime.Now;
    public bool Pinned = false;
    // An image copied as data: its PNG file in Store.MediaDir.
    public string Image = null;
    public int Width = 0, Height = 0;
    public long Bytes = 0;
    // Files copied in Explorer (videos included), kept by reference, never copied.
    public string[] Files = null;

    /// What makes two clips the same, for de-duplication.
    public string Key() {
        if (Image != null) return "image:" + Image;
        if (Files != null) return "files:" + string.Join("\n", Files);
        return "text:" + Text;
    }

    public string Label(int width) {
        string flat = Text.Replace("\r", " ").Replace("\n", "  ").Replace("\t", " ");
        while (flat.Contains("  ")) flat = flat.Replace("  ", " ");
        flat = flat.Trim();
        string line;
        if (Image != null) line = "[Image " + Width + "x" + Height + "]" + (flat.Length > 0 ? " " + flat : "");
        else if (Files != null) line = DescribeFiles(Files);
        else line = flat;
        if (line.Length <= width) return line;
        return line.Substring(0, width - 1) + "\u2026";   // ellipsis
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

    static readonly string[] VideoExt = { ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".wmv", ".webm", ".mpg", ".mpeg", ".3gp" };
    static readonly string[] ImageExt = { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic" };
    static readonly string[] AudioExt = { ".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".wma" };

    static string FileName(string path) {
        int cut = Math.Max(path.LastIndexOf('\\'), path.LastIndexOf('/'));
        return cut >= 0 ? path.Substring(cut + 1) : path;
    }

    /// Chosen from the extension alone, so listing never touches the disk.
    public static string Kind(string path) {
        string name = FileName(path).ToLowerInvariant();
        int dot = name.LastIndexOf('.');
        string ext = dot >= 0 ? name.Substring(dot) : "";
        if (VideoExt.Contains(ext)) return "Video";
        if (ImageExt.Contains(ext)) return "Image";
        if (AudioExt.Contains(ext)) return "Audio";
        return "File";
    }

    public static string DescribeFiles(string[] files) {
        if (files.Length == 1) return "[" + Kind(files[0]) + "] " + FileName(files[0]);
        return "[" + files.Length + " files] " + string.Join(", ", files.Select(FileName));
    }
}

public static class Store {
    public static string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClipStack");
    static string HistoryFile { get { return Path.Combine(Dir, "history.txt"); } }
    static string QueueFile { get { return Path.Combine(Dir, "queue.txt"); } }
    public static string MediaDir { get { return Path.Combine(Dir, "media"); } }

    public static List<Clip> Items = new List<Clip>();
    public static int MaxItems = 500;
    public static int MaxChars = 1000000;
    public static bool RecordMedia = true;
    public static long MaxMediaBytes = 100L * 1024 * 1024;     // skip bigger images
    public static long MediaBudget = 1024L * 1024 * 1024;      // oldest images go first beyond this
    // A file the recorder has just written may not be in history yet; leave it be.
    public static int PruneGraceSeconds = 60;

    static string Enc(string s) {
        return string.IsNullOrEmpty(s) ? "" : Convert.ToBase64String(Encoding.UTF8.GetBytes(s));
    }
    static string Dec(string s) {
        if (string.IsNullOrEmpty(s)) return "";
        try { return Encoding.UTF8.GetString(Convert.FromBase64String(s)); } catch { return ""; }
    }

    // One clip per line: ticks|pinned|app|text[|kind|payload], text fields base64.
    // kind "i" = image (file;width;height;bytes), "f" = files (base64 of the paths).
    static string Serialize(Clip c) {
        StringBuilder sb = new StringBuilder();
        sb.Append(c.At.Ticks).Append('|').Append(c.Pinned ? '1' : '0').Append('|')
          .Append(Enc(c.App)).Append('|').Append(Enc(c.Text));
        if (c.Image != null)
            sb.Append("|i|").Append(c.Image).Append(';').Append(c.Width).Append(';')
              .Append(c.Height).Append(';').Append(c.Bytes);
        else if (c.Files != null)
            sb.Append("|f|").Append(Enc(string.Join("\n", c.Files)));
        return sb.ToString();
    }

    static Clip Parse(string line) {
        string[] p = line.Split('|');
        if (p.Length < 4) return null;
        long ticks;
        if (!long.TryParse(p[0], out ticks)) return null;
        Clip c = new Clip();
        c.At = new DateTime(ticks);
        c.Pinned = p[1] == "1";
        c.App = Dec(p[2]);
        c.Text = Dec(p[3]);
        if (p.Length >= 6 && p[4] == "i") {
            string[] m = p[5].Split(';');
            if (m.Length < 4) return null;
            c.Image = m[0];
            int.TryParse(m[1], out c.Width);
            int.TryParse(m[2], out c.Height);
            long.TryParse(m[3], out c.Bytes);
        } else if (p.Length >= 6 && p[4] == "f") {
            c.Files = Dec(p[5]).Split('\n');
        } else if (c.Text.Length == 0) {
            return null;
        }
        return c;
    }

    public static void Load() {
        Items.Clear();
        try {
            Directory.CreateDirectory(Dir);
            if (!File.Exists(HistoryFile)) return;
            foreach (string line in File.ReadAllLines(HistoryFile, Encoding.UTF8)) {
                Clip c = Parse(line);
                if (c != null) Items.Add(c);
            }
        } catch { }
    }

    public static void Save() {
        try {
            Directory.CreateDirectory(Dir);
            StringBuilder sb = new StringBuilder();
            foreach (Clip c in Items) sb.Append(Serialize(c)).Append('\n');
            WriteAtomically(HistoryFile, Encoding.UTF8.GetBytes(sb.ToString()));
        } catch { }
    }

    static void WriteAtomically(string path, byte[] data) {
        string tmp = path + ".tmp";
        File.WriteAllBytes(tmp, data);
        if (File.Exists(path)) File.Delete(path);
        File.Move(tmp, path);
    }

    public static bool Add(string text, string app) {
        Clip c = new Clip();
        c.Text = text ?? ""; c.App = app ?? "";
        return Add(c);
    }

    /// Adds a clip, promoting an existing identical one instead of duplicating.
    public static bool Add(Clip clip) {
        if (clip.Image == null && clip.Files == null) {
            if (clip.Text.Trim().Length == 0) return false;
            if (clip.Text.Length > MaxChars) return false;
        }
        string key = clip.Key();
        if (Items.Count > 0 && Items[0].Key() == key) return false;

        int idx = Items.FindIndex(c => c.Key() == key);
        if (idx >= 0) {
            Clip existing = Items[idx];
            Items.RemoveAt(idx);
            existing.At = DateTime.Now;
            if (!string.IsNullOrEmpty(clip.App)) existing.App = clip.App;
            Items.Insert(0, existing);
        } else {
            clip.At = DateTime.Now;
            Items.Insert(0, clip);
        }
        bool dropped = Trim();
        Save();
        if (dropped) PruneMedia();
        return true;
    }

    /// Moves a clip to the top, e.g. when ClipStack itself pasted it back.
    public static bool Promote(string key) {
        Clip c = Items.Find(x => x.Key() == key);
        return c != null && Add(c);
    }

    /// Enforces MaxItems and the media budget. Returns true if anything went.
    static bool Trim() {
        List<Clip> kept = new List<Clip>();
        int unpinned = 0;
        long media = 0;
        foreach (Clip c in Items) {
            if (c.Pinned) { kept.Add(c); continue; }
            if (++unpinned > MaxItems) continue;
            if (c.Image != null) {
                media += c.Bytes;
                if (media > MediaBudget) continue;   // newest first, so older images go
            }
            kept.Add(c);
        }
        bool dropped = kept.Count != Items.Count;
        Items = kept;
        return dropped;
    }

    /// Most recent first, with pinned clips hoisted to the top.
    public static List<Clip> Ordered() {
        List<Clip> pinned = new List<Clip>();
        List<Clip> rest = new List<Clip>();
        foreach (Clip c in Items) { if (c.Pinned) pinned.Add(c); else rest.Add(c); }
        pinned.AddRange(rest);
        return pinned;
    }

    public static void Remove(Clip c) {
        Items.Remove(c);
        Save();
        PruneMedia();
    }

    public static void ClearUnpinned() {
        Items = Items.Where(c => c.Pinned).ToList();
        Save();
        SaveQueue(new List<Clip>(), 0);
        PruneMedia();
    }

    // ---- images ----

    /// Stores PNG bytes under a name taken from their content (so the same
    /// image is stored once) and returns a clip for them, or null when too big.
    /// Touches only the media folder, so it is safe on the recorder thread.
    public static Clip SaveImage(byte[] png, string text, string app) {
        if (png == null || png.Length == 0 || png.Length > MaxMediaBytes) return null;
        int w, h;
        if (!PngSize(png, out w, out h)) return null;
        string name;
        using (SHA256 sha = SHA256.Create()) {
            byte[] hash = sha.ComputeHash(png);
            name = string.Concat(hash.Take(8).Select(b => b.ToString("x2"))) + ".png";
        }
        Directory.CreateDirectory(MediaDir);
        string path = Path.Combine(MediaDir, name);
        if (!File.Exists(path)) WriteAtomically(path, png);
        Clip c = new Clip();
        c.Image = name; c.Width = w; c.Height = h; c.Bytes = png.Length;
        c.Text = text ?? ""; c.App = app ?? "";
        return c;
    }

    /// Reads the size from the PNG header, without decoding any pixels.
    public static bool PngSize(byte[] png, out int w, out int h) {
        w = h = 0;
        if (png.Length < 24 || png[0] != 0x89 || png[1] != (byte)'P') return false;
        w = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
        h = (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23];
        return w > 0 && h > 0;
    }

    public static byte[] ReadImage(Clip c) {
        try { return File.ReadAllBytes(Path.Combine(MediaDir, c.Image)); } catch { return null; }
    }

    /// Deletes stored images that neither history nor the paste queue uses.
    public static void PruneMedia() {
        try {
            if (!Directory.Exists(MediaDir)) return;
            HashSet<string> used = new HashSet<string>(Items.Where(c => c.Image != null).Select(c => c.Image));
            int index;
            foreach (Clip c in LoadQueue(out index)) if (c.Image != null) used.Add(c.Image);
            foreach (string path in Directory.GetFiles(MediaDir)) {
                string name = Path.GetFileName(path);
                if (used.Contains(name) || name.EndsWith(".tmp")) continue;
                if ((DateTime.Now - File.GetLastWriteTime(path)).TotalSeconds < PruneGraceSeconds) continue;
                File.Delete(path);
            }
        } catch { }
    }

    // ---- paste queue ----

    public static void SaveQueue(List<Clip> items, int index) {
        try {
            Directory.CreateDirectory(Dir);
            StringBuilder sb = new StringBuilder();
            sb.Append(index).Append('\n');
            foreach (Clip c in items) sb.Append(Serialize(c)).Append('\n');
            File.WriteAllText(QueueFile, sb.ToString(), Encoding.UTF8);
        } catch { }
    }

    public static List<Clip> LoadQueue(out int index) {
        index = 0;
        List<Clip> items = new List<Clip>();
        try {
            if (!File.Exists(QueueFile)) return items;
            string[] lines = File.ReadAllLines(QueueFile, Encoding.UTF8);
            if (lines.Length == 0) return items;
            int.TryParse(lines[0], out index);
            for (int i = 1; i < lines.Length; i++) {
                Clip c = Parse(lines[i]);
                if (c != null) items.Add(c);
            }
        } catch { }
        return items;
    }
}

/// CF_HTML, the clipboard's HTML format: a header of byte offsets, then the page.
public static class Html {
    public static string Escape(string s) {
        return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
                .Replace("\r\n", "<br>").Replace("\n", "<br>");
    }

    public static string Wrap(string fragment) {
        const string header = "Version:0.9\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\n"
                            + "StartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
        const string pre = "<html><body><!--StartFragment-->";
        const string post = "<!--EndFragment--></body></html>";
        int startHtml = string.Format(header, 0, 0, 0, 0).Length;
        int startFragment = startHtml + Encoding.UTF8.GetByteCount(pre);
        int endFragment = startFragment + Encoding.UTF8.GetByteCount(fragment);
        int endHtml = endFragment + Encoding.UTF8.GetByteCount(post);
        return string.Format(header, startHtml, endHtml, startFragment, endFragment) + pre + fragment + post;
    }
}

/// Records clips on one background thread, in the order they were copied, so
/// encoding and hashing a big image never makes the picker or tray stutter.
/// Each job returns what to do next on the UI thread, where Store lives.
public static class Recorder {
    static BlockingCollection<Func<MethodInvoker>> jobs = new BlockingCollection<Func<MethodInvoker>>();
    static Control ui;

    public static void Start(Control uiThread) {
        ui = uiThread;
        Thread t = new Thread(delegate() {
            foreach (Func<MethodInvoker> job in jobs.GetConsumingEnumerable()) {
                try {
                    MethodInvoker then = job();
                    if (then != null) ui.BeginInvoke(then);
                } catch { }
            }
        });
        t.IsBackground = true;
        t.Priority = ThreadPriority.BelowNormal;
        t.Start();
    }

    public static void Enqueue(Func<MethodInvoker> job) { jobs.Add(job); }

    public static void Add(Clip c) {
        Enqueue(delegate { return delegate { Store.Add(c); }; });
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
    /// Set on everything ClipStack puts back on the clipboard, holding the
    /// clip's key, so the recorder just promotes it instead of storing it again.
    public const string RestoredFormat = "ClipStack.Restored";

    /// Clipboard calls fail if another app holds the clipboard open, so retry.
    public static IDataObject GetData() {
        for (int i = 0; i < 6; i++) {
            try { return Clipboard.GetDataObject(); }
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

    static void Put(DataObject obj) {
        try { Clipboard.SetDataObject(obj, true, 6, 40); } catch { }
    }

    /// Puts a clip back the way it was copied: text as text, an image as an
    /// image, files as the files themselves.
    public static void SetClip(Clip c) {
        if (c.Image == null && c.Files == null) { SetText(c.Text); return; }
        DataObject obj = new DataObject();
        if (c.Files != null) {
            StringCollection files = new StringCollection();
            files.AddRange(c.Files);
            obj.SetFileDropList(files);
            obj.SetText(string.Join("\r\n", c.Files));
        } else {
            byte[] png = Store.ReadImage(c);
            if (png == null) { SetText(c.Text.Length > 0 ? c.Text : c.Label(200)); return; }
            obj.SetData("PNG", false, new MemoryStream(png));   // keeps transparency
            // The classic bitmap format too, for older apps; skipped for huge images.
            if ((long)c.Width * c.Height <= 25000000) {
                using (MemoryStream ms = new MemoryStream(png))
                using (Bitmap tmp = new Bitmap(ms)) obj.SetImage(new Bitmap(tmp));
            }
            if (c.Text.Length > 0) obj.SetText(c.Text);
        }
        obj.SetData(RestoredFormat, c.Key());
        Put(obj);
    }

    /// Pastes several clips as one: text joined; files all together; anything
    /// with an image as HTML with the pictures inline (Word, Outlook, Gmail...),
    /// plus the text on its own for plain fields.
    public static void SetMerged(List<Clip> clips, string sep) {
        if (clips.Count == 1) { SetClip(clips[0]); return; }
        if (clips.TrueForAll(c => c.Image == null && c.Files == null)) {
            SetText(string.Join(sep, clips.Select(c => c.Text)));
            return;
        }
        DataObject obj = new DataObject();
        if (clips.TrueForAll(c => c.Files != null)) {
            StringCollection files = new StringCollection();
            foreach (Clip c in clips) files.AddRange(c.Files);
            obj.SetFileDropList(files);
            obj.SetText(string.Join(sep, clips.Select(c => c.Text)));
            Put(obj);
            return;
        }
        StringBuilder html = new StringBuilder();
        List<string> plain = new List<string>();
        for (int i = 0; i < clips.Count; i++) {
            Clip c = clips[i];
            if (i > 0) html.Append(Html.Escape(sep));
            byte[] png = c.Image != null ? Store.ReadImage(c) : null;
            if (png != null) {
                html.Append("<img src=\"data:image/png;base64,").Append(Convert.ToBase64String(png))
                    .Append("\" width=\"").Append(c.Width).Append("\" height=\"").Append(c.Height).Append("\">");
            } else {
                html.Append(Html.Escape(c.Text));
                plain.Add(c.Text);
            }
        }
        obj.SetData(DataFormats.Html, Html.Wrap(html.ToString()));
        if (plain.Count > 0) obj.SetText(string.Join(sep, plain));
        Put(obj);
    }
}

public class PickerForm : Form {
    public static string Separator = "\r\n";
    public static PickerForm Open_ = null;

    ListView list;
    TextBox search;
    List<Clip> shown = new List<Clip>();
    List<string> marks = new List<string>();   // marked clip keys, in the order ticked
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
        string key = (string)e.Item.Tag;
        if (e.Item.Checked) { if (!marks.Contains(key)) marks.Add(key); }
        else marks.Remove(key);
        RenumberMarks();
    }

    /// Shows the tick order as a prefix, so a merge/queue order is visible.
    void RenumberMarks() {
        foreach (ListViewItem item in list.Items) {
            int at = marks.IndexOf((string)item.Tag);
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
            string hay = (c.Text + " " + c.App + " " + c.Label(400)).ToLowerInvariant();
            bool ok = true;
            foreach (string t in terms) if (!hay.Contains(t)) { ok = false; break; }
            if (!ok) continue;

            shown.Add(c);
            ListViewItem item = new ListViewItem((c.Pinned ? "* " : "") + c.Label(110));
            item.SubItems.Add(c.Meta());
            item.Tag = c.Key();
            item.Checked = marks.Contains(c.Key());
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
    List<Clip> Chosen() {
        List<Clip> chosen = new List<Clip>();
        foreach (string key in marks) {
            Clip c = Store.Items.Find(x => x.Key() == key);
            if (c != null) chosen.Add(c);
        }
        if (chosen.Count == 0 && Current() != null) chosen.Add(Current());
        return chosen;
    }

    void Commit(bool asQueue) {
        List<Clip> chosen = Chosen();
        if (chosen.Count == 0) return;

        if (asQueue) {
            Store.SaveQueue(chosen, 1);
            Clip2.SetClip(chosen[0]);
            TrayApp.Notify("Queue started",
                "1/" + chosen.Count + " on the clipboard. Ctrl+Shift+N for the next one.");
        } else {
            Clip2.SetMerged(chosen, Separator);
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
                marks.Remove(c.Key());
                Store.Remove(c);
                Rebuild();
            }
            return true;
        }

        if (ctrl && key >= Keys.D1 && key <= Keys.D9) {
            int n = key - Keys.D1;
            if (n < shown.Count) { Clip2.SetClip(shown[n]); CloseAndPaste(); }
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
        IDataObject data = Clip2.GetData();
        if (data == null) return;
        try {
            // Password managers mark their clips with this format; honour it.
            if (data.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing")) return;
        } catch { }

        string app = Native.ForegroundAppName();
        string lower = (app ?? "").ToLowerInvariant();
        foreach (string s in SkipApps) if (lower.Contains(s)) return;

        try {
            if (data.GetDataPresent(Clip2.RestoredFormat)) {
                string key = data.GetData(Clip2.RestoredFormat) as string;
                if (key != null) Recorder.Enqueue(delegate { return delegate { Store.Promote(key); }; });
                return;
            }

            // Files from Explorer (videos, photos, anything) are kept by
            // reference: nothing is copied, whatever their size.
            if (data.GetDataPresent(DataFormats.FileDrop)) {
                string[] files = data.GetData(DataFormats.FileDrop) as string[];
                if (files != null && files.Length > 0) {
                    Clip c = new Clip();
                    c.Files = files; c.Text = string.Join("\n", files); c.App = app ?? "";
                    Recorder.Add(c);
                    return;
                }
            }

            string text = data.GetData(DataFormats.UnicodeText) as string;
            bool hasImage = Store.RecordMedia &&
                (data.GetDataPresent("PNG") || data.GetDataPresent(DataFormats.Bitmap));

            // Text wins, except when it is just the address of a copied image.
            if (!string.IsNullOrEmpty(text) && text.Trim().Length > 0 && (!hasImage || !IsJustAnAddress(text))) {
                Clip c = new Clip();
                c.Text = text; c.App = app ?? "";
                Recorder.Add(c);
                return;
            }
            if (!hasImage) return;

            // Grab the image now (the clipboard can only be read on this thread);
            // encode, hash and save it on the recorder thread.
            MemoryStream pngStream = data.GetDataPresent("PNG") ? data.GetData("PNG") as MemoryStream : null;
            byte[] png = pngStream != null ? pngStream.ToArray() : null;
            Image bitmap = png == null ? data.GetData(DataFormats.Bitmap) as Image : null;
            if (png == null && bitmap == null) return;
            string alt = text, source = app;
            Recorder.Enqueue(delegate {
                byte[] bytes = png;
                if (bytes == null) {
                    using (MemoryStream ms = new MemoryStream()) {
                        bitmap.Save(ms, ImageFormat.Png);
                        bytes = ms.ToArray();
                    }
                    bitmap.Dispose();
                }
                Clip c = Store.SaveImage(bytes, alt, source);
                if (c == null) return null;
                return delegate { Store.Add(c); };
            });
        } catch { }
    }

    static bool IsJustAnAddress(string text) {
        string t = text.Trim();
        if (t.Any(char.IsWhiteSpace)) return false;
        Uri uri;
        return Uri.TryCreate(t, UriKind.Absolute, out uri)
            && (uri.Scheme == "http" || uri.Scheme == "https" || uri.Scheme == "file" || uri.Scheme == "data");
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
        List<Clip> items = Store.LoadQueue(out index);
        if (items.Count == 0 || index >= items.Count) {
            Store.SaveQueue(new List<Clip>(), 0);
            TrayApp.Notify("Queue finished", "Nothing left to paste.");
            return;
        }
        Clip2.SetClip(items[index]);
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
        Recorder.Start(win);

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
