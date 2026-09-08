# Design: NCO composite-check validation runs

## Context

NCO applies ACLs, writes `acl_enforced` (and later switch/port) through
`PATCH /api/devices/:uid/metadata`, then needs a fresh isolation verdict
from an authored composite check. It has IP + partition (`default` today).
MAC is optional and often wrong. It must not learn `sr:` out of band.

Composite checks derive only (`add-composite-service-checks` D1). Sweep
groups on farm01 (`farm01-sweep-open` on `agent-alma-test01`,
`farm01-sweep-isolated` on `k8s-agent`) re-probe `in:devices` hourly.
Ad-hoc scans probe a subset but do not write `device_agent_availability`.

This design adds an orchestrator in front of those existing pieces.

## Decisions

### D1 — One resource, two timescales

`POST /api/v1/validation-runs` is **synchronous for identity** and
**asynchronous for probes + evaluation**.

- Identity (IP + partition → `sr:` UID) is a CNPG lookup. It happens
  inside the request. The 202 body includes every resolved `uid` plus
  the run id. NCO does not poll to learn the UID.
- Probes and composite evaluation take as long as the slower vantage
  agent (typically seconds; worst case the run deadline). NCO polls
  `GET /api/v1/validation-runs/:id`.

A single-shot "POST and block until verdict" is rejected: an agent
command-bus stall would hold an HTTP worker, and NCO already has a
change-window poll loop.

### D2 — IP is authoritative; partition scopes; MAC corroborates

Resolution order for each target:

1. Normalize IP. Reject malformed. Default `partition` to `"default"`.
2. Look up `platform.device_identifiers` where
   `identifier_type = ip`, `identifier_value = <ip>`,
   `partition = <partition>`. If exactly one live `device_id`, use it.
3. Else look up `platform.ocsf_devices` where `ip = <ip>` and
   `deleted_at IS NULL`. If exactly one row, use it. (Today
   `ocsf_devices_unique_active_ip_idx` makes this unique globally;
   the identifier path is what keeps working if that index ever
   becomes `(ip, partition)`.)
4. Zero hits → 404, no run created.
5. More than one hit → 409 with the candidate UIDs, no run created.

If `mac` is present:

- Normalize (uppercase, no separators).
- Look up `device_identifiers` `(mac, partition)` and/or
  `ocsf_devices.mac`.
- Missing MAC in inventory → ignore (IP still wins).
- MAC resolves to a **different** UID than the IP → 409 `mac_ip_conflict`.
- MAC resolves to the same UID → accept.

The API never mints a UID and never writes identifiers. Unknown hosts
are NCO's problem to inventory first.

Batch POST: if **any** target fails identity, the whole request fails
and no run is created. NCO retries after fixing the bad row.

### D3 — Probe settings come from the sweep group that already covers the device

NCO does not pass a profile. The run does not invent ICMP. For each
resolved device and each `vantage_point.agent_id` on the named check,
the orchestrator asks the same question the scheduled sweeper already
answers: *which sweep group would scan this device from this agent,
and what compiled settings does that group use?*

Two existing objects, not one:

- **Sweep group** (`SweepGroup`) owns targeting: `target_query` (SRQL),
  `static_targets`, `agent_id`, `partition`, and optional overrides
  (`ports`, `sweep_modes`, `overrides`).
