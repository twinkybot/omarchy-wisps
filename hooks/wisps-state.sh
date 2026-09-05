#!/usr/bin/env bash
# Records what a Claude Code session is currently doing, for the Wisp plugin.
#
# Wired up as hooks in ~/.claude/settings.json; each event calls this with the
# state it represents. The hook payload arrives on stdin as JSON, and all we
# want from it is a few string fields, so we match them with bash's own regex
# rather than forking sed or taking a dependency on jq -- this runs on every
# tool call, so it has to be cheap.
#
# One file per session in a runtime dir, so the files die with the login and
# nothing accumulates on disk:
#
#   $XDG_RUNTIME_DIR/bert-wisps/<session_id>.state
#   line 1: state   line 2: cwd   line 3: owning claude pid
#
# Never fails the hook: any problem here should be invisible to the session,
# and PreToolUse in particular can block a tool if a hook exits non-zero.
set -u

state="${1:-idle}"
dir="${XDG_RUNTIME_DIR:-/tmp}/bert-wisps"

# Read stdin whole without forking a subshell. Command substitution costs a
# fork every time, and this script now runs on every tool call.
payload=""
IFS= read -r -d '' payload || true

# Sets $_f rather than printing, for the same reason.
_f=""
field() {
  _f=""
  if [[ $payload =~ \"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    _f="${BASH_REMATCH[1]}"
  fi
}

# Strip anything that could be misread further downstream: control characters,
# angle brackets (a QML Text with AutoText would treat them as markup), and
# runaway length. Everything here ends up in a file another process parses.
sanitize() {
  local s="${1//[[:cntrl:]]/ }"
  s="${s//</}"; s="${s//>/}"
  printf '%s' "${s:0:256}"
}

field session_id; sid="$_f"
[ -n "$sid" ] || sid="default"

# Session ids are uuids. Anything else is refused outright rather than cleaned,
# so a malformed payload can never steer the write out of the runtime dir.
case "$sid" in
  *[!a-zA-Z0-9._-]*|.*|"") sid="default" ;;
esac

file="$dir/$sid.state"

# The runtime dir must be a real directory we own, never a symlink pointing
# somewhere else.
if [ -e "$dir" ] && { [ -L "$dir" ] || [ ! -d "$dir" ]; }; then exit 0; fi

# Owner-only, and written through a temp file so a pre-planted symlink at the
# destination is replaced rather than followed.
umask 077
write_lines() {
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  local dest="$1"; shift
  local tmp
  tmp="$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || return 0
  printf '%s\n' "$@" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$dest" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

if [ "$state" = "gone" ]; then
  [ -L "$file" ] || rm -f "$file" 2>/dev/null
  exit 0
fi

# --- Notification is two different events wearing one name ------------------
# It fires both when the agent genuinely needs a decision from you, and as a
# plain nudge when the prompt has simply been sitting idle. Only the first is
# worth flying the wisp over to your cursor; treating the nudge as "needs you"
# is what made it hover at the pointer long after the work was finished.
if [ "$state" = "attention" ]; then
  field message; msg="$(sanitize "$_f")"
  # Keep the last one so the filter below can be calibrated against real text
  # rather than guessed at. Runtime dir, single file, overwritten every time.
  write_lines "$dir/last-notification.txt" "$msg"
  case "$msg" in
    *"waiting for your input"*|*"is idle"*|*"been idle"*)
      exit 0 ;;                      # a nudge: leave whatever state we were in
  esac
fi

# --- "busy": clear a stale attention, and nothing else -----------------------
# Granting a permission fires no hook of its own, so without this the wisp
# stays parked at your cursor for the rest of the turn. PreToolUse calls us
# with "busy" -- a tool starting proves the agent is no longer waiting on you.
#
# It is deliberately weaker than "working": it ONLY rescues the attention
# state. It must not touch done/trouble (a terminal verdict the wisp is still
# playing), and it must not rewrite the file on every single tool call.
if [ "$state" = "busy" ]; then
  prev=""
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    read -r prev < "$file" 2>/dev/null || prev=""
  fi
  [ "$prev" = "attention" ] || exit 0
  state="working"
fi

# --- "done" is provisional --------------------------------------------------
# The Stop hook knows the agent stopped but not how it went, and PostToolUse
# never fires for failed tool calls, so the only record of a bad turn is the
# transcript. Ask the verdict script to read it back; if python3 is missing or
# anything goes wrong, stay with "done".
if [ "$state" = "done" ]; then
  verdict_script="${0%/*}/wisps-verdict.py"
  if [ -x "$verdict_script" ] && command -v python3 >/dev/null 2>&1; then
    verdict="$(printf '%s' "$payload" | timeout 5 python3 "$verdict_script" 2>/dev/null)"
    case "$verdict" in
      trouble|done) state="$verdict" ;;
    esac
  fi
fi

field cwd; cwd="$(sanitize "$_f")"
[ -n "$cwd" ] || cwd="${PWD:-}"

# Line 3 is the pid of the claude process that owns this session -- a hook's
# own parent. Killing a terminal outright (super+w) never runs SessionEnd, so
# without a liveness handle the state file, and its wisp, would linger for
# hours after the session died. Rewritten on every event, so it self-heals.
write_lines "$file" "$state" "$cwd" "$PPID"
exit 0
