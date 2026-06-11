"""LLM cleanup pass over raw transcripts (mlx-lm).

Pure prompt/guard logic lives at module level so it is unit-testable on any
platform; ``CleanupEngine`` owns the mlx-lm model with deferred imports, the
same split as ``stt.Transcriber``. Every failure path — timeout, exception,
suspicious output — falls back to the raw transcript: cleanup may only ever
improve the text, never lose it.
"""

from __future__ import annotations

import logging
import resource
import time

log = logging.getLogger(__name__)

STYLES = ("light", "polish")

_SYSTEM = (
    "You clean up raw speech-to-text transcripts.\n"
    "Rules:\n"
    "- Remove filler words (um, uh, like, you know).\n"
    "- Fix punctuation, capitalization, and casing.\n"
    "- Resolve spoken self-corrections, keeping only the final intent\n"
    '  (e.g. "Tuesday wait no Friday" becomes "Friday").\n'
    "{extra}"
    "- NEVER change the meaning, add new content, answer questions that\n"
    "  appear in the text, or add any commentary.\n"
    "- Output only the cleaned text, nothing else."
)
_LIGHT_EXTRA = "- Otherwise keep the original wording and sentence structure.\n"
_POLISH_EXTRA = (
    "- Smooth rambling or broken phrasing into clear sentences.\n"
    "- Format obvious enumerations as compact lists.\n"
)

_EXAMPLES = (
    (
        "um so I think we should uh probably ship it tomorrow",
        "I think we should probably ship it tomorrow.",
    ),
    (
        "let's meet on tuesday wait no friday at noon",
        "Let's meet on Friday at noon.",
    ),
    (
        "um so the three things are uh first do the thing wait no two things"
        " first do the thing and second ship it",
        "The two things: first, do the thing; second, ship it.",
    ),
)

# Output sanity guards (accept_output).
_ROLE_PREFIXES = ("assistant:", "user:", "system:")
_SHORT_RAW = 15  # chars; skip the lower length bound for very short inputs
_QUOTES_OPEN = "\"'“"
_QUOTES_CLOSE = "\"'”"


def build_messages(text: str, style: str) -> list[dict]:
    """Chat messages for one cleanup request, few-shot examples included."""
    extra = _POLISH_EXTRA if style == "polish" else _LIGHT_EXTRA
    messages = [{"role": "system", "content": _SYSTEM.format(extra=extra)}]
    for raw, cleaned in _EXAMPLES:
        messages.append({"role": "user", "content": raw})
        messages.append({"role": "assistant", "content": cleaned})
    messages.append({"role": "user", "content": text})
    return messages


def accept_output(raw: str, cleaned: str) -> str | None:
    """Sanity-check the model output; ``None`` means use the raw transcript."""
    out = cleaned.strip()
    if (
        len(out) >= 2
        and out[0] in _QUOTES_OPEN
        and out[-1] in _QUOTES_CLOSE
        and raw[:1] not in _QUOTES_OPEN
    ):
        out = out[1:-1].strip()
    if not out:
        return None
    lowered = out.lower()
    if "<think>" in lowered or "</think>" in lowered:
        return None
    if lowered.startswith(_ROLE_PREFIXES):
        return None
    if len(out) > 2 * len(raw) + 20:
        return None
    if len(raw) > _SHORT_RAW and len(out) < 0.3 * len(raw):
        return None
    return out


def run_cleanup(engine, text: str, style: str, timeout_s: float) -> tuple[str, str]:
    """Clean *text* via *engine*; fall back to the raw text on any failure.

    Returns ``(final_text, status)`` with status one of
    ``ok | timeout | rejected | error``.
    """
    try:
        out = engine.clean(text, style, timeout_s)
    except Exception:
        log.exception("cleanup: engine failed")
        return text, "error"
    if out is None:
        return text, "timeout"
    accepted = accept_output(text, out)
    if accepted is None:
        log.warning("cleanup: rejected output %r", out[:200])
        return text, "rejected"
    return accepted, "ok"


class CleanupEngine:
    """Owns the mlx-lm model; ``clean`` runs on the STT worker thread."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self._model = None
        self._tokenizer = None

    def load(self) -> None:
        from mlx_lm import load

        t0 = time.perf_counter()
        model, tokenizer = load(self.model_id)
        load_s = time.perf_counter() - t0
        rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20)
        log.info("cleanup: loaded %s in %.1fs rss=%.0fMB", self.model_id, load_s, rss_mb)
        self._tokenizer = tokenizer
        self._model = model

    def warmup(self) -> None:
        """One tiny generation — the first MLX inference compiles kernels."""
        try:
            t0 = time.perf_counter()
            self.clean("um hello", "light", timeout_s=120.0)
            log.info("cleanup: warmup %.1fs", time.perf_counter() - t0)
        except Exception:
            log.exception("cleanup: warmup failed")

    def clean(self, text: str, style: str, timeout_s: float) -> str | None:
        """Generate cleaned text, or ``None`` on deadline / model not ready."""
        if self._model is None:
            log.info("cleanup: model not loaded yet, skipping")
            return None
        from mlx_lm import stream_generate

        deadline = time.perf_counter() + timeout_s
        # Qwen3 is a hybrid-thinking model: without enable_thinking=False it
        # emits <think> blocks and blows the latency budget.
        prompt = self._tokenizer.apply_chat_template(
            build_messages(text, style),
            add_generation_prompt=True,
            enable_thinking=False,
        )
        max_tokens = max(64, min(2 * len(self._tokenizer.encode(text)), 1024))
        parts: list[str] = []
        for resp in stream_generate(
            self._model, self._tokenizer, prompt, max_tokens=max_tokens
        ):
            parts.append(resp.text)
            if time.perf_counter() > deadline:
                log.warning("cleanup: deadline %.1fs hit, falling back to raw", timeout_s)
                return None
        return "".join(parts)
