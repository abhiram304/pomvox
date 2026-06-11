"""HUD pure logic: state machine, geometry, truncation, level mapping."""

from __future__ import annotations

from murmur.hud import (
    HudStateMachine,
    LevelHistory,
    level01,
    pill_frame,
    split_stable_prefix,
    truncate_head,
)
from murmur.uibus import UiEvent


def test_split_stable_prefix_marks_the_new_chunk():
    stable, delta = split_stable_prefix("the quick", "the quick brown fox")
    assert stable == "the quick"
    assert delta == " brown fox"

def test_split_stable_prefix_handles_revisions():
    # Parakeet may revise earlier words between chunks: the changed part
    # counts as new.
    stable, delta = split_stable_prefix("the quik brown", "the quick brown fox")
    assert stable == "the qui"
    assert delta == "ck brown fox"

def test_split_stable_prefix_first_draft_is_all_new():
    assert split_stable_prefix("", "hello") == ("", "hello")


class TestLevelHistory:
    def test_keeps_a_fixed_window_newest_last(self):
        h = LevelHistory(n=3)
        for v in (0.1, 0.2, 0.3, 0.4):
            h.push(v)
        assert h.bars() == [0.2, 0.3, 0.4]

    def test_pads_with_zeros_until_full(self):
        h = LevelHistory(n=4)
        h.push(0.5)
        assert h.bars() == [0.0, 0.0, 0.0, 0.5]

    def test_reset_flattens(self):
        h = LevelHistory(n=2)
        h.push(0.9)
        h.reset()
        assert h.bars() == [0.0, 0.0]


def test_pill_frame_notch_hugs_the_top_edge():
    # visibleFrame excludes the menu bar, so flush-top sits just under it,
    # blending into the notch area on a MacBook.
    x, y, w, h = pill_frame((0.0, 0.0, 1000.0, 600.0), (420.0, 64.0), 24.0,
                            position="notch")
    assert y == 600.0 - 64.0  # no margin
    assert x == 290.0


def test_truncate_head_keeps_the_newest_words():
    assert truncate_head("the quick brown fox", 10) == "…brown fox"

def test_truncate_head_short_text_untouched():
    assert truncate_head("hi there", 20) == "hi there"


def test_pill_frame_centers_at_bottom():
    # visible frame x, y, w, h; pill w, h; margin
    x, y, w, h = pill_frame((0.0, 0.0, 1000.0, 600.0), (420.0, 64.0), 24.0)
    assert (x, y, w, h) == (290.0, 24.0, 420.0, 64.0)

def test_pill_frame_handles_negative_origin_screens():
    x, y, _, _ = pill_frame((-1920.0, -200.0, 1920.0, 1080.0), (420.0, 64.0), 24.0)
    assert x == -1920.0 + (1920.0 - 420.0) / 2
    assert y == -176.0

def test_pill_frame_top_center():
    _, y, _, _ = pill_frame((0.0, 0.0, 1000.0, 600.0), (420.0, 64.0), 24.0, position="top-center")
    assert y == 600.0 - 64.0 - 24.0


def test_level01_maps_speech_range():
    assert level01(-60.0) == 0.0          # silence floor
    assert level01(-10.0) == 1.0          # loud speech ceiling
    assert 0.0 < level01(-35.0) < 1.0

def test_level01_clamps_out_of_range():
    assert level01(-120.0) == 0.0
    assert level01(0.0) == 1.0


