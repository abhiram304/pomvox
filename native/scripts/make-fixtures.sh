#!/bin/sh
# Synthesize deterministic benchmark WAVs (16 kHz mono LEI16) with the system
# voice — same recipe as scripts/preflight.py. Output: native/fixtures/*.wav
# (gitignored; regenerate anywhere with this script).
#
# Three lengths bracket Murmur's typical dictations: ~3 s (one sentence),
# ~8 s (a few sentences), ~15 s (long-form), matching the M0 spike's
# volatile/confirmed promotion probe.
set -eu

dir="$(cd "$(dirname "$0")/.." && pwd)/fixtures"
mkdir -p "$dir"

synth() { # name text
  say -o "$dir/$1.aiff" "$2"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$dir/$1.aiff" "$dir/$1.wav"
  rm "$dir/$1.aiff"
  dur=$(afinfo "$dir/$1.wav" | awk '/estimated duration/ {print $3}')
  echo "$1.wav  ${dur}s"
}

synth short_3s "let's meet on Tuesday, wait no, Friday at two pm to review the draft"

synth medium_8s "um so the three things are uh first do the thing wait no two things \
first do the thing and second ship it. also remind me to email the team about \
the quarterly numbers before the end of the week"

synth long_15s "okay so here's the plan for the murmur project. first we benchmark \
the new speech model on the neural engine and compare it against the current \
pipeline. then if the numbers hold up we port the hotkey state machine and the \
endpoint detector, keeping the python tests as the specification. finally we wire \
up the cleanup model and measure the end to end latency against the budget in \
the spec document"
