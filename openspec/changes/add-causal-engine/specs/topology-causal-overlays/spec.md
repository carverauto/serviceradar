# topology-causal-overlays Specification

## ADDED Requirements

### Requirement: Causal Overlay Observation Inputs

The topology causal overlay's causal state SHALL be sourced from `causal-engine` verdicts (delivered as `causal-prediction-signals`) together with risk, flow, and package NUMERIC observations defined over canonical topology nodes. The overlay SHALL NOT recompute causal state from an in-NIF reasoning routine; the prior in-NIF 244-line causal stub (betweenness scoring plus the 3-hop BFS `evaluate_causal_states_with_reasons` path) SHALL be retired as the source of causal classification. The overlay SHALL reaffirm the separation between structural layout (computed locally) and causal-overlay classification (sourced externally), and SHALL continue to apply causal verdicts without forcing structural-layout recomputation when the topology revision is unchanged. The overlay SHALL stay within the bounded, backbone-centric snapshot defined by `refactor-topology-read-model-for-carrier-scale` and SHALL NOT reintroduce unbounded causal-graph fanout (for example per-edge or per-endpoint causal expansion) into the rendered snapshot. This requirement REFINES the recomputation source described in the existing `Layout and Causal Overlay Separation` requirement: causal classifications are now APPLIED from external `causal-engine` verdicts rather than recomputed by an in-NIF reasoning routine, while the structural-layout-recomputation behavior described there is unchanged.

#### Scenario: Causal classification sourced from external engine verdicts

- **WHEN** the topology overlay refreshes its causal state for the current topology revision
- **THEN** node causal classification SHALL be derived from `causal-engine` verdicts delivered via `causal-prediction-signals`
- **AND** the overlay SHALL NOT invoke the retired in-NIF 244-line causal reasoning routine to (re)compute classification
- **AND** structural layout coordinates for the unchanged revision SHALL remain unmodified

#### Scenario: Numeric observations attach to canonical nodes

- **WHEN** risk, flow, and package observations are projected onto the overlay
- **THEN** each numeric observation SHALL be keyed to a canonical topology node identifier
- **AND** observations referencing nodes not present in the bounded snapshot SHALL be retained as explicit numeric inputs without expanding the rendered node set

#### Scenario: Overlay stays within the bounded backbone-centric snapshot

- **WHEN** causal verdicts and numeric observations are applied to the overlay
- **THEN** the overlay SHALL operate only over the bounded, backbone-centric node and edge set defined by `refactor-topology-read-model-for-carrier-scale`
- **AND** the overlay SHALL NOT reintroduce unbounded causal-graph fanout into the rendered snapshot
- **AND** verdicts addressed to nodes summarized away by the bounded snapshot SHALL be reconciled against the surviving canonical node rather than expanding fanout

#### Scenario: Structural-vs-causal separation preserved on causal-only update

- **GIVEN** the topology revision is unchanged and only external causal verdicts or numeric observations change
- **WHEN** the overlay refreshes
- **THEN** causal classifications and `topology-god-view` atmosphere classes SHALL update from the external inputs
- **AND** previously computed structural layout coordinates SHALL remain unchanged
