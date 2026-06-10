"""Parakeet (parakeet-mlx) streaming transcription.

The model is owned by a single worker thread: it loads at startup, then
consumes PCM blocks from the recorder's queue, feeding a transcribe_stream
session while recording so finalize-on-stop is near-instant. The ``None``
sentinel ends a session; the final text goes to the controller callback.
"""

from __future__ import annotations

import logging
import queue
import resource
import threading
import time

log = logging.getLogger(__name__)


class Transcriber:
    def __init__(self, model_name: str) -> None:
        self.model_name = model_name
        self._model = None

    def load(self) -> None:
        from parakeet_mlx import from_pretrained

        t0 = time.perf_counter()
        self._model = from_pretrained(self.model_name)
        load_s = time.perf_counter() - t0
        rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20)
        log.info("stt: loaded %s in %.1fs rss=%.0fMB", self.model_name, load_s, rss_mb)

    def stream(self):
        return self._model.transcribe_stream(context_size=(256, 256))


class SttWorker(threading.Thread):
    """Owns the model; turns queued PCM blocks into final transcripts."""

    def __init__(self, transcriber: Transcriber, audio_q: queue.Queue, on_text, on_ready=None):
        super().__init__(name="stt-worker", daemon=True)
        self._transcriber = transcriber
        self._q = audio_q
        self._on_text = on_text
        self._on_ready = on_ready

    def run(self) -> None:
        self._transcriber.load()
        if self._on_ready:
            self._on_ready()
        while True:
            block = self._q.get()
            if block is None:
                # Sentinel with no audio: utterance too short to capture.
                self._emit("")
                continue
            try:
                text = self._session(block)
            except Exception:
                log.exception("stt: transcription failed")
                text = ""
            self._emit(text)

    def _session(self, first_block) -> str:
        import mlx.core as mx

        with self._transcriber.stream() as ctx:
            ctx.add_audio(mx.array(first_block))
            while True:
                block = self._q.get()
                if block is None:
                    break
                ctx.add_audio(mx.array(block))
                # Draft tokens are just logged in Phase 1; the Phase 2 HUD
                # will consume them live.
                if log.isEnabledFor(logging.DEBUG) and ctx.result is not None:
                    log.debug("stt: draft %r", ctx.result.text)
            result = ctx.result
        return (result.text if result else "").strip()

    def _emit(self, text: str) -> None:
        try:
            self._on_text(text)
        except Exception:
            log.exception("stt: result callback failed")
