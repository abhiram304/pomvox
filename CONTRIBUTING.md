# Contributing to Murmur

Thanks for helping build local, privacy-first dictation. Start with
[README.md](README.md) (setup), [ARCHITECTURE.md](ARCHITECTURE.md) (how the
pieces fit), and [SPEC.md](SPEC.md) (where the project is going).

## Ground rules

1. **Local-only is the product.** No telemetry, no cloud calls, no "optional"
   network features that are on by default. The only acceptable network
   operation is downloading models from Hugging Face.
2. **Models are config, not constants.** Anything model-shaped (STT model,
   cleanup model, prompts' tunables, deadlines) must be reachable from
   `~/.murmur/config.toml`. Hard-coding a model id outside `config.py`
   defaults will be asked to change in review.
3. **Never lose the user's words.** New pipeline stages must fall back to the
   previous stage's output on any failure, bounded by a deadline. See
   `cleanup.run_cleanup` for the pattern.
4. **Measure before optimizing, on-device.** Latency claims in PRs come with
   numbers from a real Apple Silicon run (the `bench:` and `cleanup: gen` log
   lines, or a script under `scripts/`). The repo's history has several
   examples of plausible optimizations that measurement refuted — keep that
   tradition.

## Development setup

```sh
uv sync
uv run pytest                        # pure-logic tests, run anywhere
uv run python scripts/preflight.py   # macOS only: STT model end-to-end check
uv run murmur                        # macOS only: the app
```

- **Apple Silicon Mac** is required to run the app and anything touching
  `mlx`/`parakeet-mlx`/`pyobjc`.
- **Any platform (including Linux)** can work on pure-logic modules —
  `config`, `hotkey` state machine, `bench`, and the prompt/guard half of
  `cleanup` — the test suite covers them without mlx installed.
- Permissions while developing: TCC grants attach to your *terminal app*, not
  Murmur. See the dev note in README.

### Building the native Hub / engine (Swift)

The Hub (`Murmur/`) is a SwiftUI app generated with XcodeGen:

```sh
brew install xcodegen                                 # one-time
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # not CommandLineTools
cd Murmur && xcodegen generate                        # after editing project.yml / adding files
xcodebuild test -scheme Murmur -derivedDataPath /tmp/murmur-hub-dd \
  -destination 'platform=macOS'                       # build to /tmp, never iCloud Desktop
```

From M4, the Hub carries an off-by-default **Native engine (beta)** toggle
(Settings ▸ General) that uses the Microphone, Input Monitoring, and
Accessibility TCC permissions. macOS keys those grants to the app's *code
identity*, so the build is signed with a stable, free, self-signed certificate
rather than ad-hoc — otherwise every rebuild resets the grants. Create it once:

```sh
scripts/dev-signing-cert.sh          # makes the "Murmur Dev" Code Signing cert
```

`project.yml` then signs with `CODE_SIGN_IDENTITY: "Murmur Dev"`. The native and
Python engines never hold the event tap / mic at the same time — a pidfile
(`~/.murmur/engine.pid`, see `src/murmur/pidfile.py` and
`Murmur/Sources/Engine/Pidfile.swift`) enforces it; arming one while the other
runs is refused with a message. Distribution signing (Developer ID +
notarization) is a later milestone.

## Code style

- Match what's there: type hints, dataclasses for config, deferred imports
  for heavy/macOS-only modules, module docstrings that explain threading and
  ownership.
- Pure logic at module level, side-effectful engines in classes — keeps the
  testable surface large on non-Mac machines (`cleanup.py` and `stt.py` are
  the reference split).
- Logging: one `log.info` line per user-visible event, with stage timings.
  No print().

## Tests

- `uv run pytest` must pass; new pure logic gets unit tests next to the
  existing ones in `tests/`.
- mlx-dependent behavior can't run in CI on Linux — cover it with a script
  the reviewer can run on-device, and paste the output in the PR.

## Pull requests

- One concern per PR, smallest reviewable change.
- Conventional commits (`feat:`, `fix:`, `perf:`, `docs:`…), subject ≤ 72
  chars, body explains *why* with measurements where relevant — read a few
  recent commits for the voice.
- PR description: what changed, what you measured (before/after for
  latency/quality claims), how you verified on-device.
- Phases land in order (SPEC §5); don't start a phase before the previous
  one's acceptance criteria pass.

## Good first areas

- The Phase 2/4 stubs: `vad.py` (auto-stop endpointing), `hud.py` (live draft
  overlay), `context.py` (per-app tone profiles), `dictionary.py` (custom
  words).
- Cleanup quality: the few-shot examples and guards in `cleanup.py` are
  data-driven — failing transcripts make great issues, with the raw text and
  what you expected.
- Latency: speculative decoding for the cleanup model is measured-but-unbuilt
  territory; the STT `add_audio` fixed cost is an upstream (parakeet-mlx)
  conversation.
