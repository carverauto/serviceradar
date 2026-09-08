## Context
Camera analysis workers now persist bounded recent probe outcomes. That gives the platform enough local history to derive whether a worker is stable or oscillating, without introducing a separate time-series dependency for this operator-facing state.

## Goals
- Derive a simple flapping state from the existing bounded probe history.
- Keep the derivation deterministic and inexpensive.
- Surface flapping clearly in API and UI without replacing the existing raw probe history.
- Emit explicit telemetry when a worker starts or stops flapping.

## Non-Goals
- Add alert delivery or paging rules.
- Add unbounded probe history storage.
- Introduce a separate health analytics pipeline.

## Proposed Approach
1. Add a small flapping evaluator in the worker runtime path that inspects recent probe history and derives:
   - `flapping` boolean
   - `flapping_transition_count`
   - `flapping_window_size`
2. Use a bounded threshold such as "at least 3 status transitions in the most recent 5 probe results" as the initial rule.
3. Recompute the flapping state whenever probe history is updated.
4. Expose the derived fields in the authenticated management API and operator LiveView.
5. Emit a telemetry event only on state transitions into or out of flapping.

## Risks
- False positives if the bounded history window is too small.
- Operator confusion if flapping is shown without raw context.

## Mitigations
- Keep the raw recent probe rows visible alongside the derived flapping label.
- Use a conservative initial threshold and encode the transition count in the API/UI response.
