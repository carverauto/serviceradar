# Design — edge↔central `series_key` alignment

## The two sub-problems (they are separable)

A series's canonical key is `TimeseriesSeriesKey.build/1` over
`{metric_type, metric_name, partition, agent_id, device_id, target_device_ip,
if_index}` → `Base.encode16`. The metric pipeline already produces this
(`metric_envelope.ex:215-221`). For the anomaly to match it, **two** things must
hold, and they fail independently today:

1. **Same identity inputs.** The anomaly must carry the *same field values* the
   metric used — crucially the **device**. The edge trace (below) established the
   agent already stamps the polled **target** (`target_device_ip` = the switch IP)
   on every SNMP metric and the current addon already attributes to it, *not*
   `agent_id` — so this input arrives. What does NOT arrive is the **canonical `sr:`
   device**: the edge carries the raw target IP; only central resolves that IP to the
   canonical `sr:` device (the metric pipeline does exactly this). So the anomaly
   carries the target IP while the metric carries `sr:<target>`.
2. **Same key function.** The anomaly's stored `series_key` must be computed by the
   **same** `TimeseriesSeriesKey.build/1` over the canonical-resolved fields. Today
   `causal_signals.ex:1282/1290/1311` persists `payload["anomaly"]["series_key"]`
   verbatim (the edge's `v2|…` key), and resolves the device off the raw `device_uid`
   — which fails for SNMP (an IP/agent is not a canonical device).

Both reduce to **one central fix**: resolve the anomaly's target identity to the same
canonical `sr:` device the metric pipeline resolves (keyed off `target_device_ip`),
then run `TimeseriesSeriesKey.build`. The edge already hands central the target.

## What the edge trace established (4-way, agent → feed → addon → demo)

- **Agent** (`metric_envelope.go`/`push_loop_snmp.go`): one construction path stamps
  the polled switch as `target_device_ip = HostIP` (+ `host`/`target` tags) on every
  SNMP metric; the *same* bytes feed the addon and central — no fork. SNMP sets no
  `device_id` (resolution is central, by design).
- **Feed**: the addon decodes the **identical** `MetricBatch`; it has `target_device_ip`.
- **Addon** (`addon.rs`): `is_snmp_metric_class("snmp")` matches and
  `snmp_target_identity` reads `metric.metadata["target_device_ip"]`, so attribution
  resolves to the **target IP**, not `agent_id`, and the verdict emits
  `source_identity.target_device_ip`.
- **Demo**: 100% of agent-dusk01's 2.43M SNMP rows carry `target_device_ip` and
  `device_id = sr:<target>` (never the agent); per-target-per-interface `series_key`.

So the edge is **not** the gap. The demo's `agent-dusk01`-attributed anomalies are
inconsistent with current code (which attributes to the target IP) — almost certainly
a **deployed addon predating the `snmp_target_identity` logic**. Either way the
remaining gap, and the entire fix, is central.

## Decision: carry the target identity, canonicalize centrally for both

- **Canonicalization stays central** (the security boundary). The agent never stamps
  the authoritative key; it contributes typed fields. `agent_id` is gateway-attested
  and anchors the composite, so a misbehaving/compromised agent can only collide
  inside its **own** `agent_id` namespace — it cannot spoof another agent's series or
  device. This is the "meet in the middle": the agent *does* produce the SNMP
  target/interface identity (it is the sole source), but it is scoped, not trusted
  as an opaque key.
- **The edge already carries the target identity** (trace-confirmed). The agent
  stamps `target_device_ip` and the addon emits it on the verdict's
  `source_identity` (`+ if_index, metric_name, agent_id`). No edge change is required
  beyond ensuring the current addon is the *deployed* version; this proposal does not
  modify the agent or addon attribution.
- **Central reconciles + keys both the same way (the fix).** On anomaly ingest
  (`causal_signals.ex`), resolve the anomaly's device to the same canonical `sr:`
  device the metric pipeline resolves — **keyed off `target_device_ip`** (the polled
  switch IP), which is the lookup the metric pipeline uses to assign `sr:<target>`,
  NOT the raw `device_uid` (an IP/agent has no canonical device). The existing re-key
  at `:1410` already resolves the finding's device-uid; the fix is to (a) drive that
  resolution from `target_device_ip` for SNMP and (b) recompute
  `series_key = TimeseriesSeriesKey.build(canonical fields)` instead of persisting the
  edge's `v2|…` key. Keep the `v2|…` key as debug-only metadata and log disagreement
  (mirrors `metric_envelope.ex`'s `maybe_record_series_hint`).

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
