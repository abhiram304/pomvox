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
    "polishing": "✍️",
}


class MenuBarApp(rumps.App):
    def __init__(
        self,
        cleanup_enabled: bool = False,
        style: str = "polish",
        on_cleanup_toggle=None,
        on_style_change=None,
        hud_enabled: bool | None = None,
        on_hud_toggle=None,
        vad_enabled: bool | None = None,
        on_vad_toggle=None,
    ) -> None:
        super().__init__(GLYPHS["loading"], quit_button="Quit Murmur")
        self._status = rumps.MenuItem("Status: loading models…")
        self._on_cleanup_toggle = on_cleanup_toggle
        self._on_style_change = on_style_change
        self._on_hud_toggle = on_hud_toggle
        self._on_vad_toggle = on_vad_toggle
        self._style = style
        self._cleanup_item = rumps.MenuItem("Cleanup", callback=self._toggle_cleanup)
        self._cleanup_item.state = 1 if cleanup_enabled else 0
        self._style_item = rumps.MenuItem(
            f"Style: {style.capitalize()}", callback=self._cycle_style
        )
        items = [self._status, self._cleanup_item, self._style_item]
        if hud_enabled is not None:  # None = HUD off in config, no toggle
            self._hud_item = rumps.MenuItem("Show HUD", callback=self._toggle_hud)
            self._hud_item.state = 1 if hud_enabled else 0
            items.append(self._hud_item)
        if vad_enabled is not None:  # None = VAD off in config / failed to load
            self._vad_item = rumps.MenuItem(
                "Hands-free auto-stop", callback=self._toggle_vad
            )
            self._vad_item.state = 1 if vad_enabled else 0
            items.append(self._vad_item)
        items.append(rumps.MenuItem("Check permissions", callback=self._check_permissions))
        self.menu = items

    def set_state(self, state: str, detail: str = "") -> None:
        self.title = GLYPHS.get(state, GLYPHS["idle"])
        self._status.title = f"Status: {detail or state}"

    def _toggle_cleanup(self, sender) -> None:
        sender.state = 0 if sender.state else 1
        if self._on_cleanup_toggle:
            self._on_cleanup_toggle(bool(sender.state))

    def _toggle_hud(self, sender) -> None:
        sender.state = 0 if sender.state else 1
        if self._on_hud_toggle:
            self._on_hud_toggle(bool(sender.state))

    def _toggle_vad(self, sender) -> None:
        sender.state = 0 if sender.state else 1
        if self._on_vad_toggle:
            self._on_vad_toggle(bool(sender.state))

    def _cycle_style(self, sender) -> None:
        self._style = "light" if self._style == "polish" else "polish"
        sender.title = f"Style: {self._style.capitalize()}"
        if self._on_style_change:
            self._on_style_change(self._style)

    def _check_permissions(self, _sender) -> None:
        from . import permissions

        rumps.alert(title="Murmur permissions", message=permissions.report())
