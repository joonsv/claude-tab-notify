# tab-notify: Claude Code notification hook (per session / per Windows Terminal tab).
#   -Mode prompt : (UserPromptSubmit) remember when the prompt was sent
#   -Mode stop   : (Stop, and Notification when Claude needs input: permission prompt, question) find this
#                  session's terminal + tab; if another app is in front, chime + bring it up right here (instant),
#                  otherwise hand off to a detached watcher
#   -Mode watch  : the watcher. When Claude finishes or needs input:
#       * this tab in front, user active in the last 60s   -> nothing, they've seen it
#       * this tab in front, user idle                       -> wait up to 3 min; cancel on input here or a
#                                                               new prompt; otherwise chime
#       * user in ANOTHER tab of the terminal                -> chime + mark this tab (bell in the title +
#                                                               blinking progress ring). Switch to it after
#                                                               the user's next Enter in the terminal, or right
#                                                               away if the tab in front is a busy Claude
#                                                               session (after 10s idle, or 30s if they were typing there); clear the mark if
#                                                               they switch to it themselves
#       * user in another app                                -> chime + bring terminal to front on this tab
#       * fullscreen app in front                            -> chime + mark the tab, never steal focus
param(
    [string]$Mode = 'stop',
    [string]$Sid = 'default',
    [int]$ClaudePid = 0,
    [int]$OwnerPid = 0,
    [string]$OwnerName = '',
    [long]$MainHwnd = 0,
    [long]$StopTicks = 0,
    [string]$Event = 'Stop',
    [string]$Kind = ''
)

$SEEN_IDLE_SEC = 60
$TYPE_QUIET_SEC = 10   # busy front tab: switch only after this long without ANY input (keys incl. arrows, mouse)
$TYPING_PAUSE_SEC = 30 # ...and if the user typed there (no Enter yet): also this long since the last keystroke
$FALLBACK_SEC  = 180
$MAX_WATCH_H   = 12

# Per-user state (prompt times, log, compiled helper) lives outside the plugin folder,
# which Claude Code may replace on update.
$stateDir = Join-Path $env:USERPROFILE '.claude\tab-notify'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory $stateDir | Out-Null }

if ($Mode -ne 'watch') {
    try {
        $j = [Console]::In.ReadToEnd() | ConvertFrom-Json
        if ($j.session_id) { $Sid = $j.session_id }
        if ($j.hook_event_name) { $Event = $j.hook_event_name }
        if ($j.notification_type) { $Kind = $j.notification_type }
    } catch {}
}
$promptFile  = Join-Path $stateDir "$Sid.prompt"
$watcherFile = Join-Path $stateDir "$Sid.watcher"

# "<sid>.awaiting" holds the tab title of a session blocked on the user (permission prompt, question):
# its spinner may still turn, but the user is not just waiting on it, so it must not count as busy.
$awaitFile = Join-Path $stateDir "$Sid.awaiting"

if ($Mode -eq 'prompt') {
    Remove-Item $awaitFile -ErrorAction SilentlyContinue
    [DateTime]::UtcNow.Ticks | Set-Content $promptFile
    exit 0
}

$logFile = Join-Path $stateDir 'notify.log'
function Log($msg) {
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 200KB) { Remove-Item $logFile }
    "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Sid.Substring(0, [Math]::Min(8, $Sid.Length)), $msg |
        Add-Content $logFile -Encoding utf8
}
function PromptTicks {
    if (Test-Path $promptFile) { try { return [long]((Get-Content $promptFile -Raw).Trim()) } catch {} }
    return [long]0
}

