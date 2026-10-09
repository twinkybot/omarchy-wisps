Feature: Wisps for agents running on other machines
  An agent started over ssh fires its hooks on the far side, so its state
  files and its pid live there. wisps-remote.sh keeps one ssh connection
  open and mirrors that machine's poller output into remote/<host>.list;
  the local poller merges the file in while it is fresh.

  Scenario: A fresh remote list adds its sessions under the host name
    Given the remote list for "atlas.example.org" holds a "working" session "0b6bc27e-1111-4c5f-8888-000000000001" in "/home/me/ai"
    When the poller runs
    Then the poller lists session "0b6bc27e-1111-4c5f-8888-000000000001"
    And the poller shows session "0b6bc27e-1111-4c5f-8888-000000000001" in "atlas:/home/me/ai"

  Scenario: A remote list nobody has refreshed is ignored
    Given the remote list for "atlas.example.org" holds a "working" session "0b6bc27e-1111-4c5f-8888-000000000001" in "/home/me/ai"
    And the remote list is 10 seconds old
    When the poller runs
    Then the poller lists nothing

  Scenario: A remote line with a mangled session id is dropped
    Given the remote list for "atlas.example.org" holds a "working" session "../../etc/passwd" in "/home/me/ai"
    When the poller runs
    Then the poller lists nothing

  Scenario: The remote helper mirrors what ssh streams
    Given ssh is faked to stream a "working" session "0b6bc27e-1111-4c5f-8888-000000000001" in "/home/me/ai"
    When the remote helper runs for "atlas.example.org"
    Then the remote list for "atlas.example.org" holds a "working" session "0b6bc27e-1111-4c5f-8888-000000000001" in "/home/me/ai"

  Scenario: The remote helper removes its list when the connection drops
    Given ssh is faked to stream a "working" session "0b6bc27e-1111-4c5f-8888-000000000001" in "/home/me/ai"
    And the fake ssh exits after streaming
    When the remote helper runs for "atlas.example.org"
    Then there is no remote list for "atlas.example.org"

  # The far side prints the agent in a fifth column, the same one the local
  # poller prints. It has to survive the merge: read as part of cwd, the tab
  # in front of it is stripped as a control character and the two columns end
  # up glued together, leaving the wisp with no agent and a mangled path.

  Scenario: A remote session keeps the agent its machine named
    Given the remote list for "atlas.example.org" holds a "working" session "0b6bc27e-1111-4c5f-8888-000000000001" in "/home/me/ai" running "opencode"
    When the poller runs
    Then the poller shows session "0b6bc27e-1111-4c5f-8888-000000000001" in "atlas:/home/me/ai"
    And the poller reports session "0b6bc27e-1111-4c5f-8888-000000000001" as agent "opencode"

  Scenario: A remote machine still running an older poller names no agent
    Given the remote list for "atlas.example.org" holds a "working" session "0b6bc27e-1111-4c5f-8888-000000000001" in "/home/me/ai"
    When the poller runs
    Then the poller shows session "0b6bc27e-1111-4c5f-8888-000000000001" in "atlas:/home/me/ai"
    And the poller reports session "0b6bc27e-1111-4c5f-8888-000000000001" as agent "claude"
