import json
import os
import pathlib
import shutil
import subprocess

import pytest
from pytest_bdd import given, parsers, scenarios, then, when

from conftest import HOOKS, ROOT, run_hook, run_poll

scenarios("features/agent-sessions.feature")


@pytest.fixture
def ctx():
    return {}


@given(parsers.parse('a Claude Code payload for session "{sid}" in "{cwd}"'))
def claude_payload(ctx, sid, cwd):
    ctx["payload"] = {"session_id": sid, "cwd": cwd, "hook_event_name": "UserPromptSubmit"}


@given(parsers.parse('a Copilot CLI payload for session "{sid}" in "{cwd}"'))
def copilot_payload(ctx, sid, cwd):
    ctx["payload"] = {"sessionId": sid, "timestamp": 1788765573888, "cwd": cwd}


@given(parsers.parse('a grok payload for session "{sid}" in "{cwd}"'))
def grok_payload(ctx, sid, cwd):
    ctx["payload"] = {"sessionId": sid, "cwd": cwd}


@given(parsers.parse('a grok payload with no session id, in "{cwd}"'))
def grok_payload_without_id(ctx, cwd):
    ctx["payload"] = {"cwd": cwd}


@given(parsers.parse('the environment names session "{sid}"'))
def env_names_session(ctx, sid):
    ctx.setdefault("env", {})["GROK_SESSION_ID"] = sid


@given(parsers.parse("grok's registry records pid {pid:d} for that session"))
def grok_registry_records(ctx, grok_home, pid):
    sid = ctx.get("env", {}).get("GROK_SESSION_ID") or ctx["payload"]["sessionId"]
    (grok_home / "active_sessions.json").write_text(json.dumps(
        {"sessions": [{"sessionId": sid, "cwd": "/home/me/proj", "pid": pid,
                       "startedAt": 1788765573888}]}))


@given("the payload carries an initialPrompt")
def with_initial_prompt(ctx):
    ctx["payload"]["source"] = "new"
    ctx["payload"]["initialPrompt"] = "Antworte nur mit dem Wort OK."


@given(parsers.parse('the payload carries a tool call to "{tool}"'))
def with_tool_call(ctx, tool):
    ctx["payload"]["toolCalls"] = [{"id": "toolu_1", "name": tool, "args": {"question": "Which one?"}}]


@given(parsers.parse('the payload is a permissionRequest for "{tool}"'))
def as_permission_request(ctx, tool):
    ctx["payload"].update({"hookName": "permissionRequest", "toolName": tool,
                           "toolInput": {"command": "ls"}, "permissionSuggestions": []})


@given(parsers.parse('the payload is a notification of type "{kind}"'))
def as_notification(ctx, kind):
    text = {"agent_idle": 'Agent "spec-review" has finished processing and is now idle.',
            "elicitation_dialog": "Welche der folgenden Zertifikate sind vorhanden?",
            "permission_prompt": "Run command: python3 -m pytest tests -q",
            # Deliberately not one of the phrases the message filter also catches,
            # so this pins the notificationType gate and nothing else.
            "idle_prompt": "grok has finished this turn."}[kind]
    ctx["payload"].update({"message": text, "notificationType": kind, "title": kind})


@given(parsers.parse("{n:d} seconds pass"))
def seconds_pass(runtime_dir, n):
    import os, time
    for f in runtime_dir.glob("*.state"):
        past = time.time() - n
        os.utime(f, (past, past))


@given(parsers.parse('the "{state}" hook runs'))
@when(parsers.parse('the "{state}" hook runs'))
def hook_runs(ctx, runtime_dir, state):
    result = run_hook(state, json.dumps(ctx["payload"]), env=ctx.get("env"))
    assert result.returncode == 0, result.stderr
    assert result.stdout == "", "hooks must stay silent on stdout"


@given(parsers.parse('a wisp for session "{sid}" owned by a running "{name}" binary'))
def wisp_owned_by_running(ctx, runtime_dir, fake_binaries, sid, name):
    ctx["owner"] = name
    proc = fake_binaries(name)
    _write_state(runtime_dir, sid, "working", "/home/me/proj", proc.pid)


@given(parsers.parse('a wisp for session "{sid}" whose owner is a "{link}" link to a running "{name}" binary'))
def wisp_owned_by_linked(ctx, runtime_dir, fake_binaries, sid, link, name):
    proc = fake_binaries(name, link=link)
    _write_state(runtime_dir, sid, "working", "/home/me/proj", proc.pid)


