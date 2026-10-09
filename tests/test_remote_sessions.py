import os
import signal
import subprocess
import time

import pytest
from pytest_bdd import given, parsers, scenarios, then, when

from conftest import HOOKS, run_poll

scenarios("features/remote-sessions.feature")


@pytest.fixture
def ctx():
    return {"ssh_exits": False}


@pytest.fixture
def helpers():
    started = []
    yield started
    for p in started:
        try:
            os.killpg(p.pid, signal.SIGTERM)
            p.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            pass


def _remote_dir(runtime_dir):
    d = runtime_dir / "remote"
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    return d


@given(parsers.parse('the remote list for "{host}" holds a "{state}" session "{sid}" in "{cwd}"'))
def remote_list(runtime_dir, host, state, sid, cwd):
    (_remote_dir(runtime_dir) / f"{host}.list").write_text(f"{sid}\t{state}\t3\t{cwd}\n")


@given(parsers.parse("the remote list is {n:d} seconds old"))
def remote_list_old(runtime_dir, n):
    for f in _remote_dir(runtime_dir).glob("*.list"):
        past = time.time() - n
        os.utime(f, (past, past))


@given(parsers.parse('ssh is faked to stream a "{state}" session "{sid}" in "{cwd}"'))
def fake_ssh(ctx, tmp_path, monkeypatch, state, sid, cwd):
    """A stand-in for ssh that ignores its arguments and prints one snapshot."""
    fake = tmp_path / "fakebin" / "ssh"
    fake.parent.mkdir(exist_ok=True)
    ctx["fake_ssh"] = fake
    ctx["snapshot"] = f"{sid}\t{state}\t3\t{cwd}"
    monkeypatch.setenv("PATH", f"{fake.parent}:{os.environ['PATH']}")
    monkeypatch.setenv("WISPS_REMOTE_RETRY", "30")
    _write_fake(ctx)


@given("the fake ssh exits after streaming")
def fake_ssh_exits(ctx):
    ctx["ssh_exits"] = True
    _write_fake(ctx)


def _write_fake(ctx):
    # A dropped connection still lingers a moment, long enough to observe
    # that the list existed before the helper removed it.
    tail = "sleep 1\n" if ctx["ssh_exits"] else "sleep 30\n"
    ctx["fake_ssh"].write_text(f"#!/usr/bin/env bash\nprintf '%s\\n--\\n' {_q(ctx['snapshot'])}\n{tail}")
    ctx["fake_ssh"].chmod(0o755)


def _q(s):
    return "'" + s.replace("'", "'\\''") + "'"


@when(parsers.parse('the remote helper runs for "{host}"'))
def helper_runs(ctx, runtime_dir, helpers, host):
    p = subprocess.Popen([os.path.join(HOOKS, "wisps-remote.sh"), host], start_new_session=True)
    helpers.append(p)
    lst = runtime_dir / "remote" / f"{host}.list"
    deadline = time.time() + 5
    seen = False
    while time.time() < deadline:
        if lst.exists():
            seen = True
            if not ctx["ssh_exits"]:
                break
        elif seen:
            break                       # it was written, then removed
        time.sleep(0.05)
    ctx["list_seen"] = seen


@when("the poller runs")
def poller_runs(ctx):
    result = run_poll()
    assert result.returncode == 0, result.stderr
    ctx["poll"] = [line.split("\t") for line in result.stdout.splitlines()]


@then(parsers.parse('the remote list for "{host}" holds a "{state}" session "{sid}" in "{cwd}"'))
def remote_list_holds(runtime_dir, host, state, sid, cwd):
    assert (runtime_dir / "remote" / f"{host}.list").read_text() == f"{sid}\t{state}\t3\t{cwd}\n"


@then(parsers.parse('there is no remote list for "{host}"'))
def no_remote_list(ctx, runtime_dir, host):
    assert ctx["list_seen"], "the helper never wrote the list at all"
    assert not (runtime_dir / "remote" / f"{host}.list").exists()


@then(parsers.parse('the poller lists session "{sid}"'))
def poller_lists(ctx, sid):
    assert [row for row in ctx["poll"] if row[0] == sid], ctx["poll"]


@then(parsers.parse('the poller shows session "{sid}" in "{cwd}"'))
def poller_shows_cwd(ctx, sid, cwd):
    rows = [row for row in ctx["poll"] if row[0] == sid]
    assert rows and rows[0][3] == cwd, ctx["poll"]


@then("the poller lists nothing")
def poller_lists_nothing(ctx):
    assert ctx["poll"] == []
