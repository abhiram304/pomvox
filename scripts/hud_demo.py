"""Drive the HUD through its states with synthetic events (macOS only).

Run with: uv run python scripts/hud_demo.py
Shows the pill for ~6 s: recording with rising level bars and two draft
updates, then transcribing, then the done flash, then fade-out. Verifies
panel construction, state rendering, and the tick-driven hide without the
full dictation pipeline.
"""

from __future__ import annotations

import logging

from PyObjCTools import AppHelper

from natter.hud import Hud
from natter.uibus import UiEvent

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("hud_demo")

hud = Hud()

SCRIPT = [
    (0.5, {UiEvent.STATE: ("recording", "recording (demo)")}),
    (1.0, {UiEvent.LEVEL: 0.3}),
    (1.5, {UiEvent.DRAFT: "the quick brown fox", UiEvent.LEVEL: 0.8}),
    (2.5, {UiEvent.DRAFT: "the quick brown fox jumps over the lazy dog",
           UiEvent.LEVEL: 0.5}),
    (3.5, {UiEvent.STATE: ("transcribing", "")}),
    (4.2, {UiEvent.STATE: ("polishing", "")}),
    (5.0, {UiEvent.RESULT: ("ok", "The quick brown fox jumps over the lazy dog."),
           UiEvent.STATE: ("idle", "ready")}),
]


def main() -> None:
    AppHelper.callAfter(hud.prepare)
    for delay, payloads in SCRIPT:
        AppHelper.callLater(delay, _step, payloads)
    AppHelper.callLater(3.0, _probe)
    AppHelper.callLater(7.5, _finish)
    AppHelper.runConsoleEventLoop(installInterrupt=True)


def _probe() -> None:
    panel = hud._panel._panel
    f = panel.frame()
    log.info(
        "probe: onscreen=%s alpha=%.1f key=%s frame=(%.0f, %.0f, %.0f, %.0f)",
        bool(panel.isVisible()), panel.alphaValue(), bool(panel.isKeyWindow()),
        f.origin.x, f.origin.y, f.size.width, f.size.height,
    )
    assert panel.isVisible() and not panel.isKeyWindow()


def _step(payloads) -> None:
    log.info("render %s", {e.value: p for e, p in payloads.items()})
    hud.render(payloads)


def _finish() -> None:
    visible = hud._machine.vm.visible
    log.info("final state visible=%s (want False after done-flash tick)", visible)
    print(f"DEMO {'PASS' if not visible else 'FAIL'}")
    AppHelper.stopEventLoop()


if __name__ == "__main__":
    main()
