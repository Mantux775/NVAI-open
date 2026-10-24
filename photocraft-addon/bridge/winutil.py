"""Win32-Hilfen: Panel-Fenster, Registry, Dateiversionen.

pywebview-Fenstermethoden aus fremden Threads (HTTP-Server, JS-API) verklemmen sich unter
Windows mit dem GUI-Thread: pythonnet hält während ``Control.Invoke`` das GIL, das der
GUI-Thread für den Rückruf braucht – der ganze Prozess steht dann (gemessen). ctypes gibt das
GIL während jedes Aufrufs frei. Alles, was das Fenster nachträglich verändert, läuft deshalb
hierüber und nicht über pywebview.
"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
from pathlib import Path
from typing import Any

# Fenstertitel je Sprache; ein zweiter Start sucht das vorhandene Fenster unter allen. Bis 0.4.4
# hieß die App „NV-AI für PhotoCraft“: ein noch offenes Fenster von damals wird so auch gefunden.
TITLES = ("NVAI-open for PhotoCraft", "NVAI-open für PhotoCraft", "NV-AI for PhotoCraft", "NV-AI für PhotoCraft")
# Dieselbe ID trägt die Startmenü-Verknüpfung des Setups. Die Taskleiste ordnet das Fenster dann
# ihr zu: Anheften heftet die Verknüpfung an, nicht pythonw.exe.
APP_ID = "NVAI.PhotoCraft"

_user32 = ctypes.WinDLL("user32", use_last_error=True)
_EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
_user32.EnumWindows.argtypes = [_EnumWindowsProc, wintypes.LPARAM]
_user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
_user32.InternalGetWindowText.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
_user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
_user32.IsWindowVisible.argtypes = [wintypes.HWND]
_user32.IsIconic.argtypes = [wintypes.HWND]
_user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
_user32.SetForegroundWindow.argtypes = [wintypes.HWND]
_user32.SetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPCWSTR]
_user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                 ctypes.c_int, ctypes.c_int, wintypes.UINT]

_HWND_TOPMOST = wintypes.HWND(-1)
_HWND_NOTOPMOST = wintypes.HWND(-2)
_SWP_NOSIZE, _SWP_NOMOVE, _SWP_NOACTIVATE = 0x0001, 0x0002, 0x0010
_SW_RESTORE = 9


def find_window(titles: tuple[str, ...] = TITLES, pid: int | None = None) -> int | None:
    """Hauptfenster mit einem dieser Titel, wahlweise nur aus Prozess ``pid``; sichtbare zuerst."""
    found: list[int] = []

    def visit(hwnd: int, _lparam: int) -> bool:
        length = _user32.GetWindowTextLengthW(hwnd)
        if not length:
            return True
        buf = ctypes.create_unicode_buffer(length + 1)
        # InternalGetWindowText schickt keine Nachricht an das Fenster – kein Warten auf dessen Thread.
        _user32.InternalGetWindowText(hwnd, buf, length + 1)
        if buf.value not in titles:
            return True
        if pid is not None:
            owner = wintypes.DWORD()
            _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
            if owner.value != pid:
                return True
        found.append(hwnd)
        return True

    _user32.EnumWindows(_EnumWindowsProc(visit), 0)
    found.sort(key=lambda h: not _user32.IsWindowVisible(h))
    return found[0] if found else None


def set_title(hwnd: int, title: str) -> None:
    """Fenstertitel ändern (nach einem Sprachwechsel)."""
    _user32.SetWindowTextW(hwnd, title)


def set_topmost(hwnd: int, flag: bool) -> None:
    _user32.SetWindowPos(hwnd, _HWND_TOPMOST if flag else _HWND_NOTOPMOST, 0, 0, 0, 0,
                         _SWP_NOMOVE | _SWP_NOSIZE | _SWP_NOACTIVATE)


def bring_to_front(hwnd: int) -> None:
    if _user32.IsIconic(hwnd) or not _user32.IsWindowVisible(hwnd):
        # Den ersten ShowWindow-Aufruf eines Prozesses ersetzt Windows durch dessen Startmodus
        # (STARTUPINFO.wShowWindow) – gestartet „versteckt“ würde er das Fenster verbergen
        # (gemessen). Der zweite Aufruf gilt so, wie er geschrieben ist.
        _user32.ShowWindow(hwnd, _SW_RESTORE)
        _user32.ShowWindow(hwnd, _SW_RESTORE)
    _user32.SetForegroundWindow(hwnd)


# Microsoft Edge WebView2 Runtime (Evergreen). Fehlt sie, fällt pywebview auf die IE-Engine
# (MSHTML) zurück – darin läuft das Panel nicht (modernes JavaScript).
_WEBVIEW2_CLIENT = r"Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"


def webview2_available() -> bool:
    """Ist die WebView2-Laufzeit installiert – pro Nutzer oder für den Rechner?"""
    import winreg

    for hive, path in ((winreg.HKEY_CURRENT_USER, rf"SOFTWARE\{_WEBVIEW2_CLIENT}"),
                       (winreg.HKEY_LOCAL_MACHINE, rf"SOFTWARE\WOW6432Node\{_WEBVIEW2_CLIENT}"),
                       (winreg.HKEY_LOCAL_MACHINE, rf"SOFTWARE\{_WEBVIEW2_CLIENT}")):
        try:
            with winreg.OpenKey(hive, path) as key:
                version, _ = winreg.QueryValueEx(key, "pv")
        except OSError:
            continue
        if str(version) not in ("", "0.0.0.0"):
            return True
    return False


def set_app_id(app_id: str = APP_ID) -> None:
    """Eigene AppUserModelID für diesen Prozess – vor dem ersten Fenster setzen."""
    try:
        fn = ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID
        fn.argtypes = [wintypes.LPCWSTR]
        fn(app_id)
    except (AttributeError, OSError):
        pass


# ------------------------------------------------------------------ Registry

def registry_values(path: str, hive: str = "HKCU") -> dict[str, Any] | None:
    """Alle Werte eines Schlüssels (64-Bit-Ansicht), REG_EXPAND_SZ aufgelöst – oder None, wenn
    der Schlüssel fehlt. Der Standardwert heißt ``""``."""
    import winreg

    root = {"HKCU": winreg.HKEY_CURRENT_USER, "HKLM": winreg.HKEY_LOCAL_MACHINE}[hive]
    try:
        key = winreg.OpenKey(root, path, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
    except OSError:
        return None
    values: dict[str, Any] = {}
    with key:
        index = 0
        while True:
            try:
                name, value, kind = winreg.EnumValue(key, index)
            except OSError:
                break
            if kind == winreg.REG_EXPAND_SZ and isinstance(value, str):
                value = winreg.ExpandEnvironmentStrings(value)
            values[name] = value
            index += 1
    return values


def app_path(exe: str) -> Path | None:
    """Programm laut „App Paths“ (erst pro Nutzer, dann für den Rechner). Dort tragen sich
    Installer ein, damit Win+R und ShellExecute ein Programm ohne Pfad finden."""
    for hive in ("HKCU", "HKLM"):
        values = registry_values(rf"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{exe}", hive)
        target = (values or {}).get("")
        if isinstance(target, str) and target.strip().strip('"'):
            return Path(target.strip().strip('"'))
    return None


# ----------------------------------------------------------- Dateiversionen

class _FixedFileInfo(ctypes.Structure):
    _fields_ = [(name, wintypes.DWORD) for name in (
        "dwSignature", "dwStrucVersion", "dwFileVersionMS", "dwFileVersionLS", "dwProductVersionMS",
        "dwProductVersionLS", "dwFileFlagsMask", "dwFileFlags", "dwFileOS", "dwFileType",
        "dwFileSubtype", "dwFileDateMS", "dwFileDateLS")]


_version = ctypes.WinDLL("version", use_last_error=True)
_version.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
_version.GetFileVersionInfoSizeW.restype = wintypes.DWORD
_version.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
_version.GetFileVersionInfoW.restype = wintypes.BOOL
_version.VerQueryValueW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_void_p),
                                    ctypes.POINTER(wintypes.UINT)]
_version.VerQueryValueW.restype = wintypes.BOOL


def file_version(path: Path | str) -> str | None:
    """Dateiversion aus der Versionsressource einer .exe, etwa „0.10.0“ – oder None."""
    size = _version.GetFileVersionInfoSizeW(str(path), None)
    if not size:
        return None
    buf = ctypes.create_string_buffer(size)
    if not _version.GetFileVersionInfoW(str(path), 0, size, buf):
        return None
    ptr, length = ctypes.c_void_p(), wintypes.UINT()
    if not _version.VerQueryValueW(buf, "\\", ctypes.byref(ptr), ctypes.byref(length)) or not ptr.value \
            or length.value < ctypes.sizeof(_FixedFileInfo):
        return None
    info = _FixedFileInfo.from_address(ptr.value)  # zeigt in buf, also vor dessen Freigabe lesen
    if info.dwSignature != 0xFEEF04BD:
        return None
    parts = [info.dwFileVersionMS >> 16, info.dwFileVersionMS & 0xFFFF,
             info.dwFileVersionLS >> 16, info.dwFileVersionLS & 0xFFFF]
    if parts[3] == 0:
        parts.pop()
    return ".".join(map(str, parts))
