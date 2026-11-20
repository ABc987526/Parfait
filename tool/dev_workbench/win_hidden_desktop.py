"""Run Windows Dev clients inside an isolated secondary Win32 desktop.

Creates and holds open a named Win32 desktop (`WinSta0\\<name>`) via
`CreateDesktopW`, launches `parfait.exe` onto that desktop via `CreateProcessW`
(`STARTUPINFO.lpDesktop`), asserts zero windows exist on the user's `Default`
desktop (`DEFAULT_WINS == 0`), and dispatches background mouse clicks via
`EnumDesktopWindows(OpenDesktopW(...))` + `PostMessage`.

This avoids `flutter_window.cpp` / `desktop_window.dart` `Show()` and `focus()`
calls ever flashing windows or stealing cursor/keyboard focus on the user's
active Windows session.
"""

from __future__ import annotations

import base64
import dataclasses
import os
import re
import subprocess
import tempfile
import time
import uuid
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

DEFAULT_POWERSHELL = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
DEFAULT_DESKTOP_NAME = "ParfaitDevHidden"
_DESKTOP_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
_ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_MNT_DRIVE_RE = re.compile(r"^/mnt/([a-zA-Z])(?:/(.*))?$")
_WIN_DRIVE_RE = re.compile(r"^([a-zA-Z]):(?:[/\\](.*))?$")


class HiddenDesktopError(RuntimeError):
    """Raised when Win32 hidden-desktop isolation fails or leaks a Default window."""


@dataclasses.dataclass(frozen=True)
class LaunchResult:
    """Metadata reported immediately after spawning a Windows child process."""

    pid: int
    hidden_windows: int
    default_windows: int
    wait_result: int
    exit_code: int

    @property
    def still_running(self) -> bool:
        """Win32 WaitForSingleObject WAIT_TIMEOUT (258) means still alive."""
        return self.wait_result == 258


_PS_SINGLE_QUOTES = ("'", "\u2018", "\u2019", "\u201a", "\u201b")


def ps_single_quote(value: str) -> str:
    """Wrap *value* in PowerShell single quotes with ASCII and smart quotes doubled."""
    escaped = value
    for ch in _PS_SINGLE_QUOTES:
        escaped = escaped.replace(ch, ch * 2)
    return "'" + escaped + "'"


def to_windows_path(path: str | Path) -> str:
    """Convert a WSL `/mnt/<drive>/...` or Linux path into a Windows path."""
    raw = str(path)
    if len(raw) >= 2 and raw[1] == ":" and raw[0].isalpha():
        return raw.replace("/", "\\")
    match = _MNT_DRIVE_RE.match(raw)
    if match:
        drive = match.group(1).upper()
        rest = (match.group(2) or "").replace("/", "\\")
        return f"{drive}:\\{rest}" if rest else f"{drive}:\\"
    res = subprocess.run(
        ["wslpath", "-w", raw],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=5.0,
        check=True,
    )
    return res.stdout.strip()


def to_wsl_path(path: str | Path) -> Path:
    """Convert a `C:\\...` Windows path to `/mnt/<drive>/...`, or return Path."""
    raw = str(path)
    match = _WIN_DRIVE_RE.match(raw)
    if match:
        drive = match.group(1).lower()
        rest = (match.group(2) or "").replace("\\", "/")
        return Path(f"/mnt/{drive}/{rest}" if rest else f"/mnt/{drive}")
    return Path(raw)


def build_windows_command_line(exe_path: str, args: Sequence[str] = ()) -> str:
    """Build a Win32 CreateProcessW command line from *exe_path* and *args*."""
    if not exe_path.strip():
        raise ValueError("exe_path must not be empty")
    return subprocess.list2cmdline([exe_path, *args])


