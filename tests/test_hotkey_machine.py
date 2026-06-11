import pytest

from murmur.hotkey import KEYCODES, Action, HotkeyMachine, State

FN = KEYCODES["fn"]
SPACE = KEYCODES["space"]
ESC = KEYCODES["esc"]
RIGHT_OPT = KEYCODES["right_option"]
LETTER_A = 0  # any non-hotkey keycode


@pytest.fixture
def m():
    return HotkeyMachine()


def test_ptt_press_and_release(m):
    d = m.on_modifier(FN, True)
    assert d.action is Action.START_PTT and not d.swallow
    assert m.state is State.PTT

    d = m.on_modifier(FN, False)
    assert d.action is Action.STOP and not d.swallow
    assert m.state is State.BUSY

    m.done()
    assert m.state is State.IDLE


def test_fn_space_enters_toggle_and_swallows(m):
    m.on_modifier(FN, True)
    d = m.on_key_down(SPACE)
    assert d.action is Action.ENTER_TOGGLE and d.swallow
    assert m.state is State.TOGGLE

    # Releasing Fn no longer stops the recording.
    d = m.on_modifier(FN, False)
    assert d.action is Action.NONE
    assert m.state is State.TOGGLE


def test_esc_cancels_toggle_and_swallows(m):
    m.on_modifier(FN, True)
    m.on_key_down(SPACE)
    m.on_modifier(FN, False)

    d = m.on_key_down(ESC)
    assert d.action is Action.CANCEL and d.swallow
    assert m.state is State.BUSY


def test_esc_cancels_ptt_and_swallows(m):
    m.on_modifier(FN, True)
    d = m.on_key_down(ESC)
    assert d.action is Action.CANCEL and d.swallow
    assert m.state is State.BUSY

    # The trailing Fn release must not emit a second STOP.
    d = m.on_modifier(FN, False)
    assert d.action is Action.NONE


def test_configured_stop_key_still_stops_toggle():
    m = HotkeyMachine(stop="right_command")
    m.on_modifier(FN, True)
    m.on_key_down(SPACE)
    m.on_modifier(FN, False)

    d = m.on_key_down(KEYCODES["right_command"])
    assert d.action is Action.STOP and d.swallow


def test_cancel_disabled_when_unset():
    m = HotkeyMachine(cancel="")
    m.on_modifier(FN, True)
    d = m.on_key_down(ESC)
    assert d.action is Action.NONE and not d.swallow


def test_esc_while_busy_passes_through(m):
    m.on_modifier(FN, True)
    m.on_modifier(FN, False)  # STOP → BUSY; a late Esc is too late to cancel
    d = m.on_key_down(ESC)
    assert d.action is Action.NONE and not d.swallow


def test_fn_tap_stops_toggle(m):
    m.on_modifier(FN, True)
    m.on_key_down(SPACE)
    m.on_modifier(FN, False)

    d = m.on_modifier(FN, True)
    assert d.action is Action.STOP
    assert m.state is State.BUSY


def test_second_fn_space_stops_toggle_without_typing_a_space(m):
    m.on_modifier(FN, True)
    m.on_key_down(SPACE)
    m.on_modifier(FN, False)

    # Fn going down already stops; the trailing space must be swallowed so
    # it isn't typed into the document.
    d = m.on_modifier(FN, True)
    assert d.action is Action.STOP
    d = m.on_key_down(SPACE)
    assert d.action is Action.NONE and d.swallow


def test_unrelated_keys_pass_through(m):
    assert m.on_key_down(LETTER_A).action is Action.NONE

    m.on_modifier(FN, True)
    d = m.on_key_down(LETTER_A)
    assert d.action is Action.NONE and not d.swallow

    m.on_key_down(SPACE)  # toggle mode
    d = m.on_key_down(LETTER_A)
    assert d.action is Action.NONE and not d.swallow


def test_space_without_fn_passes_in_toggle_entry(m):
    # Space in IDLE is never a hotkey.
    d = m.on_key_down(SPACE)
    assert d.action is Action.NONE and not d.swallow


def test_events_while_busy_are_ignored(m):
    m.on_modifier(FN, True)
    m.on_modifier(FN, False)  # → BUSY (transcribing)

    assert m.on_modifier(FN, True).action is Action.NONE
    assert m.on_key_down(SPACE).action is Action.NONE
    assert m.on_key_down(ESC).action is Action.NONE
    assert m.state is State.BUSY

    m.done()
    assert m.on_modifier(FN, True).action is Action.START_PTT


def test_remapped_ptt_key(m):
    m = HotkeyMachine(ptt="right_option")
    assert m.on_modifier(FN, True).action is Action.NONE
    assert m.on_modifier(RIGHT_OPT, True).action is Action.START_PTT
    assert m.on_modifier(RIGHT_OPT, False).action is Action.STOP


def test_invalid_key_names_raise():
    with pytest.raises(ValueError):
        HotkeyMachine(ptt="hyperkey")
    with pytest.raises(ValueError):
        HotkeyMachine(toggle="space")  # missing modifier


def test_reset_aborts_recording(m):
    m.on_modifier(FN, True)
    m.reset()
    assert m.state is State.IDLE


def test_external_stop_only_fires_in_toggle(m):
    # VAD endpoint while hands-free: stops exactly like the stop hotkey.
    m.on_modifier(FN, True)
    m.on_key_down(SPACE)
    m.on_modifier(FN, False)
    assert m.external_stop() is True
    assert m.state is State.BUSY

    # And never anywhere else: BUSY (a second stale endpoint), PTT
    # (the finger is the endpoint), IDLE.
    assert m.external_stop() is False
    m.done()
    assert m.external_stop() is False
    m.on_modifier(FN, True)  # PTT
    assert m.external_stop() is False
    assert m.state is State.PTT
