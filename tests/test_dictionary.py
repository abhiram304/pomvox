"""Pure-logic tests for the user dictionary (no mlx required)."""

from natter.dictionary import (
    Dictionary,
    compile_replacements,
    prompt_hint,
    substitute,
)


def sub(text, replacements):
    """Compile + apply in one step for terse test bodies."""
    return substitute(text, compile_replacements(replacements))


# --- prompt_hint ------------------------------------------------------------


def test_prompt_hint_lists_terms():
    hint = prompt_hint(["Salammagari", "parakeet-mlx"])
    assert "Salammagari" in hint
    assert "parakeet-mlx" in hint
    assert hint.endswith("\n")  # drops cleanly into the rule list


def test_prompt_hint_empty_when_no_terms():
    assert prompt_hint([]) == ""
    assert prompt_hint(["", "   "]) == ""


def test_prompt_hint_strips_and_skips_blanks():
    hint = prompt_hint(["  MLX  ", "", "Natter"])
    assert "MLX, Natter" in hint


# --- substitute -------------------------------------------------------------


def test_substitute_basic_replacement():
    assert sub("i love para keet", {"para keet": "parakeet"}) == "i love parakeet"


def test_substitute_is_case_insensitive_but_keeps_replacement_casing():
    assert sub("Salam Mcgarry shipped it", {"salam mcgarry": "Salammagari"}) == (
        "Salammagari shipped it"
    )


def test_substitute_whole_word_only():
    # "para" must not rewrite inside "apparatus".
    assert sub("the apparatus", {"para": "PARA"}) == "the apparatus"
    assert sub("para and more", {"para": "PARA"}) == "PARA and more"


def test_substitute_longest_key_wins():
    out = sub(
        "new york city is big",
        {"new york": "NYC", "new york city": "NYC proper"},
    )
    assert out == "NYC proper is big"


def test_substitute_treats_value_literally():
    # A "\1"/"&" in the replacement is not a regex backreference.
    assert sub("ref one", {"ref one": r"\1 & co"}) == r"\1 & co"


def test_substitute_handles_regex_special_source():
    assert sub("c++ rocks", {"c++": "C-plus-plus"}) == "C-plus-plus rocks"


def test_compile_replacements_skips_empty_key(caplog):
    compiled = compile_replacements({"": "x", "ok": "OK"})
    assert len(compiled) == 1
    assert any("empty replacement" in r.message for r in caplog.records)


# --- Dictionary -------------------------------------------------------------


def test_dictionary_applies_replacements_and_exposes_hint():
    d = Dictionary(["Natter"], {"mur mur": "Natter"})
    assert "Natter" in d.hint
    assert d.apply("open mur mur now") == "open Natter now"


def test_dictionary_disabled_is_a_passthrough():
    d = Dictionary(["Natter"], {"mur mur": "Natter"}, enabled=False)
    assert d.hint == ""
    assert d.apply("open mur mur now") == "open mur mur now"


def test_dictionary_empty_text_passthrough():
    d = Dictionary([], {"a": "b"})
    assert d.apply("") == ""


def test_dictionary_no_replacements_returns_text_unchanged():
    d = Dictionary(["Natter"], {})
    assert d.apply("nothing to change here") == "nothing to change here"
