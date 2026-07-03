"""OnboardingFlow pure logic — the checklist window is a dumb renderer."""

from __future__ import annotations

from natter.onboarding import OnboardingFlow

ALL_GRANTED = {"microphone": True, "input_monitoring": True, "accessibility": True}


def test_rows_cover_the_three_permissions_in_order():
    flow = OnboardingFlow()
    rows = flow.rows(ALL_GRANTED, tap_installed=True)
    assert [r.key for r in rows] == ["microphone", "input_monitoring", "accessibility"]
    assert all(r.granted is True for r in rows)
    assert all(r.why for r in rows)  # every row explains itself


def test_unknown_probe_status_passes_through_as_none():
    flow = OnboardingFlow()
    statuses = dict(ALL_GRANTED, accessibility=None)
    rows = flow.rows(statuses, tap_installed=True)
    assert rows[2].granted is None


def test_relaunch_note_when_granted_but_tap_still_dead():
    # Input Monitoring grants don't reach an already-running process.
    flow = OnboardingFlow()
    rows = flow.rows(ALL_GRANTED, tap_installed=False)
    im = rows[1]
    assert im.granted is True
    assert "relaunch" in im.note.lower()


def test_no_relaunch_note_while_simply_ungranted():
    flow = OnboardingFlow()
    statuses = dict(ALL_GRANTED, input_monitoring=False)
    rows = flow.rows(statuses, tap_installed=False)
    assert rows[1].note == ""


def test_complete_requires_all_grants_and_a_live_tap():
    flow = OnboardingFlow()
    assert flow.complete(ALL_GRANTED, tap_installed=True) is True
    assert flow.complete(ALL_GRANTED, tap_installed=False) is False
    assert flow.complete(dict(ALL_GRANTED, microphone=False), tap_installed=True) is False
    assert flow.complete(dict(ALL_GRANTED, microphone=None), tap_installed=True) is False
