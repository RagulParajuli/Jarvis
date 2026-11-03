"""Local PC control and connectivity helpers for Jarvis.

Standard-library only on purpose: these helpers must keep working even when
optional packages (for example Playwright) are missing.

Public helpers
--------------
is_online        - detect whether the machine currently has internet access.
list_drives      - enumerate mounted drives with free/total space.
find_files       - time-bounded search for files (movies, music, ...) on disk.
open_path        - open a file or folder with the default application.
set_wifi         - enable/disable the Wi-Fi adapter (needs administrator).
set_bluetooth    - enable/disable Bluetooth radios (needs administrator).
is_admin         - whether the current process is elevated.
"""

from __future__ import annotations

import asyncio
import os
import re
import shutil
import socket
import string
import subprocess
import sys
import time
from collections import deque
from pathlib import Path

# --- File-type classification -------------------------------------------------

MOVIE_EXTENSIONS = {
    ".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v",
    ".mpg", ".mpeg", ".ts", ".3gp", ".vob",
}
MUSIC_EXTENSIONS = {
    ".mp3", ".wav", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wma", ".aiff",
}
IMAGE_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".svg", ".tiff",
}
DOCUMENT_EXTENSIONS = {
    ".pdf", ".doc", ".docx", ".txt", ".rtf", ".ppt", ".pptx",
    ".xls", ".xlsx", ".csv", ".md",
}

_FILE_TYPE_GROUPS = {
    "movie": MOVIE_EXTENSIONS,
    "video": MOVIE_EXTENSIONS,
    "music": MUSIC_EXTENSIONS,
    "audio": MUSIC_EXTENSIONS,
    "song": MUSIC_EXTENSIONS,
    "image": IMAGE_EXTENSIONS,
    "photo": IMAGE_EXTENSIONS,
    "picture": IMAGE_EXTENSIONS,
    "document": DOCUMENT_EXTENSIONS,
    "doc": DOCUMENT_EXTENSIONS,
}

# Directories that are never worth scanning and can be very large.
_SKIP_DIR_NAMES = {
    "windows", "$recycle.bin", "system volume information", "recovery",
    "program files", "program files (x86)", "programdata", "appdata",
    "node_modules", ".git", "__pycache__", ".venv", "venv", ".next",
    "$windows.~bt", "$windows.~ws", "perflogs", "config.msi",
}

# --- Connectivity -------------------------------------------------------------


def is_online(*, timeout: float = 2.0) -> bool:
    """Return True when the machine can reach the internet."""
    for host in ("1.1.1.1", "8.8.8.8"):
        try:
            with socket.create_connection((host, 53), timeout=timeout):
                return True
        except OSError:
            continue
    return False


# --- Drives -------------------------------------------------------------------


def list_drives() -> list[dict[str, object]]:
    """Return the mounted drives with their total and free space in GB."""
    drives: list[dict[str, object]] = []
    for letter in string.ascii_uppercase:
        root = f"{letter}:\\"
        if not os.path.exists(root):
            continue
        entry: dict[str, object] = {"drive": root}
        try:
            usage = shutil.disk_usage(root)
            entry["total_gb"] = round(usage.total / 1e9, 1)
            entry["free_gb"] = round(usage.free / 1e9, 1)
        except OSError:
            pass
        drives.append(entry)
    return drives


# --- File search --------------------------------------------------------------


def _extensions_for(file_type: str | None) -> set[str] | None:
    if not file_type:
        return None
    return _FILE_TYPE_GROUPS.get(file_type.strip().casefold())


def find_files(
    query: str,
    *,
    file_type: str | None = None,
    limit: int = 20,
    time_budget: float = 15.0,
    roots: list[str] | None = None,
) -> dict[str, object]:
    """Search every drive for files whose name contains all query words.

    The scan is time-bounded so the voice agent stays responsive: when the
    budget runs out the partial results collected so far are returned.
    """
    terms = [term for term in re.split(r"\s+", query.casefold().strip()) if term]
    extensions = _extensions_for(file_type)
    deadline = time.monotonic() + max(time_budget, 1.0)

    if roots is None:
        roots = [str(drive["drive"]) for drive in list_drives()]

    matches: list[dict[str, str]] = []
    scanned = 0
    timed_out = False

    for root in roots:
        if timed_out:
            break
        queue: deque[str] = deque([root])
        while queue:
            if time.monotonic() > deadline:
                timed_out = True
                break
            current = queue.popleft()
            try:
                entries = list(os.scandir(current))
            except (PermissionError, FileNotFoundError, OSError):
                continue
            for entry in entries:
                name = entry.name
                if name.startswith("$") or name.casefold() in _SKIP_DIR_NAMES:
                    continue
                try:
                    if entry.is_dir(follow_symlinks=False):
                        queue.append(entry.path)
                        continue
                    if not entry.is_file(follow_symlinks=False):
                        continue
                except OSError:
                    continue

                scanned += 1
                lowered = name.casefold()
                if extensions and Path(lowered).suffix not in extensions:
                    continue
                if all(term in lowered for term in terms):
                    matches.append({"name": name, "path": entry.path})
                    if len(matches) >= limit:
                        return {
                            "query": query,
                            "matches": matches,
                            "count": len(matches),
                            "scanned_files": scanned,
                            "timed_out": False,
                        }

    matches.sort(key=lambda item: item["name"].casefold())
    return {
        "query": query,
        "matches": matches,
        "count": len(matches),
        "scanned_files": scanned,
        "timed_out": timed_out,
    }


