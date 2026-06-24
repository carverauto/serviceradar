# Design — canonical device-identity alignment for anomalies

## What the investigation established (so the design is grounded, not assumed)

- **Edge is correct.** The agent stamps the polled target (`target_device_ip` = switch
  IP, plus `host`/`target`/`interface_uid` tags) on every SNMP metric; the addon
  receives identical bytes, attributes to the target (not `agent_id`), and emits
  `source_identity.target_device_ip`. 100% of agent-dusk01's 2.43M SNMP metric rows
  carry `target_device_ip` + `device_id = sr:<target>`. **No agent/addon change.**
- **The metric `series_key` is the wrong join target.** It is `md5(typed fields +
  ingestion tags)`, hashed with `device_id` *empty* (column backfilled, hash not).
  Reproducing a real key from stored fields failed across 6 component sets. Folding in
  `payload_kind`/`producer_kind`/`source` means an anomaly can never reproduce it.
- **The real join is `device_id`.** `profile_hour_of_week_peak` groups by
  `device_id AS series`. Canonical `device_id` is the stable identity both sides hold.
- **The resolver already exists but is ineffective on demo.**
  `anomaly_detection_device_uid` (`causal_signals.ex`) resolves SNMP by
  `target_device_ip` via `DeviceCorrelation.resolve` to `sr:<target>` — yet recent
  demo anomalies have an **empty** `device.uid`. So either the deployed build predates
  it, or the resolved uid is not written where the finding's device identity is read.

## Decision: align on `(device_id, metric_name, if_index)`, not the hash

The canonical join key is the tuple **`(device_id = sr:<target>, metric_name,
if_index)`** — deterministic, stable, and producible by both sides:

- **Metric**: carries `device_id = sr:<target>` (column), `metric_name`, `if_index`.
- **Anomaly**: resolves `target_device_ip → sr:<target>` via the *existing*
  `DeviceCorrelation` path; carries `metric_name`/`if_index` from the verdict.

This sidesteps both fatal series_key problems (the empty-`device_id` hash and the
ingestion tags) and is **type-agnostic**: sysmon/process anomalies resolve their host
the same way, with no SNMP-special-casing of the *join* (only of which field feeds the
resolver — `target_device_ip` for a remote poll, the host id otherwise, which the
resolver already branches on).

### The actual work is three things

1. **Root-cause the empty `device.uid`** on the live path. Confirm whether
   `anomaly_detection_device_uid` runs and where its result is written, vs. a stale
   deploy. This is the load-bearing unknown; everything else is mechanical once the
   resolved `sr:` uid actually reaches the persisted finding identity.
2. **Key the joins on the canonical tuple.** Ensure the disposition feed and the
   `#4288` stale-alert liveness query correlate on `(device_id, metric_name,
   if_index)` — never on `series_key`. The disposition SQL already groups by
   `device_id`; verify the anomaly side persists the resolved `device_id` as a
   queryable field (not buried in metadata).
3. **Parity test** (definition of done): for a known SNMP series, a resolved anomaly's
   `(device_id, metric_name, if_index)` equals the metric's, and a join returns the
   metric's samples.

## Why not the alternatives

- **Equalize `series_key`** (first draft) — rejected: the hash is `device_id`-empty +
  ingestion-tag-polluted + not reproducible. Aligning to it requires re-keying every
  metric (breaking historical keys) for a *worse* identity than `device_id`.
- **Trust an agent-computed key** — rejected: untrusted identity (behavioral-identity
  rule). The agent contributes typed fields; `agent_id`-anchored canonicalization stays
  central.
- **Join on raw `device_uid`** — rejected: that is the bug (agent host / unreconciled
  hostname), which is why `device.uid` is empty/raw today.

## Degradation (never worse than today)

If `DeviceCorrelation` cannot resolve a canonical device (no `target_device_ip`, no
matching inventory device), the anomaly keeps its raw id and simply does not join — the
current behavior. The fix is additive: it correlates what it can resolve and never
mis-attributes. Cutover must not orphan *already-open* anomalies (review **M4**):
either re-key in place on next evaluation or leave them resolvable by raw id.

## Security model (unchanged, explicit)

`agent_id` is gateway-attested and anchors the canonical resolution; the agent-reported
target/interface are scoped under it, so a hostile/misconfigured agent can only collide
inside its own `agent_id` namespace. The agent does the one thing only it can —
identify what it polled — without being trusted as the authority for the canonical id.
