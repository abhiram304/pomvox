"""First-run setup: a permission checklist, not a wizard.

No account, no profile quiz (anti-Wispr). Three permission rows with a
plain-language *why*, live status polling (the documented failure mode of
permission-heavy mac apps is checking once at launch), System Settings
deep links, the stale-TCC hint, and a real insertion self-test — the
silent-Accessibility failure ("paste does nothing") gets diagnosed here,
not in the user's Slack.

:class:`OnboardingFlow` is pure logic (Linux-tested with fake probes);
:class:`OnboardingWindow` is the AppKit renderer behind deferred imports,
main thread only. This window is activating and key — it's ours, shown
pre-dictation, gated on the hotkey machine being idle.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)

MARKER_PATH = Path.home() / ".murmur" / "onboarded"

PERMISSIONS = (
    ("microphone", "Microphone", "so Murmur can hear you"),
    ("input_monitoring", "Input Monitoring", "so the hotkey works in every app"),
    ("accessibility", "Accessibility", "so Murmur can type your words for you (⌘V)"),
)

RELAUNCH_NOTE = "granted — relaunch Murmur to pick it up"
STALE_TCC_HINT = (
    "Granted but still red? Remove the app from the list in System Settings "
    "and add it back. (Running via `uv run`? Grants attach to your terminal.)"
)
SELF_TEST_TEXT = "Murmur works! 🎉"


@dataclass(frozen=True)
class Row:
    key: str
    title: str
    why: str
    granted: bool | None
    note: str = ""


class OnboardingFlow:
    """Pure checklist state: probe statuses in, display rows out."""

    def rows(self, statuses: dict, tap_installed: bool) -> list[Row]:
        out = []
        for key, title, why in PERMISSIONS:
            granted = statuses.get(key)
            note = ""
            if key == "input_monitoring" and granted is True and not tap_installed:
                # The grant landed but CGEventTapCreate still fails: macOS
                # does not extend Input Monitoring to a running process.
                note = RELAUNCH_NOTE
            out.append(Row(key, title, why, granted, note))
        return out

    def complete(self, statuses: dict, tap_installed: bool) -> bool:
        return tap_installed and all(
            statuses.get(key) is True for key, _, _ in PERMISSIONS
        )


def mark_onboarded() -> None:
    try:
        MARKER_PATH.parent.mkdir(parents=True, exist_ok=True)
        MARKER_PATH.touch()
    except OSError:
        log.exception("onboarding: could not write marker file")


def is_onboarded() -> bool:
    return MARKER_PATH.exists()


_ACTIONS_CLS = None


def _actions_class():
    """Buttons need an NSObject target; register the proxy class once."""
    global _ACTIONS_CLS
    if _ACTIONS_CLS is None:
        from Foundation import NSObject

        class _OnboardingActions(NSObject):
            def request_(self, sender):
                self.owner._request_clicked(str(sender.identifier()))

            def selfTest_(self, _sender):
                self.owner._self_test_clicked()

            def finish_(self, _sender):
                self.owner._finish_clicked()

        _ACTIONS_CLS = _OnboardingActions
    return _ACTIONS_CLS


class OnboardingWindow:
    """AppKit checklist renderer. Owned and refreshed by the controller's
    1 Hz permission poll; never shown while dictation is in flight."""

    WIDTH, HEIGHT = 520.0, 460.0

    def __init__(self, on_request, on_self_test, on_done) -> None:
        # on_request(key): fire the native prompt or open System Settings.
        # on_self_test(): run the real insert path into our test field.
        # on_done(): user finished/skipped.
        self._on_request = on_request
        self._on_self_test = on_self_test
        self._on_done = on_done
        self._window = None
        self._dots: dict = {}
        self._notes: dict = {}
        self._buttons: dict = {}
        self.test_field = None

    # -- main thread only ------------------------------------------------

    def show(self) -> None:
        from AppKit import NSApp

        if self._window is None:
            self._build()
        self._window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)  # ours, pre-dictation: fine

    def close(self) -> None:
        if self._window is not None:
            self._window.orderOut_(None)

    def refresh(self, rows: list[Row], complete: bool) -> None:
        if self._window is None:
            return
        for row in rows:
            mark = {True: "🟢", False: "🔴", None: "⚪️"}[row.granted]
            self._dots[row.key].setStringValue_(mark)
            self._notes[row.key].setStringValue_(row.note)
            self._buttons[row.key].setEnabled_(row.granted is not True)
        title = "You're set — try the self-test" if complete else "Murmur setup"
        self._window.setTitle_(title)

    def focus_test_field_and(self, fire) -> None:
        """Make the self-test field first responder, then run *fire* once
        focus has settled (the synthesized ⌘V lands wherever focus is)."""
        from PyObjCTools import AppHelper

        self._window.makeFirstResponder_(self.test_field)
        AppHelper.callLater(0.6, fire)

    # -- construction ------------------------------------------------------

    def _build(self) -> None:
        from AppKit import (
            NSBackingStoreBuffered,
            NSButton,
            NSFont,
            NSTextField,
            NSWindow,
            NSWindowStyleMaskClosable,
            NSWindowStyleMaskTitled,
        )
        from Foundation import NSMakeRect

        w, h = self.WIDTH, self.HEIGHT
        window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, w, h),
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable,
            NSBackingStoreBuffered,
            False,
        )
        window.setTitle_("Murmur setup")
        window.setReleasedWhenClosed_(False)
        window.center()
        content = window.contentView()
        self._actions = _actions_class().alloc().init()
        self._actions.owner = self

        def label(text, x, y, width, size=13.0, bold=False, color=None):
            f = NSTextField.labelWithString_(text)
            font = (
                NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size)
            )
            f.setFont_(font)
            if color is not None:
                f.setTextColor_(color)
            f.setFrame_(NSMakeRect(x, y, width, size + 9))
            content.addSubview_(f)
            return f

        label("Welcome to Murmur", 24, h - 52, w - 48, size=20.0, bold=True)
        label(
            "Local dictation — your voice and words never leave this Mac.",
            24, h - 78, w - 48,
        )

        y = h - 130
        for key, title, why in PERMISSIONS:
            self._dots[key] = label("⚪️", 24, y, 28, size=14.0)
            label(title, 56, y, 170, size=14.0, bold=True)
            label(why, 56, y - 20, 300, size=11.0)
            self._notes[key] = label("", 56, y - 38, 330, size=11.0)
            btn = NSButton.buttonWithTitle_target_action_(
                "Grant…", self._actions, "request:"
            )
            btn.setFrame_(NSMakeRect(w - 130, y - 8, 106, 30))
            btn.setIdentifier_(key)
            content.addSubview_(btn)
            self._buttons[key] = btn
            y -= 78

        from AppKit import NSColor

        label(STALE_TCC_HINT, 24, y - 2, w - 48, size=10.0,
              color=NSColor.secondaryLabelColor())

        y -= 46
        label("Self-test — click, then watch Murmur type into this box:",
              24, y, w - 48, size=12.0, bold=True)
        field = NSTextField.alloc().initWithFrame_(NSMakeRect(24, y - 34, w - 190, 26))
        field.setEditable_(True)
        field.setPlaceholderString_("test text lands here")
        content.addSubview_(field)
        self.test_field = field
        test_btn = NSButton.buttonWithTitle_target_action_(
            "Test insertion", self._actions, "selfTest:"
        )
        test_btn.setFrame_(NSMakeRect(w - 154, y - 36, 130, 30))
        content.addSubview_(test_btn)

        done = NSButton.buttonWithTitle_target_action_("Done", self._actions, "finish:")
        done.setFrame_(NSMakeRect(w - 110, 16, 86, 32))
        content.addSubview_(done)

        self._window = window

    # -- button handlers (called by the NSObject action proxy) -------------

    def _request_clicked(self, key: str) -> None:
        try:
            self._on_request(key)
        except Exception:
            log.exception("onboarding: request action failed")

    def _self_test_clicked(self) -> None:
        try:
            self._on_self_test()
        except Exception:
            log.exception("onboarding: self-test failed")

    def _finish_clicked(self) -> None:
        try:
            self._on_done()
        except Exception:
            log.exception("onboarding: done action failed")
