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
    def __init__(
        self,
        cleanup_enabled: bool = False,
        style: str = "polish",
        on_cleanup_toggle=None,
        on_style_change=None,
    ) -> None:
        super().__init__(GLYPHS["loading"], quit_button="Quit Murmur")
        self._status = rumps.MenuItem("Status: loading models…")
        self._on_cleanup_toggle = on_cleanup_toggle
        self._on_style_change = on_style_change
        self._style = style
        self._cleanup_item = rumps.MenuItem("Cleanup", callback=self._toggle_cleanup)
        self._cleanup_item.state = 1 if cleanup_enabled else 0
        self._style_item = rumps.MenuItem(
            f"Style: {style.capitalize()}", callback=self._cycle_style
        )
        self.menu = [
            self._status,
            self._cleanup_item,
            self._style_item,
            rumps.MenuItem("Check permissions", callback=self._check_permissions),
        ]

    def set_state(self, state: str, detail: str = "") -> None:
        self.title = GLYPHS.get(state, GLYPHS["idle"])
        self._status.title = f"Status: {detail or state}"

    def _toggle_cleanup(self, sender) -> None:
        sender.state = 0 if sender.state else 1
        if self._on_cleanup_toggle:
            self._on_cleanup_toggle(bool(sender.state))

    def _cycle_style(self, sender) -> None:
        self._style = "light" if self._style == "polish" else "polish"
        sender.title = f"Style: {self._style.capitalize()}"
        if self._on_style_change:
            self._on_style_change(self._style)

    def _check_permissions(self, _sender) -> None:
        from . import permissions

        rumps.alert(title="Murmur permissions", message=permissions.report())
