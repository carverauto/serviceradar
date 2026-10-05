---
sidebar_position: 91
title: Composite Check Validation Runs
---

# Composite Check Validation Runs

After a change on the network, such as an ACL or firewall rule, a caller
can ask ServiceRadar to re-probe the affected hosts from a composite
check's vantage-point agents and return that check's verdict.

Callers do not need the canonical `sr:` device UID. Send IP plus partition
(and optionally MAC). Identity is resolved in the create request; probes
and evaluation are polled.

To obtain a UID without starting a run — no probe, no check to name — use
[Resolve a Device Identity](./identity-resolve.md) instead.

This API is a general HTTP contract. Any client that can POST JSON and
poll can use it.

Supply optional scalar `facts` on each target (or at top level for the
single-device shorthand). ServiceRadar resolves identity, applies the facts
through the [Device Facts API](./device-facts.md) write action, and commits
the facts and run before queuing probes. Invalid facts reject the entire
request. Supplying facts also requires `devices.facts.write`.

If you already know the UID, you may instead finish a Device Facts API write
before creating the run. If you do not know it, use inline facts or the
[identity resolve API](./identity-resolve.md), write facts, then create the
run. A separate write after the create response races evaluation and cannot
attest that run; create a new run after the write completes.

## Create

```
POST /api/v1/validation-runs
Authorization: Bearer $SERVICERADAR_API_TOKEN
Content-Type: application/json
```

Single-device shorthand:

```json
{
  "check": "isolation",
  "partition": "default",
  "ip": "192.168.1.55",
  "mac": "aa:bb:cc:dd:ee:ff",
  "facts": {"acl_enforced": true}
}
```

`mac` is optional. `partition` defaults to `default`. A list is also
accepted:

```json
{
  "check": "isolation",
  "partition": "default",
  "devices": [
    {"ip": "192.168.1.55"},
    {"ip": "192.168.1.103"}
  ]
}
```

`check` is the slug of an enabled composite check in this tenant. The
examples use `isolation`; substitute the check you actually run.

Response `202 Accepted`:

```json
{
  "id": "2f6c0e3a-....",
  "status": "pending",
  "check": "isolation",
  "devices": [
    {
      "ip": "192.168.1.55",
      "partition": "default",
      "uid": "sr:8cad4cc3-e9f8-4873-a1fe-cf2529b246a0"
    }
  ]
}
```

Identity is finished at this point. The UID will not change on later
polls.

## How probes are chosen

The create request does not take a sweep profile. For each resolved
device and each `vantage_point` agent on the named check, ServiceRadar
finds the enabled sweep **group** in that agent's partition whose
`target_query` or `static_targets` already cover the device, then uses
that group's compiled scan settings (sweep **profile** modes, ports, and
timeout, plus group overrides).

Only that host is re-probed. The agent's scheduled fleet-wide sweep is
not started.

A device that matches no covering group for a vantage is `uncovered` for
that vantage. ServiceRadar does not invent ICMP.

## Poll

```
GET /api/v1/validation-runs/{id}
GET /api/v1/validation-runs/{id}/results
```

Statuses: `pending`, `probing`, `evaluating`, `completed`, `failed`,
`timed_out`. Poll every few seconds. Default deadline is 180 seconds.

A validation verdict uses this run's probe evidence, not a background
availability sample. Each vantage input includes `covered`, `probed`, and
`reason`. An uncovered or skipped vantage, a failed scan, or a missing
per-target result produces `not_probed` with `unknown` status, even if
background availability is fresh. The run can finish `completed` while its
device verdict is `not_probed`; completion does not mean verification passed.
Such a run does not overwrite the official composite result. Require
`inputs.<key>.probed` for every vantage before treating a verdict as proof.

## Identity rules

- IP is authoritative. Partition scopes the lookup (default `default`).
- Unknown IP: `404 device_not_found`. No device is created.
- Two live matches: `409 ambiguous`.
- MAC missing in inventory: ignored.
- MAC maps to a different device than the IP: `409 mac_ip_conflict`.

Permission: `validation_runs.execute` to create, `validation_runs.read`
to poll (operator/admin execute; viewer+ read).

## Example: isolation verdicts

Verdicts come from the named check's decision table, not from this API.
An isolation check that expects one vantage to reach the host, another
not to, and `acl_enforced` to be true might produce:

| Verdict | Status | Meaning for the change |
| --- | --- | --- |
| `isolated_verified` | healthy | Isolated and `acl_enforced` is true. Pass. |
| `isolated_unenforced` | degraded | Isolated, fact is false. |
| `not_isolated` | down | Both vantage agents still reach it. |
| `device_unreachable` | degraded | Liveness witness cannot see it. |
| `inverted_reachability` | down | Isolation probe sees it, witness does not. |
| `not_probed` | unknown | Required run-specific probe evidence is missing. Do not pass. |
| `inconclusive` | unknown | Probes ran, but the decision table lacks sufficient facts or evidence. Do not pass. |

A different check returns that check's own verdict slugs. Treat those as
the check's contract.

## Prerequisites

There is no extra Helm value, Gateway API object, or env var for this
API. Core runs the `platform.validation_runs` /
`platform.validation_run_devices` migration on startup. The role-profile
seeder adds two catalog keys to **system** profiles:

| Permission | Default roles | Use |
| --- | --- | --- |
| `validation_runs.execute` | operator, admin | POST a run |
| `validation_runs.read` | viewer+ | GET status / results |

If operators use a **custom** role profile (not the built-in `admin` /
`operator` / `viewer` system profiles), add those two keys on the
profile in Settings. Built-in system profiles pick the keys up on core
restart.

The deployment also needs:

1. Devices already in inventory (IP + partition; no minting on miss).
2. An **enabled** composite check whose vantage-point `agent_id`s match
   the witnesses the check evaluates (for isolation, typically one agent
   expected to reach the host, one expected not to, plus any facts the
   check reads).
3. Enabled sweep **groups** on those agents whose `target_query` /
   `static_targets` already cover the host, pointing at a sweep
   **profile**.
4. An API token (or user) with `validation_runs.execute`. Include
   `devices.facts.write` if the caller also writes facts.

Typical sequence:

1. `POST /api/v1/validation-runs` with IP, partition, optional MAC, and
   optional inline `facts`. The facts commit before the run can dispatch.
2. Poll `GET /api/v1/validation-runs/{id}` until `completed`, `failed`, or
   `timed_out`.
3. Require `probed: true` on every vantage input and the verdict the check
   treats as success. Never treat `not_probed` as a pass.
