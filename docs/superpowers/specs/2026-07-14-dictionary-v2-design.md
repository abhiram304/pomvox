# Spec: Dictionary v2 — visible, instant, and (eventually) self-learning

- **Date:** 2026-07-14
- **Status:** approved design, pre-implementation (plan: `docs/superpowers/plans/2026-07-14-dictionary-v2-phase1.md`)
- **Scope:** Phase 1 specced in full; Phases 2–3 roadmap-level (each gets its own brainstorm/spec when started)
- **Supersedes:** the engine-only dictionary shipped in v0.1.0 (#28/#33) + v0.1.8 wipe contract (#62). Engine contracts are preserved; this adds the product layer.

## Context & problem

Pomvox's dictionary today is two engine mechanisms with no UI:

1. **Words** → injected into the cleanup LLM prompt as spelling preferences (rides the cached prompt prefix; editing requires re-arm).
2. **Replacements** → deterministic whole-word, case-insensitive, longest-source-first fixups applied to final text, always — even when cleanup is off or fails.

Users hand-edit `[dictionary]` in `config.toml` and restart. That's fine plumbing and a dead end as a product: nobody discovers it, nobody maintains it.

## Competitive positioning (2026-07 research)

- **Wispr Flow** auto-learns from your corrections, but silently and in the cloud; its screen-context surveillance caused public backlash, and its dictionary has documented silent-failure modes.
- **VoiceInk** shipped silent *local* auto-learn (Apple NER on post-paste edits) in Apr 2026 and removed it within a month — learned words were invisible and unvetted. The idea didn't fail; the silence did.
- **Handy** has good local phonetic matching (Levenshtein + Soundex) but it's invisible runtime fuzz with the knob hidden in a debug menu, and no learning.
- **Superwhisper** tells users to hand-enumerate every misheard variation. A third-party tool exists solely to mine its transcripts for rules — proof of unmet demand.
- **Nobody ships:** a live "test your rule" preview, generated misheard variants surfaced for review, a "which rules fired" audit trail, local vocabulary mining, or consent-first learning with a review queue.

**Pomvox's bet:** *local + visible + consented*. Every piece of intelligence produces an editable, reviewable artifact — never a silent mutation. Flow's learning minus the surveillance; VoiceInk's instincts minus the silence; Handy's phonetics made visible.

## Goals

- A user can go from "it misheard X" to "X is fixed forever" in one interaction, from anywhere (History, any app via hotkey, the Dictionary page).
- Edits apply without a manual re-arm or restart.
- The user can always see what the dictionary did (which rules fired) and test what it would do (live preview).
- The dictionary file stays plain-text, hand-editable, and git-friendly.

## Non-goals (Phase 1)

- No silent/automatic dictionary mutation of any kind.
- No runtime fuzzy matching (phonetics generate *rules*, they don't fuzz at runtime).
- No per-app/context dictionary scoping (pairs with the tone-profiles roadmap item; revisit in Phase 2+).
- No cloud anything.

## Phasing

| Phase | Contents | Depth here |
|---|---|---|
| **1 — Foundation + visible intelligence** | Dictionary page, add-from-History, quick-add hotkey, live preview, phonetic auto-variants, hot-apply, rule-fired transparency | Full spec (below) |
| **2 — Consented learning** | Suggestion queue; history-edit diffing feeds it; opt-in local vocab mining wizard (per-source checkboxes: Contacts, /Applications, git repos, bookmarks; preview before import) | Roadmap |
| **3 — Ambient signals** | Re-dictation detection; AX post-insert edit watching; HUD "that was wrong" affordance — all feeding the Phase 2 queue | Roadmap |

---

# Phase 1 specification

## 1. Data model & storage

**New file: `~/.pomvox/dictionary.toml`**, owned by the app (hand-editing remains supported). The surgical `ConfigDocument` editor deliberately writes only scalars; the dictionary needs arrays-of-tables and per-rule metadata, so it moves to its own file with a real reader/writer (`DictionaryDocument`: parse to model, serialize canonically — comments outside the emitted header aren't preserved, and the header says so).

```toml
# Pomvox dictionary — safe to hand-edit; the app rewrites this file.
schema = 1
words = ["Kubernetes", "Anthropic", "ChargeBee"]

[[rule]]
sources = ["pom box", "palm vox", "pomme vox"]   # many-to-one
target = "Pomvox"
enabled = true
origin = "manual"        # manual | history | variant | (phase 2: suggested, mined:*)
```

- `words` — the prompt-hint list, unchanged semantics.
- `[[rule]]` — replacement rules. `sources` is a list (many-to-one, replacing today's one-pair-per-line table). `target = ""` remains legal (tic wipe). `origin` records provenance now so Phase 2 suggestions don't need a schema migration. Unknown keys are ignored on parse (a Phase-2 file must not brick a Phase-1 app).
- Rule identity is content-derived (normalized target + sorted sources), so stats survive file rewrites without persisting IDs in the TOML.
- Hit counts / last-fired are **not** stored here (the file stays clean for git); they live in a small sidecar (`~/.pomvox/dictionary-stats.json`), best-effort, loss is harmless.

**Migration:** on first launch with no `dictionary.toml`, read `config.toml`'s `[dictionary]` words + replacements and write them into the new file (`origin = "manual"`). The old section is left in place but dormant — config.toml is never written. If both exist, `dictionary.toml` wins. `[dictionary] enabled` in config.toml continues to gate the whole feature.

**Import/export:** plain text (one word per line) for words; CSV (`source1|source2,target`) for rules — the recurring competitor complaint we don't repeat. Export from the page; import merges with dedupe, never overwrites.

**Components:** `DictionaryStore` (@MainActor single writer: load/save/migrate, publish, notify), `DictionaryDocument` (TOML parse/serialize with round-trip tests), `DictionaryLoader` (pure read-side resolution shared by store and engine).

## 2. Engine

`PomvoxDictionary` grows a rules-aware initializer; the pure `substitute`/`compileReplacements` parity core stays untouched as the legacy spec.

- **Compilation:** each rule's `sources` list expands into per-source whole-word regexes. Existing contracts preserved exactly: whole-word, case-insensitive, longest-source-first across all rules, literal templates, empty-source skip, wipe detection (`dictionary_wiped` classification, HUD flash + telemetry).
- **Fired-rule reporting:** `applyReporting` returns `(text, fired: [ruleID])`. The insertion path records fired rules to the stats sidecar (per-rule count + last-fired). The frozen history schema is **not** migrated — per-row rule tagging is deferred; the sidecar powers the transparency UI.
- **Punctuation edge fix:** a wipe rule (empty target) absorbs one adjacent punctuation mark and the tidy pass collapses leftover double spaces ("um." → "" not "."), closing the known v0.1.8 rough edge. Non-wipe rules never reshape their surroundings. Behavior defined by test vectors first.
- **Hot-apply, two speeds:**
  - *Rules* — applied post-transcription, so a save takes effect on the very next utterance. `DictionaryStore` posts `.pomvoxDictionaryDidChange`; the engine hot-reloads and swaps its compiled set. No re-arm.
  - *Words* — ride the cached LLM prompt prefix. A words edit triggers `CleanupEngine.updateTermsHint`, which swaps the hint and **rebuilds the per-style prefix caches in the background** (seconds of prefill — cheaper than the full re-arm the draft design assumed, same UX). The page shows a transient "Applying…" chip until the engine posts `.pomvoxDictionaryHintApplied`; dictation during the rebuild uses the old hint (never blocks).

## 3. Dictionary page (Hub sidebar, peer of History/Settings)

- **Words section:** chip field (type, return, chip appears). Deleting a chip is one click. One-line explainer that words guide the cleanup model's spelling.
- **Fixups section:** one row per rule — variant chips for `sources`, arrow, `target`, enable toggle, hit count + last-fired (from the sidecar), edit/delete. Wipe rules (`target = ""`) render with a distinct "removes" treatment so tic-wipes are legible.
- **Test box (persistent):** type any phrase; shows before → after with a fired-rule count, recomputed live as rules are edited. Powered directly by the pure `PomvoxDictionary` — cheap, and no competitor has it.
- **Rule editor (sheet):** target field, sources as chips, phonetic variant suggestions (§4), live preview of the rule against sample text.
- Import/export menu; malformed-file banner (parse error + line, in-app edits paused so a hand-edit in progress is never clobbered, Reload button).

## 4. Phonetic auto-variants

When a rule's target is set, Pomvox proposes likely mishearings:

- **Heuristic generator (always available, pure, tested):** compound/hump splits ("ChargeBee" → "charge bee"), acronym letter-spacing ("GPT" → "g p t"), digit-boundary splits ("Qwen3" → "qwen 3"), hyphen↔space.
- **LLM generator (when the cleanup model is resident — never triggers a load):** one-shot "list plausible STT transcriptions of ⟨term⟩", parsed and capped.
- Presented as **editable chips** in the rule editor: heuristic suggestions pre-checked, LLM suggestions offered unchecked. Nothing enters the dictionary unreviewed. `origin = "variant"` on rules created this way.

Explicitly *not* runtime fuzzing: the artifact is always a visible rule the user approved.

## 5. Add-from-History

Every History row gets a "Fix a misheard word…" action → rule editor sheet with the raw transcript rendered as **tappable word tokens** (tap "pom", tap "box" → source "pom box"), target field focused, variant suggestions on target entry. Save → active on next utterance. `origin = "history"`.

## 6. Quick-add hotkey

- New `[hotkey] quick_add` config key (default `""` = off; restart-required, like the existing hotkey keys), parsed as a modifier chord ("cmd+shift+d"; ≥1 modifier required). Settings row under Hotkeys.
- Chord summons a small **non-activating floating panel** (NSPanel, `canBecomeKey`, never activates the app): word field + optional "misheard as" field. Return saves (word-only → words list; both → rule), Escape closes, focus stays with the app the user was in.
- Implemented as NSEvent global/local monitors, deliberately separate from the dictation `HotkeyMachine`/event-tap (different lifecycle: works even when the engine is off, given the Input Monitoring grant).

## 7. Error handling

- Malformed `dictionary.toml` → page-level banner with the parse error + line; the engine loads an empty set for that session (never crashes) and recovers on next reload; in-app edits are paused until reload so the user's hand-edit can't be clobbered.
- The v0.1.8 wipe contract is preserved verbatim (HUD flash, `dictionary_wiped` telemetry, honest log; flash copy now points at the Dictionary page). Still deliberately no fallback paste.
- Stats sidecar corruption → recreated empty; hit counts reset harmlessly.
- `DictionaryStore` is the single writer; external hand-edits are picked up via explicit Reload (and win — the store re-reads before assuming its in-memory copy).

## 8. Testing

- **Pure logic (extend `PomvoxDictionaryTests`):** many-to-one expansion, fired-rule reporting, punctuation-absorbing wipe vectors, whole-transcript wipe still classifiable; existing parity vectors stay green untouched.
- **`DictionaryDocument`:** TOML round-trip (parse → serialize → byte-stable), escaping, malformed-line errors, unknown-key tolerance.
- **`DictionaryLoader`/`DictionaryStore`:** legacy migration, precedence, malformed-file behavior, save/notify.
- **`VariantGenerator` + LLM response parser:** deterministic vectors; the actor method is verified on-device.
- **Live verification (wiki playbook):** migration, hot-apply of rules and words (log lines `dictionary: hot-reloaded`, `cleanup: prefix caches rebuilt`), wipe flash, malformed-file banner, quick-add focus behavior, add-from-History flow.

## 9. Telemetry (content-free, consent-gated as shipped)

Counts and enum codes only, never text: `dictionary_edited` (that an edit happened), `dictionaryFired` count on `dictation_completed`. Nothing about the user's vocabulary ever leaves the machine.

---

# Phase 2 (roadmap): consented learning

- **Suggestion queue:** a Dictionary-page inbox. Every learning signal produces a *suggestion* (proposed rule + evidence: "you changed 'pom box' → 'Pomvox' in History on 3 transcripts"). Accept / edit / dismiss / "never suggest this". Dismissals are remembered. This is the review surface whose absence killed VoiceInk's version and keeps Flow's opaque.
- **History-edit diffing:** History becomes editable; a save diffs old vs new transcript, word-aligns, and files suggestions.
- **Local vocab mining wizard:** one-time, opt-in, per-source checkboxes (Contacts — with the system permission prompt, /Applications names, git repo + branch names under chosen dirs, browser bookmark titles). Preview list before anything is imported; imported entries carry `origin = "mined:<source>"`. Apple's contact-upload backlash is the design lesson: granular consent, visible results.

# Phase 3 (roadmap): ambient signals

- **Re-dictation detection:** two similar utterances in quick succession → diff → suggestion.
- **AX post-insert watching:** observe edits to just-inserted text in the target app (Accessibility API), diff → suggestion. Highest-value signal (Flow's flagship), highest sensitivity — ships opt-in, off by default, with an activity log of what was observed. Needs its own spec.
- **HUD affordance:** brief post-insert window where a keypress flags "that was wrong" → opens the rule editor pre-filled with the last transcript.

# Risks & open questions

- **Prefix-cache rebuild cost:** seconds of prefill on M1-class hardware (prefill ~130 tok/s); acceptable debounce-free since chips add one word per return — verify on-device; fallback is batching words edits behind an explicit Apply button.
- **Variant over-generation:** bad variants that over-match are worse than none. Mitigations: whole-word matching (already), the live preview in the editor, conservative heuristics, LLM extras arriving unchecked.
- **Two-file config story:** dictionary in its own file must be documented in README/config.example; a CLI append entry point (VoiceInk request #751's shape) is cheap later because the file has a single-writer store.
