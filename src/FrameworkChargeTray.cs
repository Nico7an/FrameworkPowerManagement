// Framework Charge Tray — bascule la limite de charge de la batterie d'un
// Framework Laptop entre la valeur par défaut du BIOS et 100 %, depuis la zone
// de notification Windows.
//
// La limite vit dans l'Embedded Controller : elle est globale à la machine et
// exige les droits administrateur (accès par port I/O via framework_tool.exe,
// embarqué en ressource dans cet exécutable).

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace FrameworkChargeTray
{
    internal static class Paths
    {
        public static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "FrameworkChargeTray");

        // L'EC est global à la machine : l'état vit donc sous ProgramData, pas
        // sous %LOCALAPPDATA%. Deux sessions Windows partagent la préférence au
        // lieu de se la réappliquer mutuellement.
        public static string Config { get { return Path.Combine(Dir, "config.txt"); } }
        public static string Log { get { return Path.Combine(Dir, "tray.log"); } }
        public static string Tool { get { return Path.Combine(Dir, "framework_tool.exe"); } }

        public static void EnsureDir()
        {
            if (!Directory.Exists(Dir)) Directory.CreateDirectory(Dir);
        }
    }

    internal static class Journal
    {
        private static readonly object Gate = new object();

        public static void Write(string message)
        {
            try
            {
                lock (Gate)
                {
                    Paths.EnsureDir();
                    var f = new FileInfo(Paths.Log);
                    if (f.Exists && f.Length > 200 * 1024) File.WriteAllText(Paths.Log, string.Empty);
                    File.AppendAllText(Paths.Log,
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)
                        + "  " + message + Environment.NewLine,
                        Encoding.UTF8);
                }
            }
            catch { /* un journal muet ne doit jamais faire tomber l'app */ }
        }
    }

    internal sealed class Settings
    {
        public int DefaultLimit;      // valeur BIOS, découverte au premier lancement
        public int DesiredLimit;      // 0 = ne rien imposer
        public int PollSeconds = 300;

        public static Settings Load()
        {
            var s = new Settings();
            try
            {
                if (!File.Exists(Paths.Config)) return s;
                foreach (var raw in File.ReadAllLines(Paths.Config, Encoding.UTF8))
                {
                    var line = raw.Trim();
                    if (line.Length == 0 || line[0] == '#') continue;
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    string key = line.Substring(0, eq).Trim();
                    string val = line.Substring(eq + 1).Trim();
                    int n;
                    if (!int.TryParse(val, NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) continue;
                    switch (key)
                    {
                        case "defaultLimit": s.DefaultLimit = n; break;
                        case "desiredLimit": s.DesiredLimit = n; break;
                        case "pollSeconds": if (n >= 30) s.PollSeconds = n; break;
                    }
                }
            }
            catch (Exception ex) { Journal.Write("config illisible, valeurs par défaut : " + ex.Message); }
            return s;
        }

        public void Save()
        {
            try
            {
                Paths.EnsureDir();
                var sb = new StringBuilder();
                sb.AppendLine("# Framework Charge Tray — état partagé entre sessions Windows.");
                sb.AppendLine("defaultLimit=" + DefaultLimit.ToString(CultureInfo.InvariantCulture));
                sb.AppendLine("desiredLimit=" + DesiredLimit.ToString(CultureInfo.InvariantCulture));
                sb.AppendLine("pollSeconds=" + PollSeconds.ToString(CultureInfo.InvariantCulture));
                File.WriteAllText(Paths.Config, sb.ToString(), Encoding.UTF8);
            }
            catch (Exception ex) { Journal.Write("écriture de la config impossible : " + ex.Message); }
        }
    }

    internal static class Tool
    {
        private const string ResourceName = "FrameworkChargeTray.framework_tool.exe";

        // Réextrait si absent ou si la taille diffère de la ressource : une mise
        // à jour de l'exe doit remplacer l'outil déposé par la version précédente.
        public static void EnsureExtracted()
        {
            Paths.EnsureDir();
            var asm = Assembly.GetExecutingAssembly();
            using (var src = asm.GetManifestResourceStream(ResourceName))
            {
                if (src == null) throw new InvalidOperationException("ressource " + ResourceName + " absente de l'exécutable.");

                if (File.Exists(Paths.Tool))
                {
                    var existing = new FileInfo(Paths.Tool);
                    if (existing.Length == src.Length) return;
                }

                string tmp = Paths.Tool + ".new";
                using (var dst = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
                    src.CopyTo(dst);

                if (File.Exists(Paths.Tool)) File.Delete(Paths.Tool);
                File.Move(tmp, Paths.Tool);
                Journal.Write("framework_tool.exe extrait (" + new FileInfo(Paths.Tool).Length + " octets)");
            }
        }

        private static string Run(string arguments)
        {
            var psi = new ProcessStartInfo
            {
                FileName = Paths.Tool,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
            };

            using (var p = Process.Start(psi))
            {
                // framework_tool attend un ENTER quand sa sortie est redirigée :
                // fermer stdin le débloque.
                p.StandardInput.Close();
                string stdout = p.StandardOutput.ReadToEnd();
                string stderr = p.StandardError.ReadToEnd();
                if (!p.WaitForExit(10000))
                {
                    try { p.Kill(); } catch { }
                    throw new TimeoutException("framework_tool n'a pas répondu en 10 s.");
                }
                if (p.ExitCode != 0)
                    throw new InvalidOperationException("framework_tool a échoué (code " + p.ExitCode + "). " + (stdout + stderr).Trim());
                return stdout + stderr;
            }
        }

        // Sortie attendue : « Minimum 0%, Maximum 80% »
        public static int GetLimit()
        {
            string text = Run("--charge-limit");
            var m = System.Text.RegularExpressions.Regex.Match(text, @"Maximum\s+(\d+)\s*%");
            if (!m.Success) throw new InvalidOperationException("limite illisible dans la sortie : " + text.Trim());
            return int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
        }

        // Écrit puis relit : sur certains BIOS l'EC ignore la consigne.
        public static int SetLimit(int percent)
        {
            if (percent < 20 || percent > 100)
                throw new ArgumentOutOfRangeException("percent", "limite hors bornes : " + percent);
            Run("--charge-limit " + percent.ToString(CultureInfo.InvariantCulture));
            int readback = GetLimit();
            if (readback != percent)
                throw new InvalidOperationException("l'EC a retenu " + readback + " % au lieu de " + percent + " %.");
            return readback;
        }
    }

    internal static class Scheduler
    {
        private static string TaskName
        {
            get { return "FrameworkChargeTray-" + Environment.UserName; }
        }

        private static string Xml(string exePath, string user)
        {
            // Interactive + HighestAvailable : l'app démarre élevée à l'ouverture
            // de session, sans invite UAC.
            return
"<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\n" +
"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\r\n" +
"  <RegistrationInfo>\r\n" +
"    <Description>Framework Charge Tray - limite de charge de la batterie</Description>\r\n" +
"  </RegistrationInfo>\r\n" +
"  <Triggers>\r\n" +
"    <LogonTrigger>\r\n" +
"      <Enabled>true</Enabled>\r\n" +
"      <Delay>PT20S</Delay>\r\n" +
"      <UserId>" + Escape(user) + "</UserId>\r\n" +
"    </LogonTrigger>\r\n" +
"  </Triggers>\r\n" +
"  <Principals>\r\n" +
"    <Principal id=\"Author\">\r\n" +
"      <UserId>" + Escape(user) + "</UserId>\r\n" +
"      <LogonType>InteractiveToken</LogonType>\r\n" +
"      <RunLevel>HighestAvailable</RunLevel>\r\n" +
"    </Principal>\r\n" +
"  </Principals>\r\n" +
"  <Settings>\r\n" +
"    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\r\n" +
"    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\r\n" +
"    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\r\n" +
"    <AllowHardTerminate>true</AllowHardTerminate>\r\n" +
"    <StartWhenAvailable>true</StartWhenAvailable>\r\n" +
"    <Enabled>true</Enabled>\r\n" +
"    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>\r\n" +
"    <Priority>7</Priority>\r\n" +
"  </Settings>\r\n" +
"  <Actions Context=\"Author\">\r\n" +
"    <Exec>\r\n" +
"      <Command>" + Escape(exePath) + "</Command>\r\n" +
"    </Exec>\r\n" +
"  </Actions>\r\n" +
"</Task>\r\n";
        }

        private static string Escape(string s)
        {
            return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
        }

        private static int Schtasks(string arguments, string stdinNothing)
        {
            var psi = new ProcessStartInfo
            {
                FileName = "schtasks.exe",
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using (var p = Process.Start(psi))
            {
                string o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                p.WaitForExit(20000);
                if (p.ExitCode != 0) Journal.Write("schtasks (" + arguments + ") : " + o.Trim());
                return p.ExitCode;
            }
        }

        // Vrai si la tâche est absente OU si elle ne pointe pas sur cet
        // exécutable : sans ce second test, un exe déplacé — ou une tâche
        // héritée d'une version antérieure — garderait une commande morte.
        public static bool NeedsRegistration()
        {
            var psi = new ProcessStartInfo
            {
                FileName = "schtasks.exe",
                Arguments = "/Query /TN \"" + TaskName + "\" /XML",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            try
            {
                using (var p = Process.Start(psi))
                {
                    string xml = p.StandardOutput.ReadToEnd();
                    p.StandardError.ReadToEnd();
                    p.WaitForExit(20000);
                    if (p.ExitCode != 0) return true;

                    string exe = Assembly.GetExecutingAssembly().Location;
                    if (xml.IndexOf(exe, StringComparison.OrdinalIgnoreCase) >= 0) return false;

                    Journal.Write("la tâche ne pointe pas sur " + exe + ", réenregistrement");
                    return true;
                }
            }
            catch { return true; }
        }

        public static void EnsureRegistered()
        {
            try
            {
                string exe = Assembly.GetExecutingAssembly().Location;
                string user = WindowsIdentity.GetCurrent().Name;
                string xmlPath = Path.Combine(Path.GetTempPath(), "fct-task-" + Guid.NewGuid().ToString("N") + ".xml");

                // schtasks /XML exige de l'UTF-16.
                File.WriteAllText(xmlPath, Xml(exe, user), Encoding.Unicode);
                try
                {
                    int code = Schtasks("/Create /TN \"" + TaskName + "\" /XML \"" + xmlPath + "\" /F", null);
                    if (code == 0) Journal.Write("tâche « " + TaskName + " » enregistrée sur " + exe);
                }
                finally { try { File.Delete(xmlPath); } catch { } }
            }
            catch (Exception ex) { Journal.Write("enregistrement de la tâche impossible : " + ex.Message); }
        }

        public static void Unregister()
        {
            Schtasks("/Delete /TN \"" + TaskName + "\" /F", null);
        }
    }

    internal sealed class TrayApp : IDisposable
    {
        private readonly NotifyIcon _icon;
        private readonly ContextMenuStrip _menu;
        private readonly ToolStripMenuItem _header, _itemMax, _itemDefault;
        private readonly System.Windows.Forms.Timer _timer;
        private readonly Settings _cfg;
        private Icon _current;

        public TrayApp(int hardwareLimit)
        {
            _cfg = Settings.Load();

            if (_cfg.DefaultLimit <= 0)
            {
                _cfg.DefaultLimit = (hardwareLimit > 0 && hardwareLimit < 100) ? hardwareLimit : 80;
                Journal.Write("valeur par défaut retenue : " + _cfg.DefaultLimit + " %");
                _cfg.Save();
            }

            _header = new ToolStripMenuItem { Enabled = false };
            _itemMax = new ToolStripMenuItem("Charge maximale 100 %");
            _itemDefault = new ToolStripMenuItem("Par défaut Framework");
            _itemMax.Click += (s, e) => SetMode(100);
            _itemDefault.Click += (s, e) => SetMode(_cfg.DefaultLimit);

            var refresh = new ToolStripMenuItem("Actualiser");
            refresh.Click += (s, e) => Sync(false);
            var quit = new ToolStripMenuItem("Quitter");
            quit.Click += (s, e) => { _icon.Visible = false; Application.Exit(); };

            _menu = new ContextMenuStrip();
            _menu.Items.Add(_header);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(_itemMax);
            _menu.Items.Add(_itemDefault);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(refresh);
            _menu.Items.Add(quit);

            _icon = new NotifyIcon { Visible = true, ContextMenuStrip = _menu };
            // Clic gauche ouvre le même menu que le clic droit.
            _icon.MouseUp += (s, e) =>
            {
                if (e.Button != MouseButtons.Left) return;
                var m = typeof(NotifyIcon).GetMethod("ShowContextMenu",
                    BindingFlags.Instance | BindingFlags.NonPublic);
                if (m != null) m.Invoke(_icon, null);
            };

            Journal.Write("démarrage");

            // Réapplication dès le lancement : l'EC retombe sur la valeur du
            // BIOS après un redémarrage ou une remise à zéro du battery
            // extender, c'est ici qu'on rattrape.
            Update(hardwareLimit);
            Sync(true);

            _timer = new System.Windows.Forms.Timer { Interval = Math.Max(30, _cfg.PollSeconds) * 1000 };
            _timer.Tick += (s, e) => Sync(true);
            _timer.Start();

            Microsoft.Win32.SystemEvents.PowerModeChanged += (s, e) =>
            {
                if (e.Mode == Microsoft.Win32.PowerModes.Resume) Sync(true);
            };
        }

        private void SetMode(int percent)
        {
            try
            {
                int applied = Tool.SetLimit(percent);
                _cfg.DesiredLimit = applied;
                _cfg.Save();
                Update(applied);
                Journal.Write("limite réglée sur " + applied + " %");
                _icon.ShowBalloonTip(3000, "Framework Charge Tray",
                    "Charge limitée à " + applied + " %.", ToolTipIcon.Info);
            }
            catch (Exception ex) { Fail(ex.Message); }
        }

        // Reapply : relit la préférence partagée avant de juger l'écart, sinon
        // l'autre session imposerait sa valeur en mémoire, périmée.
        private void Sync(bool reapply)
        {
            try
            {
                var shared = Settings.Load();
                if (shared.DefaultLimit > 0) _cfg.DefaultLimit = shared.DefaultLimit;
                _cfg.DesiredLimit = shared.DesiredLimit;

                int hardware = Tool.GetLimit();
                if (reapply && _cfg.DesiredLimit > 0 && hardware != _cfg.DesiredLimit)
                {
                    Journal.Write("limite matérielle " + hardware + " % au lieu de "
                                  + _cfg.DesiredLimit + " %, réapplication");
                    hardware = Tool.SetLimit(_cfg.DesiredLimit);
                }
                Update(hardware);
            }
            catch (Exception ex) { Fail(ex.Message); }
        }

        private void Update(int hardwareLimit)
        {
            bool capped = hardwareLimit > 0 && hardwareLimit < 100;
            int charge = BatteryPercent();

            _header.Text = "Limite : " + hardwareLimit + " %  ·  batterie " + charge + " %";
            _itemDefault.Text = "Par défaut Framework (" + _cfg.DefaultLimit + " %)";
            _itemMax.Checked = !capped;
            _itemDefault.Checked = capped;

            string tip = "Framework Charge Tray — limite " + hardwareLimit + " %, batterie " + charge + " %";
            _icon.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;

            var old = _current;
            _current = BuildIcon(charge, capped);
            _icon.Icon = _current;
            if (old != null) { NativeMethods.DestroyIcon(old.Handle); old.Dispose(); }
        }

        private static int BatteryPercent()
        {
            float f = SystemInformation.PowerStatus.BatteryLifePercent;
            if (f < 0 || f > 1) return 0;
            return (int)Math.Round(f * 100f);
        }

        // Batterie dessinée : verte en mode limité, orange à 100 %, remplissage
        // proportionnel à la charge réelle.
        private static Icon BuildIcon(int charge, bool capped)
        {
            using (var bmp = new Bitmap(32, 32))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.None;
                    g.Clear(Color.Transparent);

                    Color fill = capped ? Color.FromArgb(76, 175, 80) : Color.FromArgb(255, 152, 0);
                    var body = new Rectangle(4, 9, 22, 14);

                    using (var pen = new Pen(Color.FromArgb(235, 235, 235), 2f))
                        g.DrawRectangle(pen, body);
                    using (var cap = new SolidBrush(Color.FromArgb(235, 235, 235)))
                        g.FillRectangle(cap, 26, 13, 3, 6);

                    int inner = body.Width - 4;
                    int w = (int)Math.Round(inner * Math.Max(0, Math.Min(100, charge)) / 100.0);
                    if (w > 0)
                        using (var b = new SolidBrush(fill))
                            g.FillRectangle(b, body.X + 2, body.Y + 2, w, body.Height - 4);
                }
                return Icon.FromHandle(bmp.GetHicon());
            }
        }

        private void Fail(string message)
        {
            Journal.Write("ERREUR : " + message);
            _icon.ShowBalloonTip(6000, "Framework Charge Tray", message, ToolTipIcon.Error);
        }

        public void Dispose()
        {
            if (_timer != null) { _timer.Stop(); _timer.Dispose(); }
            if (_icon != null) { _icon.Visible = false; _icon.Dispose(); }
            if (_menu != null) _menu.Dispose();
            if (_current != null) { NativeMethods.DestroyIcon(_current.Handle); _current.Dispose(); }
        }
    }

    internal static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr handle);
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length > 0 && args[0].Equals("--uninstall", StringComparison.OrdinalIgnoreCase))
            {
                Scheduler.Unregister();
                Journal.Write("désinstallé (tâche retirée)");
                MessageBox.Show("Tâche de démarrage retirée.\n\nLa limite en cours reste dans l'EC ; elle "
                    + "reviendra à la valeur du BIOS au prochain redémarrage.",
                    "Framework Charge Tray", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            }

            bool created;
            using (var mutex = new Mutex(true, @"Local\FrameworkChargeTray", out created))
            {
                if (!created) { Journal.Write("instance déjà en cours, arrêt."); return 0; }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                try { Tool.EnsureExtracted(); }
                catch (Exception ex)
                {
                    Fatal("Impossible de déposer framework_tool.exe.\n\n" + ex.Message);
                    return 1;
                }

                int limit;
                try { limit = Tool.GetLimit(); }
                catch (Exception ex)
                {
                    Fatal("Accès à l'Embedded Controller impossible.\n\n" + ex.Message
                        + "\n\nCette app exige un Framework Laptop et des droits administrateur.");
                    return 1;
                }

                if (Scheduler.NeedsRegistration()) Scheduler.EnsureRegistered();

                using (var app = new TrayApp(limit)) { Application.Run(); }
                return 0;
            }
        }

        private static void Fatal(string message)
        {
            Journal.Write("FATAL : " + message.Replace(Environment.NewLine, " "));
            MessageBox.Show(message, "Framework Charge Tray", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