# ---------------------------------------------------------------- helper DLL (stop + watch)
$dll = Join-Path $stateDir 'claude-win-v8.dll'
if (-not (Test-Path $dll)) {
    $src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ClaudeWin {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern uint GetConsoleTitle(StringBuilder sb, uint n);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool SetConsoleTitle(string t);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateFile(string n, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool WriteConsole(IntPtr h, string s, uint n, out uint written, IntPtr r);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    public static IntPtr Foreground() { return GetForegroundWindow(); }
    public static uint WindowPid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
    public static string WindowTitle(IntPtr h) { var sb = new StringBuilder(1024); GetWindowText(h, sb, 1024); return sb.ToString(); }
    public static bool KeyDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }
    // Pressed and released since the previous call: catches taps shorter than our polling interval.
    public static bool KeyTapped(int vk) { return (GetAsyncKeyState(vk) & 0x0001) != 0; }
    // A key that edits text (letters, digits, punctuation, space, backspace, delete) is held down.
    // Ctrl/Alt combos are shortcuts, not typing.
    public static bool TypingKeyDown() {
        if (KeyDown(0x11) || KeyDown(0x12)) return false;
        int[] r = { 0x08, 0x08, 0x20, 0x20, 0x2E, 0x2E, 0x30, 0x39, 0x41, 0x5A, 0x60, 0x6F, 0xBA, 0xC0, 0xDB, 0xDF, 0xE2, 0xE2 };
        for (int i = 0; i < r.Length; i += 2)
            for (int vk = r[i]; vk <= r[i + 1]; vk++)
                if (KeyDown(vk)) return true;
        return false;
    }

    // The console of a process = its terminal tab. We attach only briefly: staying attached would keep
    // the tab alive after Claude exits and expose us to that tab's Ctrl+C.
    public static string ConsoleTitleOf(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) return null;
        var sb = new StringBuilder(1024);
        GetConsoleTitle(sb, 1024);
        FreeConsole();
        return sb.ToString();
    }
    public static bool SetConsoleTitleOf(uint pid, string title) {
        FreeConsole();
        if (!AttachConsole(pid)) return false;
        bool ok = SetConsoleTitle(title);
        FreeConsole();
        return ok;
    }
    // Write a VT sequence (e.g. OSC 9;4 progress ring) into another process's console.
    public static bool WriteConsoleOf(uint pid, string s) {
        FreeConsole();
        if (!AttachConsole(pid)) return false;
        IntPtr h = CreateFile("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        bool ok = false;
        if (h != new IntPtr(-1)) {
            uint mode;
            GetConsoleMode(h, out mode);
            bool vt = (mode & 4) != 0;
            if (!vt) SetConsoleMode(h, mode | 4);
            uint w;
            ok = WriteConsole(h, s, (uint)s.Length, out w, IntPtr.Zero);
            if (!vt) SetConsoleMode(h, mode);
            CloseHandle(h);
        }
        FreeConsole();
        return ok;
    }

    public static IntPtr[] WindowsOf(uint pid, string cls) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            if (WindowPid(h) == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(256);
                GetClassName(h, sb, 256);
                if (sb.ToString() == cls) list.Add(h);
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    public static uint Now() { return unchecked((uint)Environment.TickCount); }
    public static uint LastInput() {
        var lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        return GetLastInputInfo(ref lii) ? lii.dwTime : 0;
    }
    public static uint IdleMs() { return unchecked(Now() - LastInput()); }
    // any keyboard/mouse input after the given tick (wrap-safe)
    public static bool InputSince(uint tick) { return unchecked((int)(LastInput() - tick)) > 0; }

    public static bool ForegroundIsFullscreen() {
        int s;
        // 2 = fullscreen app (QUNS_BUSY), 3 = D3D exclusive fullscreen, 4 = presentation mode
        if (SHQueryUserNotificationState(out s) == 0 && (s == 2 || s == 3 || s == 4)) return true;

        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return false;
        var sb = new StringBuilder(256);
        GetClassName(fg, sb, 256);
        string c = sb.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd") return false; // desktop / taskbar

        RECT r;
        if (!GetWindowRect(fg, out r)) return false;
        var mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(MonitorFromWindow(fg, 2), ref mi)) return false;
        // borderless-windowed games / F11 cover the whole monitor incl. taskbar; maximized windows don't
        return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
    }

    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32 {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")] static extern bool Process32First(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")] static extern bool Process32Next(IntPtr snap, ref PROCESSENTRY32 pe);

    // "pid|exe" for each ancestor of pid, nearest first (parent, grandparent, ...)
    public static string[] Ancestors(uint pid) {
        var parent = new Dictionary<uint, uint>(); var name = new Dictionary<uint, string>();
        IntPtr snap = CreateToolhelp32Snapshot(2, 0); // TH32CS_SNAPPROCESS
        var pe = new PROCESSENTRY32(); pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
        if (Process32First(snap, ref pe)) {
            do { parent[pe.th32ProcessID] = pe.th32ParentProcessID; name[pe.th32ProcessID] = pe.szExeFile; }
            while (Process32Next(snap, ref pe));
        }
        CloseHandle(snap);
        var list = new List<string>(); uint cur = pid;
        for (int i = 0; i < 16 && parent.ContainsKey(cur); i++) {
            cur = parent[cur];
            if (!name.ContainsKey(cur)) break;
            list.Add(cur + "|" + name[cur]);
        }
        return list.ToArray();
    }

    // Windows refuses SetForegroundWindow from a background process while the user is busy in another
    // app (foreground lock), so try progressively stronger ways. Returns which one worked, or "failed".
    public static string Focus(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
        IntPtr fg = GetForegroundWindow();
        uint dummy;
        uint fgThread = GetWindowThreadProcessId(fg, out dummy);
        uint me = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (attached) AttachThreadInput(me, fgThread, false);
        if (GetForegroundWindow() == h) return "attach";

        // a synthetic Alt press lifts the foreground lock
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        SetForegroundWindow(h);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        if (GetForegroundWindow() == h) return "alt";

        SwitchToThisWindow(h, true);
        System.Threading.Thread.Sleep(80);
        if (GetForegroundWindow() == h) return "switchto";

        // last resort: minimize + restore always activates (restore returns to maximized if it was)
        ShowWindow(h, 6);  // SW_MINIMIZE
        ShowWindow(h, 9);  // SW_RESTORE
        SetForegroundWindow(h);
        System.Threading.Thread.Sleep(80);
        return GetForegroundWindow() == h ? "minrestore" : "failed";
    }
}
'@
    Add-Type -TypeDefinition $src -OutputAssembly $dll -OutputType Library
}
Add-Type -Path $dll

