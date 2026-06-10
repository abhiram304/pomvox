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


def test_esc_stops_toggle_and_swallows(m):
    m.on_modifier(FN, True)
    m.on_key_down(SPACE)
    m.on_modifier(FN, False)

    d = m.on_key_down(ESC)
    assert d.action is Action.STOP and d.swallow
    assert m.state is State.BUSY


def test_second_fn_space_stops_toggle(m):
    m.on_modifier(FN, True)
    m.on_key_down(SPACE)
    m.on_modifier(FN, False)

    m.on_modifier(FN, True)
    d = m.on_key_down(SPACE)
    assert d.action is Action.STOP and d.swallow


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


def test_esc_during_ptt_passes_through(m):
    m.on_modifier(FN, True)
    d = m.on_key_down(ESC)
    assert d.action is Action.NONE and not d.swallow
    assert m.state is State.PTT


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
