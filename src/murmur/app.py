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


def preview(text: str, limit: int = 60) -> str:
    """Truncate *text* for INFO logs — full transcripts stay out of
    ~/.murmur/murmur.log (unbounded, on by default); DEBUG carries them."""
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


class Controller:
    def __init__(self, cfg: Config) -> None:
        from .audio import Recorder
        from .bench import BenchLog, Timings
        from .cleanup import CleanupEngine
        from .hotkey import EventTap, HotkeyMachine
        from .hud import Hud
        from .menubar import MenuBarApp
        from .stt import SttWorker, Transcriber
        from .uibus import MainThreadBus, UiEvent

        self._ev = UiEvent
        self.hud = (
            Hud(
                position=cfg.hud.position,
                show_draft=cfg.hud.show_draft,
                sounds=cfg.hud.sounds,
                max_chars=cfg.hud.max_chars,
            )
            if cfg.hud.enabled
            else None
        )
        self.bus = MainThreadBus(self._render_ui)
        self.machine = HotkeyMachine(
            cfg.hotkey.ptt, cfg.hotkey.toggle, cfg.hotkey.stop, cfg.hotkey.cancel
        )
        self.vad_enabled = cfg.vad.enabled
        self._endpointer = None
        self._session_gen = 0
        if cfg.vad.enabled:
            try:
                from .vad import Endpointer, EndpointDetector, WebrtcBackend

                backend = WebrtcBackend(cfg.vad.aggressiveness)
                frame_ms = backend.frame_samples * 1000 // 16000
                self._endpointer = Endpointer(
                    backend=backend,
                    detector=EndpointDetector(
                        cfg.vad.silence_ms,
                        cfg.vad.min_speech_ms,
                        frame_ms,
                        cfg.vad.energy_gate_dbfs,
                    ),
                    max_session_s=cfg.vad.max_session_s,
                )
            except Exception:
                log.exception("vad: backend failed to load — auto-stop disabled")
        self.recorder = Recorder(
            on_block=self._on_block if (self.hud or self._endpointer) else None
        )
        self.worker = SttWorker(
            Transcriber(cfg.stt.model),
            self.recorder.q,
            on_text=self._on_text,
            on_ready=lambda: self._model_ready("stt"),
            on_draft=(lambda text: self.bus.post(UiEvent.DRAFT, text)) if self.hud else None,
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
            hud_enabled=cfg.hud.enabled if self.hud else None,
            on_hud_toggle=self._set_hud_enabled,
            vad_enabled=cfg.vad.enabled if self._endpointer else None,
            on_vad_toggle=self._set_vad_enabled,
        )
        self.bench = BenchLog()
        self.timings = Timings()

    def _post_state(self, state: str, detail: str = "") -> None:
        self.bus.post(self._ev.STATE, (state, detail))

    def _render_ui(self, payloads: dict) -> None:
        # MainThreadBus render callback — the only place AppKit-facing UI
        # (menu bar title, HUD panel) is touched, always on the main thread.
        state = payloads.get(self._ev.STATE)
        if state is not None:
            self.app.set_state(*state)
        if self.hud is not None:
            self.hud.render(payloads)

    def _on_block(self, block) -> None:
        # Audio callback thread: numpy reductions + coalesced posts only.
        # Never touch the recorder or the pipeline from here.
        from .audio import block_dbfs
        from .hud import level01

        if self.hud is not None:
            self.bus.post(self._ev.LEVEL, level01(block_dbfs(block)))
        ep = self._endpointer
        if ep is not None and ep.armed:
            event, fraction = ep.process(block)
            if fraction is not None:
                self.bus.post(self._ev.ENDPOINT_PROGRESS, fraction)
            if event == "endpoint":
                from PyObjCTools import AppHelper

                AppHelper.callAfter(self._on_vad_endpoint, ep.generation)
            elif event == "cap_warning":
                log.warning("vad: session time limit approaching")
                self._post_state("recording", "recording — time limit soon")

    def _on_vad_endpoint(self, generation: int) -> None:
        # Main thread. The generation check makes a stale endpoint queued
        # across sessions a no-op; external_stop() makes it a no-op in any
        # state but TOGGLE (e.g. the user already stopped or cancelled).
        if generation != self._session_gen:
            log.debug("vad: stale endpoint (gen %d != %d)", generation, self._session_gen)
            return
        if self.machine.external_stop():
            log.info("vad: natural pause — auto-stop")
            self._stop_recording()

    def _set_hud_enabled(self, enabled: bool) -> None:
        # rumps menu callback (main thread).
        if self.hud is not None:
            self.hud.enabled = enabled
            self.hud.render({})  # apply immediately (hides the panel if shown)
        log.info("hud: %s (menu)", "enabled" if enabled else "disabled")

    def _on_action(self, action) -> None:
        # Runs in the event tap callback — keep it short.
        from .hotkey import Action

        if action is Action.START_PTT:
            self._start_recording("push-to-talk")
        elif action is Action.ENTER_TOGGLE:
            log.info("hands-free mode (stop with fn/fn+space, cancel with esc)")
            self._post_state("recording", "recording (hands-free)")
            if self._endpointer is not None and self.vad_enabled:
                self._endpointer.arm(self._session_gen)
        elif action is Action.STOP:
            self._stop_recording()
        elif action is Action.CANCEL:
            log.info("cancelled by user")
            self._end_vad_session()
            self.recorder.cancel()
            self.bus.post(self._ev.RESULT, ("cancelled", ""))

    def _start_recording(self, mode: str) -> None:
        self._session_gen += 1
        try:
            self.recorder.start()
        except Exception:
            log.exception("audio: could not start recording")
            self.machine.reset()
            return
        log.info("recording (%s)", mode)
        self._post_state("recording", f"recording ({mode})")

    def _stop_recording(self) -> None:
        self._end_vad_session()
        self.timings.start()  # t0 = recording stop
        self.recorder.stop()
        self._post_state("transcribing")

    def _end_vad_session(self) -> None:
        # Invalidate any endpoint already in flight and stop classifying.
        self._session_gen += 1
        if self._endpointer is not None:
            self._endpointer.disarm()

    def _set_vad_enabled(self, enabled: bool) -> None:
        # rumps menu callback (main thread); read at the next hands-free arm.
        self.vad_enabled = enabled
        log.info("vad: auto-stop %s (menu)", "enabled" if enabled else "disabled")

    def _on_text(self, text: str | None) -> None:
        # Runs on the STT worker thread. ``None`` = utterance cancelled.
        from .cleanup import run_cleanup
        from .insert import insert_text

        if text is None:
            self.machine.done()
            self._post_state("idle", "ready")
            return
        self.timings.stamp("stt_finalize")
        if text:
            log.info("transcript: %r (%d chars)", preview(text), len(text))
            log.debug("transcript full: %r", text)
            if self.cleanup_enabled:
                self._post_state("polishing")
                text, status = run_cleanup(
                    self.cleanup, text, self.cleanup_style, self._cleanup_timeout
                )
                self.timings.stamp("cleanup")
                if status == "ok":
                    log.info("cleanup: ok %r", preview(text))
                    log.debug("cleanup full: %r", text)
                else:
                    log.info("cleanup: %s, inserting raw", status)
            try:
                insert_text(text)
                self.timings.stamp("insert")
                self.bus.post(self._ev.RESULT, ("ok", text))
            except Exception:
                log.exception("insert failed — check Accessibility permission")
                self.bus.post(self._ev.RESULT, ("error", "insert failed"))
            self.bench.add(self.timings)
        else:
            log.info("empty utterance, nothing to insert")
            self.bus.post(self._ev.RESULT, ("empty", ""))
        self.machine.done()
        self._post_state("idle", "ready")

    def _model_ready(self, name: str) -> None:
        with self._ready_lock:
            self._pending_models.discard(name)
            if self._pending_models or self._models_ready:
                return
            self._models_ready = True
        self._post_state("idle", "ready")

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
        if self.hud is not None:
            # Build the panel once the run loop is up — never lazily inside
            # a dictation (panel construction in the tap callback path would
            # delay event delivery system-wide).
            from PyObjCTools import AppHelper

            AppHelper.callAfter(self.hud.prepare)
        self.app.run()
        return 0


def run_app(cfg: Config) -> int:
    return Controller(cfg).run()