class TestHudStateMachine:
    def make(self):
        return HudStateMachine(max_chars=40)

    def test_starts_hidden(self):
        m = self.make()
        assert m.vm.visible is False

    def test_recording_shows_with_status(self):
        m = self.make()
        vm = m.apply({UiEvent.STATE: ("recording", "recording (push-to-talk)")}, now=0.0)
        assert vm.visible is True
        assert vm.state == "recording"
        assert "push-to-talk" in vm.status

    def test_draft_and_level_update_while_recording(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        vm = m.apply({UiEvent.DRAFT: "hello world", UiEvent.LEVEL: 0.7}, now=1.0)
        assert vm.draft == "hello world"
        assert vm.level == 0.7

    def test_draft_is_head_truncated(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        vm = m.apply({UiEvent.DRAFT: "x" * 100}, now=1.0)
        assert len(vm.draft) == 40
        assert vm.draft.startswith("…")

    def test_draft_ignored_when_hidden(self):
        m = self.make()
        vm = m.apply({UiEvent.DRAFT: "stray"}, now=0.0)
        assert vm.visible is False
        assert vm.draft == ""

    def test_transcribing_freezes_draft(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        m.apply({UiEvent.DRAFT: "so far"}, now=1.0)
        vm = m.apply({UiEvent.STATE: ("transcribing", "")}, now=2.0)
        assert vm.state == "transcribing"
        assert vm.draft == "so far"

    def test_ok_result_flashes_then_hides_on_tick(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        m.apply({UiEvent.STATE: ("transcribing", "")}, now=2.0)
        vm = m.apply({UiEvent.RESULT: ("ok", "Final text.")}, now=3.0)
        assert vm.state == "done"
        assert vm.final == "Final text."
        assert vm.hide_at is not None and vm.hide_at > 3.0
        assert m.tick(now=vm.hide_at - 0.1).visible is True
        assert m.tick(now=vm.hide_at).visible is False

    def test_result_beats_idle_in_the_same_drain(self):
        # _on_text posts RESULT then STATE idle; one drain may carry both.
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        vm = m.apply(
            {UiEvent.RESULT: ("ok", "kept"), UiEvent.STATE: ("idle", "ready")},
            now=1.0,
        )
        assert vm.state == "done"
        assert vm.final == "kept"

    def test_idle_while_done_does_not_cut_the_flash_short(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        m.apply({UiEvent.RESULT: ("ok", "kept")}, now=1.0)
        vm = m.apply({UiEvent.STATE: ("idle", "ready")}, now=1.1)
        assert vm.state == "done"

    def test_error_result_shows_warning(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        vm = m.apply({UiEvent.RESULT: ("error", "copied to clipboard")}, now=1.0)
        assert vm.state == "error"
        assert "copied to clipboard" in vm.status
        assert vm.hide_at is not None

    def test_empty_result_hides_immediately(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        vm = m.apply({UiEvent.RESULT: ("empty", "")}, now=1.0)
        assert vm.visible is False

    def test_rerecord_during_done_flash_cancels_the_hide(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        m.apply({UiEvent.RESULT: ("ok", "first")}, now=1.0)
        vm = m.apply({UiEvent.STATE: ("recording", "")}, now=1.2)
        assert vm.state == "recording"
        assert vm.hide_at is None
        assert vm.draft == ""  # fresh session, no stale draft
        # The stale scheduled tick from the first utterance must be a no-op.
        assert m.tick(now=5.0).state == "recording"

    def test_endpoint_progress_tracked_while_recording(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "recording (hands-free)")}, now=0.0)
        vm = m.apply({UiEvent.ENDPOINT_PROGRESS: 0.6}, now=1.0)
        assert vm.endpoint_fraction == 0.6
        # a fresh utterance starts clean
        vm = m.apply({UiEvent.STATE: ("recording", "")}, now=2.0)
        assert vm.endpoint_fraction == 0.0

    def test_cancelled_result_flashes_briefly(self):
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        vm = m.apply({UiEvent.RESULT: ("cancelled", "")}, now=1.0)
        assert vm.state == "cancelled"
        assert "cancelled" in vm.status
        assert vm.hide_at is not None and vm.hide_at < 1.0 + 1.4  # shorter than done

    def test_idle_while_recording_hides(self):
        # e.g. recording failed to start and the controller reset to idle
        m = self.make()
        m.apply({UiEvent.STATE: ("recording", "")}, now=0.0)
        vm = m.apply({UiEvent.STATE: ("idle", "ready")}, now=0.5)
        assert vm.visible is False
