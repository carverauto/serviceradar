## 1. Agent
- [x] 1.1 Add `scan.ProbeICMPSockets`, sharing socket setup with `NewICMPSweeper`
- [x] 1.2 Probe ICMP and MTR sockets once per process; advertise `icmp`/`icmp.unavailable` and `mtr`/`mtr.unavailable`
- [x] 1.3 Log the probe result with its reason once at startup
- [x] 1.4 Log the sweeper's "scanner is not available" warning once per state change
- [x] 1.5 Go unit tests for the capability pair and the log deduplication

## 2. Core
- [x] 2.1 Filter `icmp`/`mtr` sweep modes by the compiling agent's unavailable markers; omit groups left with no modes and warn
- [x] 2.2 Treat an agent reporting neither marker as eligible
- [x] 2.3 Explain `icmp.unavailable` and `mtr.unavailable` in `Agent.capability_info/1` and on the agent detail page
- [x] 2.4 Elixir unit tests for eligibility filtering, including the agent predating the marker

## 3. Follow-ups (not in this change)
- [ ] 3.1 Run-now and ad-hoc scans consult the marker before dispatching ICMP work
