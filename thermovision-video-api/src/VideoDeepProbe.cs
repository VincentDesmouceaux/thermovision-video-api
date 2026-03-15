// src/VideoDeepProbe.cs
// .NET 6/7 console – Analyse MP4/QuickTime (titre, encodeur, meta, audio, heuristiques OS & lentille).
// Sortie: JSON sur stdout.

using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Globalization;
using System.Text.Json;

namespace VideoDeepProbeApp
{
    class Program
    {
        // ===== Endian & helpers =====
        static uint BE32(byte[] b, long o) => (uint)(b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]);
        static ulong BE64(byte[] b, long o) => ((ulong)BE32(b, o) << 32) | BE32(b, o + 4);
        static ushort BE16(byte[] b, long o) => (ushort)((b[o] << 8) | b[o + 1]);
        static string FOURCC(byte[] b, long o) => Encoding.Latin1.GetString(b, (int)o, 4);

        static string ReadUtf8OrLatin1(byte[] b, int off, int len)
        {
            if (len <= 0) return "";
            try { return Encoding.UTF8.GetString(b, off, len).TrimEnd('\0'); }
            catch { return Encoding.Latin1.GetString(b, off, len).TrimEnd('\0'); }
        }

        class Box
        {
            public string Type = "";
            public long Start;
            public long Size;
            public int Header;
            public List<Box> Kids = new();
        }

        static List<Box> ParseBoxes(byte[] f, long start, long end)
        {
            var list = new List<Box>();
            long off = start;
            while (off + 8 <= end)
            {
                uint sz = BE32(f, off);
                string typ = FOURCC(f, off + 4);
                int hdr = 8; ulong sz64 = sz;
                if (sz == 1) { if (off + 16 > end) break; sz64 = BE64(f, off + 8); hdr = 16; }
                else if (sz == 0) { sz64 = (ulong)(end - off); }
                if (sz64 < (ulong)hdr || off + (long)sz64 > end) break;

                var b = new Box { Type = typ, Start = off, Size = (long)sz64, Header = hdr };
                list.Add(b);

                bool isContainer = typ == "moov" || typ == "trak" || typ == "mdia" || typ == "minf" || typ == "stbl" ||
                                   typ == "edts" || typ == "udta" || typ == "dinf" || typ == "mvex" || typ == "mfra" || typ == "ilst";
                if (typ == "meta")
                {
                    long cs = b.Start + b.Header + 4; // FullBox version/flags
                    long ce = b.Start + b.Size;
                    b.Kids = ParseBoxes(f, cs, ce);
                }
                else if (isContainer)
                {
                    long cs = b.Start + b.Header;
                    long ce = b.Start + b.Size;
                    b.Kids = ParseBoxes(f, cs, ce);
                }
                off += (long)sz64;
            }
            return list;
        }

        static IEnumerable<Box> Find(IEnumerable<Box> nodes, params string[] path)
        {
            foreach (var n in nodes)
            {
                if (n.Type == path[0])
                {
                    if (path.Length == 1) yield return n;
                    else foreach (var c in Find(n.Kids, path[1..])) yield return c;
                }
                foreach (var c in Find(n.Kids, path)) yield return c;
            }
        }

        // ===== FTYP =====
        static (string major, uint minor, List<string> brands) ReadFtyp(byte[] f, List<Box> root)
        {
            foreach (var b in root)
            {
                if (b.Type == "ftyp")
                {
                    long p = b.Start + b.Header;
                    if (b.Size - b.Header < 8) return ("", 0, new());
                    string major = FOURCC(f, p);
                    uint minor = BE32(f, p + 4);
                    var brands = new List<string>();
                    long off = p + 8;
                    while (off + 4 <= b.Start + b.Size)
                    {
                        brands.Add(FOURCC(f, off));
                        off += 4;
                    }
                    return (major, minor, brands);
                }
            }
            return ("", 0, new());
        }

        // ===== Audio track detection & parsing =====
        static bool IsAudioTrak(byte[] f, Box trak)
        {
            foreach (var h in Find(new[] { trak }, "mdia", "hdlr"))
            {
                long p = h.Start + h.Header;
                if (h.Size - h.Header >= 12)
                {
                    string handler = FOURCC(f, p + 8);
                    if (handler == "soun") return true;
                }
            }
            return false;
        }

