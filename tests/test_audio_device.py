"""Input-device resolution (M2a).

``resolve_input_device`` maps a configured device *name* to a sounddevice
selector. Pure (devices injected), so it runs on Linux without PortAudio.
Wrong-mic is the #1 "it doesn't work" cause; a name that no longer resolves
must degrade to the system default, never crash.
"""

from pomvox.audio import resolve_input_device

DEVICES = [
    {"name": "MacBook Pro Microphone", "max_input_channels": 1},
    {"name": "BlackHole 2ch", "max_input_channels": 2},
    {"name": "External Speakers", "max_input_channels": 0},  # output only
]


def test_empty_name_is_system_default():
    assert resolve_input_device("", DEVICES) is None


def test_exact_name_match():
    assert resolve_input_device("BlackHole 2ch", DEVICES) == "BlackHole 2ch"


def test_substring_match_returns_full_name():
    assert resolve_input_device("blackhole", DEVICES) == "BlackHole 2ch"


def test_output_only_device_never_matches():
    assert resolve_input_device("External Speakers", DEVICES) is None


def test_unknown_name_falls_back_to_default(caplog):
    assert resolve_input_device("Ghost Mic", DEVICES) is None
    assert any("not found" in r.message for r in caplog.records)
