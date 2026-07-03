"""User dictionary of custom words and replacements (Phase 4).

Two independent, pure-logic mechanisms (no mlx, so they unit-test anywhere):

- ``prompt_hint`` injects a list of proper nouns / jargon into the cleanup
  system prompt so the LLM prefers the user's spelling ("parakeet-mlx", a
  person's name) over a plausible-but-wrong homophone.
- ``substitute`` runs literal post-replacements on the final text, so a term
  the STT model reliably mishears ("salam mcgarry" → "Salammagari") is fixed
  even when cleanup is off, times out, or its output is rejected.

The post-replacement is the robust path: it never depends on the model and,
like every stage, only rewrites — it can fix or re-case a term but never drops
the surrounding words. ``Dictionary`` bundles both for the controller; the
module functions stay free of state so the tests can hit them directly.
"""

from __future__ import annotations

import logging
import re

log = logging.getLogger(__name__)


def prompt_hint(words: list[str]) -> str:
    """A cleanup-prompt rule pinning the spelling of *words*; "" if none."""
    terms = [w.strip() for w in words if w and w.strip()]
    if not terms:
        return ""
    return (
        "- Keep these terms spelled exactly as written when you hear them "
        "(match phonetically, fix the spelling): " + ", ".join(terms) + ".\n"
    )


def compile_replacements(replacements: dict[str, str]) -> list[tuple[re.Pattern, str]]:
    """Pre-compile *replacements* (misheard → correct) for :func:`substitute`.

    Longest source first so a multi-word phrase wins over a shorter key it
    contains; whole-word, case-insensitive matching so "para" never rewrites
    inside "apparat". An empty source is skipped — it would match everywhere.
    """
    compiled: list[tuple[re.Pattern, str]] = []
    for src in sorted(replacements, key=len, reverse=True):
        stripped = src.strip()
        if not stripped:
            log.warning("dictionary: ignoring empty replacement key")
            continue
        pattern = re.compile(rf"(?<!\w){re.escape(stripped)}(?!\w)", re.IGNORECASE)
        compiled.append((pattern, replacements[src]))
    return compiled


def substitute(text: str, compiled: list[tuple[re.Pattern, str]]) -> str:
    """Apply pre-compiled replacements to *text*, left to right."""
    for pattern, repl in compiled:
        # A function replacement so the value is treated literally — a "\1" or
        # "&" in a corrected spelling must not be read as a backreference.
        text = pattern.sub(lambda _m, r=repl: r, text)
    return text


class Dictionary:
    """The user dictionary, built once from config and read per utterance.

    ``hint`` is handed to the cleanup engine at startup (it becomes part of the
    cached prompt prefix, so it costs nothing per utterance); ``apply`` runs on
    the final text just before insertion.
    """

    def __init__(self, words: list[str], replacements: dict[str, str], enabled: bool = True):
        self.enabled = enabled
        self._hint = prompt_hint(words) if enabled else ""
        self._compiled = compile_replacements(replacements) if enabled else []
        if enabled and (self._hint or self._compiled):
            log.info(
                "dictionary: %d term(s), %d replacement(s)",
                len([w for w in words if w and w.strip()]),
                len(self._compiled),
            )

    @property
    def hint(self) -> str:
        return self._hint

    def apply(self, text: str) -> str:
        if not self.enabled or not text or not self._compiled:
            return text
        return substitute(text, self._compiled)