        static Box? FindAudioTrak(byte[] f, List<Box> root)
        {
            foreach (var t in Find(root, "moov", "trak"))
                if (IsAudioTrak(f, t)) return t;
            return null;
        }

        static (uint timescale, ulong duration) ReadMdhd(byte[] f, Box trak)
        {
            foreach (var mdhd in Find(new[] { trak }, "mdia", "mdhd"))
            {
                long p = mdhd.Start + mdhd.Header;
                int ver = f[p];
                if (ver == 1 && mdhd.Size - mdhd.Header >= 36)
                    return (BE32(f, p + 20), BE64(f, p + 24));
                if (mdhd.Size - mdhd.Header >= 24)
                    return (BE32(f, p + 12), BE32(f, p + 16));
            }
            return (0, 0);
        }

        static (ulong totalCount, ulong totalDelta) ReadStts(byte[] f, Box trak)
        {
            foreach (var stts in Find(new[] { trak }, "mdia", "minf", "stbl", "stts"))
            {
                long p = stts.Start + stts.Header;
                if (stts.Size - stts.Header < 8) continue;
                p += 4; // version/flags
                uint n = BE32(f, p); p += 4;
                ulong sumC = 0, sumD = 0;
                for (uint i = 0; i < n; i++)
                {
                    if (p + 8 > stts.Start + stts.Size) break;
                    uint c = BE32(f, p); uint d = BE32(f, p + 4); p += 8;
                    sumC += c; sumD += (ulong)c * d;
                }
                return (sumC, sumD);
            }
            return (0, 0);
        }

        static (uint sampleCount, ulong totalBytes, uint min, uint max, double std) ReadStsz(byte[] f, Box trak)
        {
            foreach (var stsz in Find(new[] { trak }, "mdia", "minf", "stbl", "stsz"))
            {
                long p = stsz.Start + stsz.Header;
                if (stsz.Size - stsz.Header < 12) continue;
                p += 4; // version/flags
                uint sampleSize = BE32(f, p); p += 4;
                uint count = BE32(f, p); p += 4;
                if (sampleSize != 0) return (count, (ulong)sampleSize * count, sampleSize, sampleSize, 0.0);

                ulong total = 0; uint minv = uint.MaxValue; uint maxv = 0;
                double m = 0.0, s = 0.0; int k = 0;
                for (uint i = 0; i < count; i++)
                {
                    if (p + 4 > stsz.Start + stsz.Size) break;
                    uint v = BE32(f, p); p += 4;
                    total += v;
                    if (v < minv) minv = v;
                    if (v > maxv) maxv = v;
                    k++;
                    double delta = v - m;
                    m += delta / k;
                    s += delta * (v - m);
                }
                double std = k > 1 ? Math.Sqrt(s / (k - 1)) : 0.0;
                return (count, total, minv, maxv, std);
            }
            return (0, 0, 0, 0, 0.0);
        }

        static void ParseEsds(byte[] f, Box esds, out string aacProfile, out int ascSrIdx, out int ascCh)
        {
            aacProfile = ""; ascSrIdx = -1; ascCh = -1;
            long p = esds.Start + esds.Header;
            long end = esds.Start + esds.Size;
            if (esds.Size - esds.Header < 8) return;
            p += 4; // version/flags

            int ReadLen(ref long pp)
            {
                int length = 0; int cnt = 0;
                while (pp < end)
                {
                    byte b = f[pp++]; cnt++;
                    length = (length << 7) | (b & 0x7F);
                    if ((b & 0x80) == 0 || cnt >= 4) break;
                }
                return length;
            }

            while (p + 2 <= end)
            {
                byte tag = f[p++]; int ln = ReadLen(ref p); long nxt = p + ln; if (nxt > end) break;
                if (tag == 0x05 && ln >= 2)
                {
                    int b0 = f[p], b1 = f[p + 1];
                    int aot = (b0 >> 3) & 0x1F;
                    int srIdx = ((b0 & 0x07) << 1) | (b1 >> 7);
                    int chCfg = (b1 >> 3) & 0x0F;
                    aacProfile = aot switch
                    {
                        1 => "AAC Main",
                        2 => "AAC LC",
                        3 => "AAC SSR",
                        4 => "AAC LTP",
                        5 => "HE-AAC (SBR)",
                        29 => "HE-AACv2 (PS)",
                        _ => $"AAC (OT={aot})"
                    };
                    ascSrIdx = srIdx; ascCh = chCfg;
                }
                p = nxt;
            }
        }

