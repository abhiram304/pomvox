"""Pidfile mutual exclusion: one event tap / mic at a time across engines.

The native Swift engine (Murmur.app) and the Python engine must never both hold
a CGEventTap or the microphone. A single file ``~/.murmur/engine.pid`` records
the current owner; whoever is about to arm an event tap acquires it first and
refuses if a live *other* engine already holds it.

The file format is the cross-engine contract (mirrored in
``Murmur/Sources/Engine/Pidfile.swift``): line 1 is the pid, line 2 the owner
name (``python`` | ``native``). Pure stdlib so it unit-tests on any platform.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

PIDFILE = Path.home() / ".murmur" / "engine.pid"


@dataclass(frozen=True)
class Owner:
    pid: int
    name: str  # "python" | "native"


def _pid_alive(pid: int) -> bool:
    """True if a process with *pid* exists (POSIX ``kill(pid, 0)``)."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by another user
    return True


def read(path: Path = PIDFILE) -> Owner | None:
    """Parse the pidfile, or None if missing/empty/malformed."""
    try:
        text = path.read_text()
    except OSError:
        return None
    lines = text.splitlines()
    if not lines:
        return None
    try:
        pid = int(lines[0].strip())
    except ValueError:
        return None
    name = lines[1].strip() if len(lines) > 1 else ""
    return Owner(pid, name)


def current_holder(path: Path = PIDFILE) -> Owner | None:
    """The *live* owner of the pidfile, or None (no file, or a stale dead pid)."""
    owner = read(path)
    if owner is None or not _pid_alive(owner.pid):
        return None
    return owner


def acquire(name: str, pid: int | None = None, path: Path = PIDFILE) -> Owner | None:
    """Claim the pidfile for *name*.

    Returns None on success, or the live foreign holder that blocked the claim
    (the caller then refuses to arm). A file held by a live *other* process
    blocks; our own pid or a stale (dead) pid is overwritten. Written atomically
    (temp + rename).
    """
    me = os.getpid() if pid is None else pid
    holder = current_holder(path)
    if holder is not None and holder.pid != me:
        return holder
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f"{path.name}.{me}.tmp"
    tmp.write_text(f"{me}\n{name}\n")
    os.replace(tmp, path)
    return None


def release(name: str | None = None, pid: int | None = None, path: Path = PIDFILE) -> None:
    """Remove the pidfile if this pid still owns it (no-op otherwise)."""
    me = os.getpid() if pid is None else pid
    owner = read(path)
    if owner is not None and owner.pid == me:
        try:
            path.unlink()
        except OSError:
            pass
