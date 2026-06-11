"""Hotkey handling: a pure state machine plus the CGEventTap that feeds it.

:class:`HotkeyMachine` is platform-free (unit-tested on any OS); all Quartz
imports are deferred into :class:`EventTap` so this module imports cleanly
without pyobjc installed.

Scheme (config-driven, defaults shown):
- push-to-talk: hold ``fn`` → record while held; release → stop.
- toggle: ``fn+space`` while recording switches to hands-free; a second
  ``fn+space``, a tap of the PTT key, or the optional ``stop`` key stops.
- cancel: ``esc`` while recording (either mode) discards the utterance —
  nothing is transcribed or inserted (Wispr Flow muscle memory).
Toggle/stop/cancel keypresses are swallowed; everything else passes through.
"""

from __future__ import annotations

import enum
import logging
from dataclasses import dataclass

log = logging.getLogger(__name__)

# Virtual keycodes for the remappable keys (HIToolbox Events.h).
KEYCODES = {
    "fn": 63,
    "space": 49,
    "esc": 53,
    "right_option": 61,
    "left_option": 58,
    "right_command": 54,
    "right_shift": 60,
    "right_control": 62,
}

# Keycodes that arrive as flagsChanged rather than keyDown.
MODIFIER_KEYCODES = frozenset({63, 61, 58, 54, 55, 60, 56, 62, 59})


class Action(enum.Enum):
    NONE = "none"
    START_PTT = "start_ptt"
    ENTER_TOGGLE = "enter_toggle"  # ptt → hands-free; recording continues
    STOP = "stop"  # finalize: transcribe + insert
    CANCEL = "cancel"  # discard: nothing transcribed, nothing inserted


@dataclass(frozen=True)
class Decision:
    action: Action = Action.NONE
    swallow: bool = False


PASS = Decision()


class State(enum.Enum):
    IDLE = "idle"
    PTT = "ptt"
    TOGGLE = "toggle"
    BUSY = "busy"  # transcribing; hotkeys inert until done()


class HotkeyMachine:
    """Consumes (keycode, down) events, emits :class:`Decision` for each.

    The caller (EventTap) swallows the OS event when ``decision.swallow`` and
    forwards non-NONE actions to the controller. After a STOP action the
    machine stays BUSY until :meth:`done` is called post-insertion.
    """

    def __init__(
        self,
        ptt: str = "fn",
        toggle: str = "fn+space",
        stop: str = "",
        cancel: str = "esc",
    ):
        self.ptt_key = self._keycode(ptt)
        mod, sep, key = toggle.partition("+")
        if not sep:
            raise ValueError(f"toggle hotkey must be 'modifier+key', got {toggle!r}")
        self.toggle_mod = self._keycode(mod)
        self.toggle_key = self._keycode(key)
        # Both optional: fn tap / fn+space already stop hands-free, and
        # cancel="" disables the discard gesture entirely.
        self.stop_key = self._keycode(stop) if stop else None
        self.cancel_key = self._keycode(cancel) if cancel else None
        self.state = State.IDLE
        self._mods_down: set[int] = set()

    @staticmethod
    def _keycode(name: str) -> int:
        try:
            return KEYCODES[name.strip().lower()]
        except KeyError:
            raise ValueError(
                f"unknown key {name!r}; known: {', '.join(sorted(KEYCODES))}"
            ) from None

    def on_modifier(self, keycode: int, is_down: bool) -> Decision:
        """A flagsChanged event (modifier key went down or up)."""
        if is_down:
            self._mods_down.add(keycode)
        else:
            self._mods_down.discard(keycode)

        if self.state is State.IDLE and keycode == self.ptt_key and is_down:
            self.state = State.PTT
            return Decision(Action.START_PTT)
        if self.state is State.PTT and keycode == self.ptt_key and not is_down:
            self.state = State.BUSY
            return Decision(Action.STOP)
        if self.state is State.TOGGLE and keycode == self.ptt_key and is_down:
            # Tapping the PTT key again is the most discoverable way out of
            # hands-free mode (Esc and the toggle combo also work).
            self.state = State.BUSY
            return Decision(Action.STOP)
        return PASS

    def on_key_down(self, keycode: int) -> Decision:
        if self.state is State.PTT:
            if keycode == self.toggle_key and self.toggle_mod in self._mods_down:
                self.state = State.TOGGLE
                return Decision(Action.ENTER_TOGGLE, swallow=True)
            if self.cancel_key is not None and keycode == self.cancel_key:
                self.state = State.BUSY
                return Decision(Action.CANCEL, swallow=True)
            return PASS
        if self.state is State.TOGGLE:
            if self.cancel_key is not None and keycode == self.cancel_key:
                self.state = State.BUSY
                return Decision(Action.CANCEL, swallow=True)
            if (self.stop_key is not None and keycode == self.stop_key) or (
                keycode == self.toggle_key and self.toggle_mod in self._mods_down
            ):
                self.state = State.BUSY
                return Decision(Action.STOP, swallow=True)
            return PASS
        if self.state is State.BUSY:
            # The PTT key already stopped the recording on its way down; eat
            # the trailing toggle key of a fn+space stop so it isn't typed.
            if keycode == self.toggle_key and self.toggle_mod in self._mods_down:
                return Decision(swallow=True)
            return PASS
        return PASS

    def done(self) -> None:
        """Transcription + insertion finished; accept hotkeys again."""
        self.state = State.IDLE

    def reset(self) -> None:
        """Abort whatever is in flight (e.g. recording failed to start)."""
        self.state = State.IDLE