@given(parsers.parse('a wisp for session "{sid}" owned by an exited "{name}" binary'))
def wisp_owned_by_exited(runtime_dir, fake_binaries, sid, name):
    proc = fake_binaries(name)
    proc.kill()
    proc.wait()
    _write_state(runtime_dir, sid, "working", "/home/me/proj", proc.pid)


@given(parsers.parse('the "{state}" hook runs inside that binary through a throwaway shell'))
def hook_runs_inside_owner_via_shell(ctx, runtime_dir, fake_binaries, state):
    hook_runs_inside_owner(ctx, runtime_dir, fake_binaries, state, via_shell=True)


@given(parsers.parse('the "{state}" hook runs inside that binary'))
def hook_runs_inside_owner(ctx, runtime_dir, fake_binaries, state, via_shell=False):
    import time
    sid = ctx["payload"].get("sessionId") or ctx["payload"]["session_id"]
    fake_binaries(ctx["owner"], hook=(state, json.dumps(ctx["payload"])), via_shell=via_shell)
    for _ in range(50):
        f = runtime_dir / f"{sid}.state"
        if f.exists() and f.read_text().startswith(state):
            return
        time.sleep(0.05)
    raise AssertionError("hook did not write the state file")


@given(parsers.parse('a wisp for session "{sid}" owned by a running "{name}" binary recorded as "{agent}"'))
def wisp_owned_and_recorded(ctx, runtime_dir, fake_binaries, sid, name, agent):
    ctx["owner"] = name
    proc = fake_binaries(name)
    _write_state(runtime_dir, sid, "working", "/home/me/proj", proc.pid, agent)


@when(parsers.parse('the "{state}" hook runs inside a running "{name}" binary'))
def hook_runs_inside_binary(ctx, runtime_dir, fake_binaries, state, name):
    proc = fake_binaries(name, hook=(state, json.dumps(ctx["payload"])))
    ctx["owner_pid"] = proc.pid
    _wait_for_state(runtime_dir, ctx["payload"]["sessionId"], state)


@when(parsers.parse('the "{state}" hook runs inside a "{link}" link to a running "{name}" binary'))
def hook_runs_inside_linked_binary(ctx, runtime_dir, fake_binaries, state, link, name):
    # comm takes the link's name, exe resolves to the real binary, so this
    # pins the comm branch of the walk on its own.
    proc = fake_binaries(name, hook=(state, json.dumps(ctx["payload"])), link=link)
    ctx["owner_pid"] = proc.pid
    _wait_for_state(runtime_dir, ctx["payload"]["sessionId"], state)


@when(parsers.parse('the "{state}" hook runs out of reach of the ancestry walk'))
def hook_runs_buried(ctx, runtime_dir, state):
    result = run_hook(state, json.dumps(ctx["payload"]), env=ctx.get("env"), buried=True)
    assert result.returncode == 0, result.stderr
    assert result.stdout == "", "hooks must stay silent on stdout"


@when("the poller runs")
def poller_runs(ctx, runtime_dir):
    # runtime_dir is not read here, but requesting it is what redirects
    # XDG_RUNTIME_DIR. Without it a scenario with no Given of its own would
    # point the poller at the real one -- which deletes what it finds stale.
    result = run_poll()
    assert result.returncode == 0, result.stderr
    ctx["poll"] = [line.split("\t") for line in result.stdout.splitlines()]


@then(parsers.parse('the wisp for session "{sid}" is "{state}" in "{cwd}"'))
def wisp_state(runtime_dir, sid, state, cwd):
    lines = (runtime_dir / f"{sid}.state").read_text().splitlines()
    assert lines[:2] == [state, cwd]


@then(parsers.parse("there are {n:d} wisps"))
def wisp_count(runtime_dir, n):
    files = list(runtime_dir.glob("*.state")) if runtime_dir.exists() else []
    assert len(files) == n


@then(parsers.parse('the poller lists session "{sid}"'))
def poller_lists(ctx, sid):
    assert [row for row in ctx["poll"] if row[0] == sid], ctx["poll"]


@then(parsers.parse('the poller shows session "{sid}" as "{state}"'))
def poller_shows(ctx, sid, state):
    rows = [row for row in ctx["poll"] if row[0] == sid]
    assert rows and rows[0][1] == state, ctx["poll"]