if ($Mode -eq 'stop') {
    # Walk up from this hook process (must be spawned without an MSYS shell in between, or the parent
    # chain breaks): the nearest claude/node ancestor owns this session's console (= tab), the first
    # ancestor with a visible window is the terminal app (Windows Terminal, conhost, VS Code).
    foreach ($a in [ClaudeWin]::Ancestors($PID)) {
        $apid, $aname = $a.Split('|', 2); $apid = [int]$apid
        if (-not $ClaudePid -and $aname -match '^(claude|node)\.exe$') { $ClaudePid = $apid }
        $gp = Get-Process -Id $apid -ErrorAction SilentlyContinue
        if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero) {
            $OwnerPid = $apid; $OwnerName = $aname; $MainHwnd = $gp.MainWindowHandle.ToInt64(); break
        }
    }
}

$stopTick = [ClaudeWin]::Now()
$stopTime = if ($StopTicks) { New-Object DateTime $StopTicks, ([DateTimeKind]::Utc) } else { [DateTime]::UtcNow }
$promptTicks = PromptTicks
$mainHwndPtr = [IntPtr]$MainHwnd
$isWT = $OwnerName -eq 'WindowsTerminal.exe'
$ESC = [char]27; $BEL = [char]7
$BELL = [char]::ConvertFromUtf32(0x1F514)

# Tab titles carry a changing spinner glyph; compare without it.
function Norm($t) { ([string]$t -replace '^[^\p{L}\p{N}]+', '').Trim() }
function RawTitle { if ($ClaudePid) { return [ClaudeWin]::ConsoleTitleOf($ClaudePid) } return $null }
function OurTitle { return Norm (RawTitle) }
function ClaudeAlive { return [bool](Get-Process -Id $ClaudePid -ErrorAction SilentlyContinue) }
function Superseded {
    try { return (Test-Path $watcherFile) -and ((Get-Content $watcherFile -Raw -ErrorAction Stop).Trim() -ne "$PID") } catch { return $false }
}

# Is this session's tab the one the user is looking at? (WT window title = title of its active tab)
function OurTabActive {
    $fg = [ClaudeWin]::Foreground()
    if ($isWT) {
        $t = OurTitle
        if ($t) { return ([ClaudeWin]::WindowPid($fg) -eq $OwnerPid) -and ((Norm ([ClaudeWin]::WindowTitle($fg))) -eq $t) }
    }
    return $mainHwndPtr -ne [IntPtr]::Zero -and $fg -eq $mainHwndPtr
}
function TerminalInFront { return $OwnerPid -and ([ClaudeWin]::WindowPid([ClaudeWin]::Foreground()) -eq $OwnerPid) }

