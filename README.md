# Wisps

Wisps that haunt your desktop while your coding agents work, and drift over to
your cursor when one needs you.

![Wisps in action](preview.gif)

Leave the terminal, keep working in another window, and you still know what
every agent is doing — they're in the corner of your eye instead of behind a
window.

## Install

```
omarchy plugin add https://github.com/Bert0424/omarchy-wisps.git
omarchy plugin enable bert.wisps
```

Then wire up the hooks below and open a new terminal.

## The states

| | |
|---|---|
| **Dozing** | No session, or one sitting idle. Faint, eyes closed, slow drift. |
| **Working** | The agent is running. Brighter, brisker bob, eyes reading. |
| **Needs you** | It's waiting on a permission or an answer — **the wisp drifts over to your cursor** and pulses. Cleared as soon as the agent gets going again. |
| **Done** | The task finished. A happy spin, then it settles back to dozing. |
| **Trouble** | The agent spent the turn flailing — three or more failed tool calls. Droops, and the colour goes sickly. |

## Several agents at once

One wisp per live session, so three projects running means a mildly haunted
desktop — and each one keeps **its own colour**, so you can see *which* agent
is asking for you rather than just that something is:

| Slot | Colour |
|---|---|
| 1st session | amber |
| 2nd | blue |
| 3rd | white |
| 4th | violet |
| 5th | green |

Both colour **and perch** are held by slot, not by row order. If one agent
exits, the others keep their colour *and stay exactly where they were* — the
gap reads honestly as "that one's gone", and the next agent to start reclaims
that spot and colour. So position identifies an agent as reliably as colour
does.

`Done` and `Trouble` override the body colour while they play. That costs
nothing now that position identifies the agent, and it means a verdict reads
the same on every wisp with nothing to learn.

### The mark it leaves

After the celebration fades, a wisp keeps a **halo** in the colour of how its
last turn ended — green for finished, red for trouble — until you send it a
new prompt. Without it, a wisp that finished six seconds ago looks identical
to one that never started: walk away for ten minutes and you can't tell which
agents succeeded, which are still thinking, and which died on a permission
prompt an hour ago.

The mark lives in the halo rather than the body on purpose. Blending the
verdict into the body turned blue into teal and amber into mud, so "finished"
stopped looking the same on every wisp. Body says *who*; halo says *what
happened*.

## Where they perch

They stay near one corner rather than roaming across whatever you're reading.
Pick **top / bottom** × **left / middle / right** in the popup, and each drifts
on a short leash of about 25px.

Corner anchors **stack vertically**, away from the corner. Middle anchors have
the whole width to use and very little height, so they **fan out sideways**
instead — centred, then alternating right and left.

## Setup

The wisp learns what your agent is doing from Claude Code hooks. Add these to
`~/.claude/settings.json` (paths assume the default plugin location):

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "~/.config/omarchy/plugins/bert.wisps/hooks/wisps-state.sh idle" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.config/omarchy/plugins/bert.wisps/hooks/wisps-state.sh working" }] }],
    "PreToolUse":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.config/omarchy/plugins/bert.wisps/hooks/wisps-state.sh busy" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "~/.config/omarchy/plugins/bert.wisps/hooks/wisps-state.sh attention" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.config/omarchy/plugins/bert.wisps/hooks/wisps-state.sh done" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "~/.config/omarchy/plugins/bert.wisps/hooks/wisps-state.sh gone" }] }]
  }
}
```

Use absolute paths rather than `~` if your shell doesn't expand them. Hooks are
read when a session starts, so open a **new** terminal after adding them.

Without hooks the wisp still works — it just dozes. Everything is driven by
the state files, so any tool that writes them drives the wisp.

### Why the wisp stops hovering

`Notification` is two different events wearing one name: the agent genuinely
needing a decision, and a plain nudge when the prompt has just been sitting
idle. Only the first deserves a wisp at your cursor — treating the nudge as
"needs you" left it hovering long after the work was done.

Granting a permission also fires no hook of its own, so nothing used to tell
the wisp the wait was over until the whole turn ended. `PreToolUse` now calls
the hook with `busy`: a tool starting proves the agent isn't waiting on you.
It is deliberately weaker than `working` — it only ever rescues the attention
state, never overwrites a `done` or `trouble` the wisp is still playing, and
doesn't rewrite anything on a normal tool call.

The nudge filter matches on the notification text, and the last message
received is kept at `$XDG_RUNTIME_DIR/bert-wisps/last-notification.txt` so the
patterns can be checked against reality if it ever misfires.

### When a session dies without saying so

Closing a terminal with a window-kill (`super + w`) destroys the process
outright, so `SessionEnd` never runs and nothing tells the wisp its session is
gone. Each state file therefore records the pid of the claude process that owns
it — a hook's own parent — and the poll drops any file whose process is no
longer alive. A killed session's wisp disappears within a second.

The check reads `/proc/<pid>/comm` and requires exactly `claude`. Matching
against the full command line instead gave false positives: any shell whose
arguments merely mentioned a `~/.claude` path looked like a live session.

### How "trouble" is detected

There is no error hook, and `PostToolUse` does not fire for failed tool calls —
only successful ones — so a failure never reaches a hook directly. The
transcript does record it, though: every failed call lands in the session
JSONL as a `tool_result` with `"is_error": true`.

So `Stop` treats "done" as provisional. `hooks/wisps-verdict.py` reads back
just the turn that ended and counts the failures in it. Three or more and the
wisp goes to **trouble** instead of **done**.

The threshold matters: one failed command is ordinary — a grep that matches
nothing, a test meant to fail, a probe. Several in one turn is the agent
flailing, which is the moment worth looking up at. Errors from earlier turns
are not counted.

Needs `python3` (already present on Omarchy). If it is missing, or anything at
all goes wrong reading the transcript, the verdict stays **done** — a cosmetic
plugin should never claim something broke when it cannot tell.

## Settings

Click the 👻 pill in the bar. Middle-click toggles it off.

- **Size** — Small / Medium / Large
- **Where they perch** — which corner they stay near
- **Layer** — in front of windows, on the desktop, or above everything
- **Come to the cursor when needed** — the drift-to-pointer behaviour
- **Glow**
- **Linger when idle** — keep one wisp dozing between sessions
- **Preview a state** — force a state to see how it looks with no agent running

## How it draws

There is no sprite sheet. The wisp is a `Canvas` path — a dome, a travelling
wave along the hem, and two eyes — so it scales cleanly at any size and there
are no frames to redraw. The wobble is the point rather than a mistake.

## What it does to your system

- **No network access.** Nothing is sent anywhere, ever.
- **No elevated privileges.** Nothing is asked for and nothing is needed.
- Reads your pointer position by asking `hyprctl cursorpos`, and only while a
  session is actually waiting on you. The overlay never claims pointer input,
  so it can't see your clicks or what you type.
- Session state lives in `$XDG_RUNTIME_DIR/bert-wisps/`, one small file per
  session holding a single word, a working directory, and the process id of
  the session that owns it. It is a runtime
  directory, so it is wiped when you log out. Stale files are cleaned up
  after 8 hours.
- On `Stop` it reads the tail of that session's own transcript to count failed
  tool calls. It counts them and nothing else — no content is stored, copied,
  or sent anywhere.
- The overlay is fully click-through, and the surface is unmapped entirely
  when there is no wisp to draw.

## Licence

MIT.