def run_powershell(
    script: str,
    *,
    powershell_bin: str = DEFAULT_POWERSHELL,
    timeout: float = 35.0,
) -> str:
    """Execute *script* safely in non-interactive PowerShell with stdin detached."""
    full_script = "$ProgressPreference = 'SilentlyContinue'\n" + script
    encoded = base64.b64encode(full_script.encode("utf-16-le")).decode("ascii")
    cmd = [
        powershell_bin,
        "-NoProfile",
        "-NonInteractive",
        "-InputFormat",
        "None",
        "-EncodedCommand",
        encoded,
    ]
    for attempt in range(3):
        res = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        if res.returncode != 0 and "UtilAcceptVsock" in (res.stderr or "") and attempt < 2:
            time.sleep(0.6)
            continue
        if res.returncode != 0:
            raise HiddenDesktopError(f"PowerShell failed (rc={res.returncode}): {res.stderr.strip()}")
        return res.stdout.strip()
    raise HiddenDesktopError("PowerShell WSL2 UtilAcceptVsock retries exhausted")


def _validate_desktop_name(name: str) -> str:
    if not _DESKTOP_NAME_RE.match(name):
        raise ValueError(f"Invalid Win32 desktop name: {name!r}")
    return name


def _holder_script(desktop_name: str, keepalive_win_path: str, max_seconds: int) -> str:
    iterations = max(10, int(max_seconds / 0.3))
    return f"""
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class HiddenDeskHolder {{
  [StructLayout(LayoutKind.Sequential)]
  public struct SECURITY_ATTRIBUTES {{
    public int nLength;
    public IntPtr lpSecurityDescriptor;
    public bool bInheritHandle;
  }}
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr CreateDesktopW(
      string lpszDesktop, IntPtr lpszDevice, IntPtr pDevmode, int dwFlags,
      uint dwDesiredAccess, ref SECURITY_ATTRIBUTES lpsa);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr hDesktop);
  public static IntPtr OpenNew(string name) {{
    var sa = new SECURITY_ATTRIBUTES();
    sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
    sa.bInheritHandle = true;
    // GENERIC_ALL (0x10000000) allows child process creation, window enum and screenshots.
    IntPtr h = CreateDesktopW(name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000u, ref sa);
    if (h == IntPtr.Zero) throw new Exception("CreateDesktopW failed: " + Marshal.GetLastWin32Error());
    return h;
  }}
}}
'@
$hDesk = [HiddenDeskHolder]::OpenNew({ps_single_quote(desktop_name)})
Write-Output 'DESK_READY'
[Console]::Out.Flush()
$keepAlive = {ps_single_quote(keepalive_win_path)}
for ($t = 0; $t -lt {iterations}; $t++) {{
  if (-not (Test-Path -LiteralPath $keepAlive)) {{ break }}
  Start-Sleep -Milliseconds 300
}}
[HiddenDeskHolder]::CloseDesktop($hDesk) | Out-Null
"""


