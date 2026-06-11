"""Pure-logic tests for the cleanup pass (no mlx required)."""

from murmur.cleanup import (
    accept_output,
    build_messages,
    common_prefix_len,
    run_cleanup,
)

RAW = "um so I think we should uh ship it tomorrow maybe"


# --- build_messages ---------------------------------------------------------


def test_build_messages_embeds_text_and_rules():
    msgs = build_messages("hello world", "light")
    assert msgs[0]["role"] == "system"
    rules = msgs[0]["content"].lower()
    assert "filler" in rules
    assert "punctuation" in rules
    assert "never change the meaning" in rules
    assert msgs[-1] == {"role": "user", "content": "hello world"}


def test_build_messages_styles_differ():
    light = build_messages("x", "light")[0]["content"].lower()
    polish = build_messages("x", "polish")[0]["content"].lower()
    assert light != polish
    assert "smooth" in polish
    assert "smooth" not in light


def test_build_messages_has_few_shot_pairs():
    msgs = build_messages("x", "polish")
    roles = [m["role"] for m in msgs]
    assert roles[0] == "system"
    assert roles[-1] == "user"
    assert roles.count("assistant") >= 2
    # user/assistant examples alternate between system and the final user turn
    assert roles[1:-1] == ["user", "assistant"] * (roles.count("assistant"))


# --- accept_output ----------------------------------------------------------


def test_accept_normal_output():
    cleaned = "I think we should ship it tomorrow."
    assert accept_output(RAW, cleaned) == cleaned


def test_accept_strips_wrapping_quotes():
    assert (
        accept_output(RAW, '"I think we should ship it tomorrow."')
        == "I think we should ship it tomorrow."
    )


def test_reject_empty():
    assert accept_output(RAW, "") is None
    assert accept_output(RAW, "   \n") is None


def test_reject_think_artifacts():
    assert accept_output(RAW, "<think>hmm</think>Ship it tomorrow, I think.") is None


def test_reject_role_prefix():
    assert accept_output(RAW, "assistant: I think we should ship it tomorrow.") is None


def test_reject_far_too_long():
    assert accept_output("short text here ok", "x" * 200) is None


def test_reject_far_too_short():
    assert accept_output(RAW, "ok") is None


def test_short_raw_skips_lower_bound():
    assert accept_output("ok", "OK.") == "OK."


# --- run_cleanup ------------------------------------------------------------


class FakeEngine:
    def __init__(self, result=None, exc=None):
        self.result = result
        self.exc = exc
        self.calls = []

    def clean(self, text, style, timeout_s):
        self.calls.append((text, style, timeout_s))
        if self.exc is not None:
            raise self.exc
        return self.result


def test_run_cleanup_ok():
    engine = FakeEngine(result="The meeting is on Friday.")
    out = run_cleanup(engine, "um the meeting is on tuesday wait no friday", "polish", 3.0)
    assert out == ("The meeting is on Friday.", "ok")
    assert engine.calls == [("um the meeting is on tuesday wait no friday", "polish", 3.0)]


def test_run_cleanup_timeout_falls_back_to_raw():
    assert run_cleanup(FakeEngine(result=None), RAW, "polish", 3.0) == (RAW, "timeout")


def test_run_cleanup_error_falls_back_to_raw():
    engine = FakeEngine(exc=RuntimeError("boom"))
    assert run_cleanup(engine, RAW, "light", 3.0) == (RAW, "error")


def test_run_cleanup_rejected_falls_back_to_raw():
    engine = FakeEngine(result="<think>let me reason</think>")
    assert run_cleanup(engine, RAW, "polish", 3.0) == (RAW, "rejected")


# --- common_prefix_len -------------------------------------------------------


def test_common_prefix_len_diverging():
    assert common_prefix_len([1, 2, 3], [1, 2, 4]) == 2


def test_common_prefix_len_identical():
    assert common_prefix_len([1, 2, 3], [1, 2, 3]) == 3


def test_common_prefix_len_one_is_prefix_of_other():
    assert common_prefix_len([1, 2, 3], [1, 2]) == 2


def test_common_prefix_len_empty():
    assert common_prefix_len([], [1, 2]) == 0


def test_common_prefix_len_no_overlap():
    assert common_prefix_len([9], [1]) == 0
