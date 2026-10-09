#!/usr/bin/env bash
# Streams the wisp sessions of another machine into the local runtime dir.
#
#   wisps-remote.sh <ssh-host> [remote-poll-script]
#
# Agents you run over ssh fire their hooks on the far side, so their state
# files live there and their pids mean nothing here. Rather than ssh once per
# poll tick, this keeps ONE connection open and has the remote copy of
# wisps-poll.sh print its sessions every second, separated by "--" lines.
# Each snapshot is written atomically to
#
#   $XDG_RUNTIME_DIR/bert-wisps/remote/<host>.list
#
# which the local poller merges in as long as the file is fresh. The "--"
# heartbeat keeps it fresh even when nothing runs; if the connection drops,
# the file is removed, the wisps vanish, and we retry after a pause.
#
# The remote side needs wisps-state.sh wired into its agent hooks and
# wisps-poll.sh at the path given (default ~/.local/bin/bert-wisps/).
set -u

host="${1:?usage: wisps-remote.sh <ssh-host> [remote-poll-script]}"
remote_poll="${2:-.local/bin/bert-wisps/wisps-poll.sh}"
case "$host" in *[!a-zA-Z0-9._-]*|.*|"") echo "wisps-remote: bad host name" >&2; exit 1 ;; esac
case "$remote_poll" in *[!a-zA-Z0-9._/-]*|/*|*..*) echo "wisps-remote: bad script path" >&2; exit 1 ;; esac

dir="${XDG_RUNTIME_DIR:-/tmp}/bert-wisps/remote"
list="$dir/$host.list"
umask 077
mkdir -p "$dir" || exit 1
trap 'rm -f "$list"' EXIT

while :; do
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 \
      "$host" "while :; do \"\$HOME/$remote_poll\" 2>/dev/null; echo --; sleep 1; done" 2>/dev/null |
  {
    buf=""
    while IFS= read -r line; do
      if [ "$line" = "--" ]; then
        tmp="$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || continue
        printf '%s' "$buf" > "$tmp" && mv -f "$tmp" "$list" || rm -f "$tmp"
        buf=""
      else
        buf="$buf$line"$'\n'
      fi
    done
  }
  rm -f "$list"
  sleep "${WISPS_REMOTE_RETRY:-10}"
done
