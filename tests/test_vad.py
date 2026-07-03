"""VAD pure logic — webrtcvad itself is never imported here."""

from __future__ import annotations

import numpy as np

from pomvox.vad import Endpointer, EndpointDetector, FrameSlicer, frame_dbfs

FRAME_MS = 30  # 480 samples at 16 kHz


class TestFrameSlicer:
    def test_slices_blocks_into_frames_with_remainder_carry(self):
        s = FrameSlicer(frame_samples=480)
        # 1600-sample block → 3 frames of 480, 160 samples carried
        frames = s.add(np.zeros(1600, dtype="float32"))
        assert len(frames) == 3
        assert all(len(f) == 960 for f in frames)  # 480 samples × int16
        # next block: 160 carried + 1600 = 1760 → 3 frames, 320 carried
        assert len(s.add(np.zeros(1600, dtype="float32"))) == 3

    def test_frame_size_is_a_constructor_argument(self):
        s = FrameSlicer(frame_samples=512)  # the Silero seam
        frames = s.add(np.zeros(1600, dtype="float32"))
        assert len(frames) == 3
        assert all(len(f) == 1024 for f in frames)

    def test_int16_conversion_clips(self):
        s = FrameSlicer(frame_samples=4)
        frames = s.add(np.array([2.0, -2.0, 1.0, -1.0], dtype="float32"))
        vals = np.frombuffer(frames[0], dtype="<i2")
        assert vals[0] == 32767 and vals[1] == -32767

    def test_reset_drops_carried_samples(self):
        s = FrameSlicer(frame_samples=480)
        s.add(np.zeros(1600, dtype="float32"))
        s.reset()
        assert len(s.add(np.zeros(480, dtype="float32"))) == 1


def test_frame_dbfs_silence_vs_loud():
    quiet = (np.zeros(480, dtype="<i2")).tobytes()
    loud = (np.full(480, 16000, dtype="<i2")).tobytes()
    assert frame_dbfs(quiet) < -80
    assert frame_dbfs(loud) > -10


def det(**kw):
    defaults = dict(silence_ms=600, min_speech_ms=90, frame_ms=FRAME_MS,
                    energy_gate_dbfs=-45.0)
    defaults.update(kw)
    return EndpointDetector(**defaults)


LOUD = -20.0
QUIET = -70.0


class TestEndpointDetector:
    def test_speech_start_needs_min_consecutive_voiced(self):
        d = det()  # 90 ms = 3 frames
        assert d.feed(True, LOUD) is None
        assert d.feed(True, LOUD) is None
        assert d.feed(True, LOUD) == "speech_start"

    def test_blips_do_not_start_speech(self):
        d = det()
        d.feed(True, LOUD)
        d.feed(False, QUIET)  # resets the run
        d.feed(True, LOUD)
        assert d.feed(True, LOUD) is None  # only 2 consecutive

    def test_energy_gate_vetoes_vad_vote(self):
        # webrtcvad says voiced but the room is silent: breath/keyboard noise
        d = det()
        for _ in range(10):
            assert d.feed(True, QUIET) is None

    def test_endpoint_after_silence_hangover(self):
        d = det()  # 600 ms silence = 20 frames
        for _ in range(3):
            d.feed(True, LOUD)
        for _ in range(19):
            assert d.feed(False, QUIET) is None
        assert d.feed(False, QUIET) == "endpoint"

    def test_speech_resumption_snaps_silence_back(self):
        d = det()
        for _ in range(3):
            d.feed(True, LOUD)
        for _ in range(15):
            d.feed(False, QUIET)
        assert d.silence_fraction > 0.5
        d.feed(True, LOUD)  # spoke again
        assert d.silence_fraction == 0.0

    def test_fires_once_then_inert_until_reset(self):
        d = det()
        for _ in range(3):
            d.feed(True, LOUD)
        for _ in range(20):
            d.feed(False, QUIET)
        for _ in range(30):
            assert d.feed(False, QUIET) is None
        d.reset()
        for _ in range(2):
            d.feed(True, LOUD)
        assert d.feed(True, LOUD) == "speech_start"

    def test_no_endpoint_before_speech_ever_started(self):
        # hands-free armed but the user never spoke: don't auto-stop
        d = det()
        for _ in range(100):
            assert d.feed(False, QUIET) is None


class FakeBackend:
    frame_samples = 480

    def __init__(self, voiced: bool = True):
        self.voiced = voiced

    def is_voiced(self, frame: bytes) -> bool:
        return self.voiced


def make_endpointer(backend=None, max_session_s=600.0):
    return Endpointer(
        backend=backend or FakeBackend(),
        detector=det(),
        max_session_s=max_session_s,
    )


def loud_block(n=1600):
    return np.full(n, 0.1, dtype="float32")


def quiet_block(n=1600):
    return np.zeros(n, dtype="float32")


class TestEndpointer:
    def test_disarmed_processes_nothing(self):
        ep = make_endpointer()
        event, frac = ep.process(loud_block())
        assert event is None and frac is None

    def test_speech_then_silence_fires_endpoint_once(self):
        ep = make_endpointer(FakeBackend(voiced=True))
        ep.arm(generation=1)
        ep.process(loud_block())  # 3 voiced frames → speech start
        ep.backend.voiced = False
        events = []
        for _ in range(10):  # 30 frames of silence ≫ 600 ms hangover
            event, _ = ep.process(quiet_block())
            if event:
                events.append(event)
        assert events == ["endpoint"]
        assert ep.generation == 1

    def test_silence_fraction_reported_while_armed(self):
        ep = make_endpointer(FakeBackend(voiced=True))
        ep.arm(generation=1)
        ep.process(loud_block())
        ep.backend.voiced = False
        _, frac = ep.process(quiet_block())
        assert frac is not None and 0.0 < frac < 1.0

    def test_arm_resets_state_between_sessions(self):
        ep = make_endpointer(FakeBackend(voiced=True))
        ep.arm(generation=1)
        ep.process(loud_block())
        ep.disarm()
        ep.arm(generation=2)  # stale hangover/carry must not leak in
        ep.backend.voiced = False
        event, _ = ep.process(quiet_block())
        assert event is None  # no speech yet in session 2 → no endpoint
        assert ep.generation == 2

    def test_session_cap_warning_then_endpoint(self):
        # 1 s cap at 16 kHz = 16000 samples; warning at 90%
        ep = make_endpointer(FakeBackend(voiced=True), max_session_s=1.0)
        ep.arm(generation=1)
        events = []
        for _ in range(11):  # 11 × 1600 = 17600 samples > cap
            event, _ = ep.process(loud_block())
            if event:
                events.append(event)
        assert "cap_warning" in events
        assert events[-1] == "endpoint"
