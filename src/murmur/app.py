"""App controller: wires hotkeys, audio, STT, insertion, and the menu bar.

Threading (SPEC §5):
- main thread: rumps run loop + CGEventTap source (tap installed before run)
- audio thread: sounddevice callback → queue of PCM blocks
- STT worker: owns Parakeet, streams blocks, emits final text on stop

State: IDLE → RECORDING(ptt|toggle) → TRANSCRIBING → IDLE. The HotkeyMachine
holds the authoritative state; the controller reacts to its actions and the
menu bar mirrors them.
"""

from __future__ import annotations

import logging

from .config import Config

log = logging.getLogger(__name__)


class Controller:
    def __init__(self, cfg: Config) -> None:
        from .audio import Recorder
        from .bench import BenchLog, Timings
        from .hotkey import EventTap, HotkeyMachine
        from .menubar import MenuBarApp
        from .stt import SttWorker, Transcriber

        self.machine = HotkeyMachine(cfg.hotkey.ptt, cfg.hotkey.toggle, cfg.hotkey.stop)
        self.recorder = Recorder()
        self.worker = SttWorker(
            Transcriber(cfg.stt.model),
            self.recorder.q,
            on_text=self._on_text,
            on_ready=lambda: self.app.set_state("idle", "ready"),
        )
        self.tap = EventTap(self.machine, self._on_action)
        self.app = MenuBarApp()
        self.bench = BenchLog()
        self.timings = Timings()

    def _on_action(self, action) -> None:
        # Runs in the event tap callback — keep it short.
        from .hotkey import Action

        if action is Action.START_PTT:
            self._start_recording("push-to-talk")
        elif action is Action.ENTER_TOGGLE:
            log.info("hands-free mode (stop with Esc or the toggle hotkey)")
            self.app.set_state("recording", "recording (hands-free)")
        elif action is Action.STOP:
            self._stop_recording()

    def _start_recording(self, mode: str) -> None:
        try:
            self.recorder.start()
        except Exception:
            log.exception("audio: could not start recording")
            self.machine.reset()
            return
        log.info("recording (%s)", mode)
        self.app.set_state("recording", f"recording ({mode})")

    def _stop_recording(self) -> None:
        self.timings.start()  # t0 = recording stop
        self.recorder.stop()
        self.app.set_state("transcribing")

    def _on_text(self, text: str) -> None:
        # Runs on the STT worker thread.
        from .insert import insert_text

        self.timings.stamp("stt_finalize")
        if text:
            log.info("transcript: %r", text)
            try:
                insert_text(text)
                self.timings.stamp("insert")
            except Exception:
                log.exception("insert failed — transcript is on the clipboard")
            self.bench.add(self.timings)
        else:
            log.info("empty utterance, nothing to insert")
        self.machine.done()
        self.app.set_state("idle", "ready")

    def run(self) -> int:
        from . import permissions

        for line in permissions.report().splitlines():
            log.info("%s", line)
        if permissions.microphone_status() is not True:
            permissions.request_microphone()

        self.worker.start()
        try:
            self.tap.start()
        except RuntimeError as exc:
            log.error("%s", exc)
            permissions.request_input_monitoring()
            return 1
        self.app.run()
        return 0


def run_app(cfg: Config) -> int:
    return Controller(cfg).run()
