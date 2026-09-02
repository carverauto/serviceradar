# Change: NCO composite-check validation runs

## Why

OpenText Network Automation (NCO) applies network access-control changes and
then needs ServiceRadar to say whether those changes actually isolated the
target. The composite check `farm01-lab-isolation` already answers that
question — Alma should still reach the host, the k8s agent should not, and
`acl_enforced` should be true — but NCO cannot drive that answer today.

NCO does not know ServiceRadar's `sr:` UID. It knows an IP (and sometimes a
MAC). Partition is always available and, on farm01-style deployments,
is `"default"`. The existing lookup surface is SRQL or `GET /api/devices`,
neither of which is a contract NCO should guess at, and neither of which
kicks a **fresh** probe from both vantage-point agents.

Kicking the authored sweep groups (`farm01-sweep-open` / `farm01-sweep-isolated`)
is the wrong lever: they target `in:devices` on a one-hour interval. NCO's
change set is a handful of IPs. The ad-hoc scan API (`POST /api/v1/scans`)
can probe a subset, but its results land in `adhoc_scan_results` and never
update `device_agent_availability`, so the composite check does not see them.

NCO needs one call that (1) resolves IP + partition to a UID immediately,
(2) starts a targeted re-probe of those IPs from every vantage-point agent
on a named composite check, and (3) exposes a poll URL for the resulting
verdict. No webhook. Facts (`acl_enforced`, switch/port) stay on the existing
`PATCH /api/devices/:uid/metadata` path and are written **before** this call.

## What Changes

### Identity: IP is authoritative, partition scopes it, MAC is optional

- **ADD** a public resolve used only by this API: given `ip` (required) and
  `partition` (optional, default `"default"`), return the canonical
  `sr:` UID or fail the request. No device is created.
- MAC, if supplied, is corroboration only. It MUST NOT override IP. A MAC
  that resolves to a **different** device than the IP is a 409 so NCO
  notices a bad MAC instead of silently following it. A MAC that is absent
  from inventory is ignored.
- Resolution is synchronous and is the only part of the POST that is
  required to be fast. The UID is in the 202 body so NCO never has to
  learn `sr:` on its own.

### Validation run: orchestrator, not a new probe engine

- **ADD** `ServiceRadar.CompositeChecks.ValidationRun` (and per-device
  child rows) in `platform`. One run names a composite check slug and a
  list of `{ip, partition?, mac?}` targets.
- **ADD** `POST /api/v1/validation-runs` (202), `GET /api/v1/validation-runs/:id`,
  `GET /api/v1/validation-runs/:id/results`. Same `api_key_auth` pipeline as
  ad-hoc scans. Poll; do not webhook.
- The run reads the check's `vantage_point` agent ids. For each
  `(device, agent)` it finds the enabled sweep **group** in that agent's
  partition whose `target_query` / `static_targets` already cover the
  device (the same `for_agent_partition` set the sweep compiler uses),
  then uses that group's compiled scan settings — sweep **profile**
  (`farm-scan`: modes, ports, timeout) plus any group overrides. It
  MUST NOT invent ICMP, MUST NOT call `SweepGroup.run_now`, and MUST
  NOT expand to the check's full `scope_query`. A device that matches
  no group for a vantage is `uncovered` for that vantage, not probed
  with a made-up profile.
- When those probes persist, the run upserts `device_agent_availability`
  (the table composite checks actually read), evaluates the named check for
  just those UIDs, upserts `device_composite_check_results`, and stores the
  same verdict snapshot on the run so the GET payload is the deployment
  report.

Composite checks still do not probe. This run is a separate orchestrator
that feeds the signals they already consume, then asks them to evaluate a
subset. That preserves `add-composite-service-checks` D1.

### Auth and bounds

- **ADD** RBAC `validation_runs.execute` (operator, admin) and
  `validation_runs.read` (viewer+). Execute does not imply
  `devices.update` or `devices.facts.write`.
- Cap targets per run (128). Reject unknown check slugs, disabled/draft
  checks, malformed IPs, and ambiguous identity before any probe is
  dispatched.
- Deadline the run (default 180s). Timed-out devices stay `inconclusive`
  on the run; they do not invent a pass.

## Capabilities

### New Capabilities
- `nco-validation-runs`: identity-by-IP+partition, targeted vantage-point
  re-probe, pollable composite-check verdict for a caller-supplied subset.

### Modified Capabilities
- `device-inventory`: public, partition-scoped IP resolution used by the
  validation-run API (no new UID minting).

## Impact

- `elixir/serviceradar_core`: ValidationRun resources + migration, identity
  resolve helper, orchestrator worker, availability upsert from targeted
  probes, subset composite evaluation.
- `elixir/web-ng`: `ValidationRunController` under `/api/v1`, RBAC catalog
  keys, controller tests.
- Reuses `AgentCommandBus.dispatch_adhoc_scan/3` and
  `CompositeChecks.Evaluation.evaluate_devices/5`. Does not change sweep
  group scheduling or the composite check authoring UI.
- Docs: `docs/docs/nco-validation-runs.md` (ASCII), plus a pointer from
  `docs/docs/nco-device-facts.md`.
- NCO client: PATCH facts → POST validation-run (gets uid + run id) →
  poll GET until `completed`/`failed`/`timed_out`.
