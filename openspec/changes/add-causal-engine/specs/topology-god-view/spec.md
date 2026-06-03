# topology-god-view Specification

## MODIFIED Requirements

### Requirement: Hybrid Causal Filter Bitmaps
The system SHALL emit compact bitmap metadata per snapshot revision so the client can apply visual filtering without recomputing causality. Causal node-state classifications SHALL be PRODUCED by the external `rust/causal-engine` (see capability `causal-engine`) and CONSUMED by the God-View backend rather than computed inside the God-View Rustler NIF.

Causal verdicts MUST reach the God-View backend through the existing signal path: `causal-engine` publishes `signals.causal.predictions.*` (see capability `causal-prediction-signals`), which the CausalSignals processor normalizes into `ocsf_events`; the God-View backend SHALL derive per-node `causal_class` from those normalized verdicts keyed on the canonical `sr:`-prefixed device identity. The God-View backend SHALL NOT invent causal verdicts; when no external verdict exists for a node it SHALL classify that node as `unknown`.

The God-View Rustler NIF SHALL NOT contain causal-reasoning logic. The previous in-NIF causality implementation (the `betweenness_scores` and `evaluate_causal_states_with_reasons_impl` code, including its hard 3-hop BFS cap) is EXTRACTED to `rust/causal-engine`; the NIF causality entry point is DEMOTED to a thin renderer stub (~50 lines) that maps already-decided verdicts onto node indices. The NIF SHALL drop its `deep_causality*` and `ultragraph` dependencies and SHALL rejoin the top-level Cargo workspace.

The cutover from in-NIF computation to external-engine provenance SHALL be incremental and reversible: a SHADOW phase compares external verdicts against the legacy in-NIF output without affecting the rendered snapshot, followed by a PRIMARY-WITH-FALLBACK phase in which external verdicts drive the snapshot and the legacy path remains available as a fallback.

The 4-bucket render contract is UNCHANGED. Causal classes MUST be encoded as:
- `0 = unknown`
- `1 = healthy`
- `2 = affected`
- `3 = root_cause`

Per snapshot revision, the backend MUST emit mutually-exclusive class bitmaps for:
- `causal.root_cause`
- `causal.affected`
- `causal.healthy`
- `causal.unknown`

Each node MUST belong to exactly one causal class in a given revision.

When multiple causal signals apply to a node, class assignment precedence MUST be:
`root_cause` > `affected` > `healthy` > `unknown`.

#### Scenario: Apply causal blast radius states
- **GIVEN** a snapshot revision that includes causal classification bitmaps
- **WHEN** the operator enables blast-radius mode
- **THEN** root-cause nodes render in critical emphasis
- **AND** affected nodes render in degraded emphasis
- **AND** unrelated healthy nodes render in ghosted emphasis

#### Scenario: Toggle visual filters without server round-trip
- **GIVEN** the current snapshot revision and causal bitmaps are loaded
- **WHEN** the operator toggles visual-only filters
- **THEN** the client updates visibility and styling using existing bitmap data
- **AND** no topology recomputation request is sent to the backend

#### Scenario: Causal class exclusivity is preserved
- **GIVEN** a snapshot revision is emitted
- **WHEN** the client inspects class bitmaps for all nodes
- **THEN** no node index is set in more than one causal class bitmap
- **AND** the union of the four class bitmaps covers all emitted nodes

#### Scenario: Verdicts originate from the external causal engine
- **WHEN** the God-View backend builds a snapshot revision
- **THEN** per-node `causal_class` values are derived from `causal-engine` verdicts consumed via normalized `ocsf_events`
- **AND** the God-View Rustler NIF performs no causal reasoning and contains no `deep_causality*` or `ultragraph` dependency

#### Scenario: Nodes without an external verdict default to unknown
- **GIVEN** a node in the snapshot for which `causal-engine` has published no verdict
- **WHEN** the God-View backend assigns causal classes
- **THEN** the node is classified as `unknown`
- **AND** the backend does not synthesize a `root_cause`, `affected`, or `healthy` verdict for that node

#### Scenario: Verdict for a summarized endpoint-cluster node
- **GIVEN** an external verdict keyed on a device identity that GodViewStream summarized into an endpoint-cluster node
- **WHEN** the God-View backend maps verdicts onto rendered node indices
- **THEN** the verdict is applied to the summary node that represents that device identity
- **AND** the verdict is not silently dropped because the underlying device was clustered

#### Scenario: Incremental reversible cutover
- **GIVEN** the shadow phase is active
- **WHEN** the God-View backend produces a snapshot revision
- **THEN** external `causal-engine` verdicts are compared against the legacy in-NIF output without altering the rendered classes
- **AND** when the deployment advances to the primary-with-fallback phase external verdicts drive the rendered classes while the legacy path remains available as a fallback

### Requirement: Causal Explainability Surface
The system SHALL provide operator-visible evidence for causal classifications, including confidence and source signals used for each classification decision. The explainability evidence SHALL ORIGINATE from the external `rust/causal-engine` verdicts (see capability `causal-engine`) consumed via normalized `ocsf_events` / `signals.causal.predictions` (see capability `causal-prediction-signals`); the God-View backend SHALL surface that evidence rather than recompute it.

For each node, explainability payload MUST include:
- `causal_class` (`root_cause|affected|healthy|unknown`)
- `confidence` (`0.0..1.0`)
- `signal_categories` (non-empty list for `root_cause` and `affected`, optional otherwise)
- `explanations` (list of concise human-readable reason strings)
- `model_revision` (string identifying the causal model/rule set revision emitted by `causal-engine`)
- `evaluated_at` (RFC3339 timestamp)

#### Scenario: Inspect root-cause reasoning
- **GIVEN** a node classified as root cause
- **WHEN** the operator opens node details in God-View
- **THEN** the UI shows causal confidence
- **AND** the UI lists the contributing signal categories used for that classification

#### Scenario: Affected-node explainability is available
- **GIVEN** a node classified as affected
- **WHEN** the operator opens node details in God-View
- **THEN** the UI shows confidence and signal categories for the affected classification
- **AND** the UI includes at least one explanation string

#### Scenario: Unknown classification carries explicit uncertainty
- **GIVEN** a node classified as unknown
- **WHEN** the operator opens node details in God-View
- **THEN** the UI shows `causal_class=unknown`
- **AND** the explainability payload indicates insufficient or conflicting evidence

#### Scenario: Explainability evidence carries external engine provenance
- **GIVEN** a node classified as `root_cause` or `affected` by `causal-engine`
- **WHEN** the operator opens node details in God-View
- **THEN** the `model_revision` field identifies the `causal-engine` model/rule-set revision that produced the verdict
- **AND** the surfaced `signal_categories` and `explanations` are those carried on the consumed verdict rather than values recomputed inside the God-View NIF
