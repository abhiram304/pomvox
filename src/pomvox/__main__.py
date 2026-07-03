"""Pomvox CLI entry point.

``--version`` and argument parsing must work on any platform without
importing macOS-only dependencies; the app itself (and ``--check``) import
them lazily.
"""

from __future__ import annotations

import argparse
import logging
import sys

from . import __version__
from .config import CONFIG_DIR

log = logging.getLogger("pomvox")


def setup_logging(to_file: bool) -> None:
    handlers: list[logging.Handler] = [logging.StreamHandler()]
    if to_file:
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            handlers.append(logging.FileHandler(CONFIG_DIR / "pomvox.log"))
        except OSError as exc:
            print(f"pomvox: cannot open log file ({exc})", file=sys.stderr)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s.%(msecs)03d %(levelname)s %(name)s %(message)s",
        datefmt="%H:%M:%S",
        handlers=handlers,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="pomvox", description="Fully local voice dictation for macOS."
    )
    parser.add_argument(
        "--version", action="version", version=f"pomvox {__version__}"
    )
    parser.add_argument(
        "--check", action="store_true", help="report permission status and exit"
    )
    args = parser.parse_args(argv)

    from . import config as config_mod

    cfg = config_mod.load()
    setup_logging(cfg.log.file)

    if sys.platform != "darwin":
        print("pomvox runs on macOS (Apple Silicon) only.", file=sys.stderr)
        return 1

    if args.check:
        from . import permissions

        print(permissions.report())
        return 0

    from .app import run_app

    return run_app(cfg)


if __name__ == "__main__":
    sys.exit(main())
