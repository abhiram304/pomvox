"""rumps menu bar app mirroring dictation state."""

from __future__ import annotations

import logging

import rumps

log = logging.getLogger(__name__)

GLYPHS = {
    "loading": "⏳",
    "idle": "🎤",
    "recording": "🔴",
    "transcribing": "✍️",
}


class MenuBarApp(rumps.App):
    def __init__(self) -> None:
        super().__init__(GLYPHS["loading"], quit_button="Quit Murmur")
        self._status = rumps.MenuItem("Status: loading model…")
        self.menu = [
            self._status,
            rumps.MenuItem("Check permissions", callback=self._check_permissions),
        ]

    def set_state(self, state: str, detail: str = "") -> None:
        self.title = GLYPHS.get(state, GLYPHS["idle"])
        self._status.title = f"Status: {detail or state}"

    def _check_permissions(self, _sender) -> None:
        from . import permissions

        rumps.alert(title="Murmur permissions", message=permissions.report())
