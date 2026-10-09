#!/usr/bin/env bash
# Records what a coding-agent session is currently doing, for the Wisp plugin.
#
# Wired up as hooks in ~/.claude/settings.json and ~/.grok/hooks/wisps.json;
# each event calls this with the state it represents. The two harnesses send
# the same events with the same shape -- only the key style differs (claude's
# session_id vs grok's sessionId) -- so one script serves both. The hook payload arrives on stdin as JSON, and all we
# want from it is a few string fields, so we match them with bash's own regex
# rather than forking sed or taking a dependency on jq -- this runs on every
# tool call, so it has to be cheap.
#
# One file per session in a runtime dir, so the files die with the login and
# nothing accumulates on disk:
#
#   $XDG_RUNTIME_DIR/bert-wisps/<session_id>.state
#   line 1: state   line 2: cwd   line 3: owning agent pid   line 4: agent
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

# Claude Code sends session_id; grok and GitHub Copilot CLI both send it in
# camelCase, and grok also exports the id directly.
field session_id; sid="$_f"
[ -n "$sid" ] || { field sessionId; sid="$_f"; }
[ -n "$sid" ] || sid="${GROK_SESSION_ID:-}"
[ -n "$sid" ] || sid="default"

# Session ids are uuids. Anything else is refused outright rather than cleaned,
# so a malformed payload can never steer the write out of the runtime dir.
case "$sid" in
  *[!a-zA-Z0-9._-]*|.*|"") sid="default" ;;
esac

file="$dir/$sid.state"

