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
PENDING_SECONDS=2          # a permission request unanswered this long needs you
ORPHAN_SECONDS=300         # a question untouched this long was never seen by its session
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
  # more than one agent have no line 4; those are reported as claude, and any
  # agent we know counts as a live owner for them, since the file cannot say.
  agent="$(sed -n 4p "$f" 2>/dev/null)"
  case "$agent" in
    claude|grok|copilot) expect="$agent" ;;
    *) agent="claude"; expect="" ;;
  esac

  case "$owner" in
    ''|*[!0-9]*) 
      if [ "$age" -gt "$STALE_SECONDS" ]; then rm -f "$f" 2>/dev/null; fi
      ;;
    *)
      # Match the process against the agent that wrote the file. Either the
      # process name or the binary name may carry it, and neither alone is
      # enough: Copilot CLI names its main thread "MainThread", so only
      # /proc/<pid>/exe says "copilot", while Claude's native installer runs a
      # binary named after its version, e.g. .../claude/versions/2.1.263, so
      # only comm says "claude". The full cmdline is never consulted: any
      # shell whose command line merely mentioned a ~/.claude path used to
      # count as a live session.
      comm="$(cat "/proc/$owner/comm" 2>/dev/null)"
      exe="$(readlink "/proc/$owner/exe" 2>/dev/null)"
      exe="${exe% (deleted)}"; exe="${exe##*/}"
      if [ -n "$expect" ]; then
        if [ "$comm" != "$expect" ] && [ "$exe" != "$expect" ]; then
          rm -f "$f" 2>/dev/null
          continue
        fi
      else
        case "$comm" in
          claude|grok|copilot) ;;
          *) case "$exe" in
               claude|grok|copilot) ;;
               *) rm -f "$f" 2>/dev/null; continue ;;
             esac ;;
        esac
      fi
      ;;
  esac
  [ -f "$f" ] || continue

  sid="$(basename "$f" .state)"
  case "$sid" in *[!a-zA-Z0-9._-]*) continue ;; esac

  state="$(sed -n 1p "$f" 2>/dev/null)"
  # A known word or nothing: the wisp's whole state machine keys off this.
  case "$state" in
    idle|working|done|trouble) ;;
    attention|pending)
      # A question nobody has answered for minutes is not a question any more.
      # Claude Code re-keys a session now and then (measured around a fork:
      # the transcript continued under a new session_id at 17:16, the hooks
      # followed it, and the old file sat at "attention" with a live owner
      # pid for good). Nothing will ever write that file again, so the wisp
      # must not chase the cursor on its behalf; it dozes instead.
      if [ "$age" -ge "$ORPHAN_SECONDS" ]; then state="idle"
      # Granted permissions clear within milliseconds; one still pending after
      # PENDING_SECONDS is a dialog waiting on you.
      elif [ "$state" = "pending" ]; then
        if [ "$age" -ge "$PENDING_SECONDS" ]; then state="attention"; else state="working"; fi
      fi ;;
    *) state="idle" ;;
  esac

  cwd="$(sed -n 2p "$f" 2>/dev/null | tr -d '\000-\037<>')"
  cwd="${cwd:0:160}"

  printf '%s\t%s\t%s\t%s\t%s\n' "$sid" "$state" "$age" "$cwd" "$agent"
  count=$(( count + 1 ))
done

# --- Sessions on other machines ---------------------------------------------
# wisps-remote.sh streams a remote poller's output into remote/<host>.list,
# rewriting it every second. A list older than REMOTE_STALE_SECONDS means the
# stream has died; its sessions are dropped rather than shown frozen. Every
# field is re-validated here: the file was written from another machine's
# output, and the sanitiser above must apply to it just the same.
REMOTE_STALE_SECONDS=5
rdir="$dir/remote"
if [ -d "$rdir" ] && [ ! -L "$rdir" ]; then
  for f in "$rdir"/*.list; do
    [ "$count" -ge "$MAX_SESSIONS" ] && break
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    mt="$(stat -c %Y "$f" 2>/dev/null)" || continue
    [ $(( now - mt )) -le "$REMOTE_STALE_SECONDS" ] || continue

    host="$(basename "$f" .list)"; host="${host%%.*}"
    case "$host" in *[!a-zA-Z0-9-]*|"") continue ;; esac

    while IFS=$'\t' read -r sid state age cwd agent; do
      [ "$count" -ge "$MAX_SESSIONS" ] && break
      case "$sid" in *[!a-zA-Z0-9._-]*|"") continue ;; esac
      case "$state" in idle|working|attention|done|trouble) ;; *) state="idle" ;; esac
      case "$age" in ''|*[!0-9]*) age=0 ;; esac
      # The agent has to be read into its own field: left inside cwd, the tab
      # before it is a control character, and the strip below would swallow it
      # and glue the two columns together. A machine still running an older
      # poller sends four columns and names no agent; those are claude's, as
      # every session was before the column existed.
      case "$agent" in claude|grok|copilot|opencode|qwen) ;; *) agent="claude" ;; esac
      cwd="$(printf '%s' "$cwd" | tr -d '\000-\037<>')"
      cwd="$host:${cwd:0:150}"
      printf '%s\t%s\t%s\t%s\t%s\n' "$sid" "$state" "$age" "$cwd" "$agent"
      count=$(( count + 1 ))
    done < "$f"
  done
fi
