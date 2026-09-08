# causal-attack-technique-tagging Specification

## ADDED Requirements

### Requirement: ATT&CK Technique Tagging

Each security causaloid (S1–S7) SHALL declare the MITRE ATT&CK technique(s) it detects, and every
`EvidenceRef` and `SecVerdict` it emits SHALL carry those technique tags (populating `EvidenceRef.attck`),
so that verdicts are SOC-legible and render as labeled kill-chain steps that survive the
`signals.analytics.predictions.*` → `AnalyticsSignals` → `ocsf_events` path onto the resulting alert.
Because the engine reasons only over the hand-authored causaloid catalog, tagging coverage SHALL be
understood as bounded by that catalog — a technique manifesting only in an unmodeled domain is untagged
and invisible — and this change SHALL budget ongoing per-technique authoring as a recurring effort,
rather than treating tagging as a one-time backfill that yields complete ATT&CK coverage.

#### Scenario: An S1 verdict is tagged T1071 and rendered as a labeled kill-chain step

- **WHEN** causaloid S1 (C2 beaconing) fires an incident verdict
- **THEN** each contributing `EvidenceRef` SHALL carry the technique tag `T1071` (and any co-declared
  techniques, e.g. `T1568`)
- **AND** the emitted prediction SHALL render the verdict as a labeled kill-chain step naming the ATT&CK
  technique and its tactic/stage
- **AND** the tag SHALL survive the `signals.analytics.predictions.*` → `AnalyticsSignals` →
  `ocsf_events` path onto the resulting alert

#### Scenario: Ongoing per-technique authoring is budgeted for uncovered techniques

- **WHEN** a detection is required for a technique that no existing causaloid declares
- **THEN** the catalog SHALL be extended by authoring a causaloid that declares that technique's tag(s)
- **AND** this SHALL be accounted for as recurring per-technique authoring work rather than an automatic
  capability of the engine
