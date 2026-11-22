# Rundenwettkampf Auswertung: small web server for this PC only.
# Serves the pages and passes the state from the control page (screen 1)
# on to the TV display (screen 2). Started via Starten.cmd.
#
# How it fits together
#   - Starten.cmd starts this script with -Launch: it only starts itself again without any console and ends
#     (see "No console windows" below). The server then puts an icon in the notification area (tray menu:
#     open control page, open/close TV display, quit) and opens the control page in the default browser.
#     The TV display (index.html?display, Edge kiosk on the chosen screen) is only opened on request,
#     from the tray menu or the control page, since it is only needed on match evenings.
#   - The control page POSTs its state after every change; the TV display polls it every 100 ms.
#     The server only stores and hands out the last state, all logic runs in app.js.
#   - Single-threaded: requests are handled one after another (fine for two pages on one PC).
#   - Per PC settings live in %LOCALAPPDATA%\RWK-Auswertung\settings.json (screen, gate, league).
#   - The club branding (name, three colors, logo embedded as data URL) is one file of its own:
#     %LOCALAPPDATA%\RWK-Auswertung\branding.json. It can be exported and loaded in the settings dialog,
#     so a club can hand it to another PC. Without it the neutral defaults apply (see "Branding" below).
#   - The competitions come only from the DISAG database dboss.mdb (see "DISAG database" below).
#   - A background thread takes the DISAG JSON Live events from the UDP broadcast or the log file (selectable)
#     and keeps the shooter per range up to date (see "DISAG JSON Live" below); what it receives is logged
#     to %LOCALAPPDATA%\RWK-Auswertung\gate-log. It only receives and never asks the OSS anything. (Asking the
#     web port 8081 of the OSS who is logged in was removed on 2026-11-14: it could crash the OSS.)
#
# API (all JSON unless noted)
#   GET  /api/ping                 server is up (the control page uses it to detect server mode)
#   GET  /api/state                last published state; ?display=1 also marks the TV as alive
#   POST /api/state                control page publishes its state, answer: age of the last TV poll
#   GET  /api/status               age of the last TV poll only (status line on the control page)
#   GET  /api/comp, POST /api/comp the competition currently shown (sent once per competition)
#   GET  /api/screens              connected screens and the remembered choice
#   POST /api/screens/identify     shows the screen numbers on all screens for 3 seconds
#   GET  /api/branding             club name, colors, logo flag and revision
#   POST /api/branding             stores the branding file: {"name", "colors", "logo"} (logo: data URL,
#                                  "" = default logo, missing/null = keep the current one)
#   GET  /api/branding/logo        current logo (image), custom or default
#   GET  /api/branding/file        the whole branding file (export in the settings dialog)
#   POST /api/branding/file/pick   file dialog for "Branding laden", returns name and content of the chosen file
#   POST /api/branding/logo/pick   file dialog for the logo, returns it as data URL
#   POST /api/branding/reset       deletes the branding file: neutral defaults again
#   POST /api/display/open         opens the TV display full screen, optional {"screen": id}
#   POST /api/display/window       reopens the TV display as a window (Esc on the TV)
#   POST /api/display/close        closes the TV display (tray menu)
#   POST /api/control/open         opens the control page in the default browser (tray menu)
#   GET  /api/gate                 DISAG JSON Live status and the shooter per range
#   POST /api/gate/file/pick       opens the Windows file dialog for the JSON Live log file, returns the choice
#   POST /api/gate/config          stores data source, server, UDP port, log file, number of ranges and on/off
#   GET  /api/league               today's Rundenwettkaempfe and the number of matches with shots (last reading)
#   POST /api/league/refresh       reads the DISAG database once ("Neu einlesen"), answer as GET /api/league
#   GET  /api/league/all           every match with shots of the last reading as export XML (<results>)
#   POST /api/league/file/pick     opens the Windows file dialog for the database (dboss.mdb), returns the choice
#   POST /api/league/config        stores the database file and whether today's matches show on the TV
#   POST /api/quit                 closes the TV display and stops the server
#   Anything else is served as a static file from this folder (index.html, app.js, assets ...).
param(
  [int]$Port = 8777,
  [switch]$NoBrowser,
  [switch]$Launch                  # start the server without a console window and end right away (Starten.cmd)
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# No console windows
# On Windows 11 the Windows Terminal is the default console. It ignores "-WindowStyle Hidden" and
# Start-Process -WindowStyle Hidden, so every hidden PowerShell would still pop up a terminal window.
# A process started with CreateNoWindow gets no console window at all, whichever terminal is set, so the
# server and all its helper processes are started that way.
# ---------------------------------------------------------------------------
function Start-NoWindow([string]$exe, [string[]]$arguments) {
  $psi = New-Object Diagnostics.ProcessStartInfo $exe
  $psi.Arguments = ($arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  return [Diagnostics.Process]::Start($psi)
}

# Starten.cmd: start the real server without a console and end; the short-lived window of Starten.cmd closes
if ($Launch) {
  $serverArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Port', "$Port")
  if ($NoBrowser) { $serverArgs += '-NoBrowser' }
  [void](Start-NoWindow (Join-Path $PSHOME 'powershell.exe') $serverArgs)
  exit
}
# Program version, also in app.js (APP_VERSION) and Anleitung.html; make-release.ps1 checks they match
$AppVersion = '1.0'
$Root = $PSScriptRoot
$Base = "http://localhost:$Port/"
$ProfileDir = Join-Path $env:LOCALAPPDATA 'RWK-Auswertung-Display'   # separate Edge profile just for the TV display
$ConfigDir = Join-Path $env:LOCALAPPDATA 'RWK-Auswertung'            # settings and branding, per PC
$ConfigFile = Join-Path $ConfigDir 'settings.json'
$BrandingFile = Join-Path $ConfigDir 'branding.json'
$Host.UI.RawUI.WindowTitle = "Rundenwettkampf Auswertung v$AppVersion - dieses Fenster offen lassen"

# Settings per PC: screen (screen of the TV display), gate (live data), league (database)
# Kept in memory and only read again when the file changed (time and size), because the pages ask for
# gate and database info every few seconds. Hand edits of settings.json are still picked up.
$ConfigCache = @{ stamp = ''; data = @{} }
function Get-Config {
  $stamp = ''
  try {
    $f = Get-Item -LiteralPath $ConfigFile -ErrorAction Stop
    $stamp = "$($f.LastWriteTimeUtc.Ticks)|$($f.Length)"
  } catch { }
  if ($stamp -ne $ConfigCache.stamp) {
    $cfg = @{}
    try {
      if ($stamp) {
        $json = [IO.File]::ReadAllText($ConfigFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
      }
    } catch { }
    $ConfigCache.data = $cfg
    $ConfigCache.stamp = $stamp
  }
  return $ConfigCache.data.Clone()
}

# Writes all settings to settings.json
function Save-Config($cfg) {
  New-Item -ItemType Directory -Force $ConfigDir | Out-Null
  [IO.File]::WriteAllText($ConfigFile, ($cfg | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
  $ConfigCache.stamp = ''   # read again on the next access
}

# Stores one top-level value in settings.json, keeping all others
function Set-ConfigValue([string]$key, $value) {
  $cfg = Get-Config
  $cfg[$key] = $value
  Save-Config $cfg
}

# One section of the settings (gate, league) with every value typed and filled with its default: a stored
# value counts only if it is not null and converts to the type of the default ("" stands for a string).
function Get-Section([string]$name, $defaults) {
  $stored = (Get-Config)[$name]
  $out = [ordered]@{}
  foreach ($k in $defaults.Keys) {
    $v = if ($stored) { $stored.$k } else { $null }
    $typed = if ($null -ne $v) { $v -as $defaults[$k].GetType() } else { $null }
    $out[$k] = if ($null -ne $typed) { $typed } else { $defaults[$k] }
  }
  return $out
}

# Settings of older versions, converted once at start so the rest of the program only knows the current form:
# - before 1.0 the settings lived in %LOCALAPPDATA%\SV-RWK-Tool (branding is not taken over: load a branding file)
# - "folder" (results folder), "branding" and "hideConsole" are gone
# - gate.folder / league.folder (folder of the log file / database, fixed file names) became gate.file / league.file
# - league.enabled became league.showToday
# (Can be removed once every PC has run 1.0 at least once.)
$LegacyConfigFile = Join-Path $env:LOCALAPPDATA 'SV-RWK-Tool\settings.json'
if ((Test-Path $LegacyConfigFile) -and -not (Test-Path $ConfigFile)) {
  New-Item -ItemType Directory -Force $ConfigDir | Out-Null
  Copy-Item $LegacyConfigFile $ConfigFile
}
$cfg = Get-Config
$changed = $false
foreach ($k in 'folder', 'branding', 'hideConsole') { if ($cfg.ContainsKey($k)) { $cfg.Remove($k); $changed = $true } }
foreach ($m in @(@('gate', 'OUT-JSONInterface.log'), @('league', 'dboss.mdb'))) {
  $s = $cfg[$m[0]]
  if ($s -and $s.PSObject.Properties['folder']) {
    if ($s.folder -and -not $s.file) { $s | Add-Member -NotePropertyName file -NotePropertyValue (Join-Path ([string]$s.folder) $m[1]) -Force }
    $s.PSObject.Properties.Remove('folder'); $changed = $true
  }
}
$l = $cfg['league']
if ($l -and $l.PSObject.Properties['enabled']) {
  if ($null -eq $l.showToday) { $l | Add-Member -NotePropertyName showToday -NotePropertyValue ([bool]$l.enabled) -Force }
  $l.PSObject.Properties.Remove('enabled'); $changed = $true
}
if ($changed) { Save-Config $cfg }
Remove-Variable cfg, changed, l

# Runs a script block on an STA thread of its own (Windows Forms needs one) while the server keeps answering;
# the runspace is cleaned up when the script ends
function Start-StaScript([scriptblock]$script, [object[]]$arguments = @()) {
  $rs = [runspacefactory]::CreateRunspace()
  $rs.ApartmentState = 'STA'
  $rs.Open()
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript($script)
  foreach ($a in $arguments) { [void]$ps.AddArgument($a) }
  [void]$ps.BeginInvoke()
  return $ps
}

# ---------------------------------------------------------------------------
# File dialog: one modern Windows "Open" dialog (as in Explorer) for every file the user chooses: the DISAG
# database, the JSON Live log file, a branding file and a logo. It runs inside the server on a thread of its
# own (STA), so it opens right away (no extra PowerShell process, no compiling on every click).
# - Owned by an invisible window of its own: no taskbar button, no "Windows PowerShell" in Alt+Tab.
# - Centered on the screen the mouse is on (where the button was clicked) and kept topmost, so it can never
#   get lost behind the browser (an earlier version had it open invisibly behind a hidden window).
# - All choices share one remembered state (client GUID): same view and last folder every time.
# - Works in real screen pixels (per monitor DPI) on its threads only, so with display scaling the centering
#   is right and the rest of the server (screen positions for the TV display) is not affected.
# ---------------------------------------------------------------------------
$FilePickerCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class RwkFilePicker {
  [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
  class FileOpenDialogCo { }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct FilterSpec {
    [MarshalAs(UnmanagedType.LPWStr)] public string Name;
    [MarshalAs(UnmanagedType.LPWStr)] public string Spec;
  }

  [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IFileDialog {
    [PreserveSig] int Show(IntPtr parent);
    void SetFileTypes(uint c, [MarshalAs(UnmanagedType.LPArray)] FilterSpec[] specs);
    void SetFileTypeIndex(uint i);
    void GetFileTypeIndex(out uint i);
    void Advise(IntPtr sink, out uint cookie);
    void Unadvise(uint cookie);
    void SetOptions(uint fos);
    void GetOptions(out uint fos);
    void SetDefaultFolder(IShellItem si);
    void SetFolder(IShellItem si);
    void GetFolder(out IShellItem si);
    void GetCurrentSelection(out IShellItem si);
    void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
    void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
    void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
    void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
    void GetResult(out IShellItem si);
    void AddPlace(IShellItem si, int place);
    void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string ext);
    void Close(int hr);
    void SetClientGuid(ref Guid guid);
  }

  [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellItem {
    void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    void GetParent(out IShellItem si);
    void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
  }

  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
  static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [In] ref Guid riid, out IShellItem si);

  const uint FOS_PICKFOLDERS = 0x20, FOS_FORCEFILESYSTEM = 0x40, FOS_PATHMUSTEXIST = 0x800, FOS_FILEMUSTEXIST = 0x1000;
  const uint SIGDN_FILESYSPATH = 0x80058000;
  // One remembered state (view, last folder) for all file choices of this program
  static Guid ClientGuid = new Guid("5b0c6c1e-2f4a-4d39-9a57-2b8e3f1d7a64");

  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);
  [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  delegate bool EnumProc(IntPtr hwnd, IntPtr param);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr param);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern IntPtr CreateWindowEx(uint exStyle, string cls, string name, uint style, int x, int y, int w, int h,
                                      IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
  [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

  // Real screen pixels (per monitor v2) for the calling thread only; returns the previous setting.
  // Windows PowerShell itself is not DPI aware, the dialog is: without this the centering is off with scaling.
  static IntPtr UseRealPixels() {
    try { return SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { return IntPtr.Zero; }
  }
  static void RestorePixels(IntPtr previous) {
    if (previous == IntPtr.Zero) return;
    try { SetThreadDpiAwarenessContext(previous); } catch (EntryPointNotFoundException) { }
  }

  // Work area of the screen the mouse is on; the dialog is centered on it
  static RECT work;
  // The open dialog window, so the server can close it after a timeout
  static IntPtr openDialog = IntPtr.Zero;

  // Invisible owner window on that screen. An owned dialog gets no taskbar button of its own.
  static IntPtr CreateOwner() {
    POINT p;
    var mi = new MONITORINFO(); mi.Size = Marshal.SizeOf(mi);
    work = new RECT();
    if (GetCursorPos(out p) && GetMonitorInfo(MonitorFromPoint(p, 2), ref mi)) work = mi.Work;
    // WS_EX_TOOLWINDOW, WS_POPUP; never shown
    return CreateWindowEx(0x80, "STATIC", "", 0x80000000, work.Left, work.Top, 1, 1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
  }

  // Show() blocks, so a helper thread waits for the dialog window (class #32770 of this process with the
  // dialog's title), centers it on the screen, keeps it above all other windows and brings it to the front
  // until it had the focus once (at most 5 s). It grows a moment after it appears, so during the first two
  // seconds it is centered again whenever its size changes (later the user may have moved it).
  static void PlaceDialogWhenShown(string title) {
    uint me = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    var t = new System.Threading.Thread(() => {
      UseRealPixels();
      int placedW = 0, placedH = 0;
      bool centered = false, focused = false;
      for (int i = 0; i < 250; i++) {
        System.Threading.Thread.Sleep(20);
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
          uint pid; GetWindowThreadProcessId(h, out pid);
          if (pid != me || !IsWindowVisible(h)) return true;
          var cls = new StringBuilder(32); GetClassName(h, cls, 32);
          var text = new StringBuilder(256); GetWindowText(h, text, 256);
          if (cls.ToString() == "#32770" && text.ToString() == title) { found = h; return false; }
          return true;
        }, IntPtr.Zero);
        if (found == IntPtr.Zero) continue;
        openDialog = found;
        RECT r;
        if (work.Right > work.Left && GetWindowRect(found, out r) &&
            (!centered || (i < 100 && (r.Right - r.Left != placedW || r.Bottom - r.Top != placedH)))) {
          int w = r.Right - r.Left, h = r.Bottom - r.Top;
          int x = Math.Max(work.Left, (work.Left + work.Right - w) / 2), y = Math.Max(work.Top, (work.Top + work.Bottom - h) / 2);
          // HWND_TOPMOST; SWP_NOSIZE | SWP_NOACTIVATE
          SetWindowPos(found, new IntPtr(-1), x, y, 0, 0, 0x11);
          placedW = w; placedH = h;
          centered = true;
        } else {
          // HWND_TOPMOST; SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
          SetWindowPos(found, new IntPtr(-1), 0, 0, 0, 0, 0x13);
        }
        if (!focused) { if (GetForegroundWindow() == found) focused = true; else Raise(found); }
      }
    });
    t.IsBackground = true;
    t.Start();
  }

  // Windows does not let a background process (the server) take the focus; a short Alt key press
  // lifts that lock, so the dialog does not open hidden behind the browser
  static void Raise(IntPtr hwnd) {
    keybd_event(0x12, 0, 0, UIntPtr.Zero);
    keybd_event(0x12, 0, 2, UIntPtr.Zero);
    BringWindowToTop(hwnd);
    SetForegroundWindow(hwnd);
  }

  // Closes the open dialog (as if "Abbrechen" was clicked); used by the server after its timeout
  public static void CloseOpenDialog() {
    if (openDialog != IntPtr.Zero) PostMessage(openDialog, 0x10, IntPtr.Zero, IntPtr.Zero);   // WM_CLOSE
  }

  // Lets the user choose an existing file. startFolder/startName preselect the current file, the filter
  // (e.g. "DISAG-Datenbank (*.mdb)", "*.mdb") is the first file type, "Alle Dateien" the second.
  // An empty filterSpec chooses a folder instead of a file (same dialog).
  // Must be called on an STA thread. Returns the chosen path, null on cancel.
  public static string Pick(string title, string startFolder, string startName, string filterName, string filterSpec) {
    IntPtr previous = UseRealPixels();
    IFileDialog dlg = (IFileDialog)new FileOpenDialogCo();
    IntPtr owner = CreateOwner();
    openDialog = IntPtr.Zero;
    bool folders = String.IsNullOrEmpty(filterSpec);
    try {
      dlg.SetClientGuid(ref ClientGuid);
      uint fos;
      dlg.GetOptions(out fos);
      dlg.SetOptions(fos | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | (folders ? FOS_PICKFOLDERS : FOS_FILEMUSTEXIST));
      dlg.SetTitle(title);
      if (!folders) dlg.SetFileTypes(2, new FilterSpec[] {
        new FilterSpec { Name = filterName, Spec = filterSpec },
        new FilterSpec { Name = "Alle Dateien", Spec = "*.*" }
      });
      if (!String.IsNullOrEmpty(startFolder)) {
        try {
          Guid iid = typeof(IShellItem).GUID;
          IShellItem item;
          SHCreateItemFromParsingName(startFolder, IntPtr.Zero, ref iid, out item);
          dlg.SetFolder(item);
        } catch { }
      }
      if (!String.IsNullOrEmpty(startName)) dlg.SetFileName(startName);
      PlaceDialogWhenShown(title);
      if (dlg.Show(owner) != 0) return null;
      IShellItem result;
      dlg.GetResult(out result);
      string path;
      result.GetDisplayName(SIGDN_FILESYSPATH, out path);
      return path;
    } finally {
      openDialog = IntPtr.Zero;
      Marshal.ReleaseComObject(dlg);
      if (owner != IntPtr.Zero) DestroyWindow(owner);
      RestorePixels(previous);
    }
  }
}

// Brings the TV display window to the front once Edge has opened it. Windows does not let a background
// process like this server simply raise a window, so the usual Alt key trick is used. Full screen: the window
// is also made topmost and placed exactly on the screen bounds, so it stays in front and covers the whole TV.
public static class RwkWindow {
  delegate bool EnumProc(IntPtr hwnd, IntPtr param);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr param);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
  [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

  // Largest visible Edge main window of an msedge process started after "since" (the display's own Edge)
  static IntPtr Find(DateTime since) {
    var pids = new System.Collections.Generic.HashSet<uint>();
    foreach (var p in System.Diagnostics.Process.GetProcessesByName("msedge")) {
      try { if (p.StartTime >= since) pids.Add((uint)p.Id); } catch { }
    }
    IntPtr best = IntPtr.Zero; long bestArea = 0;
    EnumWindows((h, prm) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (!pids.Contains(pid) || !IsWindowVisible(h)) return true;
      var cls = new StringBuilder(64); GetClassName(h, cls, 64);
      if (cls.ToString() != "Chrome_WidgetWin_1") return true;
      RECT r; GetWindowRect(h, out r);
      long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
      if (area > bestArea) { bestArea = area; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }

  // Waits (at most 20 s, on a thread of its own) for the window and brings it to the front; Edge switches to
  // full screen a moment after the window appears, so position and focus are applied a few times
  public static void FocusWhenShown(DateTime since, int x, int y, int w, int h, bool fullScreen) {
    var t = new System.Threading.Thread(() => {
      IntPtr hwnd = IntPtr.Zero;
      for (int i = 0; i < 80 && hwnd == IntPtr.Zero; i++) { System.Threading.Thread.Sleep(250); hwnd = Find(since); }
      if (hwnd == IntPtr.Zero) return;
      foreach (int wait in new[] { 0, 700, 1500, 3000 }) {
        System.Threading.Thread.Sleep(wait);
        if (fullScreen) SetWindowPos(hwnd, new IntPtr(-1), x, y, w, h, 0x40);   // HWND_TOPMOST, SWP_SHOWWINDOW
        ShowWindow(hwnd, 5);
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(hwnd);
      }
    });
    t.IsBackground = true;
    t.Start();
  }
}
'@
Add-Type -TypeDefinition $FilePickerCode

# The dialog needs an STA thread; the server's own thread is MTA, so it runs in a runspace of its own
$PickerRunspace = [runspacefactory]::CreateRunspace()
$PickerRunspace.ApartmentState = 'STA'
$PickerRunspace.ThreadOptions = 'ReuseThread'
$PickerRunspace.Open()

# Shows the file dialog and returns the chosen path, $null if cancelled. $current = the file set so far (its
# folder and name are preselected), $filterName/$filterSpec = first file type. The server waits for the answer
# (as before); after 10 minutes without a choice the dialog is closed so the server never hangs.
function Select-File([string]$title, [string]$current, [string]$filterName, [string]$filterSpec) {
  # Without an existing folder the dialog opens where it was used last
  $current = "$current".TrimEnd('\')
  $folder = if ($current) { Split-Path -Parent $current } else { '' }
  if (-not ($folder -and (Test-Path -LiteralPath $folder -PathType Container))) { $folder = '' }
  $name = if ($current) { Split-Path -Leaf $current } else { '' }
  $ps = [powershell]::Create()
  $ps.Runspace = $PickerRunspace
  [void]$ps.AddScript({ param($t, $f, $n, $fn, $fs) [RwkFilePicker]::Pick($t, $f, $n, $fn, $fs) }).
    AddArgument($title).AddArgument($folder).AddArgument($name).AddArgument($filterName).AddArgument($filterSpec)
  try {
    $handle = $ps.BeginInvoke()
    if (-not $handle.AsyncWaitHandle.WaitOne(600000)) {
      [RwkFilePicker]::CloseOpenDialog()
      if (-not $handle.AsyncWaitHandle.WaitOne(5000)) { return $null }
    }
    $picked = @($ps.EndInvoke($handle)) | Select-Object -First 1
    if ($picked) { return [string]$picked }
    return $null
  } catch {
    return $null
  } finally {
    $ps.Dispose()
  }
}

# Path of msedge.exe, $null if Edge is not installed
function Find-Edge {
  foreach ($p in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                   "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

# Closes the TV display (all Edge processes running with the display profile) and waits until they are
# really gone, otherwise a new start would hand its arguments to the dying instance
function Close-Display {
  for ($i = 0; $i -lt 30; $i++) {
    $left = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*RWK-Auswertung-Display*' })
    if (-not $left) { break }
    if ($i -eq 0) { $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Milliseconds 100
  }
}

# Read real monitor names (e.g. "LG TV") from the monitor entry in Windows
$MonitorCode = @'
using System;
using System.Runtime.InteropServices;

public static class RwkMonitors {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);

  // Hardware ID of the monitor on a display output, e.g. "GSM5B08"
  public static string HardwareId(string adapter) {
    DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
    dd.cb = Marshal.SizeOf(dd);
    if (!EnumDisplayDevices(adapter, 0, ref dd, 0) || String.IsNullOrEmpty(dd.DeviceID)) return null;
    string[] parts = dd.DeviceID.Split('\\');
    return parts.Length > 1 ? parts[1] : null;
  }
}
'@
Add-Type -TypeDefinition $MonitorCode
Add-Type -AssemblyName System.Windows.Forms

# Monitor names by hardware ID from WMI. The query is slow (about 40 ms) and the control page asks for the
# screens whenever its window gets the focus, so the names are kept for a minute.
$MonitorNameCache = @{ at = [datetime]::MinValue; names = @{} }
function Get-MonitorNames {
  if (((Get-Date) - $MonitorNameCache.at).TotalSeconds -lt 60) { return $MonitorNameCache.names }
  $names = @{}
  try {
    Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
      $code = ($_.InstanceName -split '\\')[1]
      $name = -join ($_.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
      if ($code -and $name) { $names[$code] = $name.Trim() }
    }
  } catch { }
  $MonitorNameCache.names = $names
  $MonitorNameCache.at = Get-Date
  return $names
}

# All connected screens: Windows device name (id), number as in the Windows display
# settings order, real monitor name if known, resolution, position and whether it is the primary one
function Get-Screens {
  $names = Get-MonitorNames
  $i = 0
  foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    $i++
    $code = $null
    try { $code = [RwkMonitors]::HardwareId($s.DeviceName) } catch { }
    [pscustomobject]@{
      id = $s.DeviceName
      number = $i
      name = if ($code -and $names[$code]) { $names[$code] } else { $null }
      width = $s.Bounds.Width
      height = $s.Bounds.Height
      x = $s.Bounds.X
      y = $s.Bounds.Y
      primary = $s.Primary
    }
  }
}

# Briefly show a big number on every screen (own STA thread, so the server keeps answering)
function Show-ScreenNumbers {
  [void](Start-StaScript {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $forms = New-Object Collections.Generic.List[object]
    $i = 0
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
      $i++
      $f = New-Object System.Windows.Forms.Form
      $f.FormBorderStyle = 'None'; $f.StartPosition = 'Manual'; $f.TopMost = $true; $f.ShowInTaskbar = $false
      $f.BackColor = [System.Drawing.Color]::FromArgb(21, 21, 21)
      $f.Bounds = New-Object System.Drawing.Rectangle(($s.Bounds.X + [int](($s.Bounds.Width - 360) / 2)), ($s.Bounds.Y + [int](($s.Bounds.Height - 360) / 2)), 360, 360)
      $l = New-Object System.Windows.Forms.Label
      $l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'; $l.Text = "$i"
      $l.ForeColor = [System.Drawing.Color]::White
      $l.Font = New-Object System.Drawing.Font('Segoe UI', 160, [System.Drawing.FontStyle]::Bold)
      $f.Controls.Add($l); $f.Show(); $forms.Add($f)
    }
    $end = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    foreach ($f in $forms) { $f.Close() }
  })
}

# Open the TV display on the chosen screen. Without a choice: the last chosen one, otherwise the first
# that is not the primary screen. Normally full screen (kiosk) and in front. With -Windowed (Esc on the
# TV display) or when there is only one screen, as a normal window on that screen.
function Open-Display([string]$screenId, [switch]$Windowed) {
  Close-Display
  $all = [System.Windows.Forms.Screen]::AllScreens
  if (-not $screenId) { $screenId = (Get-Config).screen }
  $tv = $all | Where-Object { $_.DeviceName -eq $screenId } | Select-Object -First 1
  if (-not $tv) { $tv = $all | Where-Object { -not $_.Primary } | Select-Object -First 1 }
  if (-not $tv) { $tv = $all | Select-Object -First 1 }
  if ($all.Count -lt 2) { $Windowed = $true }
  $url = "${Base}index.html?display"
  $edge = Find-Edge
  if (-not $edge) {
    Write-Host 'Microsoft Edge wurde nicht gefunden, die Anzeige oeffnet sich im Standardbrowser.'
    Start-Process $url
    return
  }
  $b = $tv.Bounds
  $edgeArgs = @("--user-data-dir=`"$ProfileDir`"", '--no-first-run', '--no-default-browser-check', '--disable-features=Translate',
                "--window-position=$($b.X + 50),$($b.Y + 50)")
  if ($Windowed) {
    # "windowed" tells the page it already runs in a window (Esc then does nothing)
    $w = [Math]::Min(1280, $b.Width - 100); $h = [Math]::Min(760, $b.Height - 100)
    $edgeArgs += "--window-size=$w,$h", "--app=${url}&windowed"
    Write-Host "TV-Anzeige als Fenster auf $($tv.DeviceName) geoeffnet."
  } else {
    $edgeArgs += '--kiosk', $url, '--edge-kiosk-type=fullscreen'
    Write-Host "TV-Anzeige im Vollbild auf $($tv.DeviceName) geoeffnet."
  }
  $since = (Get-Date).AddSeconds(-1)
  Start-Process $edge -ArgumentList $edgeArgs
  [RwkWindow]::FocusWhenShown($since, $b.X, $b.Y, $b.Width, $b.Height, -not $Windowed)
}

# Open the control page in the default browser (http://localhost:<port>/)
function Open-Control {
  Start-Process $Base
}

# ---------------------------------------------------------------------------
# Tray icon (notification area): menu to open the control page, open/close the TV display and quit.
# Runs on its own STA thread with a Windows message loop; menu clicks call the server's own API,
# so all actions still run on the main thread. $TrayState.stop = $true removes the icon.
# ---------------------------------------------------------------------------
$TrayState = [hashtable]::Synchronized(@{ stop = $false })

$TrayWorker = {
  param($State, $Base, $IconBytes)
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing

  function Invoke-Api([string]$path) {
    try {
      $wc = New-Object Net.WebClient
      $wc.Headers['Content-Type'] = 'application/json'
      [void]$wc.UploadString("$Base$path", '{}')
    } catch { }
  }

  # Icon from the club logo, scaled into a square keeping its proportions
  $icon = [System.Drawing.SystemIcons]::Application
  try {
    $img = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [byte[]]$IconBytes)))
    $bmp = New-Object System.Drawing.Bitmap 64, 64
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $scale = [Math]::Min(64 / $img.Width, 64 / $img.Height)
    $w = [int]($img.Width * $scale); $h = [int]($img.Height * $scale)
    $g.DrawImage($img, [int]((64 - $w) / 2), [int]((64 - $h) / 2), $w, $h)
    $g.Dispose(); $img.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
  } catch { }

  $tray = New-Object System.Windows.Forms.NotifyIcon
  $tray.Icon = $icon
  $tray.Text = $State.title
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  # Umlauts as char codes: this file has no BOM, so Windows PowerShell would misread them
  $oe = [char]0xF6; $ss = [char]0xDF
  $openControl = $menu.Items.Add("Steuerung ${oe}ffnen")
  $openControl.Font = New-Object System.Drawing.Font($openControl.Font, [System.Drawing.FontStyle]::Bold)
  $openControl.add_Click({ Invoke-Api 'api/control/open' })
  $menu.Items.Add("TV-Anzeige ${oe}ffnen").add_Click({ Invoke-Api 'api/display/open' })
  $menu.Items.Add("TV-Anzeige schlie${ss}en").add_Click({ Invoke-Api 'api/display/close' })
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $menu.Items.Add('Beenden').add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show('Auswertung beenden? Die TV-Anzeige wird ebenfalls geschlossen.',
      'Rundenwettkampf Auswertung', 'YesNo', 'Question')
    if ($answer -eq 'Yes') { Invoke-Api 'api/quit' }
  })
  $tray.ContextMenuStrip = $menu
  $tray.add_MouseDoubleClick({ Invoke-Api 'api/control/open' })
  # No start notification: Windows would show it as "Windows PowerShell"
  $tray.Visible = $true

  # Leave the message loop once the server stops
  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 300
  $timer.add_Tick({ if ($State.stop) { $timer.Stop(); [System.Windows.Forms.Application]::ExitThread() } })
  $timer.Start()
  [System.Windows.Forms.Application]::Run()
  $tray.Visible = $false
  $tray.Dispose()
}

function Start-Tray {
  # Club logo from the branding file if Windows can read it (PNG, JPG, GIF), otherwise the default logo
  $logo = Get-LogoData
  $iconBytes = if ($logo -and $logo.mime -match '^image/(png|jpeg|gif)$') { $logo.bytes } else { [IO.File]::ReadAllBytes((Join-Path $Root 'assets\logo.png')) }
  $TrayState.title = "Rundenwettkampf Auswertung v$AppVersion"
  $script:TrayPowerShell = Start-StaScript $TrayWorker @($TrayState, $Base, $iconBytes)
}

# Writes a text answer (JSON by default) and disables caching
function Send-Text($res, [string]$text, [string]$type = 'application/json; charset=utf-8', [int]$status = 200) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($text)
  $res.StatusCode = $status
  $res.ContentType = $type
  $res.Headers['Cache-Control'] = 'no-store'
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

# Writes an object as JSON answer
function Send-Json($res, $obj, [int]$status = 200) {
  Send-Text $res ($obj | ConvertTo-Json -Depth 6 -Compress) -status $status
}
# Error answer for a rejected input (status 400) or a failed action
function Send-Error($res, [string]$text, [int]$status = 400) { Send-Json $res @{ error = $text } $status }

# Request body as UTF-8 text
function Read-Body($req) {
  $reader = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8)
  try { return $reader.ReadToEnd() } finally { $reader.Close() }
}

# ---------------------------------------------------------------------------
# Branding: club name, three colors and logo, shared by the control page and the TV display.
# Everything club specific lives in ONE file, branding.json next to settings.json:
#   { "format": "rwk-branding", "formatVersion": 1,
#     "name": "Schuetzenverein Musterhausen",
#     "colors": { "accent": "#rrggbb", "second": "#rrggbb", "background": "#rrggbb" },
#     "logo": "data:image/png;base64,..." }
# Every field is optional; missing ones use the neutral defaults (app.js, style.css, assets\logo.png).
# The same file is what "Branding exportieren" saves and "Branding laden" reads, so a club can copy its
# look to another PC. Kept in memory and only read again when the file changed; rev = file time.
# ---------------------------------------------------------------------------
$BrandColorKeys = 'accent', 'second', 'background'
$LogoPattern = '^data:(image/(?:png|jpeg|svg\+xml|webp|gif));base64,([A-Za-z0-9+/=]+)$'
$MaxLogoBytes = 5MB
$BrandingCache = @{ stamp = $null; data = $null; rev = 0; logo = $null }

# Checks branding values (from the dialog or a loaded file) and returns them in file form.
# Unknown keys and invalid colors are dropped, an invalid logo is an error (German text for the dialog).
function ConvertTo-CleanBranding($in) {
  $name = if ($in -and $null -ne $in.name) { ([string]$in.name).Trim() } else { '' }
  if ($name.Length -gt 80) { $name = $name.Substring(0, 80) }
  $colors = [ordered]@{}
  if ($in -and $in.colors) {
    foreach ($p in $in.colors.PSObject.Properties) {
      if ($BrandColorKeys -contains $p.Name -and [string]$p.Value -match '^#[0-9a-fA-F]{6}$') { $colors[$p.Name] = ([string]$p.Value).ToLower() }
    }
  }
  $logo = if ($in -and $in.logo) { ([string]$in.logo) -replace '\s', '' } else { '' }
  if ($logo) {
    if ($logo -notmatch $LogoPattern) { throw 'Das Logo muss ein Bild sein (PNG, JPG, SVG, WebP oder GIF).' }
    if ($Matches[2].Length * 3 / 4 -gt $MaxLogoBytes) { throw ('Das Logo ist zu gro{0}, h{1}chstens 5 MB.' -f [char]0xDF, [char]0xF6) }
  }
  return [ordered]@{ format = 'rwk-branding'; formatVersion = 1; name = $name; colors = $colors; logo = $logo }
}

# The stored branding in file form, $null when there is none (neutral defaults)
function Get-BrandingData {
  $stamp = ''
  $ticks = 0
  try {
    $f = Get-Item -LiteralPath $BrandingFile -ErrorAction Stop
    $stamp = "$($f.LastWriteTimeUtc.Ticks)|$($f.Length)"
    $ticks = $f.LastWriteTimeUtc.Ticks
  } catch { }
  if ($stamp -ne $BrandingCache.stamp) {
    $data = $null
    if ($stamp) {
      try { $data = ConvertTo-CleanBranding ([IO.File]::ReadAllText($BrandingFile, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { }
    }
    $BrandingCache.data = $data
    $BrandingCache.stamp = $stamp
    $BrandingCache.rev = [long]($ticks / 10000)
    $BrandingCache.logo = $null
  }
  return $BrandingCache.data
}

# Branding as sent to the pages: name, colors, logo (true when the file has one), rev.
# rev changes with every save so the TV display notices changes and reloads the logo.
function Get-Branding {
  $b = Get-BrandingData
  $out = [ordered]@{ name = ''; colors = [ordered]@{}; logo = $false; rev = $BrandingCache.rev }
  if ($b) {
    $out.name = $b.name
    $out.colors = $b.colors
    $out.logo = [bool]$b.logo
  }
  return $out
}

# Club logo decoded from the branding file: @{ mime; bytes }, $null without one
function Get-LogoData {
  $b = Get-BrandingData
  if (-not ($b -and $b.logo)) { return $null }
  if (-not $BrandingCache.logo -and $b.logo -match $LogoPattern) {
    $BrandingCache.logo = @{ mime = $Matches[1]; bytes = [Convert]::FromBase64String($Matches[2]) }
  }
  return $BrandingCache.logo
}

# Writes the branding file (UTF-8 without BOM, so the browser can read an exported copy as JSON)
function Save-Branding($clean) {
  New-Item -ItemType Directory -Force $ConfigDir | Out-Null
  [IO.File]::WriteAllText($BrandingFile, ($clean | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
  $BrandingCache.stamp = $null   # read again on the next access
}

# ---------------------------------------------------------------------------
# DISAG JSON Live: live data from the shooting ranges
# The OpticScore server (OSS) publishes every event as JSON once JSON Live is switched on (OSS: Extras >
# Optionen > JSON Live). Two ways to get them, chosen in the settings (gate.source):
#   udp   Listen for the UDP broadcast. Reaches everyone on the network, so only data from the chosen server
#         is used. No history: only events sent while this program is running are known.
#   file  Follow the log file ("Ausgabe in Logfile aktivieren"), chosen directly in the settings. Needs access to
#         it, but at the start today's events are read back, so it also knows what happened before this program
#         was started.
# Both only receive and never send anything to the OSS, so they cannot disturb the shooting system.
# (An earlier version logged in like the DISAG BeamerView on TCP port 7934; that crashed the OSS in the club
# house and was removed.)
# Specification: DISAG-JSON-Liveschnittstelle_Extended.pdf (dokumentation.disag.de). Objects used:
#   Shot        Range, Shooter {Firstname, Lastname, Team {Name}, Club {Name}}, Count (shot number),
#               IsWarmup (Probe), IsHot (Wertung), MenuItem {MenuID, MenuPointName, MenuItemName}, ShotDateTime, X, Y
#   Result      Shooter, ShotCount (number of shots of the match, sent when it is finished)
#   Competition Shooter, MenuItem (a match is prepared on a range)
# Events only carry the values that changed, so missing fields keep their last value.
# Every message received is copied to gate-log\gate-YYYY-MM-DD.log to check the parsing against real data.
# ---------------------------------------------------------------------------
$GateLogDir = Join-Path $ConfigDir 'gate-log'

# Live data settings with their defaults: data source (udp or file), server (IP or DNS name) and UDP port, the
# log file, number of ranges, on/off. The rangeLog* values belong to the range logs of OpticScore (see below):
# read them or not, their folder ('' = next to the DISAG database), the log level before the button switched
# it to INFO (restored when switched off), when the button was last used and whether OpticScore already logged
# INFO when it started (to tell whether it still has to be restarted).
$GateDefaults = [ordered]@{
  source = 'udp'; host = 'localhost'; port = 30169; file = 'C:\DISAG\JSON Live\OUT-JSONInterface.log'
  rangeCount = 10; enabled = $false
  rangeLog = $false; rangeLogFolder = ''; rangeLogPrevLevel = ''; rangeLogSetAt = ''; rangeLogOssHadInfo = $false
}
function Get-GateConfig {
  $g = Get-Section 'gate' $GateDefaults
  if ($g.source -ne 'file') { $g.source = 'udp' }
  foreach ($k in 'host', 'file') { if (-not $g[$k]) { $g[$k] = $GateDefaults[$k] } }
  if ($g.port -lt 1 -or $g.port -gt 65535) { $g.port = $GateDefaults.port }
  if ($g.rangeCount -lt 1 -or $g.rangeCount -gt 40) { $g.rangeCount = $GateDefaults.rangeCount }
  return $g
}

# State shared between the web server and the reader threads
$GateState = [hashtable]::Synchronized(@{
  stop = $false; enabled = $false; source = ''; serverName = ''; udpPort = 0; ignoredFrom = $null
  file = ''; rangeCount = 10; configRev = 0
  status = 'off'; connected = $false; error = $null; lastData = $null; rev = 0
  ranges = @{}; shotCounts = @{}
  # Range logs: on/off, folder, restart counter, range -> assignment (published as a whole), last error
  rangeLogOn = $false; rangeLogFolder = ''; rangeLogRev = 0; rangeAssign = @{}; rangeLogError = $null
})

# Splits text into complete JSON objects (C#, fast enough for the 5 MB backlog of the log file; one datagram
# may also hold several). Text before an object (e.g. a time stamp of the log line) is returned with it; an
# unfinished object at the end is handed back as "rest" (the log file completes it with the next read).
$JsonSplitCode = @'
using System;
using System.Collections.Generic;
using System.Text;

public static class RwkJsonSplit {
  public static List<string[]> Split(string text, out string rest) {
    var list = new List<string[]>();
    int depth = 0, start = -1, prefixStart = 0;
    bool inString = false, escape = false;
    for (int i = 0; i < text.Length; i++) {
      char c = text[i];
      if (inString) {
        if (escape) escape = false;
        else if (c == '\\') escape = true;
        else if (c == '"') inString = false;
        continue;
      }
      if (c == '"') { if (depth > 0) inString = true; }
      else if (c == '{') { if (depth == 0) start = i; depth++; }
      else if (c == '}' && depth > 0) {
        depth--;
        if (depth == 0) {
          list.Add(new string[] { text.Substring(prefixStart, start - prefixStart), text.Substring(start, i - start + 1) });
          prefixStart = i + 1;
        }
      }
    }
    rest = depth > 0 ? text.Substring(start) : "";
    return list;
  }
}
'@

# Shared by both reader threads (they run in runspaces of their own, so the functions are defined there):
# the gate log and reading a growing file from a known position like "tail -f"
$WorkerCommon = {
  $enc = New-Object Text.UTF8Encoding $false
  $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
  $win1252 = [Text.Encoding]::GetEncoding(1252)
  function Write-GateLog([string]$text) {
    try {
      $file = Join-Path $LogDir ('gate-{0:yyyy-MM-dd}.log' -f (Get-Date))
      [IO.File]::AppendAllText($file, ('[{0:HH:mm:ss.fff}] {1}' -f (Get-Date), $text) + "`r`n", $enc)
    } catch { }
  }
  # Bytes of a file from position $pos (at most 8 MB), opened without locking so the writer can go on
  function Read-FileTail([string]$path, [long]$pos, [long]$length) {
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
      [void]$fs.Seek($pos, [IO.SeekOrigin]::Begin)
      $bytes = New-Object byte[] ([int][Math]::Min(8MB, $length - $pos))
      $n = $fs.Read($bytes, 0, $bytes.Length)
      if ($n -lt $bytes.Length) { [Array]::Resize([ref]$bytes, $n) }
      return ,$bytes
    } finally { $fs.Close() }
  }
  # Text of bytes whose encoding is not known: UTF-8 if valid, otherwise Windows-1252
  function Get-Text([byte[]]$bytes) {
    try { $decoded = $strictUtf8.GetString($bytes) } catch { $decoded = $win1252.GetString($bytes) }
    return $decoded.TrimStart([char]0xFEFF)
  }
}

# Worker thread: takes the JSON Live events from the chosen source and keeps what the idle screen shows up to
# date. UDP: listens on the port. Log file: follows it like "tail -f"; at the start the whole file is read once
# but only today's events are kept, so the idle screen shows who is shooting right now.
# JSON objects are PSCustomObjects from ConvertFrom-Json: a missing property simply reads as $null.
$GateWorker = {
  param($State, $LogDir, $SplitCode, $Common)
  . ([scriptblock]::Create($Common))
  if (-not ('RwkJsonSplit' -as [type])) { Add-Type -TypeDefinition $SplitCode }
  function Test-True($value) { return "$value" -match '^(true|1)$' }
  function Get-Int($value) { $n = 0; if ([int]::TryParse("$value", [ref]$n)) { return $n }; return 0 }

  # Per range, worker-private: shooter, match, shot counters and the shots already counted
  $rangeData = @{}
  function Get-RangeData([int]$range) {
    if (-not $rangeData[$range]) {
      $rangeData[$range] = @{ first = ''; last = ''; team = ''; menu = ''; total = 0
                              hot = 0; probe = 0; count = 0; sighting = $false
                              seen = New-Object 'System.Collections.Generic.HashSet[string]' }
    }
    return $rangeData[$range]
  }
  function Reset-Shots($d) {
    $d.hot = 0; $d.probe = 0; $d.count = 0; $d.total = 0; $d.sighting = $false; $d.seen.Clear()
  }
  # A different shooter on a range starts the counting from zero
  function Set-Shooter($d, $shooter) {
    $first = [string]$shooter.Firstname
    $last = [string]$shooter.Lastname
    if (-not $first -and -not $last) { return }
    if (($d.first -or $d.last) -and ($d.first -ne $first -or $d.last -ne $last)) { Reset-Shots $d; $d.menu = '' }
    $d.first = $first; $d.last = $last
    if ($shooter.Team.Name) { $d.team = [string]$shooter.Team.Name }
  }
  # Match (menu entry), e.g. "Rundenwettkampf 40 Schuss": the number of shots if the name contains it
  function Set-Menu($d, $menu) {
    $name = [string]$(if ($menu.MenuItemName) { $menu.MenuItemName } else { $menu.MenuPointName })
    if (-not $name) { return }
    $d.menu = $name
    if ($name -match '(\d{1,3})\s*(Schuss|Sch\u00fcsse|Sch\b)') { $d.total = [int]$Matches[1] }
  }

  # Kind of object: from the message verb/type if given, otherwise from its fields
  function Get-Kind($msg, $obj) {
    foreach ($k in 'MessageType', 'MessageVerb', 'CommandType', 'Type') {
      if ("$($msg.$k)" -match '^(Shot|Series|Result|Competition)$') { return $Matches[1] }
    }
    if ($null -ne $obj.IsHot -or $null -ne $obj.IsWarmup -or ($null -ne $obj.DecValue -and $null -ne $obj.X)) { return 'Shot' }
    if ($null -ne $obj.SeriesLength) { return 'Series' }
    if ($null -ne $obj.ShotCount) { return 'Result' }
    if ($null -ne $obj.ResultID -or ($null -ne $obj.MenuItem -and $null -ne $obj.Shooter)) { return 'Competition' }
    return ''
  }

  # Applies one JSON message. Returns $true if something changed.
  function Read-JsonMessage($msg) {
    $objects = if ($null -ne $msg.Objects) { @($msg.Objects) } else { @($msg) }
    $changed = $false
    foreach ($obj in $objects) {
      # An object may also be wrapped, e.g. {"Shot": {...}}
      $props = @($obj.PSObject.Properties)
      if ($props.Count -eq 1 -and $props[0].Value -is [psobject] -and $props[0].Name -match '^(Shot|Series|Result|Competition)$') {
        $kind = $props[0].Name; $obj = $props[0].Value
      } else { $kind = Get-Kind $msg $obj }
      if (-not $kind) { continue }
      $range = Get-Int $(if ($null -ne $obj.Range) { $obj.Range } else { @($msg.Ranges)[0] })
      if ($range -le 0) { continue }
      $d = Get-RangeData $range
      Set-Shooter $d $obj.Shooter
      Set-Menu $d $obj.MenuItem
      switch ($kind) {
        'Shot' {
          if (-not $d.seen.Add("$($obj.ShotDateTime)|$($obj.X)|$($obj.Y)|$($obj.Count)")) { break }
          if (Test-True $obj.IsWarmup) {
            $d.probe++; $d.sighting = $true
          } elseif (-not (Test-True $obj.IsDummy)) {   # dummy = generated shot (e.g. after a correction), not counted
            $d.hot++; $d.sighting = $false
            $d.count = [Math]::Max($d.count, (Get-Int $obj.Count))
          }
        }
        'Result' { $n = Get-Int $obj.ShotCount; if ($n -gt 0) { $d.total = $n } }
        'Competition' { Reset-Shots $d; Set-Menu $d $obj.MenuItem }   # new match prepared: counting starts again
      }
      $changed = $true
    }
    return $changed
  }

  # Applies every JSON object in a text (several per datagram or file chunk); $rest gets an unfinished object at
  # the end. $onlyDate (yyyy-MM-dd) = skip events of other days when the log file is read back: the date comes
  # from the shot time or the time stamp in front of the object, events without one (e.g. Competition) belong to
  # the date seen last. $log = copy each object to the gate log. Returns $true if something changed.
  function Read-JsonText([string]$text, [ref]$rest, [string]$onlyDate, [bool]$log) {
    $changed = $false
    $streamDate = $onlyDate
    foreach ($part in [RwkJsonSplit]::Split($text, $rest)) {
      if ($onlyDate) {
        $dm = [regex]::Match($part[0] + ' ' + $part[1], '\d{4}-\d{2}-\d{2}')
        if ($dm.Success) { $streamDate = $dm.Value }
        if ($streamDate -ne $onlyDate) { continue }
      }
      if ($log) { Write-GateLog $part[1] }
      try { $msg = $part[1] | ConvertFrom-Json } catch { Write-GateLog "JSON-Fehler: $($_.Exception.Message)"; continue }
      if (Read-JsonMessage $msg) { $changed = $true }
    }
    return $changed
  }

  # Hands the per-range data to the pages (always replaced as a whole, never half-updated)
  function Publish-Ranges {
    $ranges = @{}; $counts = @{}
    foreach ($r in @($rangeData.Keys)) {
      $d = $rangeData[$r]
      if ($d.first -or $d.last) {
        $ranges[$r] = [ordered]@{ firstname = $d.first; lastname = $d.last; shooterNr = ''; team = $d.team; competition = $d.menu }
      }
      $counts[$r] = @{ hot = $d.hot; probe = $d.probe; sighting = $d.sighting; progShot = $d.count; progTotal = $d.total }
    }
    $State.ranges = $ranges
    $State.shotCounts = $counts
    $State.rev++
  }

  # Senders we accept data from. "localhost" means the OSS runs on this PC: its broadcasts then arrive with
  # the address of a network card as sender instead of 127.0.0.1, so every address of this PC counts.
  function Get-AllowedSenders([string]$serverName) {
    $senders = New-Object 'System.Collections.Generic.HashSet[string]'
    $isLocal = $serverName -ieq 'localhost'
    if (-not $isLocal) {
      try { $resolved = [Net.Dns]::GetHostAddresses($serverName) }
      catch { throw "Server $serverName wurde nicht gefunden (Name oder IP-Adresse pruefen)" }
      foreach ($address in $resolved) {
        [void]$senders.Add($address.ToString())
        if ([Net.IPAddress]::IsLoopback($address)) { $isLocal = $true }
      }
    }
    if ($isLocal) {
      [void]$senders.Add('127.0.0.1')
      foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        foreach ($unicast in $nic.GetIPProperties().UnicastAddresses) { [void]$senders.Add($unicast.Address.ToString()) }
      }
    }
    return ,$senders
  }

  $udp = $null; $senders = $null; $sendersAt = [datetime]::MinValue
  $path = $null; $pos = 0L; $carry = ''; $decoder = $null; $backlog = $true
  $configRev = -1
  while (-not $State.stop) {
    if ($State.configRev -ne $configRev) {
      # Data source, server, port, log file or on/off changed: start over
      $configRev = $State.configRev
      if ($udp) { $udp.Close(); $udp = $null }
      $senders = $null
      $path = $null; $pos = 0L; $carry = ''; $backlog = $true
      $State.lastData = $null; $State.ignoredFrom = $null
      $rangeData.Clear(); Publish-Ranges
    }
    if (-not $State.enabled) {
      $State.status = 'off'; $State.connected = $false
      Start-Sleep -Milliseconds 300
      continue
    }
    try {
      if ($State.source -eq 'file') {
        # The log file chosen in the settings
        $file = $State.file
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Logdatei nicht gefunden: $file. Ist JSON Live mit Logfile im OpticScore-Server eingeschaltet?" }
        $info = Get-Item -LiteralPath $file
        if ($path -ne $file -or $info.Length -lt $pos) {
          # First read, other file, or the OSS started a new file (it rotates at 5 MB)
          if ($path -eq $file) { Write-GateLog 'Neue Logdatei erkannt (Rotation), lese von vorn' }
          $path = $file; $pos = 0L; $carry = ''
          $decoder = $enc.GetDecoder()   # a UTF-8 character split between two reads is completed by the next one
        }
        if ($info.Length -gt $pos) {
          $bytes = Read-FileTail $file $pos $info.Length
          $pos += $bytes.Length
          $chars = New-Object char[] ($decoder.GetCharCount($bytes, 0, $bytes.Length))
          $count = $decoder.GetChars($bytes, 0, $bytes.Length, $chars, 0)
          $text = $carry + (New-Object string ($chars, 0, $count)).TrimStart([char]0xFEFF)
          $rest = ''
          # Reading back (backlog): only today's events, nothing copied to the gate log
          $today = '{0:yyyy-MM-dd}' -f (Get-Date)
          $changed = Read-JsonText $text ([ref]$rest) $(if ($backlog) { $today } else { '' }) (-not $backlog)
          $carry = if ($rest.Length -gt 2MB) { '' } else { $rest }
          if ($backlog) {
            $backlog = $false
            Write-GateLog "Logdatei gelesen: $file, heutige Staende: $(@($rangeData.Keys | Sort-Object) -join ', ')"
            $changed = $true
          }
          if ($changed) { Publish-Ranges }
          if ($bytes.Length -gt 0) { $State.lastData = $info.LastWriteTime }
        } elseif ($backlog) {
          $backlog = $false
        }
        if (-not $State.connected) { Write-GateLog "JSON Live: lese $file" }
        $State.connected = $true; $State.status = 'connected'; $State.error = $null
        if ($null -eq $State.lastData) { $State.lastData = $info.LastWriteTime }
        Start-Sleep -Milliseconds 300
      } else {
        # Addresses can change (DHCP, DNS), so look them up again every minute; a short failure keeps the known ones
        if ($null -eq $senders -or ((Get-Date) - $sendersAt).TotalSeconds -ge 60) {
          try { $senders = Get-AllowedSenders $State.serverName } catch { if ($null -eq $senders) { throw } }
          $sendersAt = Get-Date
        }
        if (-not $udp) {
          $udp = New-Object Net.Sockets.UdpClient
          # Shared port: other listeners on this PC (e.g. another display tool) keep working
          $udp.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
          $udp.EnableBroadcast = $true
          $udp.Client.ReceiveBufferSize = 1MB
          try { $udp.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, [int]$State.udpPort))) }
          catch { throw "UDP-Port $($State.udpPort) kann nicht geoeffnet werden: $($_.Exception.InnerException.Message)" }
          Write-GateLog "JSON Live: lausche auf UDP-Port $($State.udpPort), Server $($State.serverName) ($(@($senders) -join ', '))"
        }
        $State.connected = $true; $State.status = 'connected'; $State.error = $null
        # Waits at most 300 ms so that stop and changed settings are noticed
        if (-not $udp.Client.Poll(300000, [Net.Sockets.SelectMode]::SelectRead)) { continue }
        $remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $bytes = $udp.Receive([ref]$remote)
        $source = $remote.Address.ToString()
        if (-not $senders.Contains($source)) {
          if ($State.ignoredFrom -ne $source) {
            Write-GateLog "Daten von $source ignoriert, eingestellt ist Server $($State.serverName)"
            $State.ignoredFrom = $source
          }
          continue
        }
        # The specification does not name the encoding: UTF-8 if valid, otherwise Windows-1252
        $text = Get-Text $bytes
        Write-GateLog "$source $text"
        $rest = ''
        if (Read-JsonText $text ([ref]$rest) '' $false) { Publish-Ranges }
        if ($rest) { Write-GateLog 'Unvollstaendiges JSON im Datagramm' }
        $State.lastData = Get-Date
      }
    } catch {
      if ($State.error -ne $_.Exception.Message) { Write-GateLog "FEHLER: $($_.Exception.Message)" }
      $State.connected = $false; $State.status = 'waiting'; $State.error = $_.Exception.Message
      if ($udp) { $udp.Close(); $udp = $null }
      # Reading the file again starts with the backlog, so events of earlier days stay out
      $path = $null; $backlog = $true
      for ($i = 0; $i -lt 20 -and -not $State.stop -and $State.configRev -eq $configRev; $i++) { Start-Sleep -Milliseconds 100 }
    }
  }
  if ($udp) { $udp.Close() }
  $State.status = 'off'
}

# Copies the stored settings into the shared state. Only a change that matters for the active data source
# restarts the worker: UDP has no history, so saving unrelated settings must not lose who is shooting right now.
# Folder of the range logs: the one chosen in the settings, otherwise the data folder of OpticScore next to the
# database (<folder of dboss.mdb>\RangesLog, usually C:\Disag\Daten\RangesLog)
function Get-RangeLogDefaultFolder { return Join-Path (Split-Path -Parent (Get-LeagueConfig).file) 'RangesLog' }
function Get-RangeLogFolder($g) {
  if ($g.rangeLogFolder) { return $g.rangeLogFolder }
  return Get-RangeLogDefaultFolder
}

function Update-GateState {
  $g = Get-GateConfig
  $restart = $GateState.source -ne $g.source -or $GateState.enabled -ne $g.enabled -or
    $(if ($g.source -eq 'file') { $GateState.file -ne $g.file } else { $GateState.serverName -ne $g.host -or $GateState.udpPort -ne $g.port })
  $GateState.source = $g.source
  $GateState.serverName = $g.host
  $GateState.udpPort = $g.port
  $GateState.file = $g.file
  $GateState.rangeCount = $g.rangeCount
  $GateState.enabled = $g.enabled
  if ($restart) {
    $GateState.error = $null
    $GateState.configRev++
  }
  $folder = Get-RangeLogFolder $g
  if ($GateState.rangeLogOn -ne $g.rangeLog -or $GateState.rangeLogFolder -ne $folder) {
    $GateState.rangeLogOn = $g.rangeLog
    $GateState.rangeLogFolder = $folder
    $GateState.rangeLogRev++
  }
}

# ---------------------------------------------------------------------------
# Range logs of OpticScore: who is assigned to a range, the moment it happens
# JSON Live only knows a shooter from the first shot, but shooters are often assigned to a range 10 minutes
# before they start. OpticScore can log every message it exchanges with each range in
# <data folder>\RangesLog\Range<n>.log ("2026-11-14 12:41:24,303 - OUT 10: <message ...>"), but only with the
# log level INFO, set in the registry: HKCU\SOFTWARE\DisagOSS, value oss_loglevel (read by OpticScore at start,
# default ERROR; there is no switch for it in OpticScore). Seen on the club PC on 2026-11-14:
#   OUT <n>: <message type="rangelink" shootersid="6">2, Mustermann Max</message>   shooter assigned (startnumber,
#                                                                                 last name first name)
#   OUT <n>: <message type="rangelink" shootersid="0"></message>  (or shootersid=" ")  assignment lifted
#   IN: <status ... shooterSID="12" shooterName="1, test test" ... isCompetitionFinished="True" ... />
# shootersid is not the id of the league database, so only the name is used. The files are Windows-1252.
# The tool only reads these files (shared, no lock) and never sends anything to OpticScore.
# ---------------------------------------------------------------------------
$OssRegistryKey = 'HKCU:\SOFTWARE\DisagOSS'
$OssLogLevelsWithInfo = 'INFO', 'DEBUG', 'ALL'

# Log level of OpticScore for this Windows user; $null if OpticScore was never started under this user
function Get-OssLogLevel {
  try { return [string](Get-ItemProperty -LiteralPath $OssRegistryKey -Name oss_loglevel -ErrorAction Stop).oss_loglevel }
  catch { return $null }
}

# Start time of the running OpticScore server, $null if it does not run on this PC
function Get-OssStartTime {
  $p = Get-Process -Name OpticScoreServer -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p) { try { return $p.StartTime } catch { } }
  return $null
}

# Registry state of the range logs for the pages: found (OpticScore known under this Windows user), level, on
# (logs INFO), whether OpticScore runs here and still has to be restarted (the button changed the level while it
# runs, and the level differs from the one it started with). Registry and process list are looked at most
# every 5 seconds (the pages ask every 1 to 2 seconds); the button resets the cache.
$OssInfoCache = @{ at = [datetime]::MinValue; info = $null }
function Get-OssLogInfo {
  if (((Get-Date) - $OssInfoCache.at).TotalSeconds -ge 5) {
    $g = Get-GateConfig
    $level = Get-OssLogLevel
    $started = Get-OssStartTime
    $setAt = [datetime]::MinValue
    if ($g.rangeLogSetAt) { [void][datetime]::TryParse($g.rangeLogSetAt, [ref]$setAt) }
    $on = $OssLogLevelsWithInfo -contains "$level".ToUpper()
    $OssInfoCache.info = [ordered]@{
      found = ($null -ne $level -or (Test-Path -LiteralPath $OssRegistryKey)); level = $level; on = $on
      ossRunning = [bool]$started; needsRestart = [bool]($started -and $setAt -gt $started -and $on -ne $g.rangeLogOssHadInfo)
    }
    $OssInfoCache.at = Get-Date
  }
  return [ordered]@{} + $OssInfoCache.info
}

# Switches the range logs of OpticScore on or off in the registry (button in the settings, applies at once).
# On: remember the old level, set INFO (unless it already logs INFO). Off: back to the remembered level (ERROR if
# none is known). Either way OpticScore only picks the change up when it is started again.
# Returns the new state (Get-OssLogInfo) with an "error" text, '' if all is fine.
function Set-OssRangeLog([bool]$on) {
  $g = Get-GateConfig
  $info = Get-OssLogInfo
  $err = ''
  if (-not $info.found) {
    $err = ("Die Einstellungen von OpticScore wurden unter diesem Windows-Benutzer nicht gefunden. L{0}uft OpticScore auf einem anderen PC oder unter einem anderen Benutzer, dort die Datei `"Stand-Protokoll einschalten.reg`" doppelt anklicken." -f [char]0xE4)
  } elseif ($on -ne $info.on) {
    try {
      # First click since OpticScore was started: remember what the running OpticScore uses
      $setAt = [datetime]::MinValue
      if ($g.rangeLogSetAt) { [void][datetime]::TryParse($g.rangeLogSetAt, [ref]$setAt) }
      $started = Get-OssStartTime
      if (-not $started -or $setAt -lt $started) { $g.rangeLogOssHadInfo = $info.on }
      if ($on) {
        $g.rangeLogPrevLevel = if ($info.level) { $info.level } else { 'ERROR' }
        $new = 'INFO'
      } else {
        $new = if ($g.rangeLogPrevLevel) { $g.rangeLogPrevLevel } else { 'ERROR' }
        $g.rangeLogPrevLevel = ''
      }
      Set-ItemProperty -LiteralPath $OssRegistryKey -Name oss_loglevel -Value $new -Type String
      $g.rangeLogSetAt = (Get-Date).ToString('o')
      Set-ConfigValue 'gate' $g
    } catch { $err = "OpticScore-Einstellung konnte nicht ge$([char]0xE4)ndert werden: $($_.Exception.Message)" }
  }
  $OssInfoCache.at = [datetime]::MinValue
  $info = Get-OssLogInfo
  $info.error = $err
  return $info
}

# Worker thread: follows Range<n>.log of every range like "tail -f" (only today's lines) and publishes
# range -> @{ assigned; first; last; finished } whenever something changed
$RangeLogWorker = {
  param($State, $LogDir, $Common)
  . ([scriptblock]::Create($Common))
  # "2, Mustermann Max" -> first Max, last Mustermann (startnumber dropped; OpticScore writes the last name first)
  function Split-Name([string]$raw) {
    $name = ([Net.WebUtility]::HtmlDecode($raw) -replace '^\s*\d+\s*,\s*', '').Trim()
    $words = @($name -split '\s+' | Where-Object { $_ })
    if ($words.Count -ge 2) { return @{ first = ($words[1..($words.Count - 1)] -join ' '); last = $words[0] } }
    return @{ first = ''; last = $name }
  }
  # Sets the assignment of range $r; returns $true if it differs from the one before
  function Set-Assign([int]$r, [bool]$assigned, [string]$raw, [bool]$finished) {
    $nm = if ($assigned) { Split-Name $raw } else { @{ first = ''; last = '' } }
    $a = $assign[$r]
    if ($a -and $a.assigned -eq $assigned -and $a.first -eq $nm.first -and $a.last -eq $nm.last -and $a.finished -eq $finished) { return $false }
    $assign[$r] = @{ assigned = $assigned; first = $nm.first; last = $nm.last; finished = $finished }
    if ($assigned) { Write-GateLog "Stand-Protokoll Stand ${r}: $(if ($finished) { 'fertig' } else { 'zugewiesen' }) $raw" }
    elseif ($a -and $a.assigned) { Write-GateLog "Stand-Protokoll Stand ${r}: Zuweisung aufgehoben" }
    return $true
  }
  $files = @{}; $assign = @{}; $rev = -1
  while (-not $State.stop) {
    if ($State.rangeLogRev -ne $rev) {
      # Switched on or off, or another folder: start over (today's lines are read again)
      $rev = $State.rangeLogRev; $files = @{}; $assign = @{}
      $State.rangeAssign = @{}; $State.rangeLogError = $null
    }
    if (-not ($State.enabled -and $State.rangeLogOn)) { Start-Sleep -Milliseconds 300; continue }
    try {
      $folder = $State.rangeLogFolder
      if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Ordner nicht gefunden: $folder" }
      $today = '{0:yyyy-MM-dd}' -f (Get-Date)
      $changed = $false
      foreach ($r in 1..([Math]::Max(1, [int]$State.rangeCount))) {
        $path = Join-Path $folder "Range$r.log"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $length = (Get-Item -LiteralPath $path).Length
        $f = $files[$r]
        # First read, or OpticScore started a new file (it rolls over at 5 MB): read from the start
        if (-not $f -or $length -lt $f.pos) { $f = @{ pos = 0L; carry = '' }; $files[$r] = $f }
        if ($length -le $f.pos) { continue }
        $bytes = Read-FileTail $path $f.pos $length
        $f.pos += $bytes.Length
        $lines = ($f.carry + (Get-Text $bytes)) -split "`r?`n"
        $f.carry = $lines[-1]   # an unfinished last line is completed by the next read
        foreach ($line in $lines[0..($lines.Count - 2)]) {
          if (-not $line.StartsWith($today)) { continue }
          if ($line -match '<message type="rangelink" shootersid="([^"]*)">([^<]*)</message>') {
            # Assigned in OpticScore (or the assignment lifted: shootersid 0 or empty)
            $sid = $Matches[1].Trim(); $raw = $Matches[2].Trim()
            $on = [bool]($sid -and $sid -ne '0' -and $raw)
            if (Set-Assign $r $on $raw $false) { $changed = $true }
          } elseif ($line -match '<status [^>]*shooterSID="([^"]*)"[^>]*shooterName="([^"]*)"') {
            # The range reports its state: also covers a login at the tablet and the end of the match
            $sid = $Matches[1].Trim(); $raw = $Matches[2].Trim()
            $on = [bool]($sid -and $sid -ne '0' -and $raw)
            if (($on -or ($assign[$r] -and $assign[$r].assigned)) -and (Set-Assign $r $on $raw ($line -match 'isCompetitionFinished="True"'))) { $changed = $true }
          }
        }
      }
      if ($changed) {
        $copy = @{}; foreach ($k in $assign.Keys) { $copy[$k] = $assign[$k].Clone() }
        $State.rangeAssign = $copy
        $State.rev++
      }
      if ($State.rangeLogError) { Write-GateLog 'Stand-Protokoll wird wieder gelesen' }
      $State.rangeLogError = $null
    } catch {
      if ($State.rangeLogError -ne $_.Exception.Message) { Write-GateLog "Stand-Protokoll FEHLER: $($_.Exception.Message)" }
      $State.rangeLogError = $_.Exception.Message
    }
    Start-Sleep -Milliseconds 500
  }
}

function Start-GateWorker {
  New-Item -ItemType Directory -Force $GateLogDir | Out-Null
  # Keep the logs of the last 30 days
  Get-ChildItem -LiteralPath $GateLogDir -Filter 'gate-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue
  Update-GateState
  $common = $WorkerCommon.ToString()
  $script:Workers = foreach ($w in @(@($GateWorker, $GateState, $GateLogDir, $JsonSplitCode, $common), @($RangeLogWorker, $GateState, $GateLogDir, $common))) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($w[0])
    foreach ($a in $w[1..($w.Count - 1)]) { [void]$ps.AddArgument($a) }
    [void]$ps.BeginInvoke()
    $ps
  }
}

# Same person? "Max Mustermann" from JSON Live and "Mustermann Max" from the range log are equal
function Get-NameKey([string]$first, [string]$last) {
  return ((("$first $last").ToLower() -split '\s+' | Where-Object { $_ } | Sort-Object) -join ' ')
}

# Live status and one entry per range (lastname empty = range free) for the pages
function Get-GateInfo {
  $ranges = $GateState.ranges
  $counts = $GateState.shotCounts
  $assign = if ($GateState.rangeLogOn) { $GateState.rangeAssign } else { @{} }
  $list = foreach ($r in 1..([Math]::Max(1, $GateState.rangeCount))) {
    $p = $ranges[$r]
    $c = $counts[$r]
    $finished = $false
    # With the range logs, the assignment in OpticScore decides who is on a range (from the moment of the
    # assignment, before the first shot). The shots from JSON Live only count if they are from that shooter.
    # A range without any range log line today keeps the names from JSON Live.
    $a = $assign[$r]
    if ($a) {
      if (-not $a.assigned) { $p = $null; $c = $null }
      else {
        $same = $p -and (Get-NameKey $p.firstname $p.lastname) -eq (Get-NameKey $a.first $a.last)
        if (-not $same) { $c = $null }
        $p = @{ firstname = $a.first; lastname = $a.last; shooterNr = ''; team = $(if ($same) { $p.team } else { '' }) }
        $finished = [bool]$a.finished
      }
    }
    # Number of shots only from DISAG data: the match name ("... 40 Schuss") or the final result.
    # Unknown = 0, the TV then shows the shot count without a total.
    $total = if ($c) { [int]$c.progTotal } else { 0 }
    # Shots done: the shot number from DISAG if it is ahead of our own count (e.g. started mid-match)
    $shots = if ($c) { [Math]::Max([int]$c.hot, [int]$c.progShot) } else { 0 }
    [ordered]@{
      range = $r
      firstname = if ($p) { $p.firstname } else { '' }
      lastname = if ($p) { $p.lastname } else { '' }
      shooterNr = if ($p) { $p.shooterNr } else { '' }
      team = if ($p) { $p.team } else { '' }
      shots = $shots
      probeShots = if ($c) { $c.probe } else { 0 }
      sighting = if ($c) { [bool]$c.sighting } else { $false }
      shotsTotal = $total
      finished = $finished
    }
  }
  $age = if ($GateState.lastData) { [int]((Get-Date) - $GateState.lastData).TotalSeconds } else { -1 }
  # Range logs: on/off, the last read error and the registry state of OpticScore (oss); for the settings dialog
  # also the chosen folder ('' = automatic) and the automatic one
  $rangeLog = if ($GateState.rangeLogOn) { @{ on = $true; error = $GateState.rangeLogError; oss = (Get-OssLogInfo) } } else { @{ on = $false } }
  return [ordered]@{
    enabled = $GateState.enabled; source = $GateState.source
    host = $GateState.serverName; port = $GateState.udpPort; ignoredFrom = $GateState.ignoredFrom
    file = $GateState.file; rangeCount = $GateState.rangeCount
    status = $GateState.status; connected = $GateState.connected; error = $GateState.error
    rangeLog = $rangeLog
    rangeLogFolder = (Get-GateConfig).rangeLogFolder; rangeLogDefault = (Get-RangeLogDefaultFolder)
    lastDataAge = $age; rev = $GateState.rev; ranges = @($list)
  }
}

# ---------------------------------------------------------------------------
# DISAG database: the only source of the competitions
# OpticScore keeps league matches (Rundenwettkaempfe) in its Access database dboss.mdb (usually
# C:\Disag\Daten), table Leaguecompetitions_Competitions: name ("Team A - Team B"), date (with time),
# team1/team2 (often empty), fidDisciplines -> Disciplines (name, shots_competition), teams in Teams.
# The database is only read at program start, when "Neu einlesen" is clicked or the settings are saved,
# never on a timer. The original is never opened with a database driver: it is copied (share mode, only if
# it changed, so OpticScore is not disturbed) and the copy is read. From it come all matches with shots,
# translated into the export XML format for the replay, and today's matches for the TV idle screen.
# Stored results are never read, the scores are only added up during the replay.
# ---------------------------------------------------------------------------
$LeagueDefaultFile = 'C:\Disag\Daten\dboss.mdb'
# raw = tables of the last reading, teams/disc = lookups by id, all = every match with shots as export XML
$LeagueCache = @{ at = [datetime]::MinValue; stamp = ''; raw = $null; teams = @{}; disc = @{}; all = ''; count = 0; error = $null }

# Settings: the database file and whether the TV idle screen lists today's matches (on by default)
function Get-LeagueConfig {
  $l = Get-Section 'league' @{ showToday = $true; file = $LeagueDefaultFile }
  if (-not $l.file) { $l.file = $LeagueDefaultFile }
  return $l
}

# Reads matches, teams, disciplines, shooters and shots from an Access file and returns one object with a
# list of rows per table. Runs in this process, or, if no 64-bit Access driver is installed, as script text
# in a 32-bit PowerShell with the Jet driver built into Windows (which hands the result back as JSON).
# Rows are collected in a List: adding to a PowerShell array copies it every time, which gets slow with the
# tens of thousands of shots of a whole season.
$LeagueQuery = {
  param([string]$file, [string[]]$providers)
  $last = ''
  foreach ($prov in $providers) {
    try {
      # OLE DB Services=-4: no connection pooling, otherwise the driver keeps the copy open after Close()
      $cn = New-Object System.Data.OleDb.OleDbConnection("Provider=$prov;Data Source=$file;Mode=Read;OLE DB Services=-4;")
      $cn.Open()
      try {
        $out = [ordered]@{}
        $queries = [ordered]@{
          comps = 'SELECT idLeaguecompetitions_Competitions AS id, name, team1, team2, [date], fidDisciplines FROM Leaguecompetitions_Competitions'
          teams = 'SELECT idTeams, teamsname FROM Teams'
          disc = 'SELECT idDisciplines, name, shots_competition FROM Disciplines'
          # All names in brackets: "comp" and "position" are reserved words in Access SQL
          shooters = 'SELECT ls.[idLeaguecompetitions_Shooters] AS [id], ls.[fidLeaguecompetitions_Competitions] AS [comp], ls.[team], ls.[position], ls.[assessed], s.[firstname], s.[lastname] FROM [Leaguecompetitions_Shooters] AS ls LEFT JOIN [Shooters] AS s ON ls.[fidShooters] = s.[idShooters]'
          # Discipline per shooter (for the expected number of shots); separate, so an OpticScore without this
          # column only loses the check, not the shooters
          shooterDisc = 'SELECT [idLeaguecompetitions_Shooters] AS [id], [fidDisciplines] AS [disc] FROM [Leaguecompetitions_Shooters]'
          shots = 'SELECT fidLeaguecompetitions_Shooters AS shooter, shotdata FROM Leaguecompetitions_ShootersShots ORDER BY idLeaguecompetitions_ShootersShots'
        }
        foreach ($k in $queries.Keys) {
          $rows = New-Object 'System.Collections.Generic.List[object]'
          try {
            $cmd = $cn.CreateCommand(); $cmd.CommandText = $queries[$k]
            $r = $cmd.ExecuteReader()
            $names = @(for ($i = 0; $i -lt $r.FieldCount; $i++) { $r.GetName($i) })
            while ($r.Read()) {
              $o = [ordered]@{}
              for ($i = 0; $i -lt $names.Count; $i++) {
                $v = $r.GetValue($i)
                if ($v -is [DBNull]) { $v = $null } elseif ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-dd HH:mm') }
                $o[$names[$i]] = $v
              }
              $rows.Add([pscustomobject]$o)
            }
            $r.Close()
          } catch { if ($k -eq 'comps') { throw } }
          $out[$k] = $rows.ToArray()
        }
        return [pscustomobject]$out
      } finally { $cn.Close() }
    } catch { $last = $_.Exception.Message }
  }
  throw "Datenbank nicht lesbar: $last"
}

function Read-LeagueDb([string]$file) {
  try {
    return & $LeagueQuery $file @('Microsoft.ACE.OLEDB.16.0', 'Microsoft.ACE.OLEDB.12.0')
  } catch {
    # No 64-bit Access driver: 32-bit PowerShell has the Jet 4.0 driver for .mdb files on every Windows
    $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps32)) { throw }
    $tmp = Join-Path $env:TEMP ('rwk-league-' + [guid]::NewGuid().ToString('N'))
    $script = "`$q = {$LeagueQuery}`r`n" +
      "try { `$json = & `$q '$($file -replace "'", "''")' @('Microsoft.Jet.OLEDB.4.0', 'Microsoft.ACE.OLEDB.12.0', 'Microsoft.ACE.OLEDB.16.0') | ConvertTo-Json -Depth 4 -Compress } catch { `$json = 'ERR:' + `$_.Exception.Message }`r`n" +
      "[IO.File]::WriteAllText('$tmp.out', `$json, [Text.Encoding]::UTF8)"
    [IO.File]::WriteAllText("$tmp.ps1", $script, (New-Object Text.UTF8Encoding $true))
    try {
      $p = Start-NoWindow $ps32 @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$tmp.ps1")
      if (-not $p.WaitForExit(30000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw 'Datenbank: Zeit abgelaufen' }
      $json = if (Test-Path "$tmp.out") { [IO.File]::ReadAllText("$tmp.out", [Text.Encoding]::UTF8) } else { 'ERR:keine Antwort' }
      if ($json.StartsWith('ERR:')) { throw $json.Substring(4) }
      return $json | ConvertFrom-Json
    } finally { Remove-Item "$tmp.ps1", "$tmp.out" -Force -ErrorAction SilentlyContinue }
  }
}

# Reads the database, ONLY at program start, on "Neu einlesen" or when the settings are saved: copy the original
# if it changed (time and size), read the copy, keep everything in $LeagueCache. All other requests are answered
# from that cache and never touch the database.
function Update-LeagueData {
  $cfg = Get-LeagueConfig
  $LeagueCache.error = $null
  try {
    $db = $cfg.file
    if (-not (Test-Path -LiteralPath $db -PathType Leaf)) { throw "Datenbank nicht gefunden: $db" }
    $info = Get-Item -LiteralPath $db
    $stamp = "$db|$($info.LastWriteTimeUtc.Ticks)|$($info.Length)"
    if ($stamp -ne $LeagueCache.stamp -or $null -eq $LeagueCache.raw) {
      # Copy without locking (OpticScore keeps the database open), then read only the copy. Every copy gets its
      # own name, so a copy still held by the Access driver (or another running instance) never blocks a new one.
      New-Item -ItemType Directory -Force $ConfigDir | Out-Null
      Get-ChildItem -LiteralPath $ConfigDir -Filter 'league-copy*.mdb' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
      $copy = Join-Path $ConfigDir ('league-copy-{0}.mdb' -f [DateTime]::Now.Ticks)
      $src = New-Object IO.FileStream($db, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      try {
        $dst = [IO.File]::Create($copy)
        try { $src.CopyTo($dst) } finally { $dst.Close() }
      } finally { $src.Close() }
      $raw = Read-LeagueDb $copy
      $teams = @{}; foreach ($t in @($raw.teams)) { if ($t) { $teams["$($t.idTeams)"] = [string]$t.teamsname } }
      $disc = @{}; foreach ($x in @($raw.disc)) { if ($x) { $disc["$($x.idDisciplines)"] = $x } }
      $xml = Build-LeagueXml $raw $teams $disc (Get-MenuTitles $db)
      $LeagueCache.raw = $raw; $LeagueCache.teams = $teams; $LeagueCache.disc = $disc
      $LeagueCache.all = $xml.text; $LeagueCache.count = $xml.count
      $LeagueCache.stamp = $stamp
    }
  } catch {
    # e.g. a copy taken while OpticScore was writing: the next click takes a fresh copy
    $LeagueCache.error = $_.Exception.Message
    $LeagueCache.stamp = ''
  }
  $LeagueCache.at = Get-Date
}

# Names of the menu points of the shooting menu: "100_6" -> "Luftgewehr: Liga Auflage". The menuid of a shot is
# "<menu point>_<item>" of THIS club's menu, so the numbers differ from club to club (on a test laptop 100_8 is
# "unbegrenzte Schuss", on the club PC 100_6 is the rested match); only the name says what a discipline is.
# OpticScore keeps the menu next to the database: <database folder>\etc\menu_current_de.xml (other languages and
# menu_config_*.xml as fallback). Empty when there is none; app.js then decides from the match name.
function Get-MenuTitles([string]$dbFile) {
  $titles = @{}
  $etc = Join-Path (Split-Path -Parent $dbFile) 'etc'
  $file = @('menu_current_de.xml', 'menu_config_de.xml') | ForEach-Object { Join-Path $etc $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (-not $file) { $file = Get-ChildItem -LiteralPath $etc -Filter 'menu_current_*.xml' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
  if (-not $file) { return $titles }
  try {
    $menu = New-Object Xml.XmlDocument
    $menu.Load($file)
    foreach ($point in $menu.SelectNodes('//menupoint')) {
      foreach ($item in $point.SelectNodes('menuitem')) {
        $titles["$($point.GetAttribute('id'))_$($item.GetAttribute('id'))"] = "$($point.GetAttribute('title')): $($item.GetAttribute('modetitle'))"
      }
    }
  } catch { }
  return $titles
}

# Team names of a match: team1/team2 (text, or an id looked up in Teams), otherwise split from the match name
# "A - B", dropping a discipline word appended to a team ("SV Musterhausenpistole")
function Get-LeagueTeams($c, $teams) {
  $name = { param($v) if ($null -eq $v -or "$v" -eq '') { '' } elseif ($teams["$v"]) { $teams["$v"] } elseif ("$v" -match '^\d+$') { '' } else { "$v" } }
  $t1 = & $name $c.team1; $t2 = & $name $c.team2
  if (-not ($t1 -and $t2) -and "$($c.name)" -match '^\s*(.+?)\s+(?:-|vs\.?|gegen)\s+(.+?)\s*$') {
    $t1, $t2 = @($Matches[1], $Matches[2]) | ForEach-Object { ($_ -replace '\s*(luft)?(pistole|gewehr|auflage)$', '').Trim() }
  }
  return @($t1, $t2)
}

# Every match with shots as a <result> block in the format of the DISAG result exports, all in one text, so
# app.js gets them with one request and reads them with its export parser. Shots keep their original
# <shot .../> element from the database. Shots entered by hand (shotvaluesource="M") only have a dummy position:
# they get nopos="true" (counted, but no hole drawn). Shooters and shots are grouped by match and shooter first,
# so each match only looks at its own rows. Returns @{ text; count }.
# Every shooter gets expectedShots: the number of shots of their discipline in OpticScore (shots_competition,
# discipline of the shooter, otherwise of the match), 0 if unknown. app.js warns on the card when shots are missing.
# Every shooter also gets menu: the name of the menu point of their first scoring shot (see Get-MenuTitles), from
# which app.js tells rested shooting (Auflage, scored in tenths).
function Build-LeagueXml($raw, $teams, $disc, $menus = @{}) {
  $esc = { param($v) [Security.SecurityElement]::Escape([string]$v) }
  $shotsOf = { param($id) $d = $disc["$id"]; if ($d -and $d.shots_competition) { [int]$d.shots_competition } else { 0 } }
  $shooterDisc = @{}; foreach ($x in @($raw.shooterDisc)) { if ($x) { $shooterDisc["$($x.id)"] = $x.disc } }
  $shotsBy = @{}
  foreach ($s in @($raw.shots)) {
    if (-not $s -or -not $s.shotdata) { continue }
    $k = "$($s.shooter)"
    if (-not $shotsBy[$k]) { $shotsBy[$k] = New-Object Collections.ArrayList }
    [void]$shotsBy[$k].Add([string]$s.shotdata)
  }
  $shootersBy = @{}
  foreach ($sh in @($raw.shooters)) {
    if (-not $sh -or -not $shotsBy["$($sh.id)"]) { continue }   # shooters without shots are not shown anyway
    $k = "$($sh.comp)"
    if (-not $shootersBy[$k]) { $shootersBy[$k] = New-Object Collections.ArrayList }
    [void]$shootersBy[$k].Add($sh)
  }
  $sb = New-Object Text.StringBuilder
  $count = 0
  foreach ($c in @($raw.comps)) {
    if (-not $c) { continue }
    $shooters = $shootersBy["$($c.id)"]
    if (-not $shooters) { continue }   # only matches with shots
    # Order of the replay: team, position, then the order the shooters were entered in OpticScore (id).
    # OpticScore usually leaves position at 0, and Sort-Object in Windows PowerShell 5.1 is not stable: without
    # the id, equal positions came out reversed (3, 2, 1 instead of 1, 2, 3; seen on 2026-11-12).
    $shooters = @($shooters | Sort-Object { [int]"0$($_.team)" }, { [int]"0$($_.position)" }, { [long]"0$($_.id)" })
    $names = Get-LeagueTeams $c $teams
    $when = [datetime]::ParseExact("$($c.date)", 'yyyy-MM-dd HH:mm', $null)
    [void]$sb.Append("<result type=`"lc`" source=`"db`" competitionsname=`"$(& $esc $c.name)`" date=`"$($when.ToString('dd.MM.yyyy'))`" printDateTime=`"$($when.ToString('dd.MM.yyyy HH:mm')):00`" showDecimalShots=`"0`" onlyXBestShootersPerTeam=`"-1`">")
    foreach ($ti in 1, 2) {
      [void]$sb.Append("<team id=`"$ti`" name=`"$(& $esc $names[$ti - 1])`">")
      foreach ($sh in $shooters) {
        if ("$($sh.team)" -ne "$ti") { continue }
        $assessed = if ("$($sh.assessed)" -match '^(0|False)$') { '0' } else { '1' }
        $expected = & $shotsOf $shooterDisc["$($sh.id)"]
        if (-not $expected) { $expected = & $shotsOf $c.fidDisciplines }
        $hotShot = $shotsBy["$($sh.id)"] | Where-Object { -not $_.Contains('iswarm="true"') } | Select-Object -First 1
        $menuName = if ($hotShot -and $hotShot -match 'menuid="([^"]+)"') { [string]$menus[$Matches[1]] } else { '' }
        [void]$sb.Append("<shooter firstname=`"$(& $esc $sh.firstname)`" lastname=`"$(& $esc $sh.lastname)`" assessed=`"$assessed`" position=`"$($sh.position)`" expectedShots=`"$expected`" menu=`"$(& $esc $menuName)`"><shots>")
        # Series of 10 by the order of the scoring shots; Probe shots go into series 1 (app.js skips them)
        $hot = 0; $series = @{}
        foreach ($x in $shotsBy["$($sh.id)"]) {
          $isWarm = $x.Contains('iswarm="true"')
          # Integer series number (Floor may return decimal or double, which would split one series in two)
          $sid = if ($isWarm) { 1 } else { [int][Math]::Floor($hot / 10) + 1 }
          if (-not $isWarm) { $hot++ }
          if ($x.Contains('shotvaluesource="M"')) { $x = $x -replace '^<shot ', '<shot nopos="true" ' }
          if (-not $series[$sid]) { $series[$sid] = New-Object Text.StringBuilder }
          [void]$series[$sid].Append($x)
        }
        foreach ($sid in ($series.Keys | Sort-Object)) { [void]$sb.Append("<series id=`"$sid`">$($series[$sid])</series>") }
        [void]$sb.Append('</shots></shooter>')
      }
      [void]$sb.Append('</team>')
    }
    [void]$sb.Append('</result>')
    $count++
  }
  return @{ text = $sb.ToString(); count = $count }
}

# Answer for the pages, only from the cache: today's matches (sorted by time, never a result) and how many
# matches with shots the last reading found (they are fetched with GET /api/league/all)
function Get-LeagueInfo {
  $cfg = Get-LeagueConfig
  $result = [ordered]@{ showToday = $cfg.showToday; file = $cfg.file; error = $LeagueCache.error
                        readAt = if ($LeagueCache.at -ne [datetime]::MinValue) { $LeagueCache.at.ToString('HH:mm') } else { $null }
                        matches = @(); count = $LeagueCache.count }
  if ($null -eq $LeagueCache.raw) { return $result }
  $today = Get-Date -Format 'yyyy-MM-dd'
  $result.matches = @(@($LeagueCache.raw.comps) | Where-Object { $_ -and "$($_.date)".StartsWith($today) } | Sort-Object { $_.date } | ForEach-Object {
    $names = Get-LeagueTeams $_ $LeagueCache.teams
    $d = $LeagueCache.disc["$($_.fidDisciplines)"]
    [ordered]@{
      name = [string]$_.name; team1 = $names[0]; team2 = $names[1]
      time = "$($_.date)".Substring(11)
      discipline = if ($d) { [string]$d.name } else { '' }
      shots = if ($d -and $d.shots_competition) { [int]$d.shots_competition } else { 0 }
    }
  })
  return $result
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Base)
try {
  $listener.Start()
} catch {
  # Already running (e.g. started twice): only open the control page
  Write-Host 'Die Auswertung laeuft bereits, oeffne nur die Steuerung.'
  if (-not $NoBrowser) { Open-Control }
  Start-Sleep -Seconds 3
  exit
}

Write-Host "Rundenwettkampf Auswertung v$AppVersion laeuft auf $Base"
Write-Host 'Dieses Fenster offen lassen. Bedienen und Beenden ueber das Symbol im Infobereich (unten rechts) oder in der Steuerung.'
Start-GateWorker
$gateSourceText = if ($GateState.source -eq 'file') { $GateState.file } else { "$($GateState.serverName):$($GateState.udpPort)" }
Write-Host "DISAG JSON Live: $(if ($GateState.enabled) { $gateSourceText } else { 'aus' }), Log in $GateLogDir"
Start-Tray
# Read the DISAG database once at program start; after that only on "Neu einlesen" or "Speichern"
Update-LeagueData
Write-Host "DISAG-Datenbank eingelesen$(if ($LeagueCache.error) { ": $($LeagueCache.error)" })"
# The TV display is not opened automatically (only needed on match evenings): tray menu or control page
if (-not $NoBrowser) { Open-Control }

# ---------------------------------------------------------------------------
# Web server: one handler per "METHOD /path" (see the API list at the top). Every handler gets $req and $res
# and answers with Send-Text/Send-Json; anything not in the table is served as a static file from this folder.
# The handlers run in the script scope (dot-sourced), so they share these variables:
#   $state        last state published by the control page, handed to the TV display as it is
#   $comp         the competition currently shown (JSON text), sent once per competition
#   $lastDisplay  when the TV display last asked for the state; the control page shows whether it is alive
# ---------------------------------------------------------------------------
$state = '{"rev":0,"compKey":null}'
$comp = 'null'
$lastDisplay = [datetime]::MinValue
$quit = $false
function Get-DisplayAge { if ($lastDisplay -eq [datetime]::MinValue) { -1 } else { [int]((Get-Date) - $lastDisplay).TotalMilliseconds } }
# The body of a request as object (JSON), an empty object if there is none
function Read-Json($req) { $text = Read-Body $req; if ($text.Trim()) { $text | ConvertFrom-Json } else { [pscustomobject]@{} } }

$Routes = [ordered]@{
  'GET /api/ping' = { Send-Text $res "{`"ok`":true,`"version`":`"$AppVersion`"}" }
  'GET /api/state' = {
    if ($req.QueryString['display']) { $lastDisplay = Get-Date }
    Send-Text $res $state
  }
  'POST /api/state' = { $state = Read-Body $req; Send-Json $res @{ displayAge = (Get-DisplayAge) } }
  'GET /api/status' = { Send-Json $res @{ displayAge = (Get-DisplayAge) } }
  'GET /api/comp' = { Send-Text $res $comp }
  'POST /api/comp' = { $comp = Read-Body $req; Send-Text $res '{"ok":true}' }
  'GET /api/screens' = { Send-Json $res ([ordered]@{ screens = @(Get-Screens); selected = (Get-Config).screen }) }
  'POST /api/screens/identify' = { Show-ScreenNumbers; Send-Text $res '{"ok":true}' }

  # Branding (see "Branding" above): {"name", "colors": {...}, "logo"}; logo: data URL = new logo, "" = default
  # logo, missing or null = keep the current one
  'GET /api/branding' = { Send-Json $res (Get-Branding) }
  'POST /api/branding' = {
    $in = Read-Json $req
    if ($null -eq $in.logo) {
      $current = Get-BrandingData
      $in | Add-Member -NotePropertyName logo -NotePropertyValue $(if ($current) { $current.logo } else { '' }) -Force
    }
    try { Save-Branding (ConvertTo-CleanBranding $in); Send-Json $res (Get-Branding) }
    catch { Send-Error $res $_.Exception.Message }
  }
  'GET /api/branding/logo' = {
    # Club logo from the branding file, otherwise the default logo of the program
    $logo = Get-LogoData
    if ($logo) { $bytes = $logo.bytes; $res.ContentType = $logo.mime }
    else { $bytes = [IO.File]::ReadAllBytes((Join-Path $Root 'assets\logo.png')); $res.ContentType = 'image/png' }
    $res.Headers['Cache-Control'] = 'no-store'
    # An SVG logo opened directly must not run scripts
    $res.Headers['Content-Security-Policy'] = "default-src 'none'; style-src 'unsafe-inline'"
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
  }
  'GET /api/branding/file' = {
    # The whole branding file for "Branding exportieren"; 404 while the neutral defaults are in use
    $b = Get-BrandingData
    if ($b) { Send-Text $res ($b | ConvertTo-Json -Depth 4) } else { Send-Error $res 'Noch kein eigenes Branding gespeichert.' 404 }
  }
  'POST /api/branding/file/pick' = {
    # "Branding laden": file dialog, answer {"file": name, "text": content}; the dialog checks and fills it in,
    # stored only with "Speichern". {"file": null} = cancelled.
    $picked = Select-File 'Branding-Datei laden' '' 'Branding-Datei (*.json)' '*.json'
    $answer = @{ file = $null }
    if ($picked) {
      if ((Get-Item -LiteralPath $picked).Length -gt 10MB) { $answer = @{ error = "Die Datei ist zu gro$([char]0xDF) f$([char]0xFC)r eine Branding-Datei." } }
      else { $answer = @{ file = (Split-Path -Leaf $picked); text = [IO.File]::ReadAllText($picked, [Text.Encoding]::UTF8) } }
    }
    Send-Json $res $answer
  }
  'POST /api/branding/logo/pick' = {
    # "Logo waehlen": file dialog, answer {"logo": data URL}; stored only with "Speichern". {"logo": null} = cancelled.
    $picked = Select-File "Logo w$([char]0xE4)hlen" '' 'Bilder (*.png;*.jpg;*.jpeg;*.svg;*.webp;*.gif)' '*.png;*.jpg;*.jpeg;*.svg;*.webp;*.gif'
    $answer = @{ logo = $null }
    if ($picked) {
      $mime = @{ '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.svg' = 'image/svg+xml'; '.webp' = 'image/webp'; '.gif' = 'image/gif' }[[IO.Path]::GetExtension($picked).ToLower()]
      if (-not $mime) { $answer = @{ error = "Bitte ein Bild (PNG, JPG, SVG, WebP oder GIF) w$([char]0xE4)hlen." } }
      elseif ((Get-Item -LiteralPath $picked).Length -gt $MaxLogoBytes) { $answer = @{ error = ('Das Logo ist zu gro{0}, h{1}chstens 5 MB.' -f [char]0xDF, [char]0xF6) } }
      else { $answer = @{ logo = "data:$mime;base64," + [Convert]::ToBase64String([IO.File]::ReadAllBytes($picked)) } }
    }
    Send-Json $res $answer
  }
  'POST /api/branding/reset' = {
    # Back to the neutral defaults: the branding file is deleted
    Remove-Item -LiteralPath $BrandingFile -Force -ErrorAction SilentlyContinue
    $BrandingCache.stamp = $null
    Send-Json $res (Get-Branding)
  }

  # TV display and control page
  'POST /api/display/window' = { Open-Display -Windowed; Send-Text $res '{"ok":true}' }   # Esc on the TV: full screen off
  'POST /api/display/open' = {
    # Optional {"screen": "\\.\DISPLAY2"}: remember the screen and open there
    $screenId = (Read-Json $req).screen
    if ($screenId) { Set-ConfigValue 'screen' $screenId }
    Open-Display $screenId
    Send-Text $res '{"ok":true}'
  }
  'POST /api/display/close' = { Close-Display; Send-Text $res '{"ok":true}' }
  'POST /api/control/open' = { Open-Control; Send-Text $res '{"ok":true}' }

  # DISAG JSON Live and the range logs of OpticScore
  'GET /api/gate' = { Send-Json $res (Get-GateInfo) }
  'POST /api/gate/file/pick' = {
    # File dialog for the JSON Live log file; only returns the choice, stored with "Speichern"
    Send-Json $res @{ file = (Select-File "DISAG JSON-Live-Logdatei w$([char]0xE4)hlen" (Get-GateConfig).file 'JSON-Live-Logdatei (*.log)' '*.log') }
  }
  'POST /api/gate/rangelog/pick' = {
    # Folder dialog for RangesLog of OpticScore (empty filter = folders); only returns the choice
    Send-Json $res @{ file = (Select-File "Ordner RangesLog von OpticScore w$([char]0xE4)hlen" (Get-RangeLogFolder (Get-GateConfig)) '' '') }
  }
  'GET /api/oss/loglevel' = { Send-Json $res (Get-OssLogInfo) }
  'POST /api/oss/loglevel' = { Send-Json $res (Set-OssRangeLog ([bool](Read-Json $req).on)) }   # {"on": true}: the button
  'POST /api/gate/config' = {
    # {"source": "udp", "host": "localhost", "port": 30169, "file": "C:\\DISAG\\JSON Live\\OUT-JSONInterface.log",
    #  "rangeCount": 10, "enabled": true, "rangeLog": false, "rangeLogFolder": ""}. Empty = default. The server
    # is used as the sender filter of UDP; the fields of the data source that is not chosen are not checked.
    # The registry of OpticScore is switched with its own button (/api/oss/loglevel), not here.
    $in = Read-Json $req
    $g = Get-GateConfig
    if ($in.source -eq 'udp' -or $in.source -eq 'file') { $g.source = [string]$in.source }
    $g.host = ([string]$in.host).Trim(); if (-not $g.host) { $g.host = $GateDefaults.host }
    if ($g.host.Length -gt 253 -or $g.host -notmatch '^[A-Za-z0-9._-]+$') { return Send-Error $res 'Der Server muss eine IP-Adresse oder ein DNS-Name sein.' }
    if ($g.source -eq 'file') {
      $g.file = ([string]$in.file).Trim(); if (-not $g.file) { $g.file = $GateDefaults.file }
      if ($g.file.Length -gt 260) { return Send-Error $res 'Der Dateiname ist zu lang.' }
    } else {
      $port = "$($in.port)".Trim()
      $g.port = if ($port) { $port -as [int] } else { $GateDefaults.port }
      if (-not $g.port -or $g.port -lt 1 -or $g.port -gt 65535) { return Send-Error $res 'Der Port muss zwischen 1 und 65535 liegen.' }
    }
    if ([int]$in.rangeCount -ge 1 -and [int]$in.rangeCount -le 40) { $g.rangeCount = [int]$in.rangeCount }
    if ($null -ne $in.enabled) { $g.enabled = [bool]$in.enabled }
    if ($null -ne $in.rangeLog) { $g.rangeLog = [bool]$in.rangeLog }
    if ($null -ne $in.rangeLogFolder -and ([string]$in.rangeLogFolder).Length -le 260) {
      $f = ([string]$in.rangeLogFolder).Trim().TrimEnd('\')
      $g.rangeLogFolder = if ($f -and $f -ne (Get-RangeLogDefaultFolder)) { $f } else { '' }
    }
    Set-ConfigValue 'gate' $g
    Update-GateState
    Send-Json $res (Get-GateInfo)
  }

  # DISAG database
  'GET /api/league' = { Send-Json $res (Get-LeagueInfo) }
  'POST /api/league/refresh' = { Update-LeagueData; Send-Json $res (Get-LeagueInfo) }
  'GET /api/league/all' = { Send-Text $res "<results>$($LeagueCache.all)</results>" 'application/xml; charset=utf-8' }   # from the cache
  'POST /api/league/file/pick' = {
    Send-Json $res @{ file = (Select-File "DISAG-Datenbank w$([char]0xE4)hlen" (Get-LeagueConfig).file 'DISAG-Datenbank (*.mdb)' '*.mdb') }
  }
  'POST /api/league/config' = {
    # {"showToday": true, "file": "C:\\Disag\\Daten\\dboss.mdb"}; empty file = default
    $in = Read-Json $req
    $l = Get-LeagueConfig
    if ($null -ne $in.file -and ([string]$in.file).Length -le 260) {
      $l.file = ([string]$in.file).Trim(); if (-not $l.file) { $l.file = $LeagueDefaultFile }
    }
    if ($null -ne $in.showToday) { $l.showToday = [bool]$in.showToday }
    Set-ConfigValue 'league' $l
    Update-GateState   # the range logs are next to the database
    $LeagueCache.stamp = ''   # saving counts as an explicit request: read once
    Update-LeagueData
    Send-Json $res (Get-LeagueInfo)
  }

  'POST /api/quit' = { Send-Text $res '{"ok":true}'; $quit = $true }
}

$types = @{
  '.html' = 'text/html; charset=utf-8'; '.htm' = 'text/html; charset=utf-8'
  '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'; '.svg' = 'image/svg+xml'
  '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.woff2' = 'font/woff2'
}
$rootFull = [IO.Path]::GetFullPath($Root)

# Requests are handled one after another (fine for two pages on one PC)
while ($listener.IsListening) {
  try { $ctx = $listener.GetContext() } catch { break }
  $req = $ctx.Request
  $res = $ctx.Response
  try {
    $handler = $Routes["$($req.HttpMethod) $($req.Url.AbsolutePath)"]
    if ($handler) {
      . $handler
    } else {
      $rel = [Uri]::UnescapeDataString($req.Url.AbsolutePath.TrimStart('/'))
      if (-not $rel) { $rel = 'index.html' }
      $file = [IO.Path]::GetFullPath((Join-Path $Root $rel))
      if ($file.StartsWith($rootFull) -and (Test-Path $file -PathType Leaf)) {
        $bytes = [IO.File]::ReadAllBytes($file)
        $ext = [IO.Path]::GetExtension($file).ToLower()
        $res.ContentType = if ($types[$ext]) { $types[$ext] } else { 'application/octet-stream' }
        $res.Headers['Cache-Control'] = 'no-store'
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
      } else {
        Send-Text $res 'Nicht gefunden' 'text/plain; charset=utf-8' 404
      }
    }
  } catch {
    try { $res.StatusCode = 500 } catch { }
  } finally {
    try { $res.Close() } catch { }
  }
  if ($quit) { break }
}

# Quit: stop the reader threads, close the TV display and remove the tray icon (its message loop needs a moment)
$GateState.stop = $true
Close-Display
$listener.Stop()
$TrayState.stop = $true
Start-Sleep -Milliseconds 600