class EventTap:
    """Active CGEventTap feeding flagsChanged/keyDown into a HotkeyMachine.

    One *active* (default) tap handles both event types: active so toggle/stop
    keypresses can be swallowed by returning None from the callback;
    flagsChanged events are always passed through unmodified. Must be started
    on the thread that owns the main CFRunLoop, before the rumps app runs.
    """

    def __init__(self, machine: HotkeyMachine, on_action):
        self._machine = machine
        self._on_action = on_action
        self._tap = None
        self._modifier_masks: dict[int, int] = {}

    def start(self) -> None:
        import Quartz

        self._quartz = Quartz
        # flagsChanged carries the keycode of the modifier that changed; the
        # corresponding mask bit tells us whether it went down or up.
        self._modifier_masks = {
            63: Quartz.kCGEventFlagMaskSecondaryFn,
            58: Quartz.kCGEventFlagMaskAlternate,
            61: Quartz.kCGEventFlagMaskAlternate,
            55: Quartz.kCGEventFlagMaskCommand,
            54: Quartz.kCGEventFlagMaskCommand,
            56: Quartz.kCGEventFlagMaskShift,
            60: Quartz.kCGEventFlagMaskShift,
            59: Quartz.kCGEventFlagMaskControl,
            62: Quartz.kCGEventFlagMaskControl,
        }
        mask = Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged) | Quartz.CGEventMaskBit(
            Quartz.kCGEventKeyDown
        )
        self._tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionDefault,
            mask,
            self._callback,
            None,
        )
        if self._tap is None:
            raise RuntimeError(
                "could not create event tap — grant Input Monitoring "
                "(and Accessibility) to the launching app, then restart it"
            )
        source = Quartz.CFMachPortCreateRunLoopSource(None, self._tap, 0)
        Quartz.CFRunLoopAddSource(
            Quartz.CFRunLoopGetCurrent(), source, Quartz.kCFRunLoopCommonModes
        )
        Quartz.CGEventTapEnable(self._tap, True)
        log.info("hotkey: event tap installed")

    def _callback(self, proxy, etype, event, refcon):
        # Must stay fast: classify, update the FSM, signal the controller.
        q = self._quartz
        if etype in (q.kCGEventTapDisabledByTimeout, q.kCGEventTapDisabledByUserInput):
            log.warning("hotkey: tap disabled (%s), re-enabling", etype)
            q.CGEventTapEnable(self._tap, True)
            return event

        keycode = q.CGEventGetIntegerValueField(event, q.kCGKeyboardEventKeycode)
        if etype == q.kCGEventFlagsChanged:
            mask = self._modifier_masks.get(keycode)
            if mask is None:
                return event
            is_down = bool(q.CGEventGetFlags(event) & mask)
            decision = self._machine.on_modifier(keycode, is_down)
        elif etype == q.kCGEventKeyDown:
            decision = self._machine.on_key_down(keycode)
        else:
            return event

        if decision.action is not Action.NONE:
            self._on_action(decision.action)
        return None if decision.swallow else event
