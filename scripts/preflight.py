"""Pre-flight check (SPEC §9): verify the STT model loads and transcribes.

Run on the Mac:

    uv run python scripts/preflight.py [path/to/16k-mono.wav]

Without an argument, generates a test WAV with the system `say` voice and
`afconvert`. First run downloads the model from Hugging Face (~1.2 GB) — the
one permitted network operation.
"""

import resource
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
TEST_PHRASE = "this is a test of murmur dictation"


def generate_test_wav(directory: Path) -> Path:
    aiff = directory / "test.aiff"
    wav = directory / "test.wav"
    subprocess.run(["say", "-o", str(aiff), TEST_PHRASE], check=True)
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
        check=True,
    )
    return wav


def main() -> int:
    if sys.platform != "darwin":
        print("preflight: requires macOS (mlx).", file=sys.stderr)
        return 1

    from parakeet_mlx import from_pretrained

    if len(sys.argv) > 1:
        wav = Path(sys.argv[1])
    else:
        tmp = Path(tempfile.mkdtemp(prefix="murmur-preflight-"))
        print(f"generating test audio ({TEST_PHRASE!r}) …")
        wav = generate_test_wav(tmp)

    t0 = time.perf_counter()
    model = from_pretrained(MODEL)
    load_s = time.perf_counter() - t0
    rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20)
    print(f"model load: {load_s:.1f}s  rss={rss_mb:.0f}MB  ({MODEL})")

    t0 = time.perf_counter()
    result = model.transcribe(str(wav))
    stt_s = time.perf_counter() - t0
    print(f"transcribe: {stt_s:.2f}s")
    print(f"transcript: {result.text.strip()!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
