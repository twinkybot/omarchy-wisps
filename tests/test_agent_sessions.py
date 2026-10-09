import json

import pytest
from pytest_bdd import given, parsers, scenarios, then, when

from conftest import run_hook, run_poll

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
            "elicitation_dialog": "Welche der folgenden Zertifikate sind vorhanden?"}[kind]
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
    result = run_hook(state, json.dumps(ctx["payload"]))
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


@when("the poller runs")
def poller_runs(ctx):
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


@then("the poller lists nothing")
def poller_lists_nothing(ctx):
    assert ctx["poll"] == []


def _write_state(runtime_dir, sid, state, cwd, pid):
    runtime_dir.mkdir(mode=0o700, exist_ok=True)
    (runtime_dir / f"{sid}.state").write_text(f"{state}\n{cwd}\n{pid}\n")
