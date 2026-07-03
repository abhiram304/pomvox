"""Transcript log preview — full text must not reach INFO logs."""

from __future__ import annotations

from pomvox.app import preview


def test_short_text_passes_through():
    assert preview("hello world") == "hello world"

def test_long_text_truncates_with_ellipsis():
    text = "x" * 200
    out = preview(text)
    assert len(out) == 60
    assert out == "x" * 59 + "…"

def test_limit_boundary_is_untruncated():
    text = "y" * 60
    assert preview(text) == text

def test_custom_limit():
    assert preview("abcdef", limit=4) == "abc…"
