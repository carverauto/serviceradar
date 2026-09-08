# Design — add-causal-detection-feedback

## Context

This is Phase 4 (feedback) of the causal security engine (design note
`openspec/notes/sr-causal-engine.md` §9), extending the settled `add-causal-engine` chassis. Two
independent gaps close here:

- **§7 gap #7 — disposition feedback.** There is **no analyst TP/FP labeling surface anywhere** in the
  codebase. `rust/anomaly-disposition` was mistaken for one; it holds statistical dispositions over
  *metric buckets*, not analyst labels, and cannot calibrate DNS/flow/auth domains at all. So the label
  store and the calibration mapping are both net-new.
- **§7 gap #6 — ATT&CK tagging.** `EvidenceRef.attck: Option<AttckTechnique>` is defined in the
  foundation `SecVerdict` model but unpopulated, so verdicts are not SOC-legible. This change fills it
  from the causaloid catalog and renders labeled kill-chain steps.

Both feed the same end: **self-tuning precision/recall** with explainable, SOC-legible verdicts. The
calibration loop plugs into the per-domain confidence construction (foundation gap #3): L1 builds each
`Observation.confidence: Uncertain(mean, variance)` centrally from an edge/raw score; the variance is the
knob this loop turns.

## Goals / Non-Goals

- Goals:
  - A durable analyst true/false-positive label store on alerts/findings, in the `platform` schema via
    Ash, attributable to the evidence domains that drove each verdict.
  - A bounded calibration mapping from labels to per-domain `Uncertain` variances that closes the fusion
    calibration loop (§4.3) without runaway suppression.
  - ATT&CK technique tags on every causaloid and `EvidenceRef`, rendered as labeled kill-chain steps and
    surviving onto alerts.
  - An explicit, budgeted, ongoing per-technique authoring commitment (bounded-catalog caveat §0).
- Non-Goals:
  - Re-deriving the chassis, the `SecVerdict` model, the S1–S7 catalog, or the per-domain confidence
    construction (owned by `add-causal-engine` / `-foundation` / `-detections`).
  - Host-auth ingest (OCSF `class_uid 3002`) — a separate future track
    (`openspec/notes/sr-host-auth-gap.md`) that unblocks S3/S7; the Auth-domain labels/tags only become
    meaningful once it lands.
  - ML/automatic technique classification — tagging is by hand-authored causaloid declaration, not
    learned.
  - Auto-applying calibration without an operator shadow/override path.

## Decisions

- **Decision: the label store lives in Elixir/Ash (`platform` schema), keyed to the verdict/alert.**
  Alerts/findings already live in CNPG on the Elixir side; the labeling UI is LiveView. The Rust engine
  reads calibration output, never the raw labels, and never runs DDL.
  - Alternatives considered: a Rust-side store in `rust/causal-*` — rejected, it would duplicate the
    alert model and violate the "ingestion never runs DDL" rule; extending `rust/anomaly-disposition` —
    rejected, wrong data model (metric buckets, not analyst labels).
- **Decision: labels capture `contributing_domains`, not just a verdict verdict-level TP/FP.**
  Calibration must attribute a label back to per-domain confidences, so each label records which evidence
  domains drove the verdict. Without this, a false-positive could not be charged to the responsible
  domain.
- **Decision: calibration adjusts per-domain `Uncertain` *variance*, not the mean.** Widening variance
  reduces a domain's inverse-variance fusion weight (§4.3) — the lawful place to express "trust this
  domain less" — while leaving the point estimate intact. Bounds (`floor`/`ceiling`) prevent a noisy
  domain from being fully suppressed or a lucky domain from dominating.
  - Alternatives considered: thresholding each domain independently — rejected, it breaks the fusion
    lattice and double-counts; editing means — rejected, it biases the estimate rather than its weight.
- **Decision: calibration state is a persisted `platform.causal_domain_calibration` table the engine
  reads at refresh.** Keeps the Elixir recompute job and the Rust hot path decoupled; refresh cadence is
  separate from the topology freeze (§3 memory strategy).
- **Decision: ATT&CK tags are declared per causaloid and populated on emit.** The technique is a property
  of the detection logic, so each causaloid declares its tag(s); every `EvidenceRef` it emits carries
  them. Rendering happens in `causal-emit` so the tags ride the existing
  `signals.analytics.predictions.*` → `AnalyticsSignals` → `ocsf_events` path onto alerts — no new
  inbound plumbing.

## Risks / Trade-offs

- **Label sparsity / cold start** → early calibration is noisy. Mitigation: require a minimum label
  count per domain per window before adjusting, and bound every step by `floor`/`ceiling`.
- **Analyst mislabeling / poisoning the loop** → wrong variance. Mitigation: Ash policies restrict who
  can label; append-only history; shadow/override before auto-apply; bounded adjustments.
- **Bounded-catalog over-claim** → operators assume full ATT&CK coverage. Mitigation: the spec states
  coverage is bounded by the hand-authored catalog and budgets ongoing per-technique authoring;
  untagged techniques are explicitly invisible until authored.
- **Auth-domain tags/labels are premature** until host-auth lands. Mitigation: S3/S7 labels are captured
  but flagged low-confidence for calibration until `sr-host-auth-gap.md` closes.

## Migration Plan

1. Author the Ash resources (`causal_detection_labels`, `causal_domain_calibration`); generate migrations
   via `mix ash.codegen` and apply with `mix ash.migrate`.
2. Ship the LiveView disposition control (read/write labels) behind the existing alert/finding surface.
3. Land the recompute job in shadow mode (compute variance multipliers, log them, do not apply).
4. Wire `causal-ingest`/`causal-config` to read `causal_domain_calibration`; flip from shadow to applied
   once operators confirm the shadow output.
5. Land ATT&CK tag declarations + backfill on S1–S7 and the `causal-emit` rendering; verify tags reach
   alerts.
- Rollback: disable the recompute job (variances fall back to foundation defaults); tags are additive and
  can be left populated.

## Open Questions

- Calibration window length and minimum-label threshold per domain (perf/statistics trade-off; align with
  the §10 Q6 perf budget).
- Whether S3/S7 (host-auth-dependent) labels should be excluded from calibration until host-auth lands, or
  down-weighted.
- Whether calibration should be per-domain only, or per-(domain × causaloid), once label volume allows.
