"""App controller: wires hotkeys, audio, STT, cleanup, insertion, and the menu bar.

Threading (SPEC §5):
- main thread: rumps run loop + CGEventTap source (tap installed before run)
- audio thread: sounddevice callback → queue of PCM blocks
- STT worker: owns Parakeet, streams blocks, emits final text on stop;
  the LLM cleanup pass also runs here, synchronously, so insert ordering
  is preserved (worst case is the cleanup timeout)
- cleanup loader: loads + warms the mlx-lm model at startup, then exits

State: IDLE → RECORDING(ptt|toggle) → TRANSCRIBING → IDLE. The HotkeyMachine
holds the authoritative state; the controller reacts to its actions and the
menu bar mirrors them.
"""

from __future__ import annotations

import logging
import threading

from .config import Config

log = logging.getLogger(__name__)


class Controller:
    def __init__(self, cfg: Config) -> None:
        from .audio import Recorder
        from .bench import BenchLog, Timings
        from .cleanup import CleanupEngine
        from .hotkey import EventTap, HotkeyMachine
        from .menubar import MenuBarApp
        from .stt import SttWorker, Transcriber

        self.machine = HotkeyMachine(cfg.hotkey.ptt, cfg.hotkey.toggle, cfg.hotkey.stop)
        self.recorder = Recorder()
        self.worker = SttWorker(
            Transcriber(cfg.stt.model),
            self.recorder.q,
            on_text=self._on_text,
            on_ready=lambda: self._model_ready("stt"),
        )
        self.cleanup_enabled = cfg.cleanup.enabled
        self.cleanup_style = cfg.cleanup.style
        self._cleanup_timeout = cfg.cleanup.timeout_s
        self.cleanup = CleanupEngine(cfg.cleanup.model)
        self._cleanup_loader: threading.Thread | None = None
        self._ready_lock = threading.Lock()
        self._pending_models = {"stt"} | ({"cleanup"} if self.cleanup_enabled else set())
        self._models_ready = False
        self.tap = EventTap(self.machine, self._on_action)
        self.app = MenuBarApp(
            cleanup_enabled=self.cleanup_enabled,
            style=self.cleanup_style,
            on_cleanup_toggle=self._set_cleanup_enabled,
            on_style_change=self._set_cleanup_style,
        )
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
        from .cleanup import run_cleanup
        from .insert import insert_text

        self.timings.stamp("stt_finalize")
        if text:
            log.info("transcript: %r", text)
            if self.cleanup_enabled:
                text, status = run_cleanup(
                    self.cleanup, text, self.cleanup_style, self._cleanup_timeout
                )
                self.timings.stamp("cleanup")
                if status == "ok":
                    log.info("cleanup: ok %r", text)
                else:
                    log.info("cleanup: %s, inserting raw", status)
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

    def _model_ready(self, name: str) -> None:
        with self._ready_lock:
            self._pending_models.discard(name)
            if self._pending_models or self._models_ready:
                return
            self._models_ready = True
        self.app.set_state("idle", "ready")

    def _set_cleanup_enabled(self, enabled: bool) -> None:
        # rumps menu callback (main thread); the STT worker reads the flag.
        self.cleanup_enabled = enabled
        log.info("cleanup: %s (menu)", "enabled" if enabled else "disabled")
        if enabled:
            self._start_cleanup_loader()

    def _set_cleanup_style(self, style: str) -> None:
        self.cleanup_style = style
        log.info("cleanup: style=%s (menu)", style)

    def _start_cleanup_loader(self) -> None:
        if self._cleanup_loader is not None:
            return
        self._cleanup_loader = threading.Thread(
            target=self._load_cleanup, name="cleanup-loader", daemon=True
        )
        self._cleanup_loader.start()

    def _load_cleanup(self) -> None:
        try:
            self.cleanup.load()
            self.cleanup.warmup()
        except Exception:
            log.exception("cleanup: model failed to load — cleanup disabled")
            self.cleanup_enabled = False
        self._model_ready("cleanup")

    def run(self) -> int:
        from . import permissions

        for line in permissions.report().splitlines():
            log.info("%s", line)
        if permissions.microphone_status() is not True:
            permissions.request_microphone()

        self.worker.start()
        if self.cleanup_enabled:
            self._start_cleanup_loader()
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
