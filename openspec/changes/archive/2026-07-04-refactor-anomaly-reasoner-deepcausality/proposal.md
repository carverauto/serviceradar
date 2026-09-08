# Change: Unify anomaly reasoning on DeepCausality

## Why
The anomaly engine currently has two competing implementation shapes:

- `causal_reasoner_nif` uses DeepCausality, but reconstructs rolling window statistics from the full baseline list for each sample.
- `CompactEvaluator` proves the O(1) Welford/ring-buffer hot path in Elixir, but is a second detector implementation with separate parity and maintenance risk.

Issue `fj #3796` makes the architectural choice explicit: DeepCausality remains the authoritative anomaly reasoner. The O(1) rolling-state work belongs inside the Rust NIF and its Elixir boundary, not in a parallel evaluator.

## What Changes
- Extend the DeepCausality-backed NIF context with rolling Welford state and a bounded clean `window_tail`.
- Update the NIF to evaluate rolling statistics in O(1) using Welford add and West removal while preserving current semantics for withholding anomalous samples, sustained confirmation, and sample-variance `n - 1` math.
- Return the next rolling state from each verdict so the Elixir owner can persist compact state instead of copying a baseline list on every call.
- Add a batched NIF entrypoint that evaluates many `(context, sample)` pairs per call and preserves per-series ordering at the caller boundary.
- Keep a two-pass oracle path and property tests to prove parity, including large-magnitude counter data where naive variance fails.
- Delete the hand-rolled compact evaluator once the DeepCausality path has equivalent correctness and benchmark coverage.

## Impact
- Affected specs: `anomaly-detection`
- Affected code: `elixir/serviceradar_core/native/causal_reasoner_nif`, `ServiceRadar.Observability.CausalReasoner`, anomaly `ContextOwner`, anomaly pipeline/checkpoint state, benchmark harnesses, and compact evaluator tests/modules
- Runtime impact: lower per-evaluation CPU and BEAM copy pressure while keeping one production anomaly reasoning implementation
