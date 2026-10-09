import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// A wisp that haunts your desktop while a coding agent works.
//
// One transparent, click-through layer-shell surface per screen, carrying one
// wisp per live Claude Code session. Session state arrives through hooks
// (hooks/wisps-state.sh) which drop a small file per session into
// $XDG_RUNTIME_DIR/bert-wisps/; we poll that directory rather than parsing any
// terminal output, so nothing here depends on what is on screen.
//
//   dozing     no session, or a session sitting idle
//   working    the agent is running
//   attention  it is waiting on YOU — the wisp drifts to your cursor
//   done       the task finished
//   trouble    it stopped on an error
//
// Nothing is a sprite: the wisp is a Canvas path, so there is no art to load
// and no anatomy to get wrong. A dome, a travelling wave along the hem, two
// eyes. Squash and stretch is a transform, and the wobble is the point rather
// than a mistake.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // --- live config, pushed from BarWidget.applyConfig -------------------
  property bool showWisps: true
  property real sizeScale: 1.0                 // Small .72 / Medium 1.0 / Large 1.4
  property string stackLayer: "top"            // top | bottom | overlay
  property bool followCursor: true
  property bool glowEnabled: true
  property bool hauntWhenIdle: true
  property string previewState: "Off"
  property string anchorH: "right"          // left | middle | right
  property string anchorV: "bottom"         // top | bottom

  readonly property url pollScript: Qt.resolvedUrl("hooks/wisps-poll.sh")

  // --- session state ----------------------------------------------------
  // [{ id, state, age, cwd }] — rebuilt on each poll.
  property var sessions: []

  function applyConfig(s) {
    if (!s) return
    if (typeof s.enabled === "boolean") showWisps = s.enabled
    if (typeof s.follow === "boolean") followCursor = s.follow
    if (typeof s.glow === "boolean") glowEnabled = s.glow
    if (typeof s.haunt === "boolean") hauntWhenIdle = s.haunt
    if (typeof s.preview === "string") previewState = s.preview
    if (typeof s.corner === "string") {
      anchorH = s.corner.indexOf("left") >= 0 ? "left"
              : s.corner.indexOf("middle") >= 0 ? "middle" : "right"
      anchorV = s.corner.indexOf("Top") >= 0 ? "top" : "bottom"
    }
    stackLayer = s.layer === "On the desktop" ? "bottom"
               : s.layer === "Above everything" ? "overlay" : "top"
    sizeScale = s.size === "Small" ? 0.72 : s.size === "Large" ? 1.4 : 1.0
  }

  // What the Repeater draws. This MUST be a ListModel updated in place, not a
  // plain JS array: assigning a fresh array makes the Repeater destroy and
  // rebuild every delegate, which re-runs reseed() and teleports each wisp
  // back to its home spot. Polling once a second then looked like the wisp
  // flying at your cursor, snapping back, and flying in again -- a twitch, not
  // a drift. Syncing rows by session id keeps the delegates, and their
  // positions, alive across polls.
  ListModel { id: wispModel }

  // Plain mirror of the same list, for the bar widget's tooltip only. Nothing
  // renders from it, so churn here is harmless.
  property var wisps: []

  property bool anyAttention: false

  readonly property bool active: showWisps && wispModel.count > 0

  function desiredWisps() {
    if (previewState !== "Off") {
      var m = { "Dozing": "idle", "Working": "working", "Needs you": "attention",
                "Done": "done", "Trouble": "trouble" }
      return [{ id: "preview", state: m[previewState] || "idle", cwd: "preview" }]
    }
    if (sessions.length > 0) return sessions
    // No sessions at all: one wisp dozes on, if you want the company.
    return hauntWhenIdle ? [{ id: "resident", state: "idle", cwd: "" }] : []
  }

  function syncWisps() {
    var want = desiredWisps()

    // Drop rows that are gone, back to front so indices stay valid.
    for (var i = wispModel.count - 1; i >= 0; i--) {
      var keep = false
      for (var j = 0; j < want.length; j++)
        if (want[j].id === wispModel.get(i).sid) { keep = true; break }
      if (!keep) wispModel.remove(i)
    }

    // Update in place where the row already exists; only append what is new.
    for (var k = 0; k < want.length; k++) {
      var w = want[k]
      var at = -1
      for (var n = 0; n < wispModel.count; n++)
        if (wispModel.get(n).sid === w.id) { at = n; break }
      if (at === -1) {
        // Smallest free slot, so slot 0 stays amber even as other agents come
        // and go. Using the row index instead would reshuffle every colour
        // whenever an earlier session ended.
        var slot = 0
        while (true) {
          var taken = false
          for (var s = 0; s < wispModel.count; s++)
            if (wispModel.get(s).slot === slot) { taken = true; break }
          if (!taken) break
          slot++
        }
        wispModel.append({ sid: w.id, mstate: w.state || "idle", cwd: w.cwd || "", slot: slot })
      } else {
        if (wispModel.get(at).mstate !== w.state) wispModel.setProperty(at, "mstate", w.state || "idle")
        if (wispModel.get(at).cwd !== (w.cwd || "")) wispModel.setProperty(at, "cwd", w.cwd || "")
      }
    }

    var att = false
    for (var q = 0; q < want.length; q++) if (want[q].state === "attention") att = true
    anyAttention = att
    wisps = want
  }

  // `omarchy plugin remove` runs no hooks of its own, so the service tidies up
  // after itself: stop the pollers rather than leaving them attached to a
  // shell that is about to drop the plugin.
  Component.onDestruction: {
    if (pollProc.running) pollProc.running = false
    if (cursorProc.running) cursorProc.running = false
  }

  onSessionsChanged: syncWisps()
  onPreviewStateChanged: syncWisps()
  onHauntWhenIdleChanged: syncWisps()
  Component.onCompleted: syncWisps()

  // --- polling the session dir -----------------------------------------
  // A poll reads a handful of small files and is gone in milliseconds. One
  // still running after this long is not slow, it is wedged -- and because
  // the timer below only starts a poll once the last one has finished, a
  // single wedged poll stops the overlay forever. That is not theoretical:
  // a hook script left with conflict markers did it, and the wisps stayed
  // gone until the shell was restarted by hand.
  readonly property int pollStuckMs: 5000
  property real pollStartedAt: 0

  Process {
    id: pollProc
    command: ["/usr/bin/env", "bash", root.pollScript.toString().replace("file://", "")]
    stdout: StdioCollector {
      id: pollOut
      waitForEnd: true
      onStreamFinished: {
        var out = []
        var lines = String(pollOut.text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var ln = lines[i]
          if (!ln) continue
          var f = ln.split("\t")
          if (f.length < 2) continue
          out.push({ id: f[0], state: f[1], age: parseInt(f[2]) || 0, cwd: f[3] || "" })
        }
        root.sessions = out
      }
    }
  }

  Timer {
    interval: 700
    repeat: true
    running: root.showWisps && root.previewState === "Off"
    triggeredOnStart: true
    onTriggered: {
      if (!pollProc.running) {
        root.pollStartedAt = Date.now()
        pollProc.running = true
      } else if (Date.now() - root.pollStartedAt > root.pollStuckMs) {
        // Let go of it. The next tick finds nothing running and starts fresh.
        pollProc.running = false
      }
    }
  }

  // --- cursor, only while something is actually waiting on you ----------
  // Polled the same way Graveyard does it: asking hyprctl costs nothing and
  // means the overlay never has to claim pointer input to know where you are.
  property real cursorX: 0
  property real cursorY: 0
  property bool cursorValid: false

  Process {
    id: cursorProc
    command: ["/usr/bin/hyprctl", "cursorpos"]
    stdout: StdioCollector {
      id: cursorOut
      waitForEnd: true
      onStreamFinished: {
        var p = String(cursorOut.text || "").trim().split(",")
        if (p.length < 2) return
        var gx = parseFloat(p[0]), gy = parseFloat(p[1])
        if (isNaN(gx) || isNaN(gy)) return
        root.cursorX = gx; root.cursorY = gy; root.cursorValid = true
      }
    }
  }

  Timer {
    interval: 110
    repeat: true
    running: root.active && root.followCursor && root.anyAttention
    onTriggered: if (!cursorProc.running) cursorProc.running = true
  }

  // One colour per concurrent agent, so you can tell at a glance which of them
  // is asking for you. Slot 0 is the first session that showed up.
  readonly property var palette: [
    [1.00, 0.64, 0.30],   // 0 amber
    [0.48, 0.74, 1.00],   // 1 blue
    [0.93, 0.96, 1.00],   // 2 white
    [0.80, 0.64, 1.00],   // 3 violet
    [0.58, 0.95, 0.72]    // 4 green
  ]

  function rand(a, b) { return a + Math.random() * (b - a) }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      visible: root.active

      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore

      WlrLayershell.namespace: "bert-wisps"
      WlrLayershell.layer: root.stackLayer === "overlay" ? WlrLayer.Overlay
                         : root.stackLayer === "bottom"  ? WlrLayer.Bottom
                         : WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Fully click-through: a wisp you can't bump into.
      mask: Region {}

      Repeater {
        model: wispModel

        delegate: Item {
          id: g
          required property int index
          required property string sid
          required property string mstate
          required property int slot

          // What the hooks last reported. Kept separate from gstate below,
          // because the decay timer must key off THIS changing, not off the
          // derived state: resetting sinceState from onGstateChanged fed the
          // binding back into itself and made "done" flicker against "idle"
          // every tick instead of holding for six seconds.
          readonly property string rawState: mstate || "idle"

          readonly property string gstate: {
            // "done" is a beat, not a resting state — it decays back to dozing
            // so a finished session doesn't cheer at you all afternoon.
            if (rawState === "done" && sinceState > 6) return "idle"
            return rawState
          }

          readonly property real sc: root.sizeScale
          readonly property int box: Math.round(130 * sc)

          width: box
          height: box

          // Where it lives when nothing is pulling it: spread the sessions out
          // so three wisps don't stack on the same pixel.
          property real homeX: 0
          property real homeY: 0
          property real tx: 0
          property real ty: 0
          property real phase: Math.random() * 6.28
          property real sinceState: 0
          property real spin: 0
          property real squash: 1.0
          property real appear: 0        // 0..1 fade-in on birth

          // A delegate can be created before its window has been given a size.
          // Seeding then puts the wisp at 0,0 and every later clamp keeps it
          // there, pinned in the top-left corner for good. Wait for real
          // dimensions and seed on the first tick that has them.
          property bool seeded: false

          // Home is derived from the window each time rather than cached once.
          // A single bad seed -- a delegate created before its window had a
          // size -- used to pin a wisp in the top-left corner permanently,
          // because every later wander clamped against the same stale zero.
          // Recomputing means the next wander heals it on its own.
          //
          // Wisps perch near the corner you picked rather than roaming the
          // middle of the screen: the point is to be visible in peripheral
          // vision, not to wander across whatever you are reading.
          //
          // Position is keyed to `slot`, NOT to the row index. Slot is stable
          // for the life of a session, so each agent keeps one perch even when
          // another exits -- an empty gap reads honestly as "that one's gone",
          // and the next agent to start reclaims that exact spot and colour.
          // Keying it to the index instead made every wisp shuffle up a place
          // whenever an earlier one finished, which meant position could not
          // be trusted to identify an agent.
          readonly property int sidePad: 30
          readonly property int topPad: 52          // clears the bar
          readonly property int stackGap: Math.round(box * 0.74)

          // A middle anchor has the whole width to spread into and very little
          // height, so it fans sideways instead of stacking down the screen.
          readonly property bool fansSideways: root.anchorH === "middle"

          // Balanced fan: 0 centred, then alternating right and left, so the
          // group stays visually centred while each slot keeps a fixed place.
          function fanOffset(s) {
            if (s === 0) return 0
            return (s % 2 === 1) ? Math.ceil(s / 2) : -Math.ceil(s / 2)
          }

          function homeFor(axis) {
            if (axis === "x") {
              var cx = (win.width - box) / 2
              if (fansSideways) return cx + fanOffset(slot) * stackGap
              return root.anchorH === "left" ? sidePad : win.width - box - sidePad
            }
            var top = topPad
            var bot = win.height - box - sidePad
            if (fansSideways) return root.anchorV === "top" ? top : bot
            // Corner anchors stack away from the corner instead.
            return root.anchorV === "top" ? top + slot * stackGap
                                          : bot - slot * stackGap
          }

          function reseed() {
            if (win.width <= 0 || win.height <= 0) return
            seeded = true
            homeX = Math.max(0, Math.min(win.width  - box, homeFor("x")))
            homeY = Math.max(0, Math.min(win.height - box, homeFor("y")))
            tx = homeX; ty = homeY
            x = homeX; y = homeY
          }

          function wander() {
            if (!seeded || win.width <= 0 || win.height <= 0) return
            homeX = Math.max(0, Math.min(win.width  - box, homeFor("x")))
            homeY = Math.max(0, Math.min(win.height - box, homeFor("y")))
            // A short leash. Enough to look alive, not enough to drift into
            // the middle of whatever you are working on.
            tx = Math.max(0, Math.min(win.width  - box, homeX + root.rand(-26, 26)))
            ty = Math.max(0, Math.min(win.height - box, homeY + root.rand(-20, 20)))
          }

          Component.onCompleted: reseed()

          Connections {
            target: root
            function onAnchorHChanged() { g.wander() }
            function onAnchorVChanged() { g.wander() }
          }

          // How the last finished turn went, kept after the celebration fades.
          // Without this a wisp that finished six seconds ago is identical to
          // one that never started: walk away for ten minutes and you cannot
          // tell whether the agent succeeded, is still thinking, or died on a
          // permission prompt. Cleared when you send the next prompt.
          property string lastOutcome: ""        // "" | "done" | "trouble"

          onRawStateChanged: {
            sinceState = 0
            if (rawState === "done")    { spin = 0; squash = 1.35; lastOutcome = "done" }
            if (rawState === "trouble") { lastOutcome = "trouble" }
            if (rawState === "attention") squash = 1.2
            if (rawState === "working") lastOutcome = ""
          }

          Timer {
            id: wanderTimer
            repeat: true
            running: win.visible
            interval: g.gstate === "working" ? 2200 : 5200
            onTriggered: {
              if (g.gstate !== "attention") g.wander()
              interval = Math.round(root.rand(1800, g.gstate === "working" ? 3600 : 7000))
            }
          }

          // One tick drives everything: drift, bob, hem wave, squash recovery.
          // Keeping motion here rather than in QML animations avoids retargeting
          // a running NumberAnimation every time the cursor moves.
          Timer {
            interval: 40
            repeat: true
            running: win.visible
            onTriggered: {
              if (!g.seeded) { g.reseed(); if (!g.seeded) return }
              var dt = 0.04
              g.sinceState += dt
              g.appear = Math.min(1, g.appear + dt * 1.6)
              g.phase += dt * (g.gstate === "working" ? 4.2
                             : g.gstate === "attention" ? 5.4
                             : g.gstate === "trouble" ? 1.6 : 2.0)

              // Where do we want to be?
              if (g.gstate === "attention" && root.followCursor && root.cursorValid) {
                var scr = win.screen
                var ox = scr && scr.x !== undefined ? scr.x : 0
                var oy = scr && scr.y !== undefined ? scr.y : 0
                // Hover just up and left of the pointer rather than sitting on
                // it, so it never covers what you are about to click.
                g.tx = Math.max(0, Math.min(win.width  - g.box, root.cursorX - ox - g.box * 0.5 - 26 * g.sc))
                g.ty = Math.max(0, Math.min(win.height - g.box, root.cursorY - oy - g.box * 0.5 - 30 * g.sc))
              }

              // Ease toward the target. Attention closes fast; dozing drifts.
              var k = g.gstate === "attention" ? 0.085
                    : g.gstate === "working" ? 0.030 : 0.016
              g.x += (g.tx - g.x) * k
              g.y += (g.ty - g.y) * k

              if (g.gstate === "done") g.spin += dt * 7.0
              g.squash += (1.0 - g.squash) * 0.12

              canvas.requestPaint()
            }
          }

          // Bob is applied to the canvas rather than to y, so it survives the
          // easing above without fighting it.
          readonly property real bobAmp: gstate === "idle" ? 5 : gstate === "working" ? 8
                                       : gstate === "attention" ? 4 : 6
          readonly property real bob: Math.sin(phase) * bobAmp * sc

          Canvas {
            id: canvas
            anchors.fill: parent
            y: g.bob
            renderStrategy: Canvas.Cooperative
            opacity: g.appear

            transform: [
              Rotation {
                angle: g.gstate === "done" ? Math.sin(g.spin) * 16
                     : g.gstate === "trouble" ? 9 : Math.sin(g.phase * 0.5) * 3
                origin.x: canvas.width / 2
                origin.y: canvas.height * 0.72
              },
              Scale {
                xScale: g.squash
                yScale: 2.0 - g.squash
                origin.x: canvas.width / 2
                origin.y: canvas.height * 0.78
              }
            ]

            onPaint: {
              var ctx = getContext("2d")
              var W = width, H = height
              ctx.reset()
              ctx.clearRect(0, 0, W, H)

              var S = g.sc
              var cx = W / 2
              var cy = H * 0.50
              var r  = 32 * S
              var bodyH = 26 * S
              var hemAmp = 9 * S
              var hemY = cy + bodyH
              var st = g.gstate

              // --- colour: identity, then state ----------------------------
              // Each agent keeps its own hue for idle/working/attention, so
              // with several running you can see WHICH one is asking for you
              // rather than just that something is. done and trouble stay
              // universal -- a verdict should read the same on every wisp --
              // and they only last a few seconds anyway.
              var mine = root.palette[g.slot % root.palette.length]
              function mix(a, b, f) {
                return [a[0] + (b[0] - a[0]) * f,
                        a[1] + (b[1] - a[1]) * f,
                        a[2] + (b[2] - a[2]) * f]
              }
              var col, alpha
              if (st === "trouble")        { col = [1.00, 0.66, 0.62]; alpha = 0.86 }
              else if (st === "done")      { col = [0.76, 1.00, 0.86]; alpha = 0.94 }
              else if (st === "attention") { col = mine; alpha = 1.00 }
              else if (st === "working")   { col = mine; alpha = 0.80 }
              else {
                // Dozing, but still showing how the last turn ended. Only a
                // whisper of the verdict goes into the body -- blending it in
                // fully turned blue+mint into teal and amber+mint into mud, so
                // "finished" stopped looking the same on every wisp. The body
                // stays who it is; the halo below carries what happened.
                col = mine; alpha = 0.44
                if (g.lastOutcome === "done") {
                  col = mix(mine, [0.76, 1.00, 0.86], 0.18); alpha = 0.50
                } else if (g.lastOutcome === "trouble") {
                  col = mix(mine, [1.00, 0.55, 0.50], 0.18); alpha = 0.50
                }
              }

              // The halo is a separate channel from the body, so it can report
              // the verdict identically on every agent without touching identity.
              var glowCol = col
              var glowBoost = 1.0
              if (st === "idle" && g.lastOutcome === "done") {
                glowCol = [0.62, 1.00, 0.78]; glowBoost = 1.9
              } else if (st === "idle" && g.lastOutcome === "trouble") {
                glowCol = [1.00, 0.44, 0.40]; glowBoost = 1.9
              }

              // Attention breathes so it catches the eye in peripheral vision.
              if (st === "attention") alpha *= 0.78 + 0.22 * Math.sin(g.phase * 1.9)

              function rgbaOf(c, a) {
                return "rgba(" + Math.round(c[0] * 255) + "," + Math.round(c[1] * 255)
                     + "," + Math.round(c[2] * 255) + "," + a.toFixed(3) + ")"
              }
              function rgba(a) { return rgbaOf(col, a) }

              // --- glow ------------------------------------------------------
              if (root.glowEnabled) {
                var gr = r * (st === "attention" ? 3.0 : 2.3)
                var grad = ctx.createRadialGradient(cx, cy, r * 0.3, cx, cy, gr)
                grad.addColorStop(0.0, rgbaOf(glowCol, alpha * 0.50 * glowBoost))
                grad.addColorStop(0.55, rgbaOf(glowCol, alpha * 0.16 * glowBoost))
                grad.addColorStop(1.0, rgbaOf(glowCol, 0))
                ctx.fillStyle = grad
                ctx.beginPath()
                ctx.arc(cx, cy, gr, 0, Math.PI * 2)
                ctx.fill()
              }

              // --- body: dome + travelling wave along the hem ---------------
              ctx.beginPath()
              ctx.arc(cx, cy, r, Math.PI, 0, false)
              ctx.lineTo(cx + r, hemY)

              var n = 3
              var seg = (2 * r) / n
              for (var i = 0; i < n; i++) {
                var x0 = cx + r - i * seg
                var x1 = x0 - seg
                var amp = Math.sin(g.phase * 1.4 + i * 1.9) * hemAmp
                ctx.quadraticCurveTo((x0 + x1) / 2, hemY + amp, x1, hemY)
              }
              ctx.lineTo(cx - r, cy)
              ctx.closePath()

              ctx.fillStyle = rgba(alpha * 0.88)
              ctx.fill()
              ctx.lineWidth = 1.6 * S
              ctx.strokeStyle = rgba(Math.min(1, alpha * 1.05))
              ctx.stroke()

              // --- face ------------------------------------------------------
              // Two eyes carry the whole emotional range; that is the entire
              // reason this is a wisp and not an animal.
              var ex = 12 * S
              var ey = cy - 4 * S
              // Eyes must stay legible whatever the body colour is.
              var lum = 0.299 * col[0] + 0.587 * col[1] + 0.114 * col[2]
              var ink = lum > 0.55
                      ? "rgba(28,36,58," + Math.min(1, alpha * 1.15).toFixed(3) + ")"
                      : "rgba(14,18,32," + Math.min(1, alpha * 1.30).toFixed(3) + ")"
              ctx.fillStyle = ink
              ctx.strokeStyle = ink
              ctx.lineCap = "round"

              function eyeDot(px, py, rx, ry) {
                ctx.beginPath()
                ctx.ellipse(px - rx, py - ry, rx * 2, ry * 2)
                ctx.fill()
              }

              if (st === "idle") {
                // dozing: closed, gently curved
                ctx.lineWidth = 2.0 * S
                for (var s = -1; s <= 1; s += 2) {
                  ctx.beginPath()
                  ctx.moveTo(cx + s * ex - 4 * S, ey)
                  ctx.quadraticCurveTo(cx + s * ex, ey + 3 * S, cx + s * ex + 4 * S, ey)
                  ctx.stroke()
                }
              } else if (st === "done") {
                // happy: ^ ^
                ctx.lineWidth = 2.2 * S
                for (var s2 = -1; s2 <= 1; s2 += 2) {
                  ctx.beginPath()
                  ctx.moveTo(cx + s2 * ex - 4.5 * S, ey + 2 * S)
                  ctx.quadraticCurveTo(cx + s2 * ex, ey - 4 * S, cx + s2 * ex + 4.5 * S, ey + 2 * S)
                  ctx.stroke()
                }
                eyeDot(cx, ey + 11 * S, 3.4 * S, 3.0 * S)     // open smile
              } else if (st === "attention") {
                eyeDot(cx - ex, ey, 5.0 * S, 5.6 * S)
                eyeDot(cx + ex, ey, 5.0 * S, 5.6 * S)
                eyeDot(cx, ey + 12 * S, 3.0 * S, 3.6 * S)     // small o of concern
              } else if (st === "trouble") {
                ctx.lineWidth = 2.2 * S
                for (var s3 = -1; s3 <= 1; s3 += 2) {
                  var bx = cx + s3 * ex
                  ctx.beginPath(); ctx.moveTo(bx - 4 * S, ey - 4 * S); ctx.lineTo(bx + 4 * S, ey + 4 * S); ctx.stroke()
                  ctx.beginPath(); ctx.moveTo(bx + 4 * S, ey - 4 * S); ctx.lineTo(bx - 4 * S, ey + 4 * S); ctx.stroke()
                }
              } else {
                // working: eyes track slightly, like it is reading something
                var look = Math.sin(g.phase * 0.55) * 1.8 * S
                eyeDot(cx - ex + look, ey, 3.6 * S, 4.4 * S)
                eyeDot(cx + ex + look, ey, 3.6 * S, 4.4 * S)
              }
            }
          }
        }
      }
    }
  }
}