# Claude puts a spinning half-circle in its tab title while it works (an asterisk when idle).
# If the tab in front is a busy Claude session, the user is just waiting on it: switching is fine.
$SPIN = @(0x25D0, 0x25D1, 0x25D2, 0x25D3) | ForEach-Object { [char]$_ }
function FrontTabBusy {
    $fg = [ClaudeWin]::Foreground()
    if ([ClaudeWin]::WindowPid($fg) -ne $OwnerPid) { return $false }
    $t = [ClaudeWin]::WindowTitle($fg)
    if (-not ($t.Length -gt 0 -and ($SPIN -contains $t[0]))) { return $false }
    $n = Norm $t
    foreach ($f in (Get-ChildItem $stateDir -Filter '*.awaiting' -ErrorAction SilentlyContinue)) {
        try { if ((Get-Content $f.FullName -Raw -ErrorAction Stop).Trim() -eq $n) { return $false } } catch {}
    }
    return $true
}

# Only one waiting session may switch per trigger (Enter press / busy-tab check).
function ClaimSwitch {
    $claimFile = Join-Path $stateDir 'switch.claim'
    $claim = 0; try { $claim = [long]((Get-Content $claimFile -Raw -ErrorAction Stop).Trim()) } catch {}
    if ([Math]::Abs([Environment]::TickCount - $claim) -le 1500) { return $false }
    [Environment]::TickCount | Set-Content $claimFile
    return $true
}

# Find the WT window + tab element of this session via UI Automation.
function FindOurTab {
    $t = OurTitle
    if (-not $t) { return $null }
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $AE = [System.Windows.Automation.AutomationElement]
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    foreach ($h in [ClaudeWin]::WindowsOf($OwnerPid, 'CASCADIA_HOSTING_WINDOW_CLASS')) {
        try {
            foreach ($tab in $AE::FromHandle($h).FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
                if ((Norm $tab.Current.Name) -eq $t) { return @{ Hwnd = $h; Tab = $tab } }
            }
        } catch {}
    }
    return $null
}

