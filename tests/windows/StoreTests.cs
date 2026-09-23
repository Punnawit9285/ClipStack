// Unit tests for the parts of windows/ClipStack.ps1 that don't need Windows:
// history, images, files, the paste queue and the CF_HTML format.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using ClipStack;

static class StoreTests {
    static int pass, fail;

    static void Eq<T>(string what, T got, T want) {
        if (Equals(got, want)) { pass++; Console.WriteLine("  ok    " + what); }
        else { fail++; Console.WriteLine("  FAIL  " + what + "\n        expected: " + want + "\n        got:      " + got); }
    }

    /// Enough of a PNG for ClipStack: signature, IHDR with the size, then noise.
    static byte[] Png(int w, int h, int seed, int extra = 64) {
        List<byte> b = new List<byte> { 0x89, (byte)'P', (byte)'N', (byte)'G', 13, 10, 26, 10, 0, 0, 0, 13, (byte)'I', (byte)'H', (byte)'D', (byte)'R' };
        foreach (int v in new[] { w, h }) b.AddRange(new[] { (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v });
        byte[] noise = new byte[extra];
        new Random(seed).NextBytes(noise);
        b.AddRange(noise);
        return b.ToArray();
    }

    static string Keys() { return string.Join(",", Store.Ordered().Select(c => c.Label(40))); }
    static int MediaFiles() { return Directory.Exists(Store.MediaDir) ? Directory.GetFiles(Store.MediaDir).Length : 0; }

    static void Reset() {
        Store.Dir = Path.Combine(Path.GetTempPath(), "clipstack-wintest-" + Guid.NewGuid());
        Store.Items = new List<Clip>();
        Store.MaxItems = 500;
        Store.MediaBudget = 1024L * 1024 * 1024;
        Store.PruneGraceSeconds = 0;
        Store.Load();
    }

    static int Main() {
        Console.WriteLine("==> Text");
        Reset();
        Store.Add("alpha", "notepad"); Store.Add("beta", "chrome"); Store.Add("alpha", "");
        Eq("re-copying promotes instead of duplicating", Keys(), "alpha,beta");
        Eq("whitespace is skipped", Store.Add(" \r\n", "x"), false);

        Console.WriteLine("==> Images");
        Clip red = Store.SaveImage(Png(40, 30, 1), "", "paint");
        Eq("an image is stored", red != null && File.Exists(Path.Combine(Store.MediaDir, red.Image)), true);
        Eq("…its size read from the header", red.Width + "x" + red.Height, "40x30");
        Store.Add(red);
        Eq("…and labelled as an image", Store.Items[0].Label(80), "[Image 40x30]");
        Clip again = Store.SaveImage(Png(40, 30, 1), "", "paint");
        Eq("the same image gets the same file", again.Image, red.Image);
        Store.Add("gamma", ""); Store.Add(again);
        Eq("…and is promoted, not duplicated", Keys() + " / " + MediaFiles(), "[Image 40x30],gamma,alpha,beta / 1");
        Clip web = Store.SaveImage(Png(16, 16, 2), "https://example.com/cat.png", "chrome");
        Store.Add(web);
        Eq("an image keeps the address it came with", Store.Items[0].Label(80), "[Image 16x16] https://example.com/cat.png");
        Eq("something that isn't a PNG is refused", Store.SaveImage(new byte[] { 1, 2, 3 }, "", ""), (Clip)null);
        Store.MaxMediaBytes = 100;
        Eq("an image over the size cap is refused", Store.SaveImage(Png(8, 8, 3, 500), "", ""), (Clip)null);
        Store.MaxMediaBytes = 100L * 1024 * 1024;

        Console.WriteLine("==> Files");
        Clip one = new Clip(); one.Files = new[] { @"C:\Users\me\Videos\holiday.mov" }; one.Text = one.Files[0];
        Clip two = new Clip(); two.Files = new[] { @"C:\a\report.pdf", @"C:\a\photo.JPG" }; two.Text = string.Join("\n", two.Files);
        Store.Add(one); Store.Add(two);
        Eq("a video file is labelled as a video", one.Label(80), "[Video] holiday.mov");
        Eq("several files are one clip", two.Label(80), "[2 files] report.pdf, photo.JPG");
        Eq("file kinds come from the extension", Clip.Kind("x.png") + Clip.Kind("x.MP4") + Clip.Kind("x.flac") + Clip.Kind("x"), "ImageVideoAudioFile");

        Console.WriteLine("==> Saving and loading");
        Store.Items.First(c => c.Image == red.Image).Pinned = true;
        Store.Save();
        string before = string.Join("\n", Store.Items.Select(c => c.Key() + "|" + c.Pinned + "|" + c.Label(80) + "|" + c.App));
        Store.Load();
        string after = string.Join("\n", Store.Items.Select(c => c.Key() + "|" + c.Pinned + "|" + c.Label(80) + "|" + c.App));
        Eq("images, files, pins and apps survive a reload", after, before);
        File.AppendAllText(Path.Combine(Store.Dir, "history.txt"),
            DateTime.Now.Ticks + "|0|" + Convert.ToBase64String(Encoding.UTF8.GetBytes("old")) + "|" +
            Convert.ToBase64String(Encoding.UTF8.GetBytes("from an older version")) + "\n");
        Store.Load();
        Eq("history written by the previous version still loads", Store.Items.Last().Text, "from an older version");

        Store.SaveQueue(new List<Clip> { red, two, Store.Items.First(c => c.Text == "gamma") }, 1);
        int index;
        List<Clip> q = Store.LoadQueue(out index);
        Eq("the queue keeps images and files", string.Join(",", q.Select(c => c.Label(80))) + " @" + index,
           "[Image 40x30],[2 files] report.pdf, photo.JPG,gamma @1");

        Console.WriteLine("==> Cleaning up");
        Store.SaveQueue(new List<Clip>(), 0);
        Store.ClearUnpinned();
        Eq("clear keeps pinned images and deletes the rest", Keys() + " / " + MediaFiles(), "[Image 40x30] / 1");

        Reset();
        Store.MediaBudget = 150;   // bytes: room for one of these images
        for (int i = 0; i < 3; i++) Store.Add(Store.SaveImage(Png(10, 10, 10 + i), "", ""));
        Eq("the media budget keeps the newest images that fit", Store.Items.Count + " clips, " + MediaFiles() + " files", "1 clips, 1 files");

        Reset();
        Store.MaxItems = 2;
        Store.Add(Store.SaveImage(Png(10, 10, 20), "", ""));
        Store.Add("one", ""); Store.Add("two", "");
        Eq("an image pushed out by MaxItems has its file deleted", MediaFiles(), 0);

        Reset();
        Store.PruneGraceSeconds = 60;
        Store.SaveImage(Png(10, 10, 30), "", "");   // written, not yet in history
        Store.Add("a", ""); Store.ClearUnpinned();
        Eq("a just-written image isn't pruned before it reaches history", MediaFiles(), 1);

        Console.WriteLine("==> HTML clipboard format");
        string frag = "caf\u00e9 <b>\u65e5\u672c</b><img src=\"data:image/png;base64,AAAA\">";
        string wrapped = Html.Wrap(frag);
        byte[] bytes = Encoding.UTF8.GetBytes(wrapped);
        Func<string, int> at = name => int.Parse(wrapped.Split('\n').First(l => l.StartsWith(name + ":")).Split(':')[1].Trim());
        Eq("StartHTML points at the page", Encoding.UTF8.GetString(bytes, at("StartHTML"), 6), "<html>");
        Eq("the fragment offsets are exact, in UTF-8 bytes",
           Encoding.UTF8.GetString(bytes, at("StartFragment"), at("EndFragment") - at("StartFragment")), frag);
        Eq("EndHTML is the end", at("EndHTML"), bytes.Length);
        Eq("text is escaped, lines become <br>", Html.Escape("a < b & c\r\nd"), "a &lt; b &amp; c<br>d");

        Console.WriteLine("\n" + pass + " passed, " + fail + " failed");
        return fail == 0 ? 0 : 1;
    }
}
