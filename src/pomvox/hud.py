"""Floating HUD showing live draft tokens while recording (Phase 2).

Split like ``stt.py``/``cleanup.py``: the state machine, geometry, and text
helpers are pure module-level logic (unit-tested anywhere); ``HudPanel``
owns the NSPanel behind deferred AppKit imports and is only ever touched on
the main thread (the ``MainThreadBus`` render callback). The panel is a
non-activating, non-key, click-through display — it can never take focus
from the field the user is dictating into.

Events arrive as one drained ``{UiEvent: payload}`` dict per main-loop
wake-up. Apply order is fixed (STATE → DRAFT → LEVEL → RESULT) so a RESULT
posted just before the controller's trailing ``idle`` STATE still wins the
"done" flash when both land in the same drain.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, replace

from .uibus import UiEvent

log = logging.getLogger(__name__)

DONE_FLASH_S = 1.4
ERROR_FLASH_S = 2.5
CANCEL_FLASH_S = 0.8
PILL_SIZE = (420.0, 64.0)
MARGIN = 24.0

# dBFS range mapped onto the 0..1 level bars: quiet rooms sit near the
# floor, normal speech should peak the bars.
LEVEL_FLOOR_DBFS = -60.0
LEVEL_CEIL_DBFS = -10.0

# Played by the renderer on state *entry* (config-gated). Eyes-off
# hands-free dictation needs audible confirmation; the pill sits outside
# foveal vision.
STATE_SOUNDS = {"recording": "Tink", "done": "Pop", "error": "Basso"}

_APPLY_ORDER = (
    UiEvent.STATE,
    UiEvent.DRAFT,
    UiEvent.LEVEL,
    UiEvent.ENDPOINT_PROGRESS,
    UiEvent.RESULT,
)


def split_stable_prefix(prev: str, cur: str) -> tuple[str, str]:
    """Split *cur* into (stable, new) against the previous draft — the
    two-tone treatment: settled words bright, the newest chunk dimmed.
    Parakeet may revise earlier words between chunks; revisions count as
    new."""
    n = 0
    for a, b in zip(prev, cur):
        if a != b:
            break
        n += 1
    return cur[:n], cur[n:]


class LevelHistory:
    """Ring buffer of recent mic levels for the waveform bars (pure)."""

    def __init__(self, n: int = 24) -> None:
        self._n = n
        self._values: list[float] = [0.0] * n

    def push(self, level: float) -> None:
        self._values = self._values[1:] + [level]

    def bars(self) -> list[float]:
        return list(self._values)

    def reset(self) -> None:
        self._values = [0.0] * self._n


def truncate_head(text: str, max_chars: int) -> str:
    """Keep the tail — the newest words must stay visible."""
    if len(text) <= max_chars:
        return text
    return "…" + text[-(max_chars - 1) :]


def pill_frame(
    visible_frame: tuple[float, float, float, float],
    pill_size: tuple[float, float] = PILL_SIZE,
    margin: float = MARGIN,
    position: str = "bottom-center",
) -> tuple[float, float, float, float]:
    """Pill rect inside *visible_frame* (origins can be negative on
    secondary displays — never assume (0, 0))."""
    vx, vy, vw, vh = visible_frame
    pw, ph = pill_size
    x = vx + (vw - pw) / 2
    if position == "notch":
        y = vy + vh - ph  # flush under the menu bar, blending into the notch
    elif position == "top-center":
        y = vy + vh - ph - margin
    else:
        y = vy + margin
    return (x, y, pw, ph)


def level01(dbfs: float) -> float:
    """Map a dBFS reading onto 0..1 for the level bars."""
    span = LEVEL_CEIL_DBFS - LEVEL_FLOOR_DBFS
    return min(1.0, max(0.0, (dbfs - LEVEL_FLOOR_DBFS) / span))


@dataclass(frozen=True)
class HudViewModel:
    state: str = "hidden"  # hidden|recording|transcribing|polishing|done|error|cancelled
    status: str = ""
    draft: str = ""
    final: str = ""
    level: float = 0.0
    endpoint_fraction: float = 0.0  # 0..1 progress toward VAD auto-stop
    hide_at: float | None = None

    @property
    def visible(self) -> bool:
        return self.state != "hidden"


_HIDDEN = HudViewModel()


class HudStateMachine:
    """Pure: drained bus payloads in, view model out. Hide deadlines are
    data (``hide_at``); the renderer schedules a ``tick`` and a stale tick
    is harmless because it only hides past an unexpired deadline."""

    def __init__(self, max_chars: int = 120) -> None:
        self._max_chars = max_chars
        self.vm = _HIDDEN

    def apply(self, payloads: dict, now: float) -> HudViewModel:
        # A drain carrying both a RESULT and the controller's trailing
        # "idle" STATE: the idle is redundant — RESULT's terminal state
        # (done flash / error / hidden) owns the hide.
        if UiEvent.RESULT in payloads:
            state = payloads.get(UiEvent.STATE)
            if state is not None and state[0] == "idle":
                payloads = {k: v for k, v in payloads.items() if k is not UiEvent.STATE}
        for event in _APPLY_ORDER:
            if event in payloads:
                self._one(event, payloads[event], now)
        return self.vm

    def tick(self, now: float) -> HudViewModel:
        if self.vm.hide_at is not None and now >= self.vm.hide_at:
            self.vm = _HIDDEN
        return self.vm

    def _one(self, event: UiEvent, payload, now: float) -> None:
        vm = self.vm
        if event is UiEvent.STATE:
            state, detail = payload
            if state == "recording":
                self.vm = HudViewModel(state="recording", status=detail or "listening…")
            elif state in ("transcribing", "polishing") and vm.visible:
                self.vm = replace(vm, state=state, status="finishing…", hide_at=None)
            elif state == "idle" and vm.state in ("recording", "transcribing", "polishing"):
                self.vm = _HIDDEN
            # idle while hidden/done/error: leave the flash (or nothing) alone
        elif event is UiEvent.DRAFT and vm.state == "recording":
            self.vm = replace(vm, draft=truncate_head(payload, self._max_chars))
        elif event is UiEvent.LEVEL and vm.state == "recording":
            self.vm = replace(vm, level=payload)
        elif event is UiEvent.ENDPOINT_PROGRESS and vm.state == "recording":
            self.vm = replace(vm, endpoint_fraction=payload)
        elif event is UiEvent.RESULT and vm.visible:
            status, text = payload
            if status == "ok":
                self.vm = HudViewModel(
                    state="done",
                    final=truncate_head(text, self._max_chars),
                    hide_at=now + DONE_FLASH_S,
                )
            elif status == "error":
                self.vm = HudViewModel(
                    state="error", status=f"⚠️ {text}", hide_at=now + ERROR_FLASH_S
                )
            elif status == "cancelled":
                self.vm = HudViewModel(
                    state="cancelled", status="cancelled", hide_at=now + CANCEL_FLASH_S
                )
            else:  # empty utterance — nothing to show
                self.vm = _HIDDEN


_WAVE_CLS = None


def _waveform_class():
    """NSView subclass drawing the level bars; registered once. Pull-model:
    a 15 Hz timer (running only while recording) samples `current_level`
    into the ring buffer — no extra cross-thread traffic beyond the LEVEL
    posts the bus already coalesces."""
    global _WAVE_CLS
    if _WAVE_CLS is None:
        import objc
        from AppKit import NSBezierPath, NSColor, NSView
        from Foundation import NSMakeRect

        class _Waveform(NSView):
            def initWithFrame_(self, frame):
                # objc.super, not super(): plain super() breaks the ObjC
                # designated-initializer chain under pyobjc.
                self = objc.super(_Waveform, self).initWithFrame_(frame)
                if self is not None:
                    self.history = LevelHistory()
                    self.current_level = 0.0
                return self

            def tick_(self, _timer):
                self.history.push(self.current_level)
                self.setNeedsDisplay_(True)

            def isFlipped(self):
                return False

            def drawRect_(self, _rect):
                bounds = self.bounds()
                bars = self.history.bars()
                bw = bounds.size.width / len(bars)
                NSColor.whiteColor().colorWithAlphaComponent_(0.9).setFill()
                for i, v in enumerate(bars):
                    h = max(2.0, v * bounds.size.height)
                    r = NSMakeRect(
                        i * bw + bw * 0.2,
                        (bounds.size.height - h) / 2,
                        bw * 0.6,
                        h,
                    )
                    NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                        r, bw * 0.3, bw * 0.3
                    ).fill()

        _WAVE_CLS = _Waveform
    return _WAVE_CLS


class HudPanel:
    """AppKit renderer: a dumb view over :class:`HudViewModel`.

    Never-steals-focus recipe: NSPanel subclass refusing key/main status,
    Borderless|NonactivatingPanel mask, hidesOnDeactivate off, status
    window level, joins all Spaces incl. fullscreen, ignores mouse, shown
    with ``orderFrontRegardless`` only. ``setSharingType_`` keeps live
    draft text out of screen shares.
    """

    def __init__(self, position: str = "bottom-center", show_draft: bool = True,
                 sounds: bool = True) -> None:
        self._position = position
        self._show_draft = show_draft
        self._sounds = sounds
        self._panel = None
        self._status_label = None
        self._draft_label = None
        self._wave = None
        self._wave_timer = None
        self._displayed_draft = ""
        self._prev_state = "hidden"

    # -- main thread only ------------------------------------------------

    def prepare(self) -> None:
        """Build the panel ahead of first use (scheduled onto the run loop
        at startup so no construction cost lands inside a dictation)."""
        try:
            self._ensure_panel()
        except Exception:
            log.exception("hud: panel construction failed — HUD disabled")
            self._panel = False  # sentinel: don't retry every render

    def render(self, vm: HudViewModel) -> None:
        if self._panel is None:
            self._ensure_panel()
        if self._panel is False:
            return
        if vm.visible:
            self._play_sound_on_entry(vm.state)
            self._update_labels(vm)
            self._update_waveform(vm)
            if self._prev_state == "hidden":
                self._show()
        elif self._prev_state != "hidden":
            self._hide()
        self._prev_state = vm.state

    # -- internals ---------------------------------------------------------

    def _ensure_panel(self) -> None:
        import objc
        from AppKit import (
            NSColor,
            NSFont,
            NSPanel,
            NSScreen,
            NSStatusWindowLevel,
            NSTextField,
            NSWindowCollectionBehaviorCanJoinAllSpaces,
            NSWindowCollectionBehaviorFullScreenAuxiliary,
            NSWindowCollectionBehaviorIgnoresCycle,
            NSWindowCollectionBehaviorStationary,
            NSWindowSharingNone,
            NSWindowStyleMaskBorderless,
            NSWindowStyleMaskNonactivatingPanel,
        )
        from Foundation import NSMakeRect

        class _Panel(NSPanel):
            # The hard guarantee: this window can never take keyboard focus.
            def canBecomeKeyWindow(self):
                return False

            def canBecomeMainWindow(self):
                return False

        w, h = PILL_SIZE
        panel = _Panel.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, w, h),
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            2,  # NSBackingStoreBuffered
            False,
        )
        panel.setHidesOnDeactivate_(False)  # default True vanishes accessory-app HUDs
        panel.setLevel_(NSStatusWindowLevel)  # after styleMask: mask changes can reset it
        panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorIgnoresCycle
        )
        panel.setIgnoresMouseEvents_(True)
        panel.setSharingType_(NSWindowSharingNone)
        panel.setOpaque_(False)
        panel.setBackgroundColor_(NSColor.clearColor())
        panel.setHasShadow_(True)
        panel.setAlphaValue_(0.0)

        from Quartz import CGColorCreateGenericRGB

        content = panel.contentView()
        content.setWantsLayer_(True)
        layer = content.layer()
        layer.setCornerRadius_(16.0)
        layer.setBackgroundColor_(CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.85))

        def label(x: float, y: float, size: float, color):
            f = NSTextField.labelWithString_("")
            f.setFrame_(NSMakeRect(x, y, w - x - 20, size + 8))
            f.setFont_(NSFont.systemFontOfSize_(size))
            f.setTextColor_(color)
            f.setLineBreakMode_(5)  # NSLineBreakByTruncatingHead — newest words win
            f.setMaximumNumberOfLines_(1)
            content.addSubview_(f)
            return f

        wave = _waveform_class().alloc().initWithFrame_(NSMakeRect(20, 16, 84, 32))
        content.addSubview_(wave)
        self._wave = wave
        self._status_label = label(116.0, 34.0, 14.0, NSColor.whiteColor())
        self._draft_label = label(116.0, 10.0, 13.0, NSColor.lightGrayColor())
        self._screen_cls = NSScreen
        self._panel = panel
        log.info("hud: panel ready")

    def _update_labels(self, vm: HudViewModel) -> None:
        glyph = {"recording": "●", "transcribing": "✍️", "polishing": "✍️",
                 "done": "✓", "error": "", "cancelled": "✕"}.get(vm.state, "")
        head = " ".join(p for p in (glyph, vm.status) if p)
        if vm.state == "recording" and vm.endpoint_fraction > 0.4:
            # The auto-stop countdown: fills as silence accumulates, snaps
            # back the moment speech resumes — auto-stop is never a surprise.
            lit = round(vm.endpoint_fraction * 5)
            head += f" · finishing {'▮' * lit}{'▯' * (5 - lit)}"
        self._status_label.setStringValue_(head)
        if vm.state == "done":
            self._draft_label.setStringValue_(vm.final)
        elif vm.state == "recording" and self._show_draft:
            self._set_two_tone_draft(vm.draft)
        elif not self._show_draft or vm.state in ("error", "cancelled"):
            self._draft_label.setStringValue_("")

    def _set_two_tone_draft(self, draft: str) -> None:
        # Settled words bright, the newest chunk dimmed — the visible cue
        # that text is streaming, not stuck.
        from AppKit import (
            NSColor,
            NSFont,
            NSFontAttributeName,
            NSForegroundColorAttributeName,
            NSMutableAttributedString,
        )

        stable, delta = split_stable_prefix(self._displayed_draft, draft)
        font = NSFont.systemFontOfSize_(13.0)
        out = NSMutableAttributedString.alloc().initWithString_attributes_(
            stable,
            {
                NSFontAttributeName: font,
                NSForegroundColorAttributeName:
                    NSColor.whiteColor().colorWithAlphaComponent_(0.92),
            },
        )
        out.appendAttributedString_(
            NSMutableAttributedString.alloc().initWithString_attributes_(
                delta,
                {
                    NSFontAttributeName: font,
                    NSForegroundColorAttributeName: NSColor.grayColor(),
                },
            )
        )
        self._draft_label.setAttributedStringValue_(out)
        self._displayed_draft = draft

    def _update_waveform(self, vm: HudViewModel) -> None:
        from AppKit import NSTimer

        recording = vm.state == "recording"
        self._wave.setHidden_(not recording)
        self._wave.current_level = vm.level
        if recording and self._wave_timer is None:
            self._wave.history.reset()
            self._displayed_draft = ""
            self._wave_timer = (
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                    1.0 / 15.0, self._wave, "tick:", None, True
                )
            )
        elif not recording and self._wave_timer is not None:
            self._wave_timer.invalidate()
            self._wave_timer = None

    def _play_sound_on_entry(self, state: str) -> None:
        if not self._sounds or state == self._prev_state:
            return
        name = STATE_SOUNDS.get(state)
        if name:
            from AppKit import NSSound

            sound = NSSound.soundNamed_(name)
            if sound:
                sound.play()

    def _show(self) -> None:
        from AppKit import NSEvent

        mouse = NSEvent.mouseLocation()
        screen = next(
            (s for s in self._screen_cls.screens()
             if _contains(s.frame(), mouse)),
            self._screen_cls.mainScreen(),
        )
        vf = screen.visibleFrame()
        x, y, w, h = pill_frame(
            (vf.origin.x, vf.origin.y, vf.size.width, vf.size.height),
            position=self._position,
        )
        from Foundation import NSMakeRect

        self._panel.setFrame_display_(NSMakeRect(x, y, w, h), True)
        self._panel.setAlphaValue_(1.0)
        self._panel.orderFrontRegardless()  # never makeKeyAndOrderFront_

    def _hide(self) -> None:
        from AppKit import NSAnimationContext

        panel = self._panel

        def body(ctx):
            ctx.setDuration_(0.25)
            panel.animator().setAlphaValue_(0.0)

        NSAnimationContext.runAnimationGroup_completionHandler_(
            body, lambda: panel.orderOut_(None) if panel.alphaValue() == 0.0 else None
        )


def _contains(frame, point) -> bool:
    return (
        frame.origin.x <= point.x < frame.origin.x + frame.size.width
        and frame.origin.y <= point.y < frame.origin.y + frame.size.height
    )


class Hud:
    """Glue owned by the controller: machine + panel + tick scheduling.

    ``render`` is the :class:`~pomvox.uibus.MainThreadBus` callback (main
    thread). ``enabled`` is flipped by the menu-bar toggle at runtime.
    """

    def __init__(self, position: str = "bottom-center", show_draft: bool = True,
                 sounds: bool = True, max_chars: int = 120) -> None:
        self.enabled = True
        self._machine = HudStateMachine(max_chars=max_chars)
        self._panel = HudPanel(position=position, show_draft=show_draft, sounds=sounds)

    def prepare(self) -> None:
        self._panel.prepare()

    def apply_config(self, cfg) -> None:
        """Hot-apply a reloaded [hud] section (main thread)."""
        self.enabled = cfg.enabled
        self._machine._max_chars = cfg.max_chars
        self._panel._position = cfg.position
        self._panel._show_draft = cfg.show_draft
        self._panel._sounds = cfg.sounds
        if not cfg.enabled:
            self.render({})  # hide immediately if showing

    def render(self, payloads: dict) -> None:
        import time

        now = time.monotonic()
        vm = self._machine.apply(payloads, now)
        if not self.enabled:
            vm = _HIDDEN
            self._machine.vm = vm
        self._panel.render(vm)
        if vm.hide_at is not None:
            from PyObjCTools import AppHelper

            delay = max(0.0, vm.hide_at - now)
            AppHelper.callLater(delay + 0.01, self._tick)

    def _tick(self) -> None:
        import time

        self._panel.render(self._machine.tick(time.monotonic()))
