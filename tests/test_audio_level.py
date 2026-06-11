"""block_dbfs — pure numpy, feeds the HUD level bars."""

from __future__ import annotations

import numpy as np

from murmur.audio import block_dbfs


def test_silence_sits_at_the_floor():
    assert block_dbfs(np.zeros(1600, dtype="float32")) < -100.0

def test_full_scale_is_zero_dbfs():
    assert abs(block_dbfs(np.ones(1600, dtype="float32"))) < 0.1

def test_quieter_signal_reads_lower():
    loud = block_dbfs(np.full(1600, 0.5, dtype="float32"))
    quiet = block_dbfs(np.full(1600, 0.05, dtype="float32"))
    assert quiet < loud
