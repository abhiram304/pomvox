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

_SECTIONS = ("hotkey", "stt", "cleanup", "insert", "log", "hud", "vad", "history")


@dataclass(frozen=True)
class HotkeyConfig:
    ptt: str = "fn"
    toggle: str = "fn+space"
    stop: str = ""  # optional extra stop key; fn tap / fn+space always stop
    cancel: str = "esc"  # discard the utterance; "" disables


@dataclass(frozen=True)
class SttConfig:
    model: str = "mlx-community/parakeet-tdt-0.6b-v3"


@dataclass(frozen=True)
class CleanupConfig:
    enabled: bool = True
    model: str = "mlx-community/Qwen3-4B-4bit"
    style: str = "polish"  # "light" or "polish"
    timeout_s: float = 5.0  # hard deadline; on timeout the raw transcript inserts

    def __post_init__(self) -> None:
        if self.style not in ("light", "polish"):
            raise ValueError(f"style must be 'light' or 'polish', got {self.style!r}")
        if self.timeout_s <= 0:
            raise ValueError("timeout_s must be positive")


@dataclass(frozen=True)
class InsertConfig:
    method: str = "paste"


@dataclass(frozen=True)
class LogConfig:
    file: bool = True


@dataclass(frozen=True)
class HudConfig:
    enabled: bool = True
    show_draft: bool = True  # off keeps live text out of screen-share view
    position: str = "bottom-center"  # or "top-center" / "notch"
    max_chars: int = 120
    sounds: bool = True

    def __post_init__(self) -> None:
        if self.position not in ("bottom-center", "top-center", "notch"):
            raise ValueError(
                f"position must be 'bottom-center', 'top-center', or 'notch', "
                f"got {self.position!r}"
            )
        if self.max_chars <= 0:
            raise ValueError("max_chars must be positive")


@dataclass(frozen=True)
class VadConfig:
    enabled: bool = True  # hands-free auto-stop on a natural pause
    aggressiveness: int = 2  # webrtcvad mode 0–3
    silence_ms: int = 1200  # pause length that ends the utterance
    min_speech_ms: int = 250  # debounce before "speech started"
    energy_gate_dbfs: float = -45.0  # AND-gate: kills breath/keyboard votes
    max_session_s: float = 600.0  # forgotten-open-mic hard stop

    def __post_init__(self) -> None:
        if not 0 <= self.aggressiveness <= 3:
            raise ValueError(f"aggressiveness must be 0–3, got {self.aggressiveness}")
        if self.silence_ms <= 0 or self.min_speech_ms <= 0:
            raise ValueError("silence_ms and min_speech_ms must be positive")
        if self.max_session_s <= 0:
            raise ValueError("max_session_s must be positive")


@dataclass(frozen=True)
class HistoryConfig:
    enabled: bool = True  # transcripts only — audio is never stored
    retention_days: int = 7  # auto-delete window; 0 = keep nothing

    def __post_init__(self) -> None:
        if self.retention_days < 0:
            raise ValueError("retention_days must be >= 0")


@dataclass(frozen=True)
class Config:
    hotkey: HotkeyConfig = field(default_factory=HotkeyConfig)
    stt: SttConfig = field(default_factory=SttConfig)
    cleanup: CleanupConfig = field(default_factory=CleanupConfig)
    insert: InsertConfig = field(default_factory=InsertConfig)
    log: LogConfig = field(default_factory=LogConfig)
    hud: HudConfig = field(default_factory=HudConfig)
    vad: VadConfig = field(default_factory=VadConfig)
    history: HistoryConfig = field(default_factory=HistoryConfig)


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


def restart_required(old: Config, new: Config) -> list[str]:
    """Config changes the menu-bar Reload can't hot-apply, sorted.

    Models load once on worker threads at startup; the hotkey machine and
    event tap are built before the run loop. Everything else hot-applies.
    """
    out = []
    if old.hotkey != new.hotkey:
        out.append("hotkey")
    if old.stt.model != new.stt.model:
        out.append("stt.model")
    if old.cleanup.model != new.cleanup.model:
        out.append("cleanup.model")
    if old.log != new.log:
        out.append("log")
    return out


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
        hud=_load_section(HudConfig, data, "hud"),
        vad=_load_section(VadConfig, data, "vad"),
        history=_load_section(HistoryConfig, data, "history"),
    )
