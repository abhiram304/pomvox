"""Microphone capture: sounddevice InputStream → queue of PCM blocks.

16 kHz mono float32 in 100 ms blocks — what Parakeet's streaming API expects.
The InputStream is created once at startup (cuts session-start latency) and
started/stopped per recording session. A ``None`` sentinel on the queue marks
end-of-utterance for the STT worker.
"""

from __future__ import annotations

import logging
import queue

log = logging.getLogger(__name__)

SAMPLERATE = 16000
BLOCKSIZE = 1600  # 100 ms

SENTINEL = None


def block_dbfs(block) -> float:
    """RMS level of a float32 block in dBFS (pure numpy; feeds the HUD)."""
    import math

    return 10 * math.log10(float((block**2).mean()) + 1e-12)


class Recorder:
    def __init__(self, on_block=None) -> None:
        import sounddevice as sd

        self.q: queue.Queue = queue.Queue()
        self._on_block = on_block
        self._recording = False
        self._stream = sd.InputStream(
            samplerate=SAMPLERATE,
            channels=1,
            dtype="float32",
            blocksize=BLOCKSIZE,
            callback=self._callback,
        )

    def _callback(self, indata, frames, time_info, status) -> None:
        if status:
            log.warning("audio: %s", status)
        if self._recording:
            block = indata[:, 0].copy()
            self.q.put(block)
            if self._on_block is not None:
                try:
                    self._on_block(block)
                except Exception:
                    log.exception("audio: on_block tap failed — disabling it")
                    self._on_block = None

    def start(self) -> None:
        self._recording = True
        self._stream.start()
        log.debug("audio: recording started")

    def stop(self) -> None:
        """Stop capture and mark end-of-utterance for the STT worker."""
        self._recording = False
        self._stream.stop()
        self.q.put(SENTINEL)
        log.debug("audio: recording stopped")

    def close(self) -> None:
        self._stream.close()
