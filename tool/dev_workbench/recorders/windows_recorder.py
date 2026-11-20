"""Windows native automated dynamic recorder.

Default mode (`capture_mode="win32_hidden_desktop"`) runs 100% inside secondary
Win32 desktop `WinSta0\\ParfaitDevHidden` (zero popups or mouse/keyboard
stealing) via an ephemeral compiled C# agent (`/target:winexe`) dispatching real
two-stage `WM_NCHITTEST` -> client/non-client Win32 messages and capturing
frames with `PrintWindow(..., PW_RENDERFULLCONTENT)`.

Opt-in `--with-windows-foreground-shell` runs the `foreground_opt_in` shell
items on the `Default` desktop via physical Win32 `SendInput` + `ffmpeg.exe`
`gdigrab -draw_mouse 1`.
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from ..win_hidden_desktop import (
    DEFAULT_DESKTOP_NAME,
    WinHiddenDesktopSession,
    ps_single_quote,
    run_powershell,
    to_windows_path,
    to_wsl_path,
)
from .common import (
    CommandTimeoutError,
    TargetNotFoundError,
    WorkbenchClient,
    load_catalog,
    split_catalog_phases,
)
from .encoder import encode_frames_to_media, resolve_ffmpeg_exe, verify_media_stream
from .manifest import storyboard_record_fields
from .storyboard import build_storyboard_from_frame_paths

CSC_EXE = "/mnt/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
DEFAULT_WIN_EXE = Path("/mnt/e/dev/parfait-win/build/windows/x64/runner/Debug/parfait.exe")

_NCHITTEST_NAMES = {
    -2: "HTERROR",
    -1: "HTTRANSPARENT",
    0: "HTNOWHERE",
    1: "HTCLIENT",
    2: "HTCAPTION",
    3: "HTSYSMENU",
    8: "HTMINBUTTON",
    9: "HTMAXBUTTON",
    10: "HTLEFT",
    11: "HTRIGHT",
    12: "HTTOP",
    13: "HTTOPLEFT",
    14: "HTTOPRIGHT",
    15: "HTBOTTOM",
    16: "HTBOTTOMLEFT",
    17: "HTBOTTOMRIGHT",
    20: "HTCLOSE",
}

_WIN_AGENT_CS = r"""
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class ParfaitWinAgent {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT {
    public uint type;
    public MOUSEKEYBDHARDWAREINPUT u;
  }
  [StructLayout(LayoutKind.Explicit)] public struct MOUSEKEYBDHARDWAREINPUT {
    [FieldOffset(0)] public MOUSEINPUT mi;
  }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx, dy;
    public uint mouseData, dwFlags, time;
    public IntPtr dwExtraInfo;
  }

  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint tid);
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr OpenDesktopW(string lpszDesktop, int dwFlags, bool fInherit, uint dwDesiredAccess);
  [DllImport("user32.dll")] public static extern bool SetThreadDesktop(IntPtr hDesktop);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool EnumDesktopWindows(IntPtr hDesk, EnumWindowsProc lpfn, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc lpfn, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int cap);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT pt);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint SendInput(uint cInputs, INPUT[] pInputs, int cbSize);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);

  const uint WM_NCHITTEST = 0x0084;
  const uint WM_NCMOUSEMOVE = 0x00A0;
  const uint WM_NCLBUTTONDOWN = 0x00A1;
  const uint WM_NCLBUTTONUP = 0x00A2;
  const uint WM_NCLBUTTONDBLCLK = 0x00A3;
  const uint WM_MOUSEMOVE = 0x0200;
  const uint WM_LBUTTONDOWN = 0x0201;
  const uint WM_LBUTTONUP = 0x0202;
  const uint WM_LBUTTONDBLCLK = 0x0203;
  const uint WM_RBUTTONDOWN = 0x0204;
  const uint WM_RBUTTONUP = 0x0205;
  const uint WM_MOUSEWHEEL = 0x020A;
  const uint WM_KEYDOWN = 0x0100;
  const uint WM_KEYUP = 0x0101;
  const uint WM_CHAR = 0x0102;
  const uint WM_SETFOCUS = 0x0007;

  static volatile bool _capturing = false;
  static Thread _capThread = null;
  static IntPtr _hDesk = IntPtr.Zero;
  static readonly object _cursorLock = new object();
  static double _curX = -1, _curY = -1;
  static string _curLabel = "";

  static string ClassOf(IntPtr h) {
    var sb = new StringBuilder(128);
    GetClassName(h, sb, sb.Capacity);
    return sb.ToString();
  }

  static bool FindWindows(int pid, out IntPtr topHwnd, out IntPtr viewHwnd) {
    topHwnd = IntPtr.Zero;
    viewHwnd = IntPtr.Zero;
    IntPtr bestTop = IntPtr.Zero;
    int bestArea = -1;
    var tops = new List<IntPtr>();
    IntPtr desk = _hDesk != IntPtr.Zero ? _hDesk : GetThreadDesktop(GetCurrentThreadId());
    EnumDesktopWindows(desk, (h, l) => {
      uint p;
      GetWindowThreadProcessId(h, out p);
      if (p == (uint)pid) tops.Add(h);
      return true;
    }, IntPtr.Zero);
    foreach (var h in tops) {
      if (ClassOf(h) == "FLUTTER_RUNNER_WIN32_WINDOW") {
        bestTop = h;
        break;
      }
      RECT r;
      if (!GetClientRect(h, out r)) continue;
      int area = Math.Max(0, r.Right - r.Left) * Math.Max(0, r.Bottom - r.Top);
      if (area > bestArea && (IsWindowVisible(h) || area > 10000)) {
        bestArea = area;
        bestTop = h;
      }
    }
    if (bestTop == IntPtr.Zero) return false;
    topHwnd = bestTop;
    IntPtr foundView = IntPtr.Zero;
    EnumChildWindows(topHwnd, (ch, l) => {
      if (ClassOf(ch) == "FLUTTERVIEW") {
        foundView = ch;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    viewHwnd = foundView != IntPtr.Zero ? foundView : topHwnd;
    return true;
  }

  static IntPtr MakeLParam(int x, int y) {
    return new IntPtr(((y & 0xFFFF) << 16) | (x & 0xFFFF));
  }

  static double DpiScale(IntPtr hwnd) {
    uint dpi = GetDpiForWindow(hwnd);
    return dpi > 0 ? dpi / 96.0 : 1.0;
  }

  static void HitTest(IntPtr topHwnd, IntPtr viewHwnd, double lx, double ly, out int sx, out int sy, out int childHit, out int topHit, out POINT clientPt) {
    double scale = DpiScale(topHwnd);
    POINT origin = new POINT { X = 0, Y = 0 };
    ClientToScreen(topHwnd, ref origin);
    sx = origin.X + (int)Math.Round(lx * scale);
    sy = origin.Y + (int)Math.Round(ly * scale);
    IntPtr lpScreen = MakeLParam(sx, sy);
    childHit = viewHwnd != topHwnd ? (int)(long)SendMessage(viewHwnd, WM_NCHITTEST, IntPtr.Zero, lpScreen) : -1;
    topHit = childHit == -1 ? (int)(long)SendMessage(topHwnd, WM_NCHITTEST, IntPtr.Zero, lpScreen) : childHit;
    clientPt = new POINT { X = sx, Y = sy };
    ScreenToClient(viewHwnd, ref clientPt);
  }

  static void UpdateOverlay(double lx, double ly, string label) {
    lock (_cursorLock) {
      _curX = lx;
      _curY = ly;
      _curLabel = label ?? "";
    }
  }

  static void SendAbsMouse(int sx, int sy, uint flags) {
    int vsX = GetSystemMetrics(76); // SM_XVIRTUALSCREEN
    int vsY = GetSystemMetrics(77); // SM_YVIRTUALSCREEN
    int vsW = Math.Max(1, GetSystemMetrics(78)); // SM_CXVIRTUALSCREEN
    int vsH = Math.Max(1, GetSystemMetrics(79)); // SM_CYVIRTUALSCREEN
    int nx = (int)Math.Round((sx - vsX) * 65535.0 / Math.Max(1, vsW - 1));
    int ny = (int)Math.Round((sy - vsY) * 65535.0 / Math.Max(1, vsH - 1));
    var inp = new INPUT[1];
    inp[0].type = 0; // INPUT_MOUSE
    inp[0].u.mi.dx = nx;
    inp[0].u.mi.dy = ny;
    inp[0].u.mi.dwFlags = flags | 0x8000u | 0x4000u; // ABSOLUTE | VIRTUALDESK
    SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
  }

  static int ResolveVk(string name, out bool ctrl, out bool alt) {
    ctrl = false; alt = false;
    string k = name;
    if (k.StartsWith("Ctrl+", StringComparison.OrdinalIgnoreCase)) { ctrl = true; k = k.Substring(5); }
    if (k.StartsWith("Alt+", StringComparison.OrdinalIgnoreCase)) { alt = true; k = k.Substring(4); }
    switch (k) {
      case "Escape": return 0x1B;
      case "F11": return 0x7A;
      case "Left": return 0x25;
      case "Right": return 0x27;
      case "Space": return 0x20;
      case "PageUp": return 0x21;
      case "PageDown": return 0x22;
      case "Back": alt = true; return 0x25;
      default:
        if (k.Length == 1) return char.ToUpperInvariant(k[0]);
        return 0;
    }
  }

  static void StartCapture(int pid, string outDir, int fps, bool drawOverlay) {
    StopCapture();
    Directory.CreateDirectory(outDir);
    _capturing = true;
    _capThread = new Thread(() => {
      if (_hDesk != IntPtr.Zero) SetThreadDesktop(_hDesk);
      SetThreadDpiAwarenessContext(new IntPtr(-4));
      int idx = 0;
      int interval = Math.Max(16, 1000 / Math.Max(1, fps));
      var sw = Stopwatch.StartNew();
      while (_capturing) {
        long tickStart = sw.ElapsedMilliseconds;
        IntPtr top, view;
        if (FindWindows(pid, out top, out view)) {
          RECT wr;
          if (GetWindowRect(top, out wr)) {
            int w = Math.Max(2, wr.Right - wr.Left);
            int h = Math.Max(2, wr.Bottom - wr.Top);
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
              using (var g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                PrintWindow(top, hdc, 2); // PW_RENDERFULLCONTENT
                g.ReleaseHdc(hdc);
                if (drawOverlay) {
                  double cx, cy; string lbl;
                  lock (_cursorLock) { cx = _curX; cy = _curY; lbl = _curLabel; }
                  if (cx >= 0 && cy >= 0) {
                    double scale = DpiScale(top);
                    POINT cl = new POINT { X = 0, Y = 0 };
                    ClientToScreen(top, ref cl);
                    int ox = (cl.X - wr.Left) + (int)Math.Round(cx * scale);
                    int oy = (cl.Y - wr.Top) + (int)Math.Round(cy * scale);
                    using (var pen = new Pen(Color.FromArgb(220, 255, 64, 64), 2f)) {
                      g.DrawEllipse(pen, ox - 8, oy - 8, 16, 16);
                    }
                    if (!string.IsNullOrEmpty(lbl)) {
                      using (var bg = new SolidBrush(Color.FromArgb(200, 15, 20, 27)))
                      using (var fg = new SolidBrush(Color.FromArgb(255, 255, 230, 100)))
                      using (var font = new Font("Segoe UI", 10f, FontStyle.Bold)) {
                        int lx = Math.Max(4, Math.Min(w - 190, ox + 12));
                        int ly = Math.Max(4, Math.Min(h - 26, oy + 12));
                        g.FillRectangle(bg, lx, ly, 184, 22);
                        g.DrawString(lbl, font, fg, lx + 4, ly + 2);
                      }
                    }
                  }
                }
              }
              string path = Path.Combine(outDir, string.Format("f{0:D4}.png", idx++));
              bmp.Save(path, ImageFormat.Png);
            }
          }
        }
        int spent = (int)(sw.ElapsedMilliseconds - tickStart);
        int wait = interval - spent;
        if (wait > 0) Thread.Sleep(wait);
      }
    });
    _capThread.IsBackground = true;
    _capThread.Start();
  }

  static void StopCapture() {
    _capturing = false;
    if (_capThread != null) {
      _capThread.Join(3000);
      _capThread = null;
    }
  }

  public static int Main(string[] args) {
    SetThreadDpiAwarenessContext(new IntPtr(-4));
    string host = "127.0.0.1";
    int port = 0;
    string token = "";
    string desktopName = "";
    for (int i = 0; i + 1 < args.Length; i += 2) {
      if (args[i] == "--host") host = args[i + 1];
      else if (args[i] == "--port") port = int.Parse(args[i + 1]);
      else if (args[i] == "--token") token = args[i + 1];
      else if (args[i] == "--desktop") desktopName = args[i + 1];
    }
    if (port <= 0) return 2;
    if (!string.IsNullOrEmpty(desktopName)) {
      _hDesk = OpenDesktopW(desktopName, 0, false, 0x01FFu);
      if (_hDesk == IntPtr.Zero || !SetThreadDesktop(_hDesk)) return 3;
    }

    using (var client = new TcpClient(host, port))
    using (var ns = client.GetStream())
    using (var reader = new StreamReader(ns, Encoding.UTF8))
    using (var writer = new StreamWriter(ns, new UTF8Encoding(false)) { AutoFlush = true }) {
      writer.WriteLine("AUTH " + token);
      string line;
      while ((line = reader.ReadLine()) != null) {
        string[] p = line.Split(new char[] { ' ' });
        string cmd = p[0];
        try {
          if (cmd == "QUIT") { StopCapture(); writer.WriteLine("OK"); break; }
          if (cmd == "PING") { writer.WriteLine("OK PONG"); continue; }
          if (cmd == "PROBE") {
            int pid = int.Parse(p[1]);
            IntPtr top, view;
            if (!FindWindows(pid, out top, out view)) { writer.WriteLine("ERR NO_WINDOW"); continue; }
            RECT wr, cr; GetWindowRect(top, out wr); GetClientRect(top, out cr);
            POINT co = new POINT { X = 0, Y = 0 }; ClientToScreen(top, ref co);
            writer.WriteLine(string.Format("OK {0} {1} {2} {3} {4} {5} {6} {7}",
              wr.Left, wr.Top, wr.Right - wr.Left, wr.Bottom - wr.Top,
              co.X, co.Y, cr.Right - cr.Left, cr.Bottom - cr.Top));
            continue;
          }
          if (cmd == "RESTORE") {
            int pid = int.Parse(p[1]);
            IntPtr top, view;
            if (!FindWindows(pid, out top, out view)) { writer.WriteLine("ERR NO_WINDOW"); continue; }
            ShowWindow(top, 9); // SW_RESTORE
            writer.WriteLine("OK");
            continue;
          }
          if (cmd == "HIT") {
            int pid = int.Parse(p[1]);
            double lx = double.Parse(p[2], System.Globalization.CultureInfo.InvariantCulture);
            double ly = double.Parse(p[3], System.Globalization.CultureInfo.InvariantCulture);
            IntPtr top, view;
            if (!FindWindows(pid, out top, out view)) { writer.WriteLine("ERR NO_WINDOW"); continue; }
            int sx, sy, chit, thit; POINT cpt;
            HitTest(top, view, lx, ly, out sx, out sy, out chit, out thit, out cpt);
            writer.WriteLine(string.Format("OK {0} {1} {2} {3}", chit, thit, sx, sy));
            continue;
          }
          if (cmd == "CAP_START") {
            int pid = int.Parse(p[1]);
            string dir = Encoding.UTF8.GetString(Convert.FromBase64String(p[2]));
            int fps = int.Parse(p[3]);
            bool drawOverlay = p.Length > 4 && p[4] == "1";
            UpdateOverlay(-1, -1, "");
            StartCapture(pid, dir, fps, drawOverlay);
            writer.WriteLine("OK");
            continue;
          }
          if (cmd == "CAP_STOP") {
            StopCapture();
            writer.WriteLine("OK");
            continue;
          }
          if (cmd == "MOVE" || cmd == "CLICK" || cmd == "DBL" || cmd == "RCLICK" || cmd == "DRAG" || cmd == "WHEEL") {
            int pid = int.Parse(p[1]);
            double lx = double.Parse(p[2], System.Globalization.CultureInfo.InvariantCulture);
            double ly = double.Parse(p[3], System.Globalization.CultureInfo.InvariantCulture);
            bool fg = p.Length > 4 && p[4] == "fg";
            IntPtr top, view;
            if (!FindWindows(pid, out top, out view)) { writer.WriteLine("ERR NO_WINDOW"); continue; }
            int sx, sy, chit, thit; POINT cpt;
            HitTest(top, view, lx, ly, out sx, out sy, out chit, out thit, out cpt);
            UpdateOverlay(lx, ly, string.Format("HIT:{0}({1})", thit, chit));

            if (fg) {
              SetForegroundWindow(top);
              if (cmd == "MOVE") SendAbsMouse(sx, sy, 0x0001u);
              else if (cmd == "CLICK") {
                SendAbsMouse(sx, sy, 0x0001u); Thread.Sleep(40);
                SendAbsMouse(sx, sy, 0x0002u); Thread.Sleep(50);
                SendAbsMouse(sx, sy, 0x0004u);
              } else if (cmd == "DBL") {
                SendAbsMouse(sx, sy, 0x0001u); Thread.Sleep(30);
                SendAbsMouse(sx, sy, 0x0002u); Thread.Sleep(30); SendAbsMouse(sx, sy, 0x0004u); Thread.Sleep(60);
                SendAbsMouse(sx, sy, 0x0002u); Thread.Sleep(30); SendAbsMouse(sx, sy, 0x0004u);
              } else if (cmd == "RCLICK") {
                SendAbsMouse(sx, sy, 0x0001u); Thread.Sleep(40);
                SendAbsMouse(sx, sy, 0x0008u); Thread.Sleep(40); SendAbsMouse(sx, sy, 0x0010u);
              } else if (cmd == "DRAG") {
                double lx2 = double.Parse(p[5], System.Globalization.CultureInfo.InvariantCulture);
                double ly2 = double.Parse(p[6], System.Globalization.CultureInfo.InvariantCulture);
                double sc = DpiScale(top);
                POINT o = new POINT { X = 0, Y = 0 }; ClientToScreen(top, ref o);
                int sx2 = o.X + (int)Math.Round(lx2 * sc), sy2 = o.Y + (int)Math.Round(ly2 * sc);
                SendAbsMouse(sx, sy, 0x0001u); Thread.Sleep(30);
                SendAbsMouse(sx, sy, 0x0002u);
                for (int s = 1; s <= 12; s++) {
                  int ix = sx + (sx2 - sx) * s / 12, iy = sy + (sy2 - sy) * s / 12;
                  SendAbsMouse(ix, iy, 0x0001u);
                  Thread.Sleep(28);
                }
                SendAbsMouse(sx2, sy2, 0x0004u);
              }
              writer.WriteLine(string.Format("OK {0} {1}", chit, thit));
              continue;
            }

            IntPtr lpS = MakeLParam(sx, sy);
            IntPtr lpC = MakeLParam(cpt.X, cpt.Y);
            if (cmd == "MOVE") {
              if (thit != 1 && chit == -1) PostMessage(top, WM_NCMOUSEMOVE, new IntPtr(thit), lpS);
              else PostMessage(view, WM_MOUSEMOVE, IntPtr.Zero, lpC);
            } else if (cmd == "CLICK") {
              if (thit != 1 && chit == -1) {
                PostMessage(top, WM_NCMOUSEMOVE, new IntPtr(thit), lpS); Thread.Sleep(30);
                PostMessage(top, WM_NCLBUTTONDOWN, new IntPtr(thit), lpS); Thread.Sleep(45);
                PostMessage(top, WM_NCLBUTTONUP, new IntPtr(thit), lpS);
              } else {
                PostMessage(view, WM_MOUSEMOVE, IntPtr.Zero, lpC); Thread.Sleep(30);
                PostMessage(view, WM_LBUTTONDOWN, new IntPtr(1), lpC); Thread.Sleep(50);
                PostMessage(view, WM_LBUTTONUP, IntPtr.Zero, lpC);
              }
            } else if (cmd == "DBL") {
              if (thit != 1 && chit == -1) {
                PostMessage(top, WM_NCLBUTTONDBLCLK, new IntPtr(thit), lpS);
              } else {
                PostMessage(view, WM_LBUTTONDBLCLK, new IntPtr(1), lpC);
                Thread.Sleep(30);
                PostMessage(view, WM_LBUTTONUP, IntPtr.Zero, lpC);
              }
            } else if (cmd == "RCLICK") {
              PostMessage(view, WM_MOUSEMOVE, IntPtr.Zero, lpC); Thread.Sleep(30);
              PostMessage(view, WM_RBUTTONDOWN, new IntPtr(2), lpC); Thread.Sleep(45);
              PostMessage(view, WM_RBUTTONUP, IntPtr.Zero, lpC);
            } else if (cmd == "WHEEL") {
              int delta = int.Parse(p[5]);
              PostMessage(view, WM_MOUSEMOVE, IntPtr.Zero, lpC);
              PostMessage(view, WM_MOUSEWHEEL, new IntPtr((delta & 0xFFFF) << 16), lpS);
            } else if (cmd == "DRAG") {
              double lx2 = double.Parse(p[5], System.Globalization.CultureInfo.InvariantCulture);
              double ly2 = double.Parse(p[6], System.Globalization.CultureInfo.InvariantCulture);
              double sc = DpiScale(top);
              POINT orig = new POINT { X = 0, Y = 0 }; ClientToScreen(top, ref orig);
              int sx2 = orig.X + (int)Math.Round(lx2 * sc), sy2 = orig.Y + (int)Math.Round(ly2 * sc);
              POINT cpt2 = new POINT { X = sx2, Y = sy2 }; ScreenToClient(view, ref cpt2);
              PostMessage(view, WM_LBUTTONDOWN, new IntPtr(1), lpC);
              for (int s = 1; s <= 12; s++) {
                int cx = cpt.X + (cpt2.X - cpt.X) * s / 12;
                int cy = cpt.Y + (cpt2.Y - cpt.Y) * s / 12;
                PostMessage(view, WM_MOUSEMOVE, new IntPtr(1), MakeLParam(cx, cy));
                Thread.Sleep(25);
              }
              PostMessage(view, WM_LBUTTONUP, IntPtr.Zero, MakeLParam(cpt2.X, cpt2.Y));
            }
            writer.WriteLine(string.Format("OK {0} {1}", chit, thit));
            continue;
          }
          if (cmd == "KEY") {
            int pid = int.Parse(p[1]);
            string keyName = p[2];
            bool fgKey = p.Length > 3 && p[3] == "fg";
            IntPtr top, view;
            if (!FindWindows(pid, out top, out view)) { writer.WriteLine("ERR NO_WINDOW"); continue; }
            bool ctrl, alt;
            int vk = ResolveVk(keyName, out ctrl, out alt);
            if (vk == 0) { writer.WriteLine("OK SKIP"); continue; }
            SendMessage(view, WM_SETFOCUS, IntPtr.Zero, IntPtr.Zero);
            if (fgKey && ctrl) keybd_event(0x11, 0, 0, UIntPtr.Zero);
            if (fgKey && alt) keybd_event(0x12, 0, 0, UIntPtr.Zero);
            PostMessage(view, WM_KEYDOWN, new IntPtr(vk), IntPtr.Zero);
            Thread.Sleep(35);
            PostMessage(view, WM_KEYUP, new IntPtr(vk), new IntPtr(unchecked((int)0xC0000001)));
            if (fgKey && alt) keybd_event(0x12, 0, 2, UIntPtr.Zero);
            if (fgKey && ctrl) keybd_event(0x11, 0, 2, UIntPtr.Zero);
            writer.WriteLine("OK");
            continue;
          }
          if (cmd == "TEXT") {
            int pid = int.Parse(p[1]);
            string txt = Encoding.UTF8.GetString(Convert.FromBase64String(p[2]));
            IntPtr top, view;
            if (!FindWindows(pid, out top, out view)) { writer.WriteLine("ERR NO_WINDOW"); continue; }
            SendMessage(view, WM_SETFOCUS, IntPtr.Zero, IntPtr.Zero);
            foreach (char ch in txt) {
              PostMessage(view, WM_CHAR, new IntPtr(ch), IntPtr.Zero);
              Thread.Sleep(15);
            }
            writer.WriteLine("OK");
            continue;
          }
          if (cmd == "ANNOTATE") {
            string pngPath = Encoding.UTF8.GetString(Convert.FromBase64String(p[1]));
            double lx = double.Parse(p[2], System.Globalization.CultureInfo.InvariantCulture);
            double ly = double.Parse(p[3], System.Globalization.CultureInfo.InvariantCulture);
            double sc = double.Parse(p[4], System.Globalization.CultureInfo.InvariantCulture);
            string lbl = p.Length > 5 ? Encoding.UTF8.GetString(Convert.FromBase64String(p[5])) : "";
            byte[] rawBytes = File.ReadAllBytes(pngPath);
            using (var ms = new MemoryStream(rawBytes))
            using (var src = new Bitmap(ms))
            using (var bmp = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb)) {
              using (var g = Graphics.FromImage(bmp)) {
                g.DrawImage(src, 0, 0, src.Width, src.Height);
                if (lx >= 0 && ly >= 0) {
                  int ox = (int)Math.Round(lx * sc);
                  int oy = (int)Math.Round(ly * sc);
                  using (var pen = new Pen(Color.FromArgb(235, 255, 64, 64), 3f)) {
                    g.DrawEllipse(pen, ox - 10, oy - 10, 20, 20);
                  }
                  if (!string.IsNullOrEmpty(lbl)) {
                    using (var bg = new SolidBrush(Color.FromArgb(215, 15, 20, 27)))
                    using (var fg = new SolidBrush(Color.FromArgb(255, 255, 230, 100)))
                    using (var font = new Font("Segoe UI", 11f, FontStyle.Bold)) {
                      int boxX = Math.Max(4, Math.Min(bmp.Width - 210, ox + 14));
                      int boxY = Math.Max(4, Math.Min(bmp.Height - 28, oy + 14));
                      g.FillRectangle(bg, boxX, boxY, 202, 24);
                      g.DrawString(lbl, font, fg, boxX + 5, boxY + 3);
                    }
                  }
                }
              }
              bmp.Save(pngPath, ImageFormat.Png);
            }
            writer.WriteLine("OK");
            continue;
          }
          writer.WriteLine("ERR UNKNOWN_CMD");
        } catch (Exception ex) {
          writer.WriteLine("ERR " + ex.Message.Replace('\n', ' ').Replace('\r', ' '));
        }
      }
    }
    return 0;
  }
}
"""


def _compile_win_agent(stage_wsl: Path) -> Path:
    exe_wsl = stage_wsl / "win_agent.exe"
    cs_wsl = stage_wsl / "win_agent.cs"
    if (
        exe_wsl.is_file()
        and cs_wsl.is_file()
        and cs_wsl.read_text(encoding="utf-8") == _WIN_AGENT_CS
    ):
        return exe_wsl
    stage_wsl.mkdir(parents=True, exist_ok=True)
    cs_wsl.write_text(_WIN_AGENT_CS, encoding="utf-8")
    res = subprocess.run(
        [
            CSC_EXE,
            "/nologo",
            "/optimize+",
            "/target:winexe",
            f"/out:{to_windows_path(exe_wsl)}",
            "/reference:System.Drawing.dll",
            "/reference:System.Windows.Forms.dll",
            to_windows_path(cs_wsl),
        ],
        cwd="/mnt/c",
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=25.0,
    )
    if res.returncode != 0 or not exe_wsl.is_file():
        raise RuntimeError(f"csc.exe compile failed: {res.stdout}\n{res.stderr}")
    return exe_wsl


class _WinAgentClient:
    """Maintains persistent TCP control channel to `win_agent.exe`."""

    def __init__(self, conn: socket.socket) -> None:
        self._conn = conn
        self._fp = conn.makefile("r", encoding="utf-8", errors="replace")

    def cmd(self, text: str) -> str:
        self._conn.sendall((text + "\n").encode("utf-8"))
        line = self._fp.readline()
        if not line:
            raise RuntimeError("win_agent connection closed unexpectedly")
        line = line.rstrip("\r\n")
        if line.startswith("ERR "):
            raise RuntimeError(f"win_agent {text.split()[0]} error: {line[4:]}")
        return line

    def close(self) -> None:
        try:
            self._conn.sendall(b"QUIT\n")
        except Exception:
            pass
        try:
            self._fp.close()
            self._conn.close()
        except Exception:
            pass


def _spawn_win_agent(
    agent_exe: Path,
    *,
    desk: WinHiddenDesktopSession | None,
) -> _WinAgentClient:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    srv.settimeout(20.0)
    port = srv.getsockname()[1]
    tok = secrets.token_hex(16)
    try:
        args = ["--host", "127.0.0.1", "--port", str(port), "--token", tok]
        if desk is not None:
            args.extend(["--desktop", desk.desktop_name])
        subprocess.Popen(
            [str(agent_exe), *args],
            cwd="/mnt/c",
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        conn, _ = srv.accept()
        conn.settimeout(25.0)
        fp = conn.makefile("r", encoding="utf-8", errors="replace")
        auth = fp.readline().strip()
        fp.close()
        if auth != f"AUTH {tok}":
            conn.close()
            raise RuntimeError("win_agent failed auth handshake")
        return _WinAgentClient(conn)
    finally:
        srv.close()


def _hit_info(line: str) -> dict[str, Any]:
    parts = line.split()
    if len(parts) >= 3 and parts[0] == "OK":
        chit = int(parts[1])
        thit = int(parts[2])
        return {
            "nchittest_child": chit,
            "nchittest_top": thit,
            "nchittest_name": _NCHITTEST_NAMES.get(thit, str(thit)),
        }
    return {}


def _execute_windows_step(
    wb: WorkbenchClient,
    client_id: str,
    agent: _WinAgentClient,
    pid: int,
    snap: dict[str, Any],
    base_target: dict[str, Any],
    step: dict[str, Any],
    *,
    foreground: bool,
    diag: dict[str, Any],
) -> None:
    stype = step["type"]
    step_target = step.get("target") or base_target
    mode_tag = "fg" if foreground else "bg"

    if stype == "wait_ms":
        time.sleep(max(0.05, float(step.get("ms", 300)) / 1000.0))
        return
    if stype == "navigate":
        wb.navigate(client_id, str(step["path"]), settle_sec=0.55)
        return
    if stype == "fault":
        if step.get("reset"):
            wb.reset_faults()
        else:
            wb.set_fault(str(step["routePrefix"]), str(step["mode"]))
        return
    if stype == "resize_window":
        wb.send_command(client_id, "resizeWindow", {"width": step["width"], "height": step["height"]}, timeout=10.0)
        time.sleep(0.4)
        return
    if stype == "key":
        agent.cmd(f"KEY {pid} {step.get('key', '')} {mode_tag}")
        time.sleep(0.25)
        return
    if stype == "type_text":
        b64 = base64.b64encode(str(step.get("text", "")).encode("utf-8")).decode("ascii")
        agent.cmd(f"TEXT {pid} {b64}")
        time.sleep(0.25)
        return

    try:
        override = (
            float(step["offset_x_ratio"]) if "offset_x_ratio" in step else float(step_target.get("offset_x_ratio", 0.5)),
            float(step["offset_y_ratio"]) if "offset_y_ratio" in step else float(step_target.get("offset_y_ratio", 0.5)),
        )
        pt = wb.resolve_target(client_id, step_target, snap, override_offsets=override)
    except TargetNotFoundError:
        if stype == "scroll" and step.get("target") is None:
            pt = wb.resolve_target(client_id, {"kind": "viewport_ratio", "x_ratio": 0.5, "y_ratio": 0.55}, snap)
        elif step.get("optional"):
            return
        else:
            raise

    lx, ly = f"{pt['x']:.2f}", f"{pt['y']:.2f}"
    hit_res = ""
    if stype in ("tap", "click"):
        hit_res = agent.cmd(f"CLICK {pid} {lx} {ly} {mode_tag}")
    elif stype == "double_click":
        hit_res = agent.cmd(f"DBL {pid} {lx} {ly} {mode_tag}")
    elif stype in ("right_click", "context_action"):
        hit_res = agent.cmd(f"RCLICK {pid} {lx} {ly} {mode_tag}")
    elif stype == "hover":
        hit_res = agent.cmd(f"MOVE {pid} {lx} {ly} {mode_tag}")
        time.sleep(max(0.15, float(step.get("duration_ms", 500)) / 1000.0))
    elif stype == "scroll":
        dy = float(step.get("dy", -240))
        ticks = max(1, min(8, round(abs(dy) / 120.0)))
        delta = -120 if dy < 0 else 120
        for _ in range(ticks):
            hit_res = agent.cmd(f"WHEEL {pid} {lx} {ly} {mode_tag} {delta}")
            time.sleep(0.05)
    elif stype in ("drag", "swipe"):
        dx = float(step.get("dx_ratio", 0.0)) * float(pt["vw"])
        dy = float(step.get("dy_ratio", 0.0)) * float(pt["vh"])
        lx2 = max(1.0, min(float(pt["vw"]) - 1.0, float(pt["x"]) + dx))
        ly2 = max(1.0, min(float(pt["vh"]) - 1.0, float(pt["y"]) + dy))
        hit_res = agent.cmd(f"DRAG {pid} {lx} {ly} {mode_tag} {lx2:.2f} {ly2:.2f}")
    if hit_res:
        info = _hit_info(hit_res)
        diag.update(info)
        lbl = f"{info.get('nchittest_name', '')}({info.get('nchittest_top', '')})" if info else ""
        diag["_cursor"] = (float(pt["x"]), float(pt["y"]), float(pt.get("dpr", 1.0)), lbl)
    time.sleep(0.2)


def _encode_ntfs_frames(
    frames_wsl: Path,
    out_path: Path,
    fmt: str,
    fps: int,
    *,
    sheet_dir: Path | None = None,
    direction: str = "one_way",
) -> dict[str, Any]:
    pngs = sorted(frames_wsl.glob("f*.png"))
    if not pngs:
        raise RuntimeError("No frames captured by win_agent")
    if len(pngs) == 1:
        shutil.copy2(pngs[0], frames_wsl / "f0001.png")
    ffmpeg = resolve_ffmpeg_exe()
    win_in = to_windows_path(frames_wsl) + r"\f%04d.png"
    staged_out = frames_wsl / f"encoded.{fmt}"
    win_out = to_windows_path(staged_out)
    if fmt == "mp4":
        vargs = ["-r", "10", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-preset", "fast", "-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    else:
        vargs = ["-vf", f"fps={min(max(fps, 2), 20)},scale=trunc(iw/2)*2:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=192:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5"]
    res = subprocess.run(
        [ffmpeg, "-y", "-v", "error", "-framerate", str(fps), "-i", win_in, *vargs, win_out],
        cwd="/mnt/c",
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60.0,
    )
    if res.returncode != 0:
        raise RuntimeError(f"ffmpeg windows encode failed: {res.stderr.strip()}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(staged_out, out_path)
    ok, err, w, h = verify_media_stream(out_path)
    sheet_paths: list[Path] = []
    motion_metrics: dict[str, Any] = {}
    if sheet_dir is not None and ok:
        sheet_paths, motion_metrics = build_storyboard_from_frame_paths(
            pngs,
            sheet_dir,
            fps=fps,
            direction=direction,
        )
    return {
        "width": w,
        "height": h,
        "bytes": out_path.stat().st_size if out_path.is_file() else 0,
        "duration_ms": max(150, round(len(pngs) * 1000.0 / max(1, fps))),
        "decode_verified": ok,
        "decode_error": err,
        "frame_count": len(pngs),
        "sheet_paths": tuple(sheet_paths),
        "motion_metrics": motion_metrics,
    }


def run_windows_recording(
    wb: WorkbenchClient,
    workbench_url: str,
    token: str,
    run_dir: Path,
    *,
    win_exe: Path = DEFAULT_WIN_EXE,
    with_foreground_shell: bool = False,
    catalog_ids: set[str] | None = None,
) -> list[dict[str, Any]]:
    if not win_exe.is_file():
        raise FileNotFoundError(f"Windows dev executable not found: {win_exe}")

    items = load_catalog()
    if catalog_ids is not None:
        items = [it for it in items if it["id"] in catalog_ids]

    pre_items, signed_items, na_or_skipped = split_catalog_phases(
        items,
        platform="windows",
        include_foreground_opt_in=with_foreground_shell,
    )

    records: list[dict[str, Any]] = []
    for it in na_or_skipped:
        rule = str((it.get("platforms") or {}).get("windows", ""))
        if rule.startswith("foreground_opt_in:"):
            records.append({
                "catalog_id": it["id"],
                "module": it.get("module"),
                "route_template": it.get("route_template"),
                "shell_layer": it.get("shell_layer"),
                "audit_candidate": it.get("audit_candidate"),
                "direction": it.get("direction"),
                "platform": "windows",
                "evidence_kind": "skipped",
                "capture_mode": "skipped_foreground_only",
                "status": "skipped_foreground_only",
                "artifact_relpath": None,
                "decode_verified": False,
                "diagnostics": {"reason": rule, "hint": "Pass --with-windows-foreground-shell to record on Default desktop"},
                "known_blind_spots": [],
            })
        else:
            records.append({
                "catalog_id": it["id"],
                "module": it.get("module"),
                "route_template": it.get("route_template"),
                "shell_layer": it.get("shell_layer"),
                "audit_candidate": it.get("audit_candidate"),
                "direction": it.get("direction"),
                "platform": "windows",
                "evidence_kind": "not_applicable",
                "capture_mode": "not_applicable",
                "status": "not_applicable",
                "artifact_relpath": None,
                "decode_verified": False,
                "diagnostics": {"reason": rule},
                "known_blind_spots": [],
            })

    # Stage inside Windows %TEMP% so csc.exe & ffmpeg.exe perform local NTFS IO
    win_temp_raw = run_powershell("[IO.Path]::GetTempPath()").strip().splitlines()[-1].strip()
    win_stage_root = to_wsl_path(win_temp_raw) / f"parfait_win_rec_{uuid.uuid4().hex[:8]}"
    win_stage_root.mkdir(parents=True, exist_ok=True)

    try:
        agent_exe = _compile_win_agent(win_stage_root / "agent")

        def _launch_hidden(desk: WinHiddenDesktopSession, prof: str, *, fresh: bool) -> tuple[int, str]:
            dev_root = win_stage_root / "profiles" / prof
            dev_root.mkdir(parents=True, exist_ok=True)
            args = [
                f"--dev-profile={prof}",
                "--source=loopback",
                f"--loopback={workbench_url}",
                f"--workbench-url={workbench_url}",
                f"--workbench-token={token}",
            ]
            if fresh:
                args.append("--fresh-onboarding")
            env = {
                "PARFAIT_DEV_PROFILE": "1",
                "PARFAIT_DEV_INSTANCE": "1",
                "PARFAIT_DEV_ROOT": to_windows_path(dev_root),
            }
            res = desk.launch(win_exe, args, env_vars=env, wait_ms=1500, require_zero_default=True)
            client = wb.wait_for_client(platform_prefix="windows", client_id_substring=prof, timeout=45.0)
            return res.pid, str(client["clientId"])

        def _record_item_list(
            batch: list[dict[str, Any]],
            *,
            desk: WinHiddenDesktopSession | None,
            prof: str,
            fresh: bool,
            sign_in: bool,
            foreground: bool,
        ) -> None:
            if not batch:
                return
            agent = _spawn_win_agent(agent_exe, desk=desk)
            pid = 0
            try:
                if desk is not None:
                    pid, client_id = _launch_hidden(desk, prof, fresh=fresh)
                else:
                    dev_root = win_stage_root / "profiles" / prof
                    dev_root.mkdir(parents=True, exist_ok=True)
                    env = os.environ.copy()
                    env.update({
                        "PARFAIT_DEV_PROFILE": "1",
                        "PARFAIT_DEV_INSTANCE": "1",
                        "PARFAIT_DEV_ROOT": to_windows_path(dev_root),
                    })
                    proc = subprocess.Popen(
                        [
                            str(win_exe),
                            f"--dev-profile={prof}",
                            "--source=loopback",
                            f"--loopback={workbench_url}",
                            f"--workbench-url={workbench_url}",
                            f"--workbench-token={token}",
                        ],
                        cwd="/mnt/c",
                        env=env,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    pid = proc.pid
                    client = wb.wait_for_client(platform_prefix="windows", client_id_substring=prof, timeout=45.0)
                    client_id = str(client["clientId"])

                wb.send_command(client_id, "resizeWindow", {"width": 1280, "height": 780}, timeout=10.0)
                time.sleep(0.45)
                # Collapse DEV SHELL banner if present so desktop title bar sits cleanly at y=0 (critical for SC-W1)
                try:
                    snap0 = wb.snapshot(client_id, timeout=5.0)
                    cbtn = wb.resolve_target(client_id, {"kind": "key", "query": "dev-shell-collapse-btn"}, snap0)
                    agent.cmd(f"CLICK {pid} {cbtn['x']:.2f} {cbtn['y']:.2f} {'fg' if foreground else 'bg'}")
                    time.sleep(0.25)
                except Exception:
                    pass
                if sign_in:
                    wb.send_command(client_id, "loopbackSignIn", {}, timeout=12.0)
                    time.sleep(0.7)

                guide_completed_sent = False
                for it in batch:
                    cid = it["id"]
                    rt = it.get("route_template")
                    # Relaunch if previous item exited process
                    try:
                        agent.cmd(f"PROBE {pid}")
                    except Exception:
                        if desk is not None:
                            pid, client_id = _launch_hidden(desk, prof, fresh=fresh)
                            wb.send_command(client_id, "resizeWindow", {"width": 1280, "height": 780}, timeout=10.0)
                            time.sleep(0.35)
                            try:
                                snap0 = wb.snapshot(client_id, timeout=5.0)
                                cbtn = wb.resolve_target(client_id, {"kind": "key", "query": "dev-shell-collapse-btn"}, snap0)
                                agent.cmd(f"CLICK {pid} {cbtn['x']:.2f} {cbtn['y']:.2f} bg")
                                time.sleep(0.25)
                            except Exception:
                                pass
                            if sign_in:
                                wb.send_command(client_id, "loopbackSignIn", {}, timeout=12.0)
                            time.sleep(0.5)

                    if fresh and rt in ("/login", "/user-agreement", "/login/web", "/login/callback") and not guide_completed_sent:
                        wb.navigate(client_id, "/welcome/language", settle_sec=0.45)
                        snap_tmp = wb.snapshot(client_id)
                        try:
                            btn = wb.resolve_target(client_id, {"kind": "any_text", "queries": ["下一步", "Next"]}, snap_tmp)
                            agent.cmd(f"CLICK {pid} {btn['x']:.2f} {btn['y']:.2f} {'fg' if foreground else 'bg'}")
                            time.sleep(0.55)
                            guide_completed_sent = True
                        except Exception:
                            pass

                    wb.reset_faults()
                    frames_dir = win_stage_root / "frames" / cid
                    if frames_dir.exists():
                        shutil.rmtree(frames_dir, ignore_errors=True)
                    frames_dir.mkdir(parents=True, exist_ok=True)

                    diag: dict[str, Any] = {}
                    route_before = ""
                    route_after = ""
                    anomaly_reason = ""
                    capture_mode = "win32_foreground_sendinput" if foreground else "win32_hidden_desktop"
                    cap_started = False
                    ffmpeg_fg_proc: subprocess.Popen[str] | None = None
                    fg_raw_mp4 = frames_dir / "fg_raw.mp4"

                    frame_idx = 0

                    def _snap_hidden_frame() -> None:
                        nonlocal frame_idx
                        try:
                            png_data = wb.capture_screenshot_png(client_id, timeout=8.0)
                        except Exception:
                            return
                        f_wsl = frames_dir / f"f{frame_idx:04d}.png"
                        frame_idx += 1
                        f_wsl.write_bytes(png_data)
                        cur = diag.get("_cursor")
                        if isinstance(cur, tuple) and len(cur) == 4:
                            cx, cy, dpr_v, clbl = cur
                            p_b64 = base64.b64encode(to_windows_path(f_wsl).encode("utf-8")).decode("ascii")
                            l_b64 = base64.b64encode(str(clbl).encode("utf-8")).decode("ascii")
                            try:
                                agent.cmd(f"ANNOTATE {p_b64} {cx:.2f} {cy:.2f} {dpr_v:.3f} {l_b64}")
                            except Exception:
                                pass

                    try:
                        if not (fresh and rt == "/splash"):
                            wb.navigate(client_id, str(it["route"]), settle_sec=0.75)
                        snap = wb.snapshot(client_id)
                        route_before = str(snap.get("route") or "")

                        if foreground:
                            probe_parts = agent.cmd(f"PROBE {pid}").split()
                            wx, wy, ww, wh = int(probe_parts[1]), int(probe_parts[2]), int(probe_parts[3]), int(probe_parts[4])
                            ww = max(320, ww - (ww % 2))
                            wh = max(240, wh - (wh % 2))
                            ffmpeg_fg_proc = subprocess.Popen(
                                [
                                    resolve_ffmpeg_exe(),
                                    "-y",
                                    "-v",
                                    "error",
                                    "-f",
                                    "gdigrab",
                                    "-framerate",
                                    "24",
                                    "-draw_mouse",
                                    "1",
                                    "-offset_x",
                                    str(wx),
                                    "-offset_y",
                                    str(wy),
                                    "-video_size",
                                    f"{ww}x{wh}",
                                    "-i",
                                    "desktop",
                                    "-c:v",
                                    "libx264",
                                    "-preset",
                                    "ultrafast",
                                    "-pix_fmt",
                                    "yuv420p",
                                    to_windows_path(fg_raw_mp4),
                                ],
                                cwd="/mnt/c",
                                stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
                                text=True,
                            )
                            time.sleep(0.3)
                        else:
                            # Secondary Win32 desktop lacks DWM swapchain composition for PrintWindow on ANGLE HWNDs;
                            # capture real Flutter layer PNGs over loopback while dispatching authentic Win32 HWND events.
                            _snap_hidden_frame()

                        t0 = time.monotonic()
                        for step in it.get("actions", []):
                            if time.monotonic() - t0 > 18.0:
                                anomaly_reason = "item action sequence exceeded 18s cap"
                                break
                            _execute_windows_step(
                                wb,
                                client_id,
                                agent,
                                pid,
                                snap,
                                it["target"],
                                step,
                                foreground=foreground,
                                diag=diag,
                            )
                            if not foreground:
                                _snap_hidden_frame()
                            if step.get("type") in ("navigate", "resize_window", "fault"):
                                try:
                                    snap = wb.snapshot(client_id, timeout=5.0)
                                except Exception:
                                    pass
                        time.sleep(0.25)
                        if not foreground:
                            diag.pop("_cursor", None)
                            _snap_hidden_frame()

                        # SC-W1 semantic check: if close button top-edge was intercepted by HTTOP/HTTOPRIGHT
                        if cid == "shell.win_caption.close_top_edge_unmax" and diag.get("nchittest_top") in (12, 14):
                            diag["anomaly"] = (
                                f"SC-W1 reproduced: top-edge close hit {diag.get('nchittest_name')} "
                                f"({diag.get('nchittest_top')}) instead of HTCLIENT (1)"
                            )
                            anomaly_reason = diag["anomaly"]
                    except (CommandTimeoutError, TargetNotFoundError, Exception) as exc:
                        anomaly_reason = f"{type(exc).__name__}: {exc}"
                    finally:
                        if cap_started:
                            try:
                                agent.cmd("CAP_STOP")
                            except Exception:
                                pass
                        if ffmpeg_fg_proc is not None:
                            try:
                                if ffmpeg_fg_proc.stdin:
                                    ffmpeg_fg_proc.stdin.write("q\n")
                                    ffmpeg_fg_proc.stdin.flush()
                                ffmpeg_fg_proc.wait(timeout=6.0)
                            except Exception:
                                ffmpeg_fg_proc.kill()
                        wb.reset_faults()
                        try:
                            snap_after = wb.snapshot(client_id, timeout=4.0)
                            route_after = str(snap_after.get("route") or "")
                            vp_after = snap_after.get("viewport") or {}
                            vw_after = float(vp_after.get("width", 0) or 0)
                            vh_after = float(vp_after.get("height", 0) or 0)
                            needs_restore = (
                                bool(snap_after.get("isFullScreen"))
                                or bool(snap_after.get("isMaximized"))
                                or "maximize" in cid
                                or any(s.get("type") == "resize_window" for s in it.get("actions", []))
                                or abs(vw_after - 1280.0) > 2.0
                                or abs(vh_after - 780.0) > 2.0
                            )
                            if needs_restore:
                                if snap_after.get("isFullScreen"):
                                    try:
                                        agent.cmd(f"KEY {pid} F11 {'fg' if foreground else 'bg'}")
                                        time.sleep(0.2)
                                    except Exception:
                                        pass
                                try:
                                    agent.cmd(f"RESTORE {pid}")
                                    time.sleep(0.15)
                                except Exception:
                                    pass
                                try:
                                    wb.send_command(client_id, "resizeWindow", {"width": 1280, "height": 780}, timeout=8.0)
                                    time.sleep(0.25)
                                except Exception:
                                    pass
                        except Exception:
                            route_after = route_before

                    fmt = str(it.get("format", "gif"))
                    rel = f"windows/{cid}.{fmt}"
                    out_path = run_dir / rel
                    sheet_dir = run_dir / "sheets" / "windows" / cid
                    direction = str(it.get("direction") or "one_way")
                    try:
                        if foreground and fg_raw_mp4.is_file() and fg_raw_mp4.stat().st_size > 0:
                            from .encoder import transcode_video_segment

                            art = transcode_video_segment(
                                fg_raw_mp4,
                                out_path,
                                fmt,
                                fps=24,
                                sheet_dir=sheet_dir,
                                direction=direction,
                            )
                            enc_meta = {
                                "width": art.width,
                                "height": art.height,
                                "bytes": art.bytes,
                                "duration_ms": art.duration_ms,
                                "decode_verified": art.decode_verified,
                                "decode_error": art.decode_error,
                                "sheet_paths": art.sheet_paths,
                                "motion_metrics": art.motion_metrics,
                            }
                        else:
                            diag.pop("_cursor", None)
                            enc_meta = _encode_ntfs_frames(
                                frames_dir,
                                out_path,
                                fmt,
                                fps=2,
                                sheet_dir=sheet_dir,
                                direction=direction,
                            )
                    except Exception as enc_exc:
                        diag.pop("_cursor", None)
                        records.append({
                            "catalog_id": cid,
                            "module": it.get("module"),
                            "route_template": rt,
                            "shell_layer": it.get("shell_layer"),
                            "audit_candidate": it.get("audit_candidate"),
                            "direction": it.get("direction"),
                            "platform": "windows",
                            "evidence_kind": "native_os_recording",
                            "capture_mode": capture_mode,
                            "status": "failed",
                            "artifact_relpath": None,
                            "decode_verified": False,
                            "route_before": route_before,
                            "route_after": route_after,
                            "diagnostics": {**diag, "error": f"{anomaly_reason}; encode={enc_exc}".strip("; ")},
                            "known_blind_spots": [],
                        })
                        continue

                    st = "ok"
                    if not enc_meta["decode_verified"]:
                        st = "failed"
                    elif anomaly_reason:
                        st = "recorded_with_anomaly"
                    records.append({
                        "catalog_id": cid,
                        "module": it.get("module"),
                        "route_template": rt,
                        "shell_layer": it.get("shell_layer"),
                        "audit_candidate": it.get("audit_candidate"),
                        "direction": it.get("direction"),
                        "platform": "windows",
                        "evidence_kind": "native_os_recording",
                        "capture_mode": capture_mode,
                        "status": st,
                        "artifact_relpath": rel,
                        "format": fmt,
                        **{k: enc_meta[k] for k in ("width", "height", "bytes", "duration_ms", "decode_verified")},
                        "route_before": route_before,
                        "route_after": route_after,
                        "diagnostics": {
                            **diag,
                            **({"anomaly": anomaly_reason} if anomaly_reason and "anomaly" not in diag else {}),
                            **({"decode_error": enc_meta["decode_error"]} if enc_meta.get("decode_error") else {}),
                        },
                        "known_blind_spots": (
                            []
                            if foreground
                            else [
                                "system_hardware_cursor_sprite",
                                "win11_snap_layout_flyout",
                                "win32k_modal_move_size_loop",
                                "dwm_inactive_desktop_flutter_layer_capture",
                            ]
                        ),
                        **storyboard_record_fields(
                            enc_meta.get("sheet_paths", ()),
                            enc_meta.get("motion_metrics"),
                            run_dir,
                        ),
                    })
            finally:
                agent.close()
                if pid > 0:
                    run_powershell(f"Stop-Process -Id {int(pid)} -Force -ErrorAction SilentlyContinue; exit 0")
                    time.sleep(0.3)

        # Background zero-interference recording batches
        bg_pre = [it for it in pre_items if not str((it.get("platforms") or {}).get("windows", "")).startswith("foreground_opt_in:")]
        bg_signed = [it for it in signed_items if not str((it.get("platforms") or {}).get("windows", "")).startswith("foreground_opt_in:")]
        fg_signed = [it for it in signed_items if str((it.get("platforms") or {}).get("windows", "")).startswith("foreground_opt_in:")]

        with WinHiddenDesktopSession(
            desktop_name=DEFAULT_DESKTOP_NAME,
            keepalive_dir=win_stage_root,
            max_seconds=900,
        ) as desk:
            _record_item_list(bg_pre, desk=desk, prof="win_onboard", fresh=True, sign_in=False, foreground=False)
            _record_item_list(bg_signed, desk=desk, prof="win_main", fresh=False, sign_in=True, foreground=False)

        if with_foreground_shell and fg_signed:
            _record_item_list(fg_signed, desk=None, prof="win_fg", fresh=False, sign_in=True, foreground=True)

    finally:
        shutil.rmtree(win_stage_root, ignore_errors=True)

    return records