        static (int channels, double samplerate, string codec, string aacProfile, int ascSr, int ascCh)
            ReadStsdAudio(byte[] f, Box trak)
        {
            foreach (var stsd in Find(new[] { trak }, "mdia", "minf", "stbl", "stsd"))
            {
                long p = stsd.Start + stsd.Header;
                if (stsd.Size - stsd.Header < 8) continue;
                p += 4; // version/flags
                uint entries = BE32(f, p); p += 4;
                long off = p;
                for (uint i = 0; i < entries; i++)
                {
                    if (off + 8 > stsd.Start + stsd.Size) break;
                    uint esz = BE32(f, off);
                    string type = FOURCC(f, off + 4);
                    long basePos = off + 8;
                    if (esz < 16 || off + esz > stsd.Start + stsd.Size) break;

                    if (type == "mp4a" || type == "ac-4" || type == "Opus")
                    {
                        long q = basePos + 6 + 2; // skip 6 reserved + 2 ref
                        if (q + 20 <= stsd.Start + stsd.Size)
                        {
                            ushort ver = BE16(f, q); q += 2;
                            q += 6; // revision + vendor
                            ushort chans = BE16(f, q); q += 2;
                            ushort sampleSize = BE16(f, q); q += 2;
                            q += 4; // pre_defined + reserved
                            uint rate1616 = BE32(f, q); q += 4;
                            double sr = rate1616 / 65536.0;

                            string aacP = ""; int ascSr = -1, ascCh = -1;
                            foreach (var child in ParseBoxes(f, basePos, off + esz))
                                if (child.Type == "esds") ParseEsds(f, child, out aacP, out ascSr, out ascCh);

                            return (chans, sr, type, aacP, ascSr, ascCh);
                        }
                    }
                    off += esz;
                }
            }
            return (0, 0.0, "", "", -1, -1);
        }

        // ===== QuickTime meta (keys/ilst) & freeform ---- ; + 3GPP UDTA =====
        static Dictionary<int, string> ReadKeys(byte[] f, Box keys)
        {
            var map = new Dictionary<int, string>();
            if (keys == null) return map;
            long p = keys.Start + keys.Header;
            if (keys.Size - keys.Header < 8) return map;
            uint cnt = BE32(f, p + 4);
            long off = p + 8;
            int idx = 1;
            for (int i = 0; i < cnt; i++)
            {
                if (off + 8 > keys.Start + keys.Size) break;
                uint sz = BE32(f, off);
                if (sz < 8 || off + sz > keys.Start + keys.Size) break;
                string ns = FOURCC(f, off + 4);
                string nm = ReadUtf8OrLatin1(f, (int)off + 8, (int)sz - 8);
                map[idx++] = ns + ":" + nm;
                off += sz;
            }
            return map;
        }

        static void ReadIlst(byte[] f, Box ilst, Dictionary<int, string> keyMap, Dictionary<string, string> outMeta)
        {
            if (ilst == null) return;
            foreach (var item in ilst.Kids)
            {
                string itemKey = item.Type;

                // Map key index when non-printable
                bool printable = true;
                foreach (var ch in itemKey) if (ch < 32 || ch > 126) { printable = false; break; }
                if (!printable)
                {
                    int idx = (itemKey[0] << 24) | (itemKey[1] << 16) | (itemKey[2] << 8) | itemKey[3];
                    if (keyMap.TryGetValue(idx, out var real)) itemKey = real;
                    else itemKey = "keyidx:" + idx;
                }

                if (item.Type == "----")
                {
                    string mean = "", name = "", value = "";
                    foreach (var sub in item.Kids)
                    {
                        long p = sub.Start + sub.Header;
                        int len = (int)(sub.Size - sub.Header);
                        if (len <= 0) continue;
                        if (sub.Type == "mean") mean = ReadUtf8OrLatin1(f, (int)p + 4, len - 4);
                        else if (sub.Type == "name") name = ReadUtf8OrLatin1(f, (int)p + 4, len - 4);
                        else if (sub.Type == "data")
                        {
                            uint dtype = BE32(f, p);
                            int vs = (int)p + 8, vlen = (int)(sub.Start + sub.Size - vs);
                            if (vlen > 0)
                                value = (dtype == 1 || dtype == 2 || dtype == 27)
                                    ? ReadUtf8OrLatin1(f, vs, vlen)
                                    : BitConverter.ToString(f, vs, Math.Min(64, vlen));
                        }
                    }
                    if (!string.IsNullOrEmpty(mean) && !string.IsNullOrEmpty(name))
                        outMeta[$"{mean}:{name}"] = value;
                    continue;
                }

                foreach (var d in item.Kids)
                {
                    if (d.Type != "data") continue;
                    long p = d.Start + d.Header;
                    if (d.Size - d.Header < 8) continue;
                    uint dtype = BE32(f, p);
                    int vs = (int)p + 8, vlen = (int)(d.Start + d.Size - vs);
                    if (vlen <= 0) continue;
                    string val = (dtype == 1 || dtype == 2 || dtype == 27)
                        ? ReadUtf8OrLatin1(f, vs, vlen)
                        : BitConverter.ToString(f, vs, Math.Min(64, vlen));
                    outMeta[itemKey] = val;
                }
            }
        }

