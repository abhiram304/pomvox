"""Parakeet (parakeet-mlx) streaming transcription.

The model is owned by a single worker thread: it loads at startup, then
consumes PCM blocks from the recorder's queue, feeding a transcribe_stream
session while recording so finalize-on-stop is near-instant. The ``None``
sentinel ends a session; the final text goes to the controller callback.
"""

from __future__ import annotations

import logging
import math
import queue
import resource
import threading
import time

log = logging.getLogger(__name__)

SAMPLERATE = 16000
# Each transcribe_stream.add_audio() call costs ~0.5 s regardless of chunk
# size (measured on M1), so feeding the raw 100 ms capture blocks runs ~5x
# slower than realtime and degrades accuracy. ~2 s chunks run ~3x faster
# than realtime with full accuracy.
CHUNK_SECONDS = 2.0
SILENCE_DBFS = -50.0


class Chunker:
    """Aggregates small PCM blocks into ~CHUNK_SECONDS arrays."""

    def __init__(self, samplerate: int = SAMPLERATE, chunk_seconds: float = CHUNK_SECONDS):
        self._target = int(samplerate * chunk_seconds)
        self._blocks: list = []
        self._n = 0

    def add(self, block):
        """Buffer *block*; return an aggregated chunk once enough is held."""
        self._blocks.append(block)
        self._n += len(block)
        if self._n >= self._target:
            return self.flush()
        return None

    def flush(self):
        if not self._blocks:
            return None
        import numpy as np

        out = np.concatenate(self._blocks)
        self._blocks = []
        self._n = 0
        return out


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
        self._warmup()
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

    def _warmup(self) -> None:
        """Run a short silent clip through the streaming path.

        The first MLX inference compiles kernels (~7x slower than warm);
        doing it at startup keeps the first real utterance fast.
        """
        try:
            import mlx.core as mx

            t0 = time.perf_counter()
            with self._transcriber.stream() as ctx:
                ctx.add_audio(mx.zeros(SAMPLERATE // 2))
            log.info("stt: warmup %.1fs", time.perf_counter() - t0)
        except Exception:
            log.exception("stt: warmup failed")

    def _session(self, first_block) -> str:
        import mlx.core as mx

        chunker = Chunker()
        sumsq = 0.0
        samples = 0
        with self._transcriber.stream() as ctx:
            block = first_block
            while block is not None:
                sumsq += float((block**2).sum())
                samples += len(block)
                chunk = chunker.add(block)
                if chunk is not None:
                    ctx.add_audio(mx.array(chunk))
                    # Draft tokens are just logged in Phase 1; the Phase 2
                    # HUD will consume them live.
                    if log.isEnabledFor(logging.DEBUG) and ctx.result is not None:
                        log.debug("stt: draft %r", ctx.result.text)
                block = self._q.get()
            tail = chunker.flush()
            if tail is not None:
                ctx.add_audio(mx.array(tail))
            result = ctx.result
        if samples:
            rms_db = 10 * math.log10(sumsq / samples + 1e-12)
            log.info("stt: %.1fs of audio, level %.0f dBFS", samples / SAMPLERATE, rms_db)
            if rms_db < SILENCE_DBFS:
                log.warning("stt: audio nearly silent — check the input device / mic volume")
        return (result.text if result else "").strip()

    def _emit(self, text: str) -> None:
        try:
            self._on_text(text)
        except Exception:
            log.exception("stt: result callback failed")
