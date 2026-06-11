"""macOS permission detection and first-run guidance.

Detect and guide, never crash: every probe is wrapped so a missing API or
denied call degrades to a warning with a System Settings deep link.
"""

from __future__ import annotations

import logging
import subprocess

log = logging.getLogger(__name__)

SETTINGS_LINKS = {
    "microphone": "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
    "accessibility": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    "input_monitoring": "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
}

AV_AUTHORIZED = 3  # AVAuthorizationStatusAuthorized


def microphone_status() -> bool | None:
    try:
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio

        return AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio) == AV_AUTHORIZED
    except Exception:
        log.exception("permissions: microphone probe failed")
        return None


def request_microphone() -> None:
    """Trigger the system mic prompt (no-op if already decided)."""
    try:
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio

        AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVMediaTypeAudio, lambda granted: log.info("permissions: mic granted=%s", granted)
        )
    except Exception:
        log.exception("permissions: microphone request failed")


def accessibility_status() -> bool | None:
    try:
        from ApplicationServices import AXIsProcessTrusted

        return bool(AXIsProcessTrusted())
    except Exception:
        log.exception("permissions: accessibility probe failed")
        return None


def input_monitoring_status() -> bool | None:
    try:
        import Quartz

        return bool(Quartz.CGPreflightListenEventAccess())
    except Exception:
        log.exception("permissions: input monitoring probe failed")
        return None


def request_input_monitoring() -> None:
    try:
        import Quartz

        Quartz.CGRequestListenEventAccess()
    except Exception:
        log.exception("permissions: input monitoring request failed")


def request_accessibility() -> None:
    """Trigger the system Accessibility prompt (no-op if already decided)."""
    try:
        from ApplicationServices import (
            AXIsProcessTrustedWithOptions,
            kAXTrustedCheckOptionPrompt,
        )

        AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True})
    except Exception:
        log.exception("permissions: accessibility request failed")


def statuses() -> dict[str, bool | None]:
    """All probes at once — what the onboarding checklist polls."""
    return {
        "microphone": microphone_status(),
        "accessibility": accessibility_status(),
        "input_monitoring": input_monitoring_status(),
    }


def request(key: str) -> None:
    """Fire the native prompt for *key* and open its System Settings pane.

    Native prompts only appear the first time; the deep link is the path
    for users who dismissed one (those prompts never reappear).
    """
    if key == "microphone":
        request_microphone()
    elif key == "input_monitoring":
        request_input_monitoring()
    elif key == "accessibility":
        request_accessibility()
    try:
        subprocess.run(["open", SETTINGS_LINKS[key]], check=False, timeout=5)
    except Exception:
        log.exception("permissions: could not open System Settings for %s", key)


def globe_key_is_do_nothing() -> bool | None:
    """True when "Press 🌐 key to" is set to Do Nothing (AppleFnUsageType=0)."""
    try:
        out = subprocess.run(
            ["defaults", "read", "com.apple.HIToolbox", "AppleFnUsageType"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode != 0:
            return None  # key never set — macOS default is not Do Nothing
        return out.stdout.strip() == "0"
    except Exception:
        log.exception("permissions: globe key probe failed")
        return None


def report() -> str:
    """Human-readable status for `murmur --check` and the menu bar alert."""

    def fmt(name: str, ok: bool | None, link_key: str | None = None, hint: str = "") -> str:
        mark = {True: "✅", False: "❌", None: "⚠️ unknown"}[ok]
        line = f"  {mark}  {name}"
        if ok is not True:
            if link_key:
                line += f"\n        grant via: open '{SETTINGS_LINKS[link_key]}'"
            if hint:
                line += f"\n        {hint}"
        return line

    lines = [
        "Murmur permission check:",
        fmt("Microphone", microphone_status(), "microphone"),
        fmt("Accessibility (paste via ⌘V)", accessibility_status(), "accessibility"),
        fmt("Input Monitoring (hotkey tap)", input_monitoring_status(), "input_monitoring"),
        fmt(
            "Globe key set to Do Nothing",
            globe_key_is_do_nothing(),
            None,
            "System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing",
        ),
        "",
        "Note: when running via `uv run`, grants attach to the terminal app.",
    ]
    return "\n".join(lines)


def missing() -> list[str]:
    out = []
    if microphone_status() is not True:
        out.append("microphone")
    if accessibility_status() is not True:
        out.append("accessibility")
    if input_monitoring_status() is not True:
        out.append("input_monitoring")
    return out