        static void Read3GppUdta(byte[] f, Box udta, Dictionary<string, string> outMeta, string scope)
        {
            string[] names = { "titl", "dscp", "auth", "albm", "yrrc", "gnre" };
            foreach (var c in udta.Kids)
            {
                foreach (var nm in names)
                {
                    if (c.Type == nm)
                    {
                        int len = (int)(c.Size - c.Header);
                        if (len <= 0) continue;
                        long p = c.Start + c.Header;
                        string val = ReadUtf8OrLatin1(f, (int)p, len);
                        outMeta[$"{scope}/3gpp:{nm}"] = val;
                    }
                }
            }
        }

        static Dictionary<string, string> CollectMetaEverywhere(byte[] f, List<Box> root)
        {
            var meta = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            // moov-level
            foreach (var m in Find(root, "moov", "udta", "meta"))
            {
                Box keys = null, ilst = null;
                foreach (var c in m.Kids) { if (c.Type == "keys") keys = c; else if (c.Type == "ilst") ilst = c; }
                var km = ReadKeys(f, keys);
                ReadIlst(f, ilst, km, meta);
            }
            foreach (var m in Find(root, "moov", "meta"))
            {
                Box keys = null, ilst = null;
                foreach (var c in m.Kids) { if (c.Type == "keys") keys = c; else if (c.Type == "ilst") ilst = c; }
                var km = ReadKeys(f, keys);
                ReadIlst(f, ilst, km, meta);
            }
            // per-track + 3GPP
            int tix = 0;
            foreach (var trak in Find(root, "moov", "trak"))
            {
                tix++;
                foreach (var m in Find(new[] { trak }, "udta", "meta"))
                {
                    Box keys = null, ilst = null;
                    foreach (var c in m.Kids) { if (c.Type == "keys") keys = c; else if (c.Type == "ilst") ilst = c; }
                    var km = ReadKeys(f, keys);
                    ReadIlst(f, ilst, km, meta);
                }
                foreach (var udta in Find(new[] { trak }, "udta"))
                    Read3GppUdta(f, udta, meta, $"trak{tix}");
            }
            foreach (var udta in Find(root, "moov", "udta"))
                Read3GppUdta(f, udta, meta, "file");
            return meta;
        }

