# causal-detection-feedback Specification

## ADDED Requirements

### Requirement: Analyst Verdict Labeling Surface

The system SHALL provide an analyst true/false-positive labeling store on causal-engine alerts and
findings, persisted in the `platform` schema via an Ash resource and an Ash-generated migration, so that
a security analyst's disposition of a verdict is durably recorded and available to the calibration loop.
Because `rust/anomaly-disposition` holds statistical dispositions over metric buckets — NOT analyst
labels — and no true/false-positive surface exists anywhere in the codebase, this store is net-new. Each
label MUST reference the verdict/alert it dispositions, the canonical `sr:`-prefixed entity, the analyst
identity and timestamp, and the set of contributing evidence domains, so a label can be attributed back
to per-domain confidences. The Rust engine MUST NOT run DDL for this store.

#### Scenario: Analyst marks an alert false-positive and it is recorded

- **WHEN** an analyst opens a causal-engine alert and marks it a false positive
- **THEN** the system SHALL persist a label row referencing that alert/verdict, the canonical
  `sr:`-prefixed entity, the analyst identity, the timestamp, and the contributing evidence domains
- **AND** the persisted label SHALL be readable by the calibration loop

#### Scenario: Label attributes the verdict to its contributing domains

- **WHEN** a verdict driven by the Flow and DNS domains is labeled
- **THEN** the stored label SHALL record Flow and DNS as its contributing evidence domains
- **AND** the calibration loop SHALL be able to attribute the disposition to those specific domains

### Requirement: Confidence Variance Calibration

The calibration loop SHALL map recorded analyst labels back to the per-domain `Uncertain` variances that
Layer 1 uses to construct per-domain confidences (the score→`Uncertain(mean, variance)` construction of
the `add-causal-engine`/foundation confidence-construction work), closing the fusion calibration loop so
that domains contributing to false positives are trusted less and domains contributing to confirmed true
positives are trusted more. The mapping SHALL be persisted as per-domain calibration parameters in the
`platform` schema via an Ash-generated migration and consumed by the engine's ingest layer; the engine
MUST NOT run DDL. Widening a domain's variance SHALL reduce its inverse-variance fusion weight, and every
adjustment SHALL be bounded by a configured floor/ceiling so that no domain is fully suppressed nor
over-trusted.

#### Scenario: A domain with many false positives has its confidence variance widened

- **WHEN** the labeling store accumulates a high false-positive rate attributed to a given evidence
  domain (for example, Flow)
- **THEN** the calibration loop SHALL widen that domain's per-domain `Uncertain` variance
- **AND** the widened variance SHALL lower that domain's inverse-variance fusion weight on subsequent
  verdicts
- **AND** the adjustment SHALL be bounded so the domain is never fully suppressed

#### Scenario: Confirmed true positives tighten a trusted domain's variance

- **WHEN** analyst labels confirm a domain's contributions as true positives over the calibration window
- **THEN** the calibration loop SHALL be permitted to tighten that domain's variance toward the
  configured floor
- **AND** the tighter variance SHALL raise that domain's fusion weight, bounded by the floor

#### Scenario: Calibration state is read by the engine, which issues no DDL

- **WHEN** the recompute job writes updated per-domain variance parameters to
  `platform.causal_domain_calibration`
- **THEN** the engine's ingest layer SHALL read those parameters at hydrate/refresh to construct
  per-domain confidences
- **AND** the engine SHALL NOT create, alter, or migrate any table
