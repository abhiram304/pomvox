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


class _Cancel:
    """Queue marker: discard the in-flight utterance instead of finalizing."""


CANCEL = _Cancel()


def resolve_input_device(name: str, devices) -> str | int | None:
    """Map a configured input-device *name* to a sounddevice selector.

    ``""`` → ``None`` (system default). An exact or substring name match on an
    input-capable device → that device's full name. No match → ``None`` (the
    default) plus a warning: a stale device name must never crash dictation.
    *devices* is the ``sounddevice.query_devices()`` list (injected for tests).
    """
    if not name:
        return None
    inputs = [d for d in devices if d.get("max_input_channels", 0) > 0]
    for d in inputs:
        if d["name"] == name:
            return name
    for d in inputs:
        if name.lower() in d["name"].lower():
            return d["name"]
    log.warning("audio: input device %r not found — using system default", name)
    return None


def block_dbfs(block) -> float:
    """RMS level of a float32 block in dBFS (pure numpy; feeds the HUD)."""
    import math

    return 10 * math.log10(float((block**2).mean()) + 1e-12)


class Recorder:
    def __init__(self, on_block=None, device: str = "") -> None:
        import sounddevice as sd

        self.q: queue.Queue = queue.Queue()
        self._on_block = on_block
        self._recording = False
        selector = resolve_input_device(device, sd.query_devices())
        if selector is not None:
            log.info("audio: input device %r", selector)
        self._stream = sd.InputStream(
            samplerate=SAMPLERATE,
            channels=1,
            dtype="float32",
            blocksize=BLOCKSIZE,
            device=selector,
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

    def cancel(self) -> None:
        """Stop capture and tell the STT worker to discard the utterance."""
        self._recording = False
        self._stream.stop()
        self.q.put(CANCEL)
        log.debug("audio: recording cancelled")

    def close(self) -> None:
        self._stream.close()