@then(parsers.parse('the wisp for session "{sid}" is owned by that binary, recorded as "{agent}"'))
def wisp_owned_by_that_binary(ctx, runtime_dir, sid, agent):
    lines = (runtime_dir / f"{sid}.state").read_text().splitlines()
    assert lines[2:4] == [str(ctx["owner_pid"]), agent], lines


@then(parsers.parse('the wisp for session "{sid}" is owned by pid {pid:d}, recorded as "{agent}"'))
def wisp_owned_by_pid(runtime_dir, sid, pid, agent):
    lines = (runtime_dir / f"{sid}.state").read_text().splitlines()
    assert lines[2:4] == [str(pid), agent], lines


@then(parsers.parse('the poller reports session "{sid}" as agent "{agent}"'))
def poller_reports_agent(ctx, sid, agent):
    rows = [row for row in ctx["poll"] if row[0] == sid]
    assert rows and rows[0][4] == agent, ctx["poll"]


@then("the poller lists nothing")
def poller_lists_nothing(ctx):
    assert ctx["poll"] == []


@given("the hook scripts that ship with the plugin")
def the_hook_scripts(ctx):
    ctx["scripts"] = sorted(pathlib.Path(HOOKS).glob("*.sh"))
    assert ctx["scripts"], "no hook scripts found"


@then("each one is valid bash")
def each_script_parses(ctx):
    broken = []
    for script in ctx["scripts"]:
        result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        if result.returncode != 0:
            broken.append(f"{script.name}: {result.stderr.strip().splitlines()[-1]}")
    assert not broken, broken


@given("the QML files this plugin ships")
def the_qml_files(ctx):
    ctx["qml"] = sorted(pathlib.Path(ROOT).glob("*.qml"))
    assert ctx["qml"], "no QML files found"


@then("none of them has a syntax error")
def qml_has_no_syntax_error(ctx):
    # The qmllint on PATH here is Qt5's, which rejects typed JS functions that
    # the runtime accepts, so it has to be the Qt6 build or nothing. It reports
    # by category and exits 0 either way, so the exit code says nothing and
    # only "[syntax]" lines do. Everything else it says -- unresolvable qs.*
    # imports, a property shadowing one from QQuickItem -- predates this test
    # and is not what this scenario claims.
    linter = _qt6_qmllint()
    if not linter:
        pytest.skip("no Qt6 qmllint available")
    broken = []
    for qml in ctx["qml"]:
        result = subprocess.run([linter, str(qml)], capture_output=True, text=True)
        for line in (result.stdout + result.stderr).splitlines():
            if "[syntax]" in line:
                broken.append(line.strip())
    assert not broken, broken


def _qt6_qmllint():
    candidates = ["/usr/lib/qt6/bin/qmllint", "/usr/lib/qt/bin/qmllint",
                  shutil.which("qmllint")]
    for candidate in candidates:
        if not candidate or not os.access(candidate, os.X_OK):
            continue
        shown = subprocess.run([candidate, "--version"], capture_output=True, text=True)
        if " 6." in shown.stdout:
            return candidate
    return None


@given("the files this plugin ships")
def the_plugin_files(ctx):
    listed = subprocess.run(["git", "-C", ROOT, "ls-files"],
                            capture_output=True, text=True, check=True)
    ctx["files"] = [pathlib.Path(ROOT) / name for name in listed.stdout.split("\n") if name]
    assert ctx["files"], "git listed no files"


@then("none of them carries an unresolved merge marker")
def no_merge_markers(ctx):
    # Assembled at runtime so this file does not contain what it searches for.
    opening, closing = "<" * 7, ">" * 7
    found = []
    for path in ctx["files"]:
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if line.startswith(opening) or line.startswith(closing):
                found.append(f"{path.name}:{number}")
    assert not found, found


def _write_state(runtime_dir, sid, state, cwd, pid, agent=None):
    runtime_dir.mkdir(mode=0o700, exist_ok=True)
    # Line 4 is optional: files written before wisps knew more than one agent
    # do not have it, and the poller has to cope with both.
    body = f"{state}\n{cwd}\n{pid}\n" + (f"{agent}\n" if agent else "")
    (runtime_dir / f"{sid}.state").write_text(body)


def _wait_for_state(runtime_dir, sid, state):
    import time
    for _ in range(50):
        f = runtime_dir / f"{sid}.state"
        if f.exists() and f.read_text().startswith(state):
            return
        time.sleep(0.05)
    raise AssertionError("hook did not write the state file")
