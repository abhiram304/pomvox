"""Chunker: aggregates capture blocks into model-sized chunks."""

import pytest

np = pytest.importorskip("numpy")

from pomvox.stt import Chunker


def blocks(n_blocks, block_len=1600):
    return [np.full(block_len, i, dtype="float32") for i in range(n_blocks)]


def test_buffers_until_target():
    c = Chunker(samplerate=16000, chunk_seconds=0.5)  # target 8000 samples
    out = [c.add(b) for b in blocks(4)]  # 4 x 1600 = 6400 < 8000
    assert out == [None, None, None, None]


def test_emits_chunk_at_target():
    c = Chunker(samplerate=16000, chunk_seconds=0.5)
    out = None
    for b in blocks(5):  # 8000 samples on the 5th block
        chunk = c.add(b)
        if chunk is not None:
            out = chunk
    assert out is not None
    assert len(out) == 8000
    assert (out[:1600] == 0).all() and (out[-1600:] == 4).all()


def test_flush_returns_remainder_then_empties():
    c = Chunker(samplerate=16000, chunk_seconds=0.5)
    for b in blocks(3):
        assert c.add(b) is None
    tail = c.flush()
    assert tail is not None and len(tail) == 4800
    assert c.flush() is None


def test_resets_after_emitting():
    c = Chunker(samplerate=16000, chunk_seconds=0.1)  # target 1600
    assert c.add(np.zeros(1600, dtype="float32")) is not None
    assert c.flush() is None