- **Sweep profile** (`SweepProfile`, e.g. farm's `farm-scan`) owns the
  scanner: `sweep_modes`, `ports`, `timeout`, `concurrency`,
  `icmp_settings`, `tcp_settings`. The group points at it via
  `profile_id`.

Lookup, per `(device, vantage agent)`:

1. Candidate groups = `SweepGroup.for_agent_partition(agent_id, partition)`
   — the same read the sweep compiler uses (explicitly assigned to the
   agent **or** unassigned in that partition).
2. A candidate **covers** the device when either:
   - the IP is inside `static_targets` (exact or CIDR), or
   - `target_query` is set and the device is in that result set.
     Evaluate this as the group's SRQL **plus** `uid:<resolved_uid>`
     (one cheap page, not a rescan of `in:devices`).
3. Zero covering groups → that vantage is **uncovered** for this
   device. Record `uncovered` on the run row and do **not** dispatch a
   probe. Do not invent ICMP. The later verdict will be `inconclusive`
   the same way a scheduled sweep that never includes the host would.
4. One or more covering groups → compile settings exactly as
   `SweepCompiler.compile_group/3` already does: profile as base,
   group overrides on top, TCP-without-ports dropped, unsupported
   modes (historically `arp` on the agent sweeper) dropped. Multiple
   covering groups for the same agent: union `modes` and `ports`, most
   restrictive timeout — the same merge the agent applies when it runs
   more than one group.

Then dispatch **one** targeted ad-hoc scan to that agent whose
`targets` are this run's IPs that that agent covers, and whose
`modes` / `ports` / timeout are the compiled settings above. The run
records `sweep_group_id` and `profile_id` on each device/vantage row
so the report can say "probed like `farm01-sweep-isolated` / `farm-scan`".

The run MUST NOT call `SweepGroup.run_now` and MUST NOT expand the
check's `scope_query` into extra targets.

When those probes persist, the orchestrator upserts
`device_agent_availability` for `{device_uid, agent_id}` from the
results and evaluates the named check for just those UIDs. Ad-hoc
scan ingest is unchanged for console scans; the availability write is
run-owned.

On farm01 this is unambiguous today: both vantage agents have one
group (`farm01-sweep-open` / `farm01-sweep-isolated`), both
`target_query` are `in:devices`, both use profile `farm-scan`
(`icmp,tcp,arp` + ports 22/80/443/8080). A host at `192.168.1.55`
matches both queries, so the run replays `farm-scan` from Alma and
from k8s against that one IP.

### D4 — Poll, no webhook

Statuses: `pending` → `probing` → `evaluating` → `completed` |
`failed` | `timed_out`.

`GET` returns the run plus per-device `{ip, partition, uid, verdict,
status, inputs, evaluated_at, error}`. That JSON is the NCO deployment
report. No inbound webhook, no callback URL on the POST.

Default deadline 180 seconds from insert. Devices still probing at
deadline are `timed_out` / `inconclusive` on the run. The composite
result row is left as it was (do not write a fake pass).

### D5 — Facts stay on the existing endpoint

`acl_enforced` and switch/port are written with
`PATCH /api/devices/:uid/metadata` **before** this POST, using the UID
from a previous run or from this run's 202 if NCO writes facts after
resolve. Typical NCO order:

1. POST validation-run with IP + partition (gets `uid` immediately).
2. PATCH facts for that `uid` (if not already written).
3. If facts were written after step 1, POST a second run — or, v1
   allows PATCH first only when NCO already cached the uid. Simpler
   prescribed order for the NCO agent:

   **Preferred:** if NCO has no uid yet, POST a run, read uid from 202,
   PATCH facts, then either wait for this run (fact may land before
   evaluate) or POST a second run after the PATCH.

   To keep v1 dumb: the orchestrator re-reads device metadata at
   evaluate time, not at POST time. NCO can PATCH as soon as it has
   the uid from 202 and before probes finish (seconds). One run is
   enough.

## API shape

```http
POST /api/v1/validation-runs
Authorization: Bearer <token>
Content-Type: application/json

{
  "check": "farm01-lab-isolation",
  "partition": "default",
  "devices": [
    {"ip": "192.168.1.55", "mac": "aabbccddeeff"}
  ]
}
```

Single-device shorthand (equivalent to a one-element `devices` array):

```json
{
  "check": "farm01-lab-isolation",
  "partition": "default",
  "ip": "192.168.1.55",
  "mac": "aa:bb:cc:dd:ee:ff"
}
```

`mac` is optional. Top-level `partition` is the default for every
device; a per-device `partition` overrides it.

```http
HTTP/1.1 202 Accepted

{
  "id": "2f6c0e3a-…",
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

```http
GET /api/v1/validation-runs/{id}
GET /api/v1/validation-runs/{id}/results
```

Errors: `400` malformed / empty / over cap / draft-or-disabled check;
`401`/`403`; `404` unknown IP or unknown check slug; `409` ambiguous IP
or `mac_ip_conflict`.

## Alternatives considered

- **Expose `SweepGroup.run_now`.** Wrong granularity; re-probes the farm.
- **Tell NCO to call `POST /api/v1/scans` twice and SRQL the check.**
  Leaves the availability gap; NCO must know both agent ids and the
  30s refresh debounce. Acceptable as a private stepping-stone during
  implementation, not the contract.
- **Webhook to NCO.** NCO already polls a change window. Adds listener,
  auth, and retry on their side before we have a job object worth
  notifying about.
- **POST blocks until verdict.** Ties up the request; fails closed on
  any agent delay.

## Risks

- IP is a weak DIRE identifier. Overlapping live IPs across partitions
  are not fully represented on `ocsf_devices` today (global unique
  active-IP index). Callers MUST send partition now so the same client
  keeps working if that index is later partitioned.
- A stale `acl_enforced` PATCH that lands after evaluate produces a
  wrong report. Mitigated by evaluate-time metadata read plus NCO
  PATCHing immediately after 202 (seconds before probes return).
- A device that matches no sweep-group SRQL for a vantage agent is
  uncovered. That is a real coverage gap, not a prompt to invent ICMP.
  The run records it; the verdict stays `inconclusive`.
- Two covering groups with different ports/modes are merged the same
  way the agent already merges groups (union). Record every
  contributing `sweep_group_id` on the run row.
