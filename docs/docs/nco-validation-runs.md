---
sidebar_position: 91
title: Composite Check Validation Runs (NCO)
---

# Composite Check Validation Runs

After OpenText Network Automation (NCO) applies access-control changes, it
asks ServiceRadar to re-probe the affected hosts from the composite check's
vantage-point agents and return a verdict. NCO does not need to know the
canonical `sr:` device UID in advance: it sends IP plus partition (and
optionally MAC). Identity is resolved in the create request; probes and
evaluation are polled.

Facts such as `acl_enforced` are written separately with the [Device Facts
API](./nco-device-facts.md). Write facts as soon as the create response
returns a UID; evaluation reads metadata at evaluate time, not at create
time.

## Create

```
POST /api/v1/validation-runs
Authorization: Bearer $SERVICERADAR_API_TOKEN
Content-Type: application/json
```

Single-device shorthand:

```json
{
  "check": "farm01-lab-isolation",
  "partition": "default",
  "ip": "192.168.1.55",
  "mac": "aa:bb:cc:dd:ee:ff"
}
```

`mac` is optional. `partition` defaults to `default`. A list is also
accepted:

```json
{
  "check": "farm01-lab-isolation",
  "partition": "default",
  "devices": [
    {"ip": "192.168.1.55"},
    {"ip": "192.168.1.103"}
  ]
}
```

Response `202 Accepted`:

```json
{
  "id": "2f6c0e3a-....",
  "status": "pending",
  "check": "farm01-lab-isolation",
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

NCO does not pass a sweep profile. For each resolved device and each
`vantage_point` agent on the named check, ServiceRadar finds the enabled
sweep **group** in that agent's partition whose `target_query` or
`static_targets` already cover the device, then uses that group's compiled
scan settings (sweep **profile** modes/ports/timeout plus group overrides).

On farm01, `farm01-lab-isolation` vantage agents `agent-alma-test01` and
`k8s-agent` each have a group (`farm01-sweep-open` /
`farm01-sweep-isolated`) with `in:devices` and profile `farm-scan`. A host
in inventory is therefore re-probed with `farm-scan` (icmp+tcp, ports
22/80/443/8080) against that one IP only. The farm-wide sweep is not
started.

A device that matches no covering group for a vantage is `uncovered` for
that vantage. ServiceRadar does not invent ICMP.

## Poll

```
GET /api/v1/validation-runs/{id}
GET /api/v1/validation-runs/{id}/results
```

Statuses: `pending`, `probing`, `evaluating`, `completed`, `failed`,
`timed_out`. Poll every few seconds. Default deadline is 180 seconds.

Treat a report as fresh when `evaluated_at` is after the create time and
each vantage `inputs.<key>.observed_at` is also after create time.

## Identity rules

- IP is authoritative. Partition scopes the lookup (default `default`).
- Unknown IP: `404 device_not_found`. No device is created.
- Two live matches: `409 ambiguous`.
- MAC missing in inventory: ignored.
- MAC maps to a different device than the IP: `409 mac_ip_conflict`.

Permission: `validation_runs.execute` to create, `validation_runs.read`
to poll (operator/admin execute; viewer+ read).

## Verdicts for isolation

| Verdict | Status | Meaning for the change |
| --- | --- | --- |
| `isolated_verified` | healthy | Isolated and `acl_enforced` is true. Pass. |
| `isolated_unenforced` | degraded | Isolated, fact is false. |
| `not_isolated` | down | Both vantage agents still reach it. |
| `device_unreachable` | degraded | Liveness witness cannot see it. |
| `inverted_reachability` | down | Isolation probe sees it, witness does not. |
| `inconclusive` | unknown | Missing/stale probe, uncovered vantage, or missing fact. Do not pass. |

## Rolling this into production (UAL)

There is **no new Helm value** for this feature. The farm01 GitOps
`values.yaml` change used to test it was only:

```yaml
global:
  imageTag: "sha-<commit>"
```

That is the usual immutable image pointer. Copying farm01's unpublished
`sha-...` tag onto Example is wrong. Example should take a **published release**
that includes this change (`serviceradar-core-elx` and
`serviceradar-web-ng` at minimum; rolling `global.imageTag` as you already
do is enough).

Nothing else in Helm, Gateway API, or env vars is required. Core runs the
`platform.validation_runs` / `platform.validation_run_devices` migration
on startup. The role-profile seeder adds two catalog keys to **system**
profiles:

| Permission | Default roles | Use |
| --- | --- | --- |
| `validation_runs.execute` | operator, admin | POST a run |
| `validation_runs.read` | viewer+ | GET status / results |

If Example operators use a **custom** role profile (not the built-in
`admin` / `operator` / `viewer` system profiles), add those two keys on
the profile in Settings before NCO can call the API. Built-in system
profiles pick the keys up on core restart.

NCO also needs, in the deployment, not in values.yaml:

1. Devices already in inventory (IP + partition; no minting on miss).
2. An **enabled** composite check whose vantage-point `agent_id`s match
   the isolation witnesses (farm used `farm01-lab-isolation`: Alma
   expected available, k8s expected blocked, plus `acl_enforced`).
3. Enabled sweep **groups** on those agents whose `target_query` /
   `static_targets` already cover the host, pointing at a sweep
   **profile** (farm: `farm-scan`, icmp+tcp, ports 22/80/443/8080).
4. An API token (or user) with `validation_runs.execute` and
   `devices.facts.write`.

NCO sequence on Example is the same as farm:

1. `POST /api/v1/validation-runs` with IP + partition (optional MAC) to
   learn `uid` and `id`.
2. `PATCH /api/devices/{uid}/metadata` with
   `{"facts":{"acl_enforced":true}}` (and switch/port if you have them).
3. Poll `GET /api/v1/validation-runs/{id}` until `completed` /
   `failed` / `timed_out`. Pass only on `isolated_verified` with
   `evaluated_at` after the POST.
