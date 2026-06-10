"""Configuration loading for Murmur.

Reads ``~/.murmur/config.toml`` with stdlib :mod:`tomllib`. Every key has a
default, so the file is optional. A malformed file logs an error and falls
back to defaults — config loading must never crash the app.
"""

from __future__ import annotations

import dataclasses
import logging
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger(__name__)

CONFIG_DIR = Path.home() / ".murmur"
CONFIG_PATH = CONFIG_DIR / "config.toml"

_SECTIONS = ("hotkey", "stt", "cleanup", "insert", "log")


@dataclass(frozen=True)
class HotkeyConfig:
    ptt: str = "fn"
    toggle: str = "fn+space"
    stop: str = "esc"


@dataclass(frozen=True)
class SttConfig:
    model: str = "mlx-community/parakeet-tdt-0.6b-v3"


@dataclass(frozen=True)
class CleanupConfig:
    # Phase 3 — placeholder until the cleanup pass lands.
    enabled: bool = False
    model: str = "mlx-community/Qwen3-4B-4bit"


@dataclass(frozen=True)
class InsertConfig:
    method: str = "paste"


@dataclass(frozen=True)
class LogConfig:
    file: bool = True


@dataclass(frozen=True)
class Config:
    hotkey: HotkeyConfig = field(default_factory=HotkeyConfig)
    stt: SttConfig = field(default_factory=SttConfig)
    cleanup: CleanupConfig = field(default_factory=CleanupConfig)
    insert: InsertConfig = field(default_factory=InsertConfig)
    log: LogConfig = field(default_factory=LogConfig)


def _load_section(cls: type, data: dict, name: str):
    raw = data.get(name, {})
    if not isinstance(raw, dict):
        log.warning("config: [%s] is not a table, using defaults", name)
        return cls()
    known = {f.name for f in dataclasses.fields(cls)}
    kwargs = {}
    for key, value in raw.items():
        if key not in known:
            log.warning("config: unknown key %r in [%s], ignoring", key, name)
            continue
        kwargs[key] = value
    try:
        return cls(**kwargs)
    except (TypeError, ValueError) as exc:
        log.error("config: bad [%s] section (%s), using defaults", name, exc)
        return cls()


def load(path: Path | None = None) -> Config:
    """Load config from *path* (default ``~/.murmur/config.toml``)."""
    path = CONFIG_PATH if path is None else path
    if not path.exists():
        log.info("config: %s not found, using defaults", path)
        return Config()
    try:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        log.error("config: failed to read %s (%s), using defaults", path, exc)
        return Config()
    for name in data:
        if name not in _SECTIONS:
            log.warning("config: unknown section [%s], ignoring", name)
    return Config(
        hotkey=_load_section(HotkeyConfig, data, "hotkey"),
        stt=_load_section(SttConfig, data, "stt"),
        cleanup=_load_section(CleanupConfig, data, "cleanup"),
        insert=_load_section(InsertConfig, data, "insert"),
        log=_load_section(LogConfig, data, "log"),
    )