function GoToOurTab {
    if ($env:NOTIFY_DRYRUN) { Log '  DRYRUN would switch to tab'; return }
    if ($isWT) {
        $wins = @([ClaudeWin]::WindowsOf($OwnerPid, 'CASCADIA_HOSTING_WINDOW_CLASS'))
        $how = $null
        # one terminal window: bring it up first (instant), then select the tab
        if ($wins.Count -eq 1) { $how = [ClaudeWin]::Focus($wins[0]) }
        $found = FindOurTab
        if ($found) {
            try { $found.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch {}
            if (-not $how) { $how = [ClaudeWin]::Focus($found.Hwnd) }
            Log "  selected tab, bring window to front: $how"
            return
        }
        if ($how) { Log "  tab not found, bring window to front: $how"; return }
    }
    if ($mainHwndPtr -ne [IntPtr]::Zero) {
        $how = [ClaudeWin]::Focus($mainHwndPtr)
        Log "  tab not found, bring window to front: $how"
    }
}

$script:player = $null
function Chime {
    if ($env:NOTIFY_DRYRUN) { Log '  DRYRUN chime'; return }
    $wav = Join-Path $PSScriptRoot '..\sounds\done.wav'
    if (Test-Path $wav) { $script:player = New-Object System.Media.SoundPlayer $wav; $script:player.Play() }
}

# Mark this tab (bell in the title + blinking progress ring) until the user switches to it themselves,
# or presses Enter somewhere in the terminal (then we switch for them).
function MarkAndWait {
    $orig = RawTitle
    if ($null -eq $orig) { return }
    $marked = "$BELL " + (Norm $orig)
    [void][ClaudeWin]::SetConsoleTitleOf($ClaudePid, $marked)
    $fgT = [ClaudeWin]::WindowTitle([ClaudeWin]::Foreground())
    Log ("  marked tab; front=[{0}] busy={1} last input {2:N1}s ago" -f (Norm $fgT), (FrontTabBusy), ([ClaudeWin]::IdleMs() / 1000))
    $ring = $false; $lastBlink = -10000; $lastCheck = -10000; $enterDown = $false; $modsUsed = $false
    $lastType = -1000000   # last text keystroke in the tab in front
    [void][ClaudeWin]::KeyTapped(0x0D)   # drop a stale 'pressed since last call' from before we started
    $typedHere = $false   # a real keystroke seen in the tab in front since its last Enter
    $lastFront = Norm ([ClaudeWin]::WindowTitle([ClaudeWin]::Foreground()))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = 'timeout'
    $deadline = (Get-Date).AddHours($MAX_WATCH_H)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 30
        $now = $sw.ElapsedMilliseconds

        # Enter released while a terminal window of ours is in front (Shift/Ctrl/Alt+Enter don't count)
        if ((TerminalInFront) -and [ClaudeWin]::TypingKeyDown()) { $lastType = $now; $typedHere = $true }
        $down = [ClaudeWin]::KeyDown(0x0D)
        $tapped = [ClaudeWin]::KeyTapped(0x0D)
        if (-not $down -and -not $enterDown -and $tapped) {
            # a whole press happened between two polls: treat it as down + released now
            if ([ClaudeWin]::KeyDown(0x10) -or [ClaudeWin]::KeyDown(0x11) -or [ClaudeWin]::KeyDown(0x12)) { $modsUsed = $true }
            $enterDown = $true
        }
        if ($down) {
            if ([ClaudeWin]::KeyDown(0x10) -or [ClaudeWin]::KeyDown(0x11) -or [ClaudeWin]::KeyDown(0x12)) { $modsUsed = $true }
            $enterDown = $true
        } elseif ($enterDown) {
            $enterDown = $false
            if (-not $modsUsed -and (TerminalInFront) -and -not (OurTabActive)) {
                if (ClaimSwitch) {
                    Start-Sleep -Milliseconds 150
                    GoToOurTab
                    $result = 'enter'; break
                }
            }
            if (-not $modsUsed) { $typedHere = $false }
            $modsUsed = $false
        }

        if ($now - $lastCheck -ge 250) {
            $lastCheck = $now
            if (-not (ClaudeAlive)) { $result = 'claude exited'; break }
            if (OurTabActive) { $result = 'user switched to tab'; break }
            # a different tab came to the front: typing in the old one doesn't count there
            $front = Norm ([ClaudeWin]::WindowTitle([ClaudeWin]::Foreground()))
            if ($front -ne $lastFront) { $lastFront = $front; $lastType = -1000000; $typedHere = $false }
            # user is just waiting on another busy Claude tab: no input at all for a while (arrows, mouse and
            # scrolling count too), and if they had typed there, a longer pause since the last keystroke
            $idleOk  = [ClaudeWin]::IdleMs() -ge $TYPE_QUIET_SEC * 1000
            $typeOk  = (-not $typedHere) -or ($now - $lastType -ge $TYPING_PAUSE_SEC * 1000)
            if ((FrontTabBusy) -and $idleOk -and $typeOk -and (ClaimSwitch)) {
                GoToOurTab; $result = ("front tab was busy, no input for {0:N0}s (typed there: {1})" -f ([ClaudeWin]::IdleMs() / 1000), $typedHere); break
            }
            if ((PromptTicks) -ne $promptTicks) { $result = 'new prompt'; break }
            if (Superseded) { $result = 'superseded'; break }
        }
        if ($now - $lastBlink -ge 700) {
            $lastBlink = $now
            $ring = -not $ring
            $seq = if ($ring) { "$ESC]9;4;4;100$BEL" } else { "$ESC]9;4;0;0$BEL" }
            [void][ClaudeWin]::WriteConsoleOf($ClaudePid, $seq)
            # Claude may rewrite the title; keep the bell on it
            $cur = RawTitle
            if ($null -ne $cur -and -not $cur.StartsWith($BELL)) { $marked = "$BELL " + (Norm $cur); [void][ClaudeWin]::SetConsoleTitleOf($ClaudePid, $marked) }
        }
    }
    if ($result -ne 'claude exited') {
        [void][ClaudeWin]::WriteConsoleOf($ClaudePid, "$ESC]9;4;0;0$BEL")
        $cur = RawTitle
        if ($null -ne $cur -and $cur.StartsWith($BELL)) { [void][ClaudeWin]::SetConsoleTitleOf($ClaudePid, $orig) }
    }
    Log "  unmarked: $result"
}