def _launch_script(
    desktop_name: str,
    exe_win: str,
    cmd_line: str,
    env_vars: dict[str, str],
    wait_ms: int,
) -> str:
    env_lines: list[str] = []
    for k, v in env_vars.items():
        if not _ENV_KEY_RE.match(k):
            raise ValueError(f"Invalid environment variable name: {k!r}")
        env_lines.append(f"$env:{k} = {ps_single_quote(v)}")
    env_block = "\n".join(env_lines)
    return f"""
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class HiddenDeskLaunch {{
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct STARTUPINFO {{
    public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX; public int dwY; public int dwXSize; public int dwYSize;
    public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute;
    public int dwFlags; public short wShowWindow; public short cbReserved2;
    public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
  }}
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_INFORMATION {{
    public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
  }}
  [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool CreateProcess(
      string lpApplicationName, StringBuilder lpCommandLine,
      IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
      uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
      ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
  [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
  [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr hObject);
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr OpenDesktopW(string lpszDesktop, int dwFlags, bool fInherit, uint dwDesiredAccess);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr hDesktop);
  [DllImport("user32.dll")] public static extern bool EnumDesktopWindows(IntPtr hDesktop, EnumWindowsProc lpfn, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  public static int CountWins(IntPtr hDesk, int targetPid) {{
    int count = 0;
    EnumDesktopWindows(hDesk, (h, lp) => {{
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == (uint)targetPid) count++;
      return true;
    }}, IntPtr.Zero);
    return count;
  }}
  public static string Go(string desk, string exe, string cmdLine, int waitMs) {{
    IntPtr hDesk = OpenDesktopW(desk, 0, false, 0x0041u);
    if (hDesk == IntPtr.Zero) throw new Exception("OpenDesktopW failed: " + Marshal.GetLastWin32Error());
    try {{
      var si = new STARTUPINFO();
      si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
      si.lpDesktop = "WinSta0\\\\" + desk;
      var sb = new StringBuilder(cmdLine);
      PROCESS_INFORMATION pi;
      if (!CreateProcess(exe, sb, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, null, ref si, out pi)) {{
        throw new Exception("CreateProcessW failed: " + Marshal.GetLastWin32Error());
      }}
      int pid = pi.dwProcessId;
      uint wr = WaitForSingleObject(pi.hProcess, (uint)waitMs);
      uint exitCode = 999999;
      GetExitCodeProcess(pi.hProcess, out exitCode);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      int hiddenWins = CountWins(hDesk, pid);
      int defWins = CountWins(IntPtr.Zero, pid);
      return pid + ":" + hiddenWins + ":" + defWins + ":" + wr + ":" + exitCode;
    }} finally {{
      CloseDesktop(hDesk);
    }}
  }}
}}
'@
{env_block}
[HiddenDeskLaunch]::Go({ps_single_quote(desktop_name)}, {ps_single_quote(exe_win)}, {ps_single_quote(cmd_line)}, {wait_ms})
"""


def _click_script(desktop_name: str, target_pid: int, norm_x: float, norm_y: float) -> str:
    return f"""
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class HiddenDeskClick {{
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT {{ public int Left; public int Top; public int Right; public int Bottom; }}
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr OpenDesktopW(string lpszDesktop, int dwFlags, bool fInherit, uint dwDesiredAccess);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr hDesktop);
  [DllImport("user32.dll")] public static extern bool EnumDesktopWindows(IntPtr hDesktop, EnumWindowsProc lpfn, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc lpfn, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
  public static string ClassOf(IntPtr h) {{
    var sb = new StringBuilder(256); GetClassName(h, sb, sb.Capacity); return sb.ToString();
  }}
  public static string ClickChild(string deskName, int targetPid, double nx, double ny) {{
    SetThreadDpiAwarenessContext(new IntPtr(-4));
    // DESKTOP_ENUMERATE (0x0040) + DESKTOP_READOBJECTS (0x0001) + DESKTOP_WRITEOBJECTS (0x0080)
    IntPtr hDesk = OpenDesktopW(deskName, 0, false, 0x00C1u);
    if (hDesk == IntPtr.Zero) throw new Exception("OpenDesktopW failed: " + Marshal.GetLastWin32Error());
    try {{
      var topWins = new List<IntPtr>();
      EnumDesktopWindows(hDesk, (h, lp) => {{
        uint p; GetWindowThreadProcessId(h, out p);
        if (p == (uint)targetPid) topWins.Add(h);
        return true;
      }}, IntPtr.Zero);
      IntPtr target = IntPtr.Zero;
      IntPtr fallback = IntPtr.Zero;
      foreach (var tw in topWins) {{
        RECT tr;
        if (GetClientRect(tw, out tr) && (tr.Right - tr.Left) > 100 && fallback == IntPtr.Zero) fallback = tw;
        EnumChildWindows(tw, (ch, lp) => {{
          if (ClassOf(ch) == "FLUTTERVIEW") target = ch;
          return true;
        }}, IntPtr.Zero);
      }}
      if (target == IntPtr.Zero) target = fallback;
      if (target == IntPtr.Zero) throw new Exception("No render window found on hidden desktop for pid=" + targetPid);
      RECT r; GetClientRect(target, out r);
      int cx = (int)Math.Round((r.Right - r.Left) * nx);
      int cy = (int)Math.Round((r.Bottom - r.Top) * ny);
      IntPtr lParam = new IntPtr(((cy & 0xFFFF) << 16) | (cx & 0xFFFF));
      PostMessage(target, 0x0200u, IntPtr.Zero, lParam);
      System.Threading.Thread.Sleep(30);
      PostMessage(target, 0x0201u, new IntPtr(1), lParam);
      System.Threading.Thread.Sleep(50);
      PostMessage(target, 0x0202u, IntPtr.Zero, lParam);
      return "DESK_TARGET=" + ClassOf(target) + " CLIENT=" + (r.Right - r.Left) + "x" + (r.Bottom - r.Top) + " CLICK=" + cx + "," + cy;
    }} finally {{
      CloseDesktop(hDesk);
    }}
  }}
}}
'@
[HiddenDeskClick]::ClickChild({ps_single_quote(desktop_name)}, {target_pid}, {norm_x:.6f}, {norm_y:.6f})
"""


