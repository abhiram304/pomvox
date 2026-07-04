# Security Policy

Pomvox is a local-first macOS dictation app. To do its job it holds three
privacy-sensitive macOS permissions:

- **Microphone** — to capture speech while you dictate.
- **Input Monitoring** — to watch for the global push-to-talk hotkey.
- **Accessibility** — to insert the transcript into the focused app via ⌘V.

Because of that surface, I take security reports seriously and would rather hear
about a problem privately than read about it in the wild.

## Supported versions

Pomvox is pre-1.0 and ships from a single active line. Only the latest release
receives security fixes.

| Version | Supported |
| ------- | --------- |
| Latest release (`0.1.x`) | ✅ |
| Older releases | ❌ |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, report privately through either channel:

1. **GitHub Security Advisories** — the preferred path. Go to the repo's
   [**Security** tab → **Report a vulnerability**](https://github.com/abhiram304/pomvox/security/advisories/new).
   This keeps the discussion private until a fix ships.
2. **Email** — <abhiram.304@gmail.com> with the subject line `Pomvox security`.

Please include, as far as you can:

- The affected version (and your macOS version / Apple Silicon model).
- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- Any relevant logs — but **redact transcripts, audio, and personal data**; I
  do not need them and would rather you not send them.

## What to expect

- I aim to acknowledge a report within **72 hours**.
- I'll confirm the issue and share a rough remediation timeline.
- Fixes for confirmed issues are prioritized for the next release; I'll credit
  you in the release notes and the advisory unless you'd prefer to stay
  anonymous.

This is a solo, best-effort open-source project — there is no bug-bounty program,
but responsible disclosure is genuinely appreciated.

## Scope

In scope:

- The native app (`Pomvox.app`, `Pomvox/`) and its handling of permissions,
  clipboard/insertion, local history, and configuration.
- The opt-in telemetry path (what it sends, and that it cannot send content).
- The Python reference engine (`src/pomvox/`).

Out of scope:

- Vulnerabilities in third-party dependencies — please report those upstream
  (see [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)); I'll bump the
  affected version once a fix is available.
- Findings that require an already-compromised machine or physical access.

## A note on privacy

Your voice and transcripts never leave your Mac by design. The only network
calls Pomvox makes are the one-time model download from Hugging Face and, **if
you opt in**, anonymous content-free usage stats. If you believe you've found a
way that content *could* leave the device, that is exactly the kind of report I
want to hear about — treat it as a security issue and use the private channels
above.
