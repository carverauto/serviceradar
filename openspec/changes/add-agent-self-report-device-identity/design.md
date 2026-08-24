# Design: first-party agent self-report identity

## The rule this must not break

`SourcePolicy.observer_agent_source?/1` demotes `agent_id` for mapper, sweep,
network_discovery, census, mDNS, armis and snmp. The reason is not stylistic: the agent
stamps the COLLECTOR's `agent_id` on every observation it forwards, `agent_id` is first in
`Ids.identifier_priority/0`, and a source that is not demoted therefore makes every host it
describes strong-match the collector's own device. That collapse has been reproduced against
a real database (`sync_ingestor_passive_netprobe_identity_test.exs`) for `passive-netprobe`.

This change adds a source that is deliberately NOT demoted. That is the whole point, and it is
also the whole risk. The boundary is therefore not "which sources are observers" but **what a
self-report is allowed to describe**.

## The boundary

An `agent-self-report` update describes exactly one host: the one the reporting agent runs on.

Enforced at the producer, not by convention downstream:

- The update carries exactly one subject, and the subject's address is the agent's own
  re-detected `SourceIp` -- the same value Hello, PushStatus, SNMP, plugin signals and workload
  identity already use. It is never taken from a payload field an observation supplied.
- Observations the agent forwards ABOUT other hosts keep their existing sources
  (`mapper`, `sweep`, `passive-netprobe`, `netprobe-census`, ...) and stay demoted. Nothing
  about their handling changes.
- One agent produces at most one self-report subject per cycle. A self-report carrying more than
  one subject is a bug, not a batch, and is rejected rather than partially applied.

## Why `agent_id` and not MAC

MAC would be the intuitive anchor and is not available. On farm01 **neither** the old nor the
new `alma-test01` device has a MAC at all -- both were minted by `mapper_topology_sighting`,
which reports an IP and a hostname. Anchoring on a MAC the agent does not report is a
requirement the data cannot satisfy today.

`agent_id` is the right anchor independently: it is issued at onboarding, survives address
changes, survives hostname changes, and is already classified `strong` in
`device_identifiers`. If an agent later reports its own MAC, that is additive evidence and
follows the existing locally-administered-MAC rules -- a randomized or LAA MAC must not anchor,
exactly as `census_anchorable_mac?/1` already requires.

## `agent_id` rotation

Re-onboarding a host issues a new `agent_id`. That is a NEW anchor, and the self-report cannot
know it is the same hardware. Two devices will exist.

This change does not try to solve that, and deliberately says so: the correct outcome is that
the duplicate sweep merges them once they share some other strong identifier, which is what it
is for. What the change DOES guarantee is that the far more common case -- the same agent, a
new address -- never produces a duplicate in the first place.

## Ordering against observer sources

Both a mapper sighting and a self-report can describe the same host, and mapper may get there
first (it did on farm01: device A predates the `agent_id` identifier by two days). The
self-report must therefore resolve to an EXISTING device by IP before creating one, register
`agent_id` on whatever device it resolved to, and only create when nothing resolves. Creating
unconditionally would mint a second device on every agent whose host a mapper had already seen
-- inverting the bug rather than fixing it.

The reverse order also has to hold: once `agent_id` is registered, a later mapper sighting of a
NEW address for that host must not create a second device. Mapper cannot match on `agent_id`
(it is demoted for mapper, correctly), so the self-report's own update is what moves the `ip`,
and it must win over a stale mapper-written address rather than flapping against it.

## What is explicitly out of scope

- Changing `observer_agent_source?/1` membership. No existing source moves.
- Shortening the duplicate sweep interval. It ran ~2,300 times during the incident and was
  right every time; the missing input was an identifier, not a faster loop.
- Backfilling identity onto historical duplicates. The sweep already handles those once they
  share an identifier.
