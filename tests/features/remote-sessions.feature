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
