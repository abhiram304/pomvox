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
    "setup": "⚠️",
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
        on_setup=None,
        on_copy_last=None,
        on_open_config=None,
        on_reload_config=None,
        on_open_hub=None,
    ) -> None:
        super().__init__(GLYPHS["loading"], quit_button="Quit Natter")
        self._status = rumps.MenuItem("Status: loading models…")
        self._on_cleanup_toggle = on_cleanup_toggle
        self._on_style_change = on_style_change
        self._on_hud_toggle = on_hud_toggle
        self._on_vad_toggle = on_vad_toggle
        self._on_setup = on_setup
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
        items += [
            None,  # separator
            # "History…" now opens the native Hub (Natter.app), which hosts the
            # full history UI; the old PyObjC window was retired in M3.
            rumps.MenuItem("History…", callback=self._open_hub),
            rumps.MenuItem("Copy Last Transcript", callback=self._copy_last),
            rumps.MenuItem("Open Config File", callback=self._open_config),
            rumps.MenuItem("Reload Config", callback=self._reload_config),
            None,
            rumps.MenuItem("Setup Assistant…", callback=self._setup),
        ]
        self.menu = items
        self._on_copy_last = on_copy_last
        self._on_open_config = on_open_config
        self._on_reload_config = on_reload_config
        self._on_open_hub = on_open_hub

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

    def _setup(self, _sender) -> None:
        if self._on_setup:
            self._on_setup()

    def _open_hub(self, _sender) -> None:
        if self._on_open_hub:
            self._on_open_hub()

    def _copy_last(self, _sender) -> None:
        if self._on_copy_last:
            self._on_copy_last()

    def _open_config(self, _sender) -> None:
        if self._on_open_config:
            self._on_open_config()

    def _reload_config(self, _sender) -> None:
        if self._on_reload_config:
            self._on_reload_config()

    def sync(
        self,
        cleanup_enabled: bool,
        style: str,
        hud_enabled: bool | None = None,
        vad_enabled: bool | None = None,
    ) -> None:
        """Mirror hot-applied config back onto the menu item states."""
        self._cleanup_item.state = 1 if cleanup_enabled else 0
        self._style = style
        self._style_item.title = f"Style: {style.capitalize()}"
        if hud_enabled is not None and hasattr(self, "_hud_item"):
            self._hud_item.state = 1 if hud_enabled else 0
        if vad_enabled is not None and hasattr(self, "_vad_item"):
            self._vad_item.state = 1 if vad_enabled else 0
