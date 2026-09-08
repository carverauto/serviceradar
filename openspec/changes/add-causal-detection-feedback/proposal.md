# Change: Analyst label feedback + confidence calibration, and ATT&CK technique tagging

## Why

The causal security engine cannot self-tune precision/recall because there is **no analyst
true/false-positive labeling surface anywhere in the codebase** — `rust/anomaly-disposition` holds
statistical dispositions over metric buckets, not analyst labels, and cannot calibrate DNS/flow/auth
domains anyway (design note §7 gap #7). Verdicts are also not SOC-legible: `EvidenceRef.attck` exists in
the `SecVerdict` model but is unpopulated (§7 gap #6). This change adds the analyst-verdict labeling
store, a calibration loop that maps labels back to per-domain `Uncertain` variances, and ATT&CK
technique tags on every causaloid and `EvidenceRef` — the Phase 4 "self-tuning precision/recall"
deliverable (§9).

## What Changes

- **Analyst verdict labeling store (net-new):** an analyst true/false-positive labeling store on
  causal-engine alerts/findings, persisted in the `platform` schema via an Ash resource + Ash-generated
  migration. Each label references the verdict/alert, the canonical `sr:`-prefixed entity, the analyst
  identity/timestamp, and the set of contributing evidence domains so a label can be attributed back to
  per-domain confidences.
- **Labeling UI hook:** a disposition control on the alert/finding detail surface (God-View / alert
  detail) that writes a label through the Ash resource.
- **Confidence variance calibration:** a recompute job aggregates labels per evidence domain and maps
  them back to the per-domain `Uncertain` variances that L1 uses to construct per-domain confidences
  (the score→`Uncertain(mean, variance)` construction, foundation gap #3). A domain with many false
  positives has its variance **widened** (lower inverse-variance fusion weight, §4.3); confirmed true
  positives may **tighten** it toward a floor. Calibration state persists in a new
  `platform.causal_domain_calibration` table (Ash migration) consumed by the engine's ingest layer —
  the engine runs no DDL.
- **ATT&CK technique tagging:** each security causaloid S1–S7 declares the MITRE ATT&CK technique(s) it
  detects; every emitted `EvidenceRef`/`SecVerdict` carries those tags (populating `EvidenceRef.attck`),
  and the emitted prediction renders the verdict as a labeled kill-chain step. Tags survive the
  `signals.analytics.predictions.*` → `AnalyticsSignals` → `ocsf_events` path onto the resulting alert.
- **Bounded-catalog budget (§0):** tagging coverage is bounded by the hand-authored causaloid catalog —
  a technique manifesting only in an unmodeled domain is untagged and invisible — so this change budgets
  **ongoing per-technique authoring** as a recurring effort, not a one-time backfill.

## Impact

Affected specs: `causal-detection-feedback`, `causal-attack-technique-tagging` (both ADDED capabilities).

Affected code:
- Elixir (`platform` schema): NEW Ash resources + Ash-generated migrations for the analyst label store
  and `causal_domain_calibration`; an Oban/recompute job that aggregates labels into per-domain
  calibration parameters; a LiveView disposition control on the alert/finding detail surface. All schema
  changes go through the Ash codegen workflow — ingestion never runs DDL.
- `rust/causal-model` — populate `EvidenceRef.attck` (the field is defined by the foundation
  `SecVerdict` model; this change fills it).
- `rust/causal-causaloids` — per-causaloid ATT&CK technique tag declarations for S1–S7 and backfill.
- `rust/causal-emit` — render technique tags as labeled kill-chain steps in the
  `signals.analytics.predictions.*` payload so alerts carry them.
- `rust/causal-ingest` / `rust/causal-config` — read `platform.causal_domain_calibration` to
  parameterize the per-domain `Uncertain` variance during hydration/refresh.

Dependencies / Coordinate:
- **Extends** the settled `add-causal-engine` chassis (fused `rust/causal-engine`, the three ingestion
  feeds, emission via `signals.analytics.predictions.>` → `AnalyticsSignals`, the flat `rust/causal-*`
  crate family, `god_view_nif` demotion). This change does **not** redefine the chassis.
- **Depends on `add-causal-security-detections`** — the S1–S7 catalog must exist to tag, and its
  cross-domain verdicts/alerts must exist to label.
- **Coordinates with `add-causal-security-foundation`** — the `SecVerdict`/`EvidenceRef.attck` model and
  the per-domain confidence construction (score→`Uncertain(mean, variance)`, gap #3) whose variances the
  calibration loop widens/tightens are owned there; this change consumes and adjusts them.
- **Coordinates with `add-causal-mitigation`** — analyst dispositions and the mitigation-decision audit
  (`platform.mitigation_decisions`) inform the same tuning loop; the label store references verdicts,
  not policy rows, to stay decoupled.
- **References `add-identity-asset-flow-bridge`** — S3's identity leg is only tagged/labelled usefully
  once that bridge and host-auth land.
- **Host-auth ingest is a separate future change** (design note `openspec/notes/sr-host-auth-gap.md`) —
  it unblocks S3/S7 by landing OCSF `class_uid 3002` host authentication; it is out of scope here and is
  NOT authored by this change, but its arrival is what makes the Auth-domain labels/tags meaningful.