# --- Open files ---------------------------------------------------------------


def open_path(path: str) -> dict[str, object]:
    """Open a file or folder with the operating system's default application."""
    candidate = Path(path).expanduser()
    if not candidate.exists():
        return {"success": False, "error": f"Nothing exists at {path!r}."}

    try:
        if sys.platform == "win32":
            os.startfile(str(candidate))  # type: ignore[attr-defined]
        else:
            opener = "open" if sys.platform == "darwin" else "xdg-open"
            subprocess.Popen(
                [opener, str(candidate)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    except OSError as exc:
        return {"success": False, "error": f"Could not open {path!r}: {exc}"}

    return {"success": True, "opened": str(candidate)}


# --- Windows toggles ----------------------------------------------------------


def is_admin() -> bool:
    """Return True when the current process runs with administrator rights."""
    if sys.platform != "win32":
        return os.geteuid() == 0  # type: ignore[attr-defined]
    try:
        import ctypes

        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def _run_powershell(script: str, *, timeout: float = 25.0) -> subprocess.CompletedProcess:
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    return subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        timeout=timeout,
        creationflags=flags,
    )


def _clean_lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip()]


def _toggle_wifi_sync(enabled: bool) -> dict[str, object]:
    find = _run_powershell(
        "Get-NetAdapter -Physical | "
        "Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' -or "
        "$_.Name -like '*Wi-Fi*' -or $_.InterfaceDescription -like '*Wireless*' } | "
        "Select-Object -First 1 -ExpandProperty Name"
    )
    names = _clean_lines(find.stdout)
    if not names:
        message = find.stderr.strip() or "No Wi-Fi adapter was found."
        return {"success": False, "error": message}

    name = names[-1].replace("'", "''")
    verb = "Enable-NetAdapter" if enabled else "Disable-NetAdapter"
    result = _run_powershell(f"{verb} -Name '{name}' -Confirm:$false")

    if result.returncode != 0:
        error = result.stderr.strip() or "The command failed."
        if not is_admin():
            error = f"{error} This needs administrator permission."
        return {"success": False, "adapter": names[-1], "error": error}

    return {"success": True, "adapter": names[-1], "enabled": enabled}


def _toggle_bluetooth_sync(enabled: bool) -> dict[str, object]:
    verb = "Enable-PnpDevice" if enabled else "Disable-PnpDevice"
    script = (
        "$changed = 0; "
        "Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | "
        "Where-Object { $_.FriendlyName -notlike '*Enumerator*' } | "
        "ForEach-Object { "
        f"try {{ {verb} -InstanceId $_.InstanceId -Confirm:$false -ErrorAction Stop; "
        '$changed++; Write-Output "OK:$($_.FriendlyName)" }} '
        'catch { Write-Output "FAIL:$($_.FriendlyName):$($_.Exception.Message)" } '
        "}; "
        'Write-Output "CHANGED:$changed"'
    )
    result = _run_powershell(script)
    lines = _clean_lines(result.stdout)
    changed = 0
    for line in lines:
        if not line.startswith("CHANGED:"):
            continue
        try:
            changed = int(line.split(":", 1)[1])
        except ValueError:
            changed = 0

    if changed == 0:
        error = result.stderr.strip()
        if not error:
            error = "No Bluetooth device could be changed."
        if not is_admin():
            error = f"{error} This needs administrator permission."
        return {"success": False, "changed": 0, "error": error}

    return {"success": True, "enabled": enabled, "changed": changed}


async def set_wifi(enabled: bool) -> dict[str, object]:
    """Turn the Wi-Fi adapter on or off. Requires administrator rights."""
    return await asyncio.to_thread(_toggle_wifi_sync, enabled)


async def set_bluetooth(enabled: bool) -> dict[str, object]:
    """Turn Bluetooth radios on or off. Requires administrator rights."""
    return await asyncio.to_thread(_toggle_bluetooth_sync, enabled)
