<!--
Thanks for contributing to Pomvox! Please keep PRs small and focused
(one concern per PR). See CONTRIBUTING.md for the ground rules.
-->

## What & why

<!-- What does this change, and why? Link any related issue: "Closes #123". -->

## How I verified

<!--
How did you test this on-device? Pomvox's rule (CONTRIBUTING §4): latency and
footprint claims come with real numbers from an Apple Silicon run, never assumed.
-->

- [ ] `uv run pytest` passes (Python spec suite)
- [ ] `xcodebuild test … -scheme Pomvox` passes (native app), or N/A
- [ ] For latency/quality/footprint claims: before/after numbers are in the description

## Checklist

- [ ] One concern, smallest reviewable change
- [ ] Conventional-commit subject ≤ 72 chars (`feat:`, `fix:`, `perf:`, `docs:`…)
- [ ] **Local-first upheld** — no new network calls, or if any, they're off by default, anonymous, content-free, and disclosed in-app
- [ ] **Models stay config, not constants** — anything model-shaped is reachable from `config.toml`
- [ ] **The user's words are never lost** — new pipeline stages fall back to the previous stage's output on failure
- [ ] Docs updated if behavior or configuration changed
