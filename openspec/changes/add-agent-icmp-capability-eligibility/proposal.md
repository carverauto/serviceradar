# Change: Assign ICMP and MTR sweep work only to agents that can open the sockets

## Why
An agent without raw-socket permission (a Kubernetes agent without
`CAP_NET_RAW` is the common case) is normal, not a misconfiguration. Today core
still compiles ICMP sweep modes into its config, so the agent receives ICMP
targets it can never probe and logs `ICMP targets found but ICMP scanner is not
available, skipping ICMP scan` on every sweep (issue #5629).

## What Changes
- The agent probes its sockets once at startup and reports the result as an
  explicit capability pair: `icmp` or `icmp.unavailable`, and `mtr` or
  `mtr.unavailable`. The ICMP probe opens the same sockets as the sweeper's
  ICMP scanner, so `icmp` now means "the ICMP sweep scanner works". Before
  this change it came from the MTR socket probe, which on Linux falls back to
  unprivileged datagram ICMP that the sweep scanner cannot use.
- The agent logs the probe result once at startup, with the reason. Its
  per-sweep "scanner is not available" warning is logged once per state change.
- The sweep compiler removes the `icmp` mode from every group compiled for an
  agent that reports `icmp.unavailable`, and the `mtr` mode for an agent that
  reports `mtr.unavailable`. A group left with no modes is not sent to that
  agent, and core logs a warning naming the group, the agent and the missing
  capability.
- An agent that reports neither marker predates the capability and keeps
  receiving every mode, so upgrading core never stops ICMP across a fleet of
  older agents.
- The agent detail page explains each unavailable marker. SRQL already filters
  on it (`in:agents capabilities:icmp.unavailable`).

## Impact
- Affected specs: `sweep-jobs`, `agent-registry`
- Affected code: `go/pkg/scan` (ICMP socket probe), `go/pkg/agent`
  (capability advertisement, startup log), `go/pkg/sweeper` (skip-log
  deduplication), `ServiceRadar.AgentConfig.Compilers.SweepCompiler`,
  `ServiceRadar.Infrastructure.Agent.capability_info/1`, web-ng agent detail
  capabilities card.