# Don't yank focus mid-keystroke: only waits if a key is down right now, then until 150 ms without
# one (max 1 s). Mouse movement never delays, it can't land in the wrong window.
function WaitTypingBurst {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $lastKey = -1000
    while ($sw.ElapsedMilliseconds -lt 1000) {
        if ([ClaudeWin]::TypingKeyDown() -or [ClaudeWin]::KeyDown(0x0D)) { $lastKey = $sw.ElapsedMilliseconds }
        if ($sw.ElapsedMilliseconds - $lastKey -ge 150) { break }
        Start-Sleep -Milliseconds 15
    }
}

function HandleNotInFront {
    Chime
    if ((TerminalInFront) -or [ClaudeWin]::ForegroundIsFullscreen()) {
        MarkAndWait
    } else {
        WaitTypingBurst
        if ([ClaudeWin]::ForegroundIsFullscreen()) { MarkAndWait } else { GoToOurTab }
    }
}

if ($Mode -eq 'stop') {
    if ($Event -ne 'Notification') { Remove-Item $awaitFile -ErrorAction SilentlyContinue }
    $PID | Set-Content $watcherFile   # supersedes an older watcher of this session
    if (-not (OurTabActive) -and -not (TerminalInFront) -and -not [ClaudeWin]::ForegroundIsFullscreen()) {
        if ($Event -eq 'Notification') { OurTitle | Set-Content $awaitFile }
        Chime
        WaitTypingBurst
        GoToOurTab
        Log ("{0}: other app in front -> brought tab [{1}] up from the hook" -f $(if ($Event -eq 'Notification') { "needs input ($Kind)" } else { 'finished' }), (OurTitle))
        if ($script:player) { Start-Sleep -Milliseconds 700 }   # let the chime finish
        if (-not (Superseded)) { Remove-Item $watcherFile -ErrorAction SilentlyContinue }
        exit 0
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"",
        '-Mode', 'watch', '-Sid', $Sid, '-ClaudePid', $ClaudePid, '-OwnerPid', $OwnerPid,
        '-OwnerName', "`"$OwnerName`"", '-MainHwnd', $MainHwnd, '-StopTicks', [DateTime]::UtcNow.Ticks,
        '-Event', $Event, '-Kind', $(if ($Kind) { $Kind } else { 'none' }))
    Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden
    exit 0
}
$PID | Set-Content $watcherFile

$what = if ($Event -eq 'Notification') { "needs input ($Kind)" } else { 'finished' }
if ($Event -eq 'Notification') { OurTitle | Set-Content $awaitFile }
Log ("{3}: claude pid={0}, terminal={1}, tab=[{2}]" -f $ClaudePid, $OwnerName, (OurTitle), $what)
if (-not (OurTabActive)) {
    Log 'tab not in front -> notify'
    HandleNotInFront
} else {
    $idle = [ClaudeWin]::IdleMs() / 1000
    if ($idle -lt $SEEN_IDLE_SEC) {
        Log ("skip: tab in front, user active {0:N0}s ago -> seen" -f $idle)
    } else {
        Log ("deferred: tab in front but idle {0:N0}s" -f $idle)
        $deadline = $stopTime.AddSeconds($FALLBACK_SEC)
        $outcome = 'timeout'
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 1
            if ((PromptTicks) -ne $promptTicks) { $outcome = 'new prompt'; break }
            if (Superseded) { $outcome = 'superseded'; break }
            if ([ClaudeWin]::InputSince($stopTick) -and (OurTabActive)) { $outcome = 'user back in this tab'; break }
        }
        if ($outcome -ne 'timeout') { Log "  cancel: $outcome" }
        elseif (OurTabActive) { Log '  no response for 3 min -> chime'; Chime }
        else { Log '  no response for 3 min, tab no longer in front -> notify'; HandleNotInFront }
    }
}

if ($script:player) { Start-Sleep -Milliseconds 700 }
if (-not (Superseded)) { Remove-Item $watcherFile -ErrorAction SilentlyContinue }
