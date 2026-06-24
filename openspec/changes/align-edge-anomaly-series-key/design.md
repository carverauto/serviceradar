# Design — edge↔central `series_key` alignment

## The two sub-problems (they are separable)

A series's canonical key is `TimeseriesSeriesKey.build/1` over
`{metric_type, metric_name, partition, agent_id, device_id, target_device_ip,
if_index}` → `Base.encode16`. The metric pipeline already produces this
(`metric_envelope.ex:215-221`). For the anomaly to match it, **two** things must
hold, and they fail independently today:

1. **Same identity inputs.** The anomaly must carry the *same field values* the
   metric used — crucially the **device**: the canonical `sr:` target, not the
   polling `agent_id`. Today `anomaly_device_uid` (`addon.rs`) falls through to
   `agent_id` because the edge has no canonical `device_id` and no populated
   `target_device_ip`.
2. **Same key function.** The anomaly's stored `series_key` must be computed by the
   **same** `TimeseriesSeriesKey.build/1`. Today `causal_signals.ex:1282/1290/1311`
   persists `payload["anomaly"]["series_key"]` verbatim (the edge's `v2|…`
   producer key).

Fixing (2) without (1) does nothing — same function, different `device_id` input →
different hash. So (1) is the load-bearing fix; (2) is the mechanical follow-through.

## Decision: carry the target identity, canonicalize centrally for both

- **Canonicalization stays central** (the security boundary). The agent never stamps
  the authoritative key; it contributes typed fields. `agent_id` is gateway-attested
  and anchors the composite, so a misbehaving/compromised agent can only collide
  inside its **own** `agent_id` namespace — it cannot spoof another agent's series or
  device. This is the "meet in the middle": the agent *does* produce the SNMP
  target/interface identity (it is the sole source), but it is scoped, not trusted
  as an opaque key.
- **The edge carries the target identity it already has** onto the anomaly verdict's
  `source_identity`: `target_device_ip` (+ `if_index`, `metric_name`, `agent_id`).
  The edge already prioritizes `snmp_target_identity` over `agent_id` in
  `anomaly_device_uid`; the gap is that `target_device_ip` is empty on the SNMP
  metric the addon scores. The fix populates/propagates it (the agent knows the
  poll target) so the addon stops falling back to `agent_id`.
- **Central reconciles + keys both the same way.** On anomaly ingest
  (`causal_signals.ex`), resolve the raw target identity to the same canonical
  `device_id` the metric pipeline used (the existing re-key at `:1410` already does
  the device-uid resolution for findings; extend it to the series-key fields), then
  set `series_key = TimeseriesSeriesKey.build(reconciled_fields)`. Keep the edge's
  `v2|…` key as debug-only metadata and log when it disagrees (mirrors the metric
  side's `maybe_record_series_hint`, so producer drift stays observable).

## Why not the alternatives

- **Trust an agent-computed final key.** Rejected — it would let an agent assert
  another series/device's identity (silence or misroute its anomalies). Violates the
  behavioral-identity rule; `metric_envelope.ex:215` explicitly refuses it.
- **Re-key only at central, ignore the edge.** Insufficient — central cannot invent
  the poll target from an `agent_id`; the orphaned hostnames (`ns01`, `k8s-…`) and
  agent ids prove the target identity must arrive *with* the verdict.
- **A new bespoke composite for anomalies.** Rejected — there is already exactly one
  canonical key (`TimeseriesSeriesKey`); a second scheme reintroduces the divergence
  we are removing. Both sides use the one function.

## Degradation (never worse than today)

When the target identity genuinely cannot be resolved (no `target_device_ip`, no
canonical device — a truly unattributable series), the anomaly keeps a `series_key`
that simply will not join a metric. That is the **current** behavior, so this change
is strictly additive: it aligns the series we *can* attribute and leaves the rest as
they are. It must never coin a *wrong* alignment (a key that collides with a
different series) — hence the composite is anchored on the attested `agent_id`.

## Acceptance gate

A parity test: feed one known SNMP series through both paths (metric envelope and the
anomaly verdict) with the same resource/target fields, and assert
`TimeseriesSeriesKey.build(metric_fields) == TimeseriesSeriesKey.build(anomaly_fields)`
— i.e. the anomaly's persisted `series_key` equals the metric's. This converts the
"asserted, not proven" precondition into a regression-locked proof, and is the
definition of done for unblocking the disposition join (and `#4288`).

## Security model (explicit)

```
canonical_series_key = TimeseriesSeriesKey.build(
  agent_id          # GATEWAY-ATTESTED — the anchor; an agent cannot forge another's
  device_id         # canonical sr: target (central-resolved)
  target_device_ip  # agent-reported poll target (scoped under agent_id)
  metric_type/name  # agent-reported
  if_index          # agent-reported interface
  partition
)
```

The agent-reported components are namespaced under the attested `agent_id`, so the
blast radius of a hostile/misconfigured agent is bounded to its own series. This is
the behavioral-identity rule satisfied *while* letting the agent do the one thing
only it can: identify what it polled.
