"""App controller: wires hotkeys, audio, STT, cleanup, insertion, and the menu bar.

Threading (SPEC §5):
- main thread: rumps run loop + CGEventTap source (tap installed from a
  callAfter once the run loop is live, so a missing Input Monitoring grant
  degrades to the Setup Assistant instead of exiting)
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
from pathlib import Path

from .config import Config

log = logging.getLogger(__name__)


def preview(text: str, limit: int = 60) -> str:
    """Truncate *text* for INFO logs — full transcripts stay out of
    ~/.natter/natter.log (unbounded, on by default); DEBUG carries them."""
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


class Controller:
    def __init__(self, cfg: Config) -> None:
        from .audio import Recorder
        from .bench import BenchLog, Timings
        from .cleanup import CleanupEngine
        from .dictionary import Dictionary
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
        self._endpointer = self._make_endpointer(cfg.vad) if cfg.vad.enabled else None
        self._session_gen = 0
        self.recorder = Recorder(
            on_block=self._on_block if (self.hud or self._endpointer) else None,
            device=cfg.audio.device,
        )
        self.worker = SttWorker(
            Transcriber(cfg.stt.model),
            self.recorder.q,
            on_text=self._on_text,
            on_ready=lambda: self._model_ready("stt"),
            on_draft=(lambda text: self.bus.post(UiEvent.DRAFT, text)) if self.hud else None,
        )
        self.dictionary = Dictionary(
            cfg.dictionary.words, cfg.dictionary.replacements, cfg.dictionary.enabled
        )
        self.cleanup_enabled = cfg.cleanup.enabled
        self.cleanup_style = cfg.cleanup.style
        self._cleanup_timeout = cfg.cleanup.timeout_s
        self.cleanup = CleanupEngine(cfg.cleanup.model, terms_hint=self.dictionary.hint)
        self._cleanup_loader: threading.Thread | None = None
        self._ready_lock = threading.Lock()
        self._pending_models = {"stt"} | ({"cleanup"} if self.cleanup_enabled else set())
        self._models_ready = False
        self.tap = EventTap(self.machine, self._on_action)
        # The history store must exist before MenuBarApp reads self.history
        # to decide whether to show the History… item.
        self.history = None
        if cfg.history.enabled:
            try:
                import time

                from .history import HistoryStore

                self.history = HistoryStore(retention_days=cfg.history.retention_days)
                self.history.purge(now=time.time())
            except Exception:
                log.exception("history: store failed to open — history disabled")
        self.app = MenuBarApp(
            cleanup_enabled=self.cleanup_enabled,
            style=self.cleanup_style,
            on_cleanup_toggle=self._set_cleanup_enabled,
            on_style_change=self._set_cleanup_style,
            hud_enabled=cfg.hud.enabled if self.hud else None,
            on_hud_toggle=self._set_hud_enabled,
            vad_enabled=cfg.vad.enabled if self._endpointer else None,
            on_vad_toggle=self._set_vad_enabled,
            on_setup=self._open_onboarding,
            on_copy_last=self._copy_last_transcript,
            on_open_config=self._open_config,
            on_reload_config=self._reload_config,
            on_open_hub=self._open_hub,
        )
        self.bench = BenchLog()
        self.timings = Timings()
        self._cfg = cfg
        self._last_transcript = ""
        self._tap_installed = False
        self._onboarding = None
        self._ob_flow = None
        self._poll_timer = None
        self._config_watcher = None

    @staticmethod
    def _make_endpointer(vad_cfg):
        try:
            from .vad import Endpointer, EndpointDetector, WebrtcBackend

            backend = WebrtcBackend(vad_cfg.aggressiveness)
            frame_ms = backend.frame_samples * 1000 // 16000
            return Endpointer(
                backend=backend,
                detector=EndpointDetector(
                    vad_cfg.silence_ms,
                    vad_cfg.min_speech_ms,
                    frame_ms,
                    vad_cfg.energy_gate_dbfs,
                ),
                max_session_s=vad_cfg.max_session_s,
            )
        except Exception:
            log.exception("vad: backend failed to load — auto-stop disabled")
            return None

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

    # -- settings menu actions (rumps callbacks, main thread) --------------

    def _copy_last_transcript(self) -> None:
        # The always-available recovery from a failed paste — independent
        # of any history feature. A deliberate copy, so not concealed.
        if not self._last_transcript:
            log.info("copy last: nothing dictated yet")
            return
        from AppKit import NSPasteboard, NSPasteboardTypeString

        pb = NSPasteboard.generalPasteboard()
        pb.clearContents()
        pb.setString_forType_(self._last_transcript, NSPasteboardTypeString)
        log.info("copy last: %d chars on the clipboard", len(self._last_transcript))

    def _open_config(self) -> None:
        import shutil
        import subprocess

        from .config import CONFIG_DIR, CONFIG_PATH

        if not CONFIG_PATH.exists():
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            example = Path(__file__).resolve().parents[2] / "config.example.toml"
            if example.exists():
                shutil.copy(example, CONFIG_PATH)
            else:
                CONFIG_PATH.write_text(
                    "# Natter configuration — every key is optional.\n"
                    "# Reference: config.example.toml in the Natter repo.\n"
                )
            log.info("config: created %s", CONFIG_PATH)
        subprocess.run(["open", str(CONFIG_PATH)], check=False, timeout=5)

    def _reload_config(self) -> None:
        from . import config as config_mod

        new = config_mod.load()
        needs_restart = config_mod.restart_required(self._cfg, new)
        # Hot-apply everything the running pipeline reads per utterance.
        self._set_cleanup_enabled(new.cleanup.enabled)
        self._set_cleanup_style(new.cleanup.style)
        self._cleanup_timeout = new.cleanup.timeout_s
        if self.hud is not None:
            self.hud.apply_config(new.hud)
        # Replacements hot-apply; the prompt hint (words) is restart-required,
        # flagged via restart_required below — rebuild anyway so the post-step
        # picks up new replacements immediately.
        from .dictionary import Dictionary

        self.dictionary = Dictionary(
            new.dictionary.words, new.dictionary.replacements, new.dictionary.enabled
        )
        self.vad_enabled = new.vad.enabled
        if self._endpointer is not None and not self._endpointer.armed:
            rebuilt = self._make_endpointer(new.vad)
            if rebuilt is not None:
                self._endpointer = rebuilt
        self.app.sync(
            cleanup_enabled=self.cleanup_enabled,
            style=self.cleanup_style,
            hud_enabled=self.hud.enabled if self.hud else None,
            vad_enabled=self.vad_enabled if self._endpointer else None,
        )
        self._cfg = new
        if needs_restart:
            log.warning("config: restart required for: %s", ", ".join(needs_restart))
            self._post_state("idle", f"restart to apply: {', '.join(needs_restart)}")
        else:
            log.info("config: reloaded")
            self._post_state("idle", "config reloaded")

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
        raw = text
        status = "off"
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
            # Custom-word fixups run last so a misheard proper noun is corrected
            # whether cleanup polished the text, fell back to raw, or is off.
            text = self.dictionary.apply(text)
            self._last_transcript = text  # recovery path even if the paste fails
            try:
                insert_text(text)
                self.timings.stamp("insert")
                self.bus.post(self._ev.RESULT, ("ok", text))
            except Exception:
                log.exception("insert failed — check Accessibility permission")
                self.bus.post(self._ev.RESULT, ("error", "insert failed"))
            self.bench.add(self.timings)
            self._record_history(raw, text, status)
        else:
            log.info("empty utterance, nothing to insert")
            self.bus.post(self._ev.RESULT, ("empty", ""))
        self.machine.done()
        self._post_state("idle", "ready")

    def _open_hub(self) -> None:
        # Launch the native Hub (Natter.app) — a separate process that reads
        # ~/.natter/history.db read-only, so it never touches the dictation
        # path. Looks for an installed app first, then a local dev build.
        import subprocess

        candidates = [
            "/Applications/Natter.app",
            str(Path.home() / "Applications" / "Natter.app"),
            "/tmp/natter-hub-dd/Build/Products/Debug/Natter.app",
        ]
        for app_path in candidates:
            if Path(app_path).exists():
                subprocess.run(["open", app_path], check=False, timeout=5)
                return
        log.warning("hub: Natter.app not found (build it from Natter/ — see README)")

    def _record_history(self, raw: str, final: str, status: str) -> None:
        # STT worker thread, after insert + bench — strictly off the hot
        # path (a ~1 ms INSERT on a now-idle thread). Never lose a word
        # over bookkeeping: any store failure is log-and-continue.
        if self.history is None:
            return
        try:
            import json
            import time

            now = time.time()
            self.history.add(
                ts=now,
                raw_text=raw,
                final_text=final,
                cleanup_status=status,
                timings_json=json.dumps(self.timings.stages_ms()),
            )
            self.history.purge(now=now)
        except Exception:
            log.exception("history: write failed")

    def _model_ready(self, name: str) -> None:
        with self._ready_lock:
            self._pending_models.discard(name)
            if self._pending_models or self._models_ready:
                return
            self._models_ready = True
        if self._tap_installed:
            self._post_state("idle", "ready")
        else:
            # Models loaded but hotkeys are dead — don't claim "ready".
            self._post_state("setup", "setup needed — see Setup Assistant")

    # -- onboarding (main thread; driven by the 1 Hz permission poll) ------

    def _open_onboarding(self) -> None:
        from .hotkey import State

        if self.machine.state is not State.IDLE:
            return  # never steal focus while dictation is in flight
        if self._onboarding is None:
            from .onboarding import OnboardingFlow, OnboardingWindow

            self._ob_flow = OnboardingFlow()
            self._onboarding = OnboardingWindow(
                on_request=self._ob_request,
                on_self_test=self._ob_self_test,
                on_done=self._ob_done,
            )
        self._onboarding.show()
        self._refresh_onboarding()
        if self._poll_timer is None:
            import rumps

            self._poll_timer = rumps.Timer(self._poll_tick, 1)
        self._poll_timer.start()

    def _poll_tick(self, _timer) -> None:
        self._refresh_onboarding()

    def _refresh_onboarding(self) -> None:
        from . import permissions

        statuses = permissions.statuses()
        if statuses.get("input_monitoring") is True and not self._tap_installed:
            # Usually requires a relaunch; retrying costs nothing and works
            # on the macOS versions that do propagate the grant.
            if self._try_install_tap():
                log.info("hotkey: tap installed after grant")
                self._post_state("idle", "ready")
        rows = self._ob_flow.rows(statuses, self._tap_installed)
        complete = self._ob_flow.complete(statuses, self._tap_installed)
        self._onboarding.refresh(rows, complete)

    def _ob_request(self, key: str) -> None:
        from . import permissions

        permissions.request(key)

    def _ob_self_test(self) -> None:
        from .insert import insert_text
        from .onboarding import SELF_TEST_TEXT

        self._onboarding.focus_test_field_and(lambda: insert_text(SELF_TEST_TEXT))

    def _ob_done(self) -> None:
        from .onboarding import mark_onboarded

        mark_onboarded()
        if self._poll_timer is not None:
            self._poll_timer.stop()
        self._onboarding.close()

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
        from PyObjCTools import AppHelper

        from . import permissions

        for line in permissions.report().splitlines():
            log.info("%s", line)
        if permissions.microphone_status() is not True:
            permissions.request_microphone()

        self.worker.start()
        if self.cleanup_enabled:
            self._start_cleanup_loader()
        # Watch config.toml so the native Hub's saves hot-apply within ~1 s.
        # _reload_config touches the rumps UI, so hop to the main thread.
        from .config import CONFIG_PATH
        from .watcher import ConfigWatchThread

        self._config_watcher = ConfigWatchThread(
            CONFIG_PATH,
            on_change=lambda: AppHelper.callAfter(self._reload_config),
        )
        self._config_watcher.start()
        # rumps runs first; the tap is installed from inside the run loop
        # (the main thread owns it either way). A failed install degrades
        # to the Setup Assistant instead of exiting — there has to be a
        # live run loop for onboarding to exist at all.
        AppHelper.callAfter(self._startup)
        self.app.run()
        return 0

    def _startup(self) -> None:
        # Main thread, run loop live: build the HUD panel here — never
        # lazily inside a dictation (panel construction in the tap callback
        # path would delay event delivery system-wide).
        from . import onboarding, permissions

        if self.hud is not None:
            self.hud.prepare()
        self._try_install_tap()
        if not self._tap_installed or (
            permissions.missing() and not onboarding.is_onboarded()
        ):
            self._open_onboarding()

    def _try_install_tap(self) -> bool:
        if self._tap_installed:
            return True
        # Mutual exclusion: never hold the event tap while the native Swift
        # engine holds it (and vice-versa). Acquire before starting the tap so
        # two engines can't both arm. When the native engine is off — the only
        # pre-M4 reality — there's never a live foreign holder, so this is a
        # no-op write and the dictation path is unchanged.
        from . import pidfile

        blocker = pidfile.acquire("python")
        if blocker is not None:
            log.error(
                "hotkey: another Natter engine holds the tap (%s, pid %d) — "
                "quit it before starting the Python engine",
                blocker.name, blocker.pid,
            )
            self._post_state("setup", "another Natter engine is running")
            return False
        try:
            self.tap.start()
        except RuntimeError as exc:
            pidfile.release("python")
            log.error("%s", exc)
            self._post_state("setup", "setup needed — see Setup Assistant")
            return False
        import atexit

        atexit.register(pidfile.release, "python")
        self._tap_installed = True
        return True


def run_app(cfg: Config) -> int:
    return Controller(cfg).run()
