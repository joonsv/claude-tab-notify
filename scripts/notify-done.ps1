# tab-notify: Claude Code notification hook (per session / per Windows Terminal tab).
#   -Mode prompt : (UserPromptSubmit) remember when the prompt was sent
#   -Mode stop   : (Stop) find this session's terminal + tab, then hand off to a detached watcher
#   -Mode watch  : the watcher. When Claude finishes:
#       * this tab in front, user active in the last 60s   -> nothing, they've seen it
#       * this tab in front, user idle                       -> wait up to 3 min; cancel on input here or a
#                                                               new prompt; otherwise chime
#       * user in ANOTHER tab of the terminal                -> chime + mark this tab (bell in the title +
#                                                               blinking progress ring). Switch to it after
#                                                               the user's next Enter in the terminal; clear
#                                                               the mark if they switch to it themselves
#       * user in another app                                -> chime + bring terminal to front on this tab
#       * fullscreen app in front                            -> chime + mark the tab, never steal focus
param(
    [string]$Mode = 'stop',
    [string]$Sid = 'default',
    [int]$ClaudePid = 0,
    [int]$OwnerPid = 0,
    [string]$OwnerName = '',
    [long]$MainHwnd = 0,
    [long]$StopTicks = 0
)

$SEEN_IDLE_SEC = 60
$FALLBACK_SEC  = 180
$MAX_WATCH_H   = 12

# Per-user state (prompt times, log, compiled helper) lives outside the plugin folder,
# which Claude Code may replace on update.
$stateDir = Join-Path $env:USERPROFILE '.claude\tab-notify'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory $stateDir | Out-Null }

if ($Mode -ne 'watch') {
    try { $j = [Console]::In.ReadToEnd() | ConvertFrom-Json; if ($j.session_id) { $Sid = $j.session_id } } catch {}
}
$promptFile  = Join-Path $stateDir "$Sid.prompt"
$watcherFile = Join-Path $stateDir "$Sid.watcher"

if ($Mode -eq 'prompt') {
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

if ($Mode -eq 'stop') {
    # Walk up from this hook process (must be spawned without an MSYS shell in between, or the
    # parent chain breaks): the nearest claude/node ancestor owns this session's console (= tab),
    # the first ancestor with a visible window is the terminal app (Windows Terminal, conhost, VS Code).
    $procs = @{}
    Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name | ForEach-Object { $procs[[int]$_.ProcessId] = $_ }
    $cur = [int]$procs[$PID].ParentProcessId
    for ($i = 0; $i -lt 12 -and $procs[$cur]; $i++) {
        $p = $procs[$cur]
        if (-not $ClaudePid -and $p.Name -match '^(claude|node)\.exe$') { $ClaudePid = $cur }
        $gp = Get-Process -Id $cur -ErrorAction SilentlyContinue
        if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero) {
            $OwnerPid = $cur; $OwnerName = $p.Name; $MainHwnd = $gp.MainWindowHandle.ToInt64(); break
        }
        $cur = [int]$p.ParentProcessId
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"",
        '-Mode', 'watch', '-Sid', $Sid, '-ClaudePid', $ClaudePid, '-OwnerPid', $OwnerPid,
        '-OwnerName', "`"$OwnerName`"", '-MainHwnd', $MainHwnd, '-StopTicks', [DateTime]::UtcNow.Ticks)
    Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden
    exit 0
}

# ---------------------------------------------------------------- watch mode
$PID | Set-Content $watcherFile
$dll = Join-Path $stateDir 'claude-win-v4.dll'
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

    public static bool Focus(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
        IntPtr fg = GetForegroundWindow();
        uint dummy;
        uint fgThread = GetWindowThreadProcessId(fg, out dummy);
        uint me = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (attached) AttachThreadInput(me, fgThread, false);
        if (GetForegroundWindow() == h) return true;

        // fallback: a synthetic Alt press lifts the foreground lock
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        SetForegroundWindow(h);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        return GetForegroundWindow() == h;
    }
}
'@
    Add-Type -TypeDefinition $src -OutputAssembly $dll -OutputType Library
}
Add-Type -Path $dll

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
    $found = if ($isWT) { FindOurTab } else { $null }
    if ($found) {
        try { $found.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch {}
        [void][ClaudeWin]::Focus($found.Hwnd)
        Log '  switched to window + tab'
    } elseif ($mainHwndPtr -ne [IntPtr]::Zero) {
        [void][ClaudeWin]::Focus($mainHwndPtr)
        Log '  focused window (tab not found)'
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
    Log "  marked tab, waiting for Enter in terminal or manual switch"
    $claimFile = Join-Path $stateDir 'switch.claim'
    $ring = $false; $lastBlink = -10000; $lastCheck = -10000; $enterDown = $false; $modsUsed = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = 'timeout'
    $deadline = (Get-Date).AddHours($MAX_WATCH_H)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 30
        $now = $sw.ElapsedMilliseconds

        # Enter released while a terminal window of ours is in front (Shift/Ctrl/Alt+Enter don't count)
        $down = [ClaudeWin]::KeyDown(0x0D)
        if ($down) {
            if ([ClaudeWin]::KeyDown(0x10) -or [ClaudeWin]::KeyDown(0x11) -or [ClaudeWin]::KeyDown(0x12)) { $modsUsed = $true }
            $enterDown = $true
        } elseif ($enterDown) {
            $enterDown = $false
            if (-not $modsUsed -and (TerminalInFront) -and -not (OurTabActive)) {
                # one Enter switches only one waiting session
                $claim = 0; try { $claim = [long]((Get-Content $claimFile -Raw).Trim()) } catch {}
                if ([Math]::Abs([Environment]::TickCount - $claim) -gt 1500) {
                    [Environment]::TickCount | Set-Content $claimFile
                    Start-Sleep -Milliseconds 150
                    GoToOurTab
                    $result = 'enter'; break
                }
            }
            $modsUsed = $false
        }

        if ($now - $lastCheck -ge 250) {
            $lastCheck = $now
            if (-not (ClaudeAlive)) { $result = 'claude exited'; break }
            if (OurTabActive) { $result = 'user switched to tab'; break }
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

function HandleNotInFront {
    Chime
    if ((TerminalInFront) -or [ClaudeWin]::ForegroundIsFullscreen()) {
        MarkAndWait
    } else {
        # other app: bring the terminal up on this tab, after a short typing pause (max 8s)
        $t0 = Get-Date
        while ([ClaudeWin]::IdleMs() -lt 1200 -and ((Get-Date) - $t0).TotalSeconds -lt 8) { Start-Sleep -Milliseconds 200 }
        if ([ClaudeWin]::ForegroundIsFullscreen()) { MarkAndWait } else { GoToOurTab }
    }
}

Log ("stop: claude pid={0}, terminal={1}, tab=[{2}]" -f $ClaudePid, $OwnerName, (OurTitle))
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