# Copilot's one-shot mode (copilot -p) fires userPromptSubmitted before
# sessionStart, so a plain "idle" here would overwrite "working" while the
# agent is already running. A start that carries the prompt is a working one.
if [ "$state" = "idle" ] && [[ $payload =~ \"initial(P|_p)rompt\"[[:space:]]*:[[:space:]]*\" ]]; then
  state="working"
fi

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

# A verdict or a wait can only belong to a session that exists. Copilot fires
# agentStop for a finished subagent under the subagent's own sessionId; without
# this guard every subagent leaves a phantom wisp behind.
case "$state" in
  busy|pending|attention|done|trouble)
    { [ -f "$file" ] && [ ! -L "$file" ]; } || exit 0 ;;
esac

# --- Notification is two different events wearing one name ------------------
# It fires both when the agent genuinely needs a decision from you, and as a
# plain nudge when the prompt has simply been sitting idle. Only the first is
# worth flying the wisp over to your cursor; treating the nudge as "needs you"
# is what made it hover at the pointer long after the work was finished.
#
# Copilot's permissionRequest fires on every tool call, granted or not, and
# its payload does not say which. What does say so is the notification that
# follows only when a dialog is really on screen: notificationType
# "permission_prompt". Measured on Copilot CLI 1.0.83: 77 requests in one
# session, 16 with that notification, and exactly those 16 waited for the
# user (83 s, 57 s, 4.5 s, 2.3 s); the granted ones ran on within
# milliseconds. So the request itself is ignored whatever it was wired to,
# and the notification becomes "pending" -- wisps-poll.sh reports it as
# attention once it has sat unanswered for a couple of seconds, and the next
# tool event clears it.
#
# Claude Code and Qwen Code raise PermissionRequest only for a real dialog,
# and they do not send hookName, so their "pending" still lands.
if [[ $payload =~ \"hookName\"[[:space:]]*:[[:space:]]*\"permissionRequest\" ]]; then
  case "$state" in pending|attention) exit 0 ;; esac
fi
if [ "$state" = "attention" ] && [[ $payload =~ \"notificationType\"[[:space:]]*:[[:space:]]*\"permission_prompt\" ]]; then
  state="pending"
fi
if [ "$state" = "attention" ]; then
  # grok and Copilot both label the two cases outright, so when they tell us,
  # believe it and skip the text matching entirely. Only a waiting permission
  # prompt (grok) or a question dialog (Copilot's elicitation_dialog) is a
  # genuine "needs you"; grok's idle_prompt fires at every turn end, and
  # Copilot's agent_idle only says a subagent has finished.
  field notificationType
  case "$_f" in
    permission_prompt|elicitation_dialog) ;;
    ?*) exit 0 ;;
  esac

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
#
# Copilot's ask_user tool is the agent asking you a question in the terminal,
# so a tool starting can also mean the opposite: that one needs you now.
if [ "$state" = "busy" ]; then
  if [[ $payload =~ \"name\"[[:space:]]*:[[:space:]]*\"ask_user\" ]]; then
    state="attention"
  else
    prev=""
    read -r prev < "$file" 2>/dev/null || prev=""
    case "$prev" in attention|pending) state="working" ;; *) exit 0 ;; esac
  fi
fi

# --- "pending" is a dialog that may be answered any moment ------------------
# The file records "pending" and wisps-poll.sh only reports it as attention
# once it has sat unanswered for a couple of seconds; the next tool hook
# ("busy") clears it as soon as the agent moves on.

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

# Line 3 is the pid of the agent process that owns this session, and line 4
# names it. Killing a terminal outright (super+w) never runs SessionEnd, so
# without a liveness handle the state file, and its wisp, would linger for
# hours after the session died. Rewritten on every event, so it self-heals.
#
# That pid is usually the hook's own parent, but not always: agents run hooks
# through /bin/sh, and where that is dash (Debian, Ubuntu) the shell does not
# exec into the script, so $PPID is a throwaway shell that is gone a moment
# later -- and the poller would drop the wisp on its next tick. grok goes
# further and runs hooks below a node supervisor. So climb the ancestry to the
# first process that is an agent by name (comm) or binary (exe), on a short
# leash, and fall back to $PPID and "claude" when nothing matches.
#
# comm alone is not enough: Copilot CLI names its main thread "MainThread", so
# only exe says "copilot", while Claude's native install runs a binary named
# after its version, so only comm says "claude". wisps-poll.sh checks the same
# two in the same order. Kept fork-free apart from the readlink, since this
# runs on every tool call.
owner="$PPID"
agent="claude"
p="$PPID"
for _ in 1 2 3 4 5 6; do
  comm=""; read -r comm < "/proc/$p/comm" 2>/dev/null || break
  exe="$(readlink "/proc/$p/exe" 2>/dev/null)"; exe="${exe% (deleted)}"
  case "$comm" in
    claude|grok|copilot) owner="$p"; agent="$comm"; break ;;
    *) case "${exe##*/}" in
         claude|grok|copilot) owner="$p"; agent="${exe##*/}"; break ;;
       esac ;;
  esac
  pp=""
  while read -r k v; do [ "$k" = "PPid:" ] && { pp="$v"; break; }; done < "/proc/$p/status" 2>/dev/null
  case "$pp" in ''|*[!0-9]*|0|1) break ;; esac
  p="$pp"
done

# If the walk found nothing and grok is clearly the caller, take grok at its
# word: it keeps a live-session registry of its own, and the pid recorded
# there is the process the poller wants to watch. Only reached on the fallback
# path, so the common case never pays for this.
if [ "$agent" = "claude" ] && [ -n "${GROK_SESSION_ID:-}${GROK_HOOK_EVENT:-}" ]; then
  agent="grok"
  reg="${HOME:-}/.grok/active_sessions.json"
  if [ -f "$reg" ] && [ ! -L "$reg" ]; then
    # One "pid": <n> from the object that carries our session id. tr puts each
    # field on its own line so a plain grep can pick them out without jq.
    # Byte-capped: the file belongs to grok, but a long-lived shell ends up
    # parsing whatever this prints, so never read an unbounded amount of it.
    found="$(head -c 65536 "$reg" 2>/dev/null | tr ',{}' '\n\n\n' \
      | grep -A6 -F "\"$sid\"" 2>/dev/null \
      | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' \
      | head -n1)"
    case "$found" in
      ''|*[!0-9]*) ;;
      *) owner="$found" ;;
    esac
  fi
fi

write_lines "$file" "$state" "$cwd" "$owner" "$agent"
exit 0
