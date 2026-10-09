Feature: One wisp per coding-agent session
  The hook scripts turn agent events into state files, one per session, and
  the poller lists only sessions whose owning process is still alive. Both
  Claude Code and GitHub Copilot CLI drive them; they differ in the field
  names they send and in how their processes identify themselves.

  Scenario: A Claude Code session is keyed by session_id
    Given a Claude Code payload for session "0b6bc27e-1111-4c5f-8888-000000000001" in "/home/me/proj"
    When the "working" hook runs
    Then the wisp for session "0b6bc27e-1111-4c5f-8888-000000000001" is "working" in "/home/me/proj"

  Scenario: A Copilot CLI session is keyed by sessionId
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    When the "working" hook runs
    Then the wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" is "working" in "/home/me/proj"

  Scenario: Two Copilot sessions do not share one wisp
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/one"
    And the "working" hook runs
    And a Copilot CLI payload for session "c0ffee00-0000-4000-8000-000000000002" in "/home/me/two"
    When the "working" hook runs
    Then there are 2 wisps

  Scenario: An interactive session start dozes until the first prompt
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    When the "idle" hook runs
    Then the wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" is "idle" in "/home/me/proj"

  Scenario: A one-shot copilot -p run starts already working
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    And the "working" hook runs
    And the payload carries an initialPrompt
    When the "idle" hook runs
    Then the wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" is "working" in "/home/me/proj"

  Scenario: Session end removes the wisp
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    And the "working" hook runs
    When the "gone" hook runs
    Then there are 0 wisps

  Scenario: The poller keeps a wisp whose owner is a live claude binary
    Given a wisp for session "0b6bc27e-1111-4c5f-8888-000000000001" owned by a running "claude" binary
    When the poller runs
    Then the poller lists session "0b6bc27e-1111-4c5f-8888-000000000001"

  Scenario: The poller keeps a wisp owned by Claude's native install, whose binary is named after its version
    Given a wisp for session "0b6bc27e-1111-4c5f-8888-000000000001" whose owner is a "claude" link to a running "2.1.263" binary
    When the poller runs
    Then the poller lists session "0b6bc27e-1111-4c5f-8888-000000000001"

  Scenario: The poller keeps a wisp whose owner is a live copilot binary
    Given a wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" owned by a running "copilot" binary
    When the poller runs
    Then the poller lists session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d"

  Scenario: The poller drops a wisp whose owner is some other program
    Given a wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" owned by a running "sleep" binary
    When the poller runs
    Then the poller lists nothing
    And there are 0 wisps

  Scenario: The poller drops a wisp whose owner has exited
    Given a wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" owned by an exited "copilot" binary
    When the poller runs
    Then the poller lists nothing

  # Copilot runs its permissionRequest hook on every tool call, granted or
  # not -- 29 times in one measured session, almost all resolved within
  # milliseconds by an allow-all setting. Only a request nobody answers is
  # worth flying the wisp over, so "pending" ages into "attention".

  Scenario: A permission granted at once never counts as needing you
    Given a wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" owned by a running "copilot" binary
    And a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    And the "pending" hook runs inside that binary
    When the poller runs
    Then the poller shows session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" as "working"

  Scenario: A permission left unanswered flies to your cursor
    Given a wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" owned by a running "copilot" binary
    And a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    And the "pending" hook runs inside that binary
    And 3 seconds pass
    When the poller runs
    Then the poller shows session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" as "attention"

  Scenario: A tool finishing clears a pending permission
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    And the "working" hook runs
    And the "pending" hook runs
    When the "busy" hook runs
    Then the wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" is "working" in "/home/me/proj"

  Scenario: The agent asking you a question needs you right away
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    And the "working" hook runs
    And the payload carries a tool call to "ask_user"
    When the "busy" hook runs
    Then the wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" is "attention" in "/home/me/proj"

  Scenario: A subagent finishing does not spawn a wisp of its own
    Given a Copilot CLI payload for session "4aaf7e4c-5973-45c5-8103-803df6958ce9" in "/home/me/proj"
    When the "done" hook runs
    Then there are 0 wisps

  Scenario: A permission request wired to attention is still only pending
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    And the "working" hook runs
    And the payload is a permissionRequest for "bash"
    When the "attention" hook runs
    Then the wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" is "pending" in "/home/me/proj"

  Scenario: A subagent going idle is news, not a question for you
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    And the "working" hook runs
    And the payload is a notification of type "agent_idle"
    When the "attention" hook runs
    Then the wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" is "working" in "/home/me/proj"

  Scenario: The agent opening a question dialog needs you
    Given a Copilot CLI payload for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" in "/home/me/proj"
    And the "working" hook runs
    And the payload is a notification of type "elicitation_dialog"
    When the "attention" hook runs
    Then the wisp for session "b931152f-5afd-4d06-8f3c-0a3d8fb29b1d" is "attention" in "/home/me/proj"
