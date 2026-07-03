import os

from pomvox import pidfile

DEAD = 999_999  # a pid that won't exist (macOS default pid_max is ~99999)


def _file(tmp_path):
    return tmp_path / "engine.pid"


def test_acquire_on_empty_writes_and_returns_none(tmp_path):
    p = _file(tmp_path)
    assert pidfile.acquire("native", pid=os.getpid(), path=p) is None
    owner = pidfile.read(p)
    assert owner == pidfile.Owner(os.getpid(), "native")


def test_acquire_blocked_by_live_other_holder(tmp_path):
    p = _file(tmp_path)
    # Our own (alive) pid claims it as the python engine.
    assert pidfile.acquire("python", pid=os.getpid(), path=p) is None
    # A different pid trying to claim it is refused, told who holds it.
    blocker = pidfile.acquire("native", pid=DEAD, path=p)
    assert blocker == pidfile.Owner(os.getpid(), "python")
    # The file is untouched — the live holder keeps it.
    assert pidfile.read(p) == pidfile.Owner(os.getpid(), "python")


def test_acquire_overwrites_stale_dead_pid(tmp_path):
    p = _file(tmp_path)
    # A dead pid wrote the file (process crashed without releasing).
    pidfile.acquire("python", pid=DEAD, path=p)
    assert pidfile.current_holder(p) is None  # dead → no live holder
    # The new engine claims it cleanly.
    assert pidfile.acquire("native", pid=os.getpid(), path=p) is None
    assert pidfile.read(p) == pidfile.Owner(os.getpid(), "native")


def test_release_only_removes_when_we_own_it(tmp_path):
    p = _file(tmp_path)
    pidfile.acquire("python", pid=os.getpid(), path=p)
    pidfile.release(pid=os.getpid(), path=p)
    assert pidfile.read(p) is None

    # A file owned by another pid is left alone.
    pidfile.acquire("native", pid=DEAD, path=p)
    pidfile.release(pid=os.getpid(), path=p)
    assert pidfile.read(p) == pidfile.Owner(DEAD, "native")


def test_read_missing_and_malformed(tmp_path):
    p = _file(tmp_path)
    assert pidfile.read(p) is None
    p.write_text("not-a-pid\nnative\n")
    assert pidfile.read(p) is None
    assert pidfile.current_holder(p) is None
