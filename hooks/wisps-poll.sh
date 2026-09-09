#!/usr/bin/env bash
# Prints one line per live coding-agent session, for Wisps.qml to parse:
#
#   <session_id>\t<state>\t<age_seconds>\t<cwd>\t<agent>
#
# Output is bounded in every direction -- a fixed session cap, a known-word
# state, a clamped cwd -- because a long-lived shell process parses it.
set -u

dir="${XDG_RUNTIME_DIR:-/tmp}/bert-wisps"

# Only a real directory, never a symlink someone dropped in our place.
[ -d "$dir" ] || exit 0
[ -L "$dir" ] && exit 0

now="$(date +%s)"
MAX_SESSIONS=12
STALE_SECONDS=28800        # 8h backstop for files with no pid recorded
count=0

for f in "$dir"/*.state; do
  [ "$count" -ge "$MAX_SESSIONS" ] && break

  # Regular files only. A symlink here would make us read, and then delete,
  # whatever it points at.
  [ -f "$f" ] || continue
  [ -L "$f" ] && continue

  mt="$(stat -c %Y "$f" 2>/dev/null)" || continue
  age=$(( now - mt ))

  # A session whose claude process has exited is gone, whatever its file says.
  # Closing a terminal with a window-kill never fires SessionEnd, so this is
  # the only thing that reliably clears those. Files written by an older
  # version have no pid line; those fall back to the age check below.
  owner="$(sed -n 3p "$f" 2>/dev/null)"

  # Line 4 names the agent that owns the session, so the liveness check knows
  # which process name to expect. Files written before wisps learned about
  # more than one agent have no line 4; those are claude.
  agent="$(sed -n 4p "$f" 2>/dev/null)"
  case "$agent" in
    claude|grok) ;;
    *) agent="claude" ;;
  esac

  case "$owner" in
    ''|*[!0-9]*) 
      if [ "$age" -gt "$STALE_SECONDS" ]; then rm -f "$f" 2>/dev/null; fi
      ;;
    *)
      # /proc/<pid>/comm is the process name alone. Matching the full cmdline
      # instead gave false positives: any shell whose command line merely
      # mentioned a ~/.claude path counted as a live session.
      if [ "$(cat "/proc/$owner/comm" 2>/dev/null)" != "$agent" ]; then
        rm -f "$f" 2>/dev/null
        continue
      fi
      ;;
  esac
  [ -f "$f" ] || continue

  sid="$(basename "$f" .state)"
  case "$sid" in *[!a-zA-Z0-9._-]*) continue ;; esac

  state="$(sed -n 1p "$f" 2>/dev/null)"
  # A known word or nothing: the wisp's whole state machine keys off this.
  case "$state" in
    idle|working|attention|done|trouble) ;;
    *) state="idle" ;;
  esac

  cwd="$(sed -n 2p "$f" 2>/dev/null | tr -d '\000-\037<>')"
  cwd="${cwd:0:160}"

  printf '%s\t%s\t%s\t%s\t%s\n' "$sid" "$state" "$age" "$cwd" "$agent"
  count=$(( count + 1 ))
done
