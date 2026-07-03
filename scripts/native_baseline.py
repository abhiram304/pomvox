"""Python-side baseline for the M0 native spike (docs/native-swift-path.md).

Times the current stack — parakeet-mlx STT (GPU) and mlx-lm Qwen3 cleanup —
over the fixture WAVs in native/fixtures/, emitting JSON shaped to line up
with `pomvox-bench` (the Swift/FluidAudio harness). Run on the Mac:

    native/scripts/make-fixtures.sh
    uv run python scripts/native_baseline.py --out /tmp/baseline.json

Models come from config defaults (~/.pomvox/config.toml overrides apply),
per the models-are-config rule. Each measurement is 3 runs; the first run
is reported separately (buffer-pool / warmup effects are real, see
ARCHITECTURE.md).
"""

import argparse
import json
import platform
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

RUNS = 3
STYLE = "light"


def _machine() -> dict:
    chip = subprocess.run(
        ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True
    ).stdout.strip()
    return {"chip": chip, "macos": platform.mac_ver()[0], "python": platform.python_version()}


def _timed(fn) -> tuple[float, object]:
    t0 = time.perf_counter()
    out = fn()
    return time.perf_counter() - t0, out


def main() -> int:
    if sys.platform != "darwin":
        print("native_baseline: requires macOS (mlx).", file=sys.stderr)
        return 1

    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default="native/fixtures")
    ap.add_argument("--out", default="/tmp/pomvox-native-baseline.json")
    args = ap.parse_args()

    wavs = sorted(Path(args.fixtures).glob("*.wav"))
    if not wavs:
        print(f"no WAVs in {args.fixtures} — run native/scripts/make-fixtures.sh", file=sys.stderr)
        return 1

    from pomvox.config import load as load_config

    cfg = load_config()
    report: dict = {"machine": _machine(), "stt_model": cfg.stt.model, "cleanup_model": cfg.cleanup.model}

    # --- STT: parakeet-mlx batch transcribe (GPU/Metal) ---
    from parakeet_mlx import from_pretrained

    load_s, model = _timed(lambda: from_pretrained(cfg.stt.model))
    stt = {"load_s": round(load_s, 3), "files": {}}
    transcripts: dict[str, str] = {}
    for wav in wavs:
        runs = []
        for _ in range(RUNS):
            dt, result = _timed(lambda: model.transcribe(str(wav)))
            runs.append(round(dt, 3))
        transcripts[wav.stem] = result.text.strip()
        stt["files"][wav.stem] = {"runs_s": runs, "transcript": transcripts[wav.stem]}
        print(f"stt  {wav.stem}: {runs}")
    report["stt"] = stt

    # --- Cleanup: mlx-lm Qwen3 with the production prefix-cache path ---
    from pomvox.cleanup import CleanupEngine, run_cleanup

    engine = CleanupEngine(cfg.cleanup.model)
    load_s, _ = _timed(engine.load)
    warm_s, _ = _timed(engine.warmup)  # builds prefix KV caches + one tiny gen
    cleanup = {"load_s": round(load_s, 3), "warmup_s": round(warm_s, 3), "files": {}}
    for name, text in transcripts.items():
        runs, statuses = [], []
        for _ in range(RUNS):
            dt, (out, status) = _timed(lambda: run_cleanup(engine, text, STYLE, cfg.cleanup.timeout_s))
            runs.append(round(dt, 3))
            statuses.append(status)
        cleanup["files"][name] = {"runs_s": runs, "status": statuses, "output": out}
        print(f"clean {name}: {runs} {statuses}")
    report["cleanup"] = cleanup

    Path(args.out).write_text(json.dumps(report, indent=2))
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