class WinHiddenDesktopSession:
    """Context manager holding a secondary Win32 desktop for zero-interference E2E."""

    def __init__(
        self,
        *,
        desktop_name: str = DEFAULT_DESKTOP_NAME,
        keepalive_dir: Path | str | None = None,
        max_seconds: int = 300,
        powershell_bin: str = DEFAULT_POWERSHELL,
        ps_runner: Callable[..., str] = run_powershell,
        popen_fn: Callable[..., Any] = subprocess.Popen,
        win_path_resolver: Callable[[str | Path], str] = to_windows_path,
    ) -> None:
        self.desktop_name = _validate_desktop_name(desktop_name)
        base_dir = Path(keepalive_dir) if keepalive_dir is not None else Path(tempfile.gettempdir())
        self._keepalive_wsl = base_dir / f".parfait_desk_{uuid.uuid4().hex[:10]}.keepalive"
        self._keepalive_win: str | None = None
        self._max_seconds = max_seconds
        self._powershell_bin = powershell_bin
        self._ps_runner = ps_runner
        self._popen_fn = popen_fn
        self._win_path_resolver = win_path_resolver
        self._holder: Any = None
        self._pids: list[int] = []

    def __enter__(self) -> WinHiddenDesktopSession:
        self._keepalive_wsl.parent.mkdir(parents=True, exist_ok=True)
        self._keepalive_wsl.write_text("alive\n", encoding="utf-8")
        self._keepalive_win = self._win_path_resolver(self._keepalive_wsl)
        encoded = base64.b64encode(
            _holder_script(self.desktop_name, self._keepalive_win, self._max_seconds).encode("utf-16-le")
        ).decode("ascii")
        self._holder = self._popen_fn(
            [
                self._powershell_bin,
                "-NoProfile",
                "-NonInteractive",
                "-InputFormat",
                "None",
                "-EncodedCommand",
                encoded,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        deadline = time.time() + 20.0
        while time.time() < deadline:
            if self._holder.poll() is not None:
                err = self._holder.stderr.read() if self._holder.stderr else ""
                raise HiddenDesktopError(
                    f"Desktop holder exited early (rc={self._holder.returncode}): {err.strip()}"
                )
            line = self._holder.stdout.readline().strip() if self._holder.stdout else ""
            if "DESK_READY" in line:
                return self
        err = self._holder.stderr.read() if self._holder.stderr else ""
        raise HiddenDesktopError(f"Timed out waiting for WinSta0\\{self.desktop_name}: {err.strip()}")

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        for pid in reversed(list(self._pids)):
            try:
                self.stop_pid(pid, timeout=8.0)
            except Exception:
                pass
        try:
            if self._keepalive_wsl.exists():
                self._keepalive_wsl.unlink()
        except OSError:
            pass
        if self._holder is not None and self._holder.poll() is None:
            try:
                self._holder.wait(timeout=4.0)
            except Exception:
                self._holder.terminate()

    def launch(
        self,
        exe_path: str | Path,
        args: Sequence[str] = (),
        *,
        env_vars: dict[str, str] | None = None,
        wait_ms: int = 1200,
        require_zero_default: bool = True,
        timeout: float = 35.0,
    ) -> LaunchResult:
        """Spawn a Windows executable onto the isolated desktop."""
        exe_win = self._win_path_resolver(exe_path)
        cmd_line = build_windows_command_line(exe_win, args)
        raw = self._ps_runner(
            _launch_script(self.desktop_name, exe_win, cmd_line, env_vars or {}, wait_ms),
            powershell_bin=self._powershell_bin,
            timeout=timeout,
        )
        line = next((ln.strip() for ln in reversed(raw.splitlines()) if ":" in ln), "")
        parts = line.split(":")
        if len(parts) != 5:
            raise HiddenDesktopError(f"Unexpected launch result output: {raw!r}")
        result = LaunchResult(
            pid=int(parts[0]),
            hidden_windows=int(parts[1]),
            default_windows=int(parts[2]),
            wait_result=int(parts[3]),
            exit_code=int(parts[4]),
        )
        self._pids.append(result.pid)
        if require_zero_default and result.default_windows != 0:
            self.stop_pid(result.pid, timeout=5.0)
            raise HiddenDesktopError(
                f"PID {result.pid} opened {result.default_windows} window(s) on Default desktop"
            )
        return result

    def click_normalized(
        self,
        pid: int,
        norm_x: float,
        norm_y: float,
        *,
        timeout: float = 35.0,
    ) -> str:
        """Send a background mouse click into *pid*'s render window on the hidden desktop."""
        if not (0.0 <= norm_x <= 1.0 and 0.0 <= norm_y <= 1.0):
            raise ValueError(f"Normalized coordinates must be in [0, 1]: ({norm_x}, {norm_y})")
        return self._ps_runner(
            _click_script(self.desktop_name, pid, norm_x, norm_y),
            powershell_bin=self._powershell_bin,
            timeout=timeout,
        )

    def click_bounds(
        self,
        pid: int,
        bounds_result: dict[str, Any],
        viewport: dict[str, Any],
        *,
        timeout: float = 35.0,
    ) -> str:
        """Click the center reported by workbench `findBounds` without touching Default desktop."""
        vp_w = float(viewport["width"])
        vp_h = float(viewport["height"])
        if vp_w <= 0 or vp_h <= 0:
            raise ValueError(f"Invalid viewport dimensions: {viewport!r}")
        norm_x = float(bounds_result["centerX"]) / vp_w
        norm_y = float(bounds_result["centerY"]) / vp_h
        return self.click_normalized(pid, norm_x, norm_y, timeout=timeout)

    def stop_pid(self, pid: int, *, timeout: float = 10.0) -> None:
        """Terminate *pid* and poll until Win32 single-instance locks are released."""
        script = (
            f"Stop-Process -Id {int(pid)} -Force -ErrorAction SilentlyContinue; "
            f"for ($i=0; $i -lt 50; $i++) {{ "
            f"if (-not (Get-Process -Id {int(pid)} -ErrorAction SilentlyContinue)) {{ break }}; "
            f"Start-Sleep -Milliseconds 100 }}; "
            "exit 0"
        )
        self._ps_runner(script, powershell_bin=self._powershell_bin, timeout=timeout)
        time.sleep(0.2)
        if pid in self._pids:
            self._pids.remove(pid)


def kill_matching_parfait_processes(
    path_substring: str,
    *,
    powershell_bin: str = DEFAULT_POWERSHELL,
    ps_runner: Callable[..., str] = run_powershell,
) -> None:
    """Clean up stale dev `parfait.exe` processes matching *path_substring*."""
    if not path_substring.strip():
        raise ValueError("path_substring must not be empty to avoid touching unrelated binaries")
    script = (
        "Get-Process parfait -ErrorAction SilentlyContinue | "
        f"Where-Object {{ $_.Path -like {ps_single_quote('*' + path_substring + '*')} }} | "
        "ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }; "
        "exit 0"
    )
    ps_runner(script, powershell_bin=powershell_bin, timeout=15.0)


def windows_host_env() -> dict[str, str]:
    """Return environment overrides needed when invoking Win32 binaries from WSL."""
    return {k: v for k, v in os.environ.items() if k in ("PARFAIT_DEV_ROOT",)}