        // ===== Title & Generator =====
        static (string title, string generator) ExtractTitleAndGenerator(Dictionary<string, string> meta)
        {
            string[] titleKeys = { "©nam", "title", "com.apple.quicktime:title", "com.apple.quicktime.displayname",
                                   "file/3gpp:titl", "trak1/3gpp:titl", "trak2/3gpp:titl" };
            string[] genKeys = { "©too", "tool", "encoder", "©swr",
                                   "com.apple.quicktime.software", "com.apple.quicktime:software" };
            string title = null, gen = null;
            foreach (var k in titleKeys) if (meta.TryGetValue(k, out title) && !string.IsNullOrWhiteSpace(title)) break;
            if (string.IsNullOrWhiteSpace(title))
                foreach (var kv in meta)
                    if (kv.Key.Equals("©nam", StringComparison.OrdinalIgnoreCase) ||
                        kv.Key.Contains("title", StringComparison.OrdinalIgnoreCase) ||
                        kv.Key.Contains("displayname", StringComparison.OrdinalIgnoreCase))
                    { title = kv.Value; break; }

            foreach (var k in genKeys) if (meta.TryGetValue(k, out gen) && !string.IsNullOrWhiteSpace(gen)) break;
            if (string.IsNullOrWhiteSpace(gen))
                foreach (var kv in meta)
                    if (kv.Key.Equals("©too", StringComparison.OrdinalIgnoreCase) ||
                        kv.Key.Equals("tool", StringComparison.OrdinalIgnoreCase) ||
                        kv.Key.Contains("encoder", StringComparison.OrdinalIgnoreCase) ||
                        kv.Key.Contains("software", StringComparison.OrdinalIgnoreCase))
                    { gen = kv.Value; break; }

            return (title ?? "", gen ?? "");
        }

