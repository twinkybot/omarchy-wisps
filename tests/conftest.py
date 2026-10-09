"""Hermetic environment for the hook scripts.

No real agent runs here. XDG_RUNTIME_DIR points at a temp dir, and an
"owning process" is a copy of bash renamed to claude, copilot or sleep that
just sleeps, so the poller's /proc/<pid>/exe lookup sees exactly the binary
name a real agent would show without starting one. Because it is a shell, it
can also run a hook the way the real agent does: as its child, so the hook
records the fake agent as the session's owner.
"""
import os
import shlex
import shutil
import subprocess

import pytest

HOOKS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks")


@pytest.fixture
def runtime_dir(tmp_path, monkeypatch):
    d = tmp_path / "runtime"
    d.mkdir()
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(d))
    return d / "bert-wisps"


@pytest.fixture
def fake_binaries(tmp_path):
    """Start sleeping processes whose executable is named like an agent."""
    started = []

    def start(name, hook=None, link=None, via_shell=False):
        exe = tmp_path / "bin" / name
        exe.parent.mkdir(exist_ok=True)
        if not exe.exists():
            shutil.copy(shutil.which("bash"), exe)
        if link:
            # Launched through a symlink: /proc/<pid>/comm takes the link's
            # name, /proc/<pid>/exe resolves to the real binary.
            real, exe = exe, exe.parent / link
            if not exe.exists():
                exe.symlink_to(real)
        # The trailing ":" keeps bash from exec-ing straight into sleep, which
        # would turn /proc/<pid>/exe into /usr/bin/sleep.
        script = "sleep 60; :"
        if hook:
            state, payload = hook
            run = f"printf '%s' {shlex.quote(payload)} | {shlex.quote(HOOKS + '/wisps-state.sh')} {state}"
            if via_shell:
                # Like dash: a child shell that stays the hook's parent and
                # exits right after, instead of exec-ing into the script.
                run = f"bash -c {shlex.quote(run + '; :')}"
            script = f"{run}; sleep 60; :"
        proc = subprocess.Popen([str(exe), "-c", script])
        started.append(proc)
        return proc

    yield start
    for p in started:
        p.kill()
        p.wait()


def run_hook(state, payload):
    return subprocess.run(
        [os.path.join(HOOKS, "wisps-state.sh"), state],
        input=payload, text=True, capture_output=True, timeout=10,
    )


def run_poll():
    return subprocess.run(
        [os.path.join(HOOKS, "wisps-poll.sh")],
        text=True, capture_output=True, timeout=10,
    )