        // ===== ANSI + HEX =====
        static Encoding Ansi()
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(1252, EncoderFallback.ReplacementFallback, DecoderFallback.ReplacementFallback);
        }
        static byte[] ToAnsiBytes(string s) => string.IsNullOrEmpty(s) ? Array.Empty<byte>() : Ansi().GetBytes(s);
        static string ToHex(byte[] bytes)
        {
            if (bytes.Length == 0) return "";
            var sb = new StringBuilder(bytes.Length * 2);
            for (int i = 0; i < bytes.Length; i++) sb.Append(bytes[i].ToString("X2"));
            return sb.ToString();
        }

        // ===== Lens inference =====
        static double? ParseDouble(string s)
        {
            if (string.IsNullOrWhiteSpace(s)) return null;
            s = s.Trim().Replace(",", ".");
            if (s.Contains("/"))
            {
                var parts = s.Split('/', 2);
                if (double.TryParse(parts[0], NumberStyles.Any, CultureInfo.InvariantCulture, out var a) &&
                    double.TryParse(parts[1], NumberStyles.Any, CultureInfo.InvariantCulture, out var b) && b != 0)
                    return a / b;
            }
            if (double.TryParse(s, NumberStyles.Any, CultureInfo.InvariantCulture, out var v)) return v;
            return null;
        }
        static string ClassifyLens(double mm)
        {
            if (mm <= 2.1) return "Ultra-grand-angle (≈13–15 mm eq)";
            if (mm <= 5.5) return "Grand-angle principal (≈24–28 mm eq)";
            return "Téléobjectif (≥50 mm eq)";
        }
        static (string lensModel, string lensMake, double? focalMm, double? focusM, double? exposureS, string reason)
            LensInference(Dictionary<string, string> meta)
        {
            string[] lensModelKeys = {
                "com.apple.quicktime.lens-model","com.apple.quicktime.lens_model",
                "com.android.video.lens","com.android.lens-model","lens-model","lensModel"
            };
            string lensMake = "";
            foreach (var kv in meta) if (kv.Key.ToLowerInvariant().Contains("lens-make")) { lensMake = kv.Value; break; }
            string lensModel = "";
            foreach (var k in lensModelKeys) if (meta.TryGetValue(k, out lensModel) && !string.IsNullOrWhiteSpace(lensModel)) break;

            double? focal = null, focus = null, expo = null;
            foreach (var k in new[] { "com.apple.quicktime.focalLength", "focalLength", "FocalLength" })
                if (meta.TryGetValue(k, out var v) && (focal = ParseDouble(v)) != null) break;
            foreach (var k in new[] { "com.apple.quicktime.focusDistance", "focusDistance" })
                if (meta.TryGetValue(k, out var v) && (focus = ParseDouble(v)) != null) break;
            foreach (var k in new[] { "com.apple.quicktime.exposureTime", "exposureTime", "ShutterSpeedValue", "ExposureTime" })
                if (meta.TryGetValue(k, out var v) && (expo = ParseDouble(v)) != null) break;

            if (!string.IsNullOrWhiteSpace(lensModel)) return (lensModel, lensMake, focal, focus, expo, $"Modèle déclaré: {lensModel}");
            if (focal != null) return ("", lensMake, focal, focus, expo, $"Type déduit: {ClassifyLens(focal.Value)}");
            if (focus != null || expo != null)
            {
                string g = "indécidable";
                if (focus != null && expo != null)
                    g = (focus >= 1.5 && expo > 0 && expo <= 1.0 / 120.0) ? "UGA (forte PDC + vitesses courtes)" :
                        (focus >= 0.5 ? "GA principal (PDC moyenne)" : "Télé (sujet proche)");
                else if (focus != null)
                    g = focus >= 1.5 ? "UGA (forte PDC)" : (focus >= 0.5 ? "GA principal" : "Télé");
                else if (expo != null)
                    g = (expo <= 1.0 / 120.0) ? "UGA/GA (bonne lumière)" : "Télé/GA (basse lumière)";
                return ("", lensMake, focal, focus, expo, $"Déduction (focus/vitesse): {g} (incertain)");
            }
            return ("", lensMake, null, null, null, "Aucune donnée exploitable.");
        }

        // ===== OS inference =====
        static (string os, int score, List<string> reasons) InferOS(Dictionary<string, string> meta, (string major, uint minor, List<string> brands) ftyp, string encoder)
        {
            int ios = 0, andr = 0; var why = new List<string>();
            foreach (var k in meta.Keys)
            {
                var lk = k.ToLowerInvariant();
                if (lk.StartsWith("com.apple.quicktime")) { ios += 40; why.Add("clé com.apple.quicktime.*"); }
                if (lk.StartsWith("com.android")) { andr += 40; why.Add("clé com.android.*"); }
            }
            if (!string.IsNullOrWhiteSpace(encoder))
            {
                var l = encoder.ToLowerInvariant();
                if (l.Contains("apple") || l.Contains("iphone") || l.Contains("ios")) { ios += 25; why.Add("encoder Apple/iOS"); }
                if (l.Contains("android") || l.Contains("huawei") || l.Contains("xiaomi") || l.Contains("samsung")) { andr += 25; why.Add("encoder Android/marque"); }
                if (l.Contains("whatsapp") || l.Contains("ffmpeg") || l.Contains("lavf") || l.Contains("handbrake") || l.Contains("transcoder"))
                    why.Add("transcodage → OS d’origine incertain");
            }
            foreach (var b in ftyp.brands) if (b.StartsWith("3gp")) { andr += 5; why.Add("brand 3gp*"); }

            if (ios == 0 && andr == 0) return ("Inconnu (possible ré-encodage)", 0, why);
            if (ios > andr) return ("iOS (probable)", ios - andr, why);
            if (andr > ios) return ("Android (probable)", andr - ios, why);
            return ("Indéterminé", 0, why);
        }

        static bool HasSig(byte[] f, byte[] sig)
        {
            // simple search
            for (int i = 0; i <= f.Length - sig.Length; i++)
            {
                int j = 0; for (; j < sig.Length; j++) if (f[i + j] != sig[j]) break;
                if (j == sig.Length) return true;
            }
            return false;
        }

        // ===== MAIN =====
        static int Main(string[] args)
        {
            // Input: arg file path OR first *.mp4 in assets/
            string path = ""; string path = args.Length > 0 ? args[0] : null;
            if (string.IsNullOrWhiteSpace(path))
            {
                string[] candidates = { "assets", "cvassets" };
                foreach (var dir in candidates)
                {
                    var baseDir = Path.Combine(Environment.CurrentDirectory, dir);
                    if (Directory.Exists(baseDir))
                    {
                        var files = Directory.GetFiles(baseDir, "*.mp4");
                        if (files.Length > 0) { path = files[0]; break; }
                    }
                }
            }

            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                Console.Error.WriteLine("Fichier MP4 introuvable. Passe le chemin en argument ou place un .mp4 dans ./assets/");
                return 2;
            }

            byte[] f = File.ReadAllBytes(path);
            var root = ParseBoxes(f, 0, f.Length);

            // ftyp
            var ftyp = ReadFtyp(f, root);

            // audio
            var aTrak = FindAudioTrak(f, root);
            var audio = new Dictionary<string, object?>();
            if (aTrak != null)
            {
                var (ts, dur) = ReadMdhd(f, aTrak);
                var (c, sr, codec, aacP, ascSr, ascCh) = ReadStsdAudio(f, aTrak);
                var (sttsC, sttsD) = ReadStts(f, aTrak);
                var (stszC, stszTotal, stszMin, stszMax, stszStd) = ReadStsz(f, aTrak);
                double? durationS = ts > 0 ? dur / (double)ts : null;
                double? pktsPerSec = (ts > 0 && sttsC > 0 && sttsD > 0) ? ts / (sttsD / (double)sttsC) : null;
                double? bitrate = (durationS != null && durationS > 0 && stszTotal > 0) ? (stszTotal * 8.0 / durationS / 1000.0) : null;

                audio["codec"] = string.IsNullOrEmpty(codec) ? null : codec;
                audio["channels"] = c == 0 ? null : c;
                audio["samplerate_hz"] = sr == 0 ? null : sr;
                audio["aac_profile"] = string.IsNullOrEmpty(aacP) ? null : aacP;
                audio["asc_sr_idx"] = ascSr >= 0 ? ascSr : null;
                audio["asc_ch"] = ascCh >= 0 ? ascCh : null;
                audio["timescale"] = ts == 0 ? null : ts;
                audio["duration_s"] = durationS;
                audio["packets_per_sec"] = pktsPerSec;
                audio["stsz_samples"] = stszC == 0 ? null : stszC;
                audio["stsz_total_bytes"] = stszTotal == 0 ? null : stszTotal;
                audio["stsz_min"] = stszMin == 0 ? null : stszMin;
                audio["stsz_max"] = stszMax == 0 ? null : stszMax;
                audio["stsz_std"] = stszStd == 0 ? null : stszStd;
                audio["bitrate_kbps"] = bitrate;
            }

            // meta everywhere (incl. 3GPP)
            var meta = CollectMetaEverywhere(f, root);

            // title / generator
            var (title, generator) = ExtractTitleAndGenerator(meta);

            // ANSI + hex
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            var titleAnsi = Ansi().GetBytes(title ?? "");
            var genAnsi = Ansi().GetBytes(generator ?? "");
            string titleHex = ToHex(titleAnsi);
            string genHex = ToHex(genAnsi);

            // lens inference
            var (lensModel, lensMake, focalMm, focusM, expoS, lensReason) = LensInference(meta);

            // OS inference
            string encTool = generator ?? "";
            var os = InferOS(meta, ftyp, encTool);

            // signatures
            var sigs = new Dictionary<string, bool>
            {
                ["exif"] = HasSig(f, new byte[] { 0x45, 0x78, 0x69, 0x66, 0x00, 0x00 }), // "Exif\0\0"
                ["xmp"] = HasSig(f, Encoding.ASCII.GetBytes("<?xpacket")),
                ["iso6709"] = HasSig(f, Encoding.ASCII.GetBytes("ISO6709")),
            };

            // build output
            var output = new Dictionary<string, object?>
            {
                ["file"] = path,
                ["ftyp"] = new Dictionary<string, object?>
                {
                    ["major"] = ftyp.major,
                    ["minor"] = ftyp.minor,
                    ["brands"] = ftyp.brands
                },
                ["title"] = string.IsNullOrWhiteSpace(title) ? null : title,
                ["title_ansi_hex"] = string.IsNullOrEmpty(titleHex) ? null : titleHex,
                ["generator"] = string.IsNullOrWhiteSpace(generator) ? null : generator,
                ["generator_ansi_hex"] = string.IsNullOrEmpty(genHex) ? null : genHex,
                ["audio"] = audio,
                ["signatures"] = sigs,
                ["meta_keys_count"] = meta.Count,
                ["inference"] = new Dictionary<string, object?>
                {
                    ["os"] = os.os,
                    ["os_score"] = os.score,
                    ["os_reasons"] = os.reasons,
                    ["lens_model"] = string.IsNullOrWhiteSpace(lensModel) ? null : lensModel,
                    ["lens_make"] = string.IsNullOrWhiteSpace(lensMake) ? null : lensMake,
                    ["focal_mm"] = focalMm,
                    ["focus_m"] = focusM,
                    ["exposure_s"] = expoS,
                    ["lens_reason"] = lensReason
                }
            };

            var json = JsonSerializer.Serialize(output, new JsonSerializerOptions { WriteIndented = true });
            Console.WriteLine(json);
            return 0;
        }
    }
}
