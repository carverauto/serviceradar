# Runbook: god_view_nif reasoning cutover (task 1.10)

Move causal reasoning out of the render-time `god_view_nif` and into the
`causal-engine` pod, then retire the NIF reasoning path. The steps are ordered so
the live God-View never loses reasoning: the NIF keeps working until engine
verdicts are proven equivalent and serving.

## 1.10.1 — Extract reasoning into the engine ✅ DONE (reversible, code-only)

`rust/causal-engine/src/god_view.rs` ports the NIF's
`core/causality.rs` algorithm verbatim:

- `betweenness_scores(node_count, edges)` — `ultragraph` 0.9
  `betweenness_centrality(false, true)` over the undirected edge list.
- `evaluate_causal_states(health_signals, edges)` — highest-centrality unhealthy
  node becomes the root (ties: degree, then lowest index), 3-hop BFS marks the
  affected cascade; remaining nodes are healthy/unknown by signal.

The dead DeepCausality `CausaloidGraph` the NIF built-then-froze-but-never-queried
is dropped (it fed nothing downstream). State codes (0=root, 1=affected,
2=healthy, 3=unknown) and reason strings are preserved verbatim so the shadow
diff below is exact. Unit-tested for all four states + centrality root selection.

> Everything below is **deploy-gated and irreversible-if-premature**: do NOT
> demote the NIF or drop its deps until the engine is deployed and 1.10.5 shows
> parity. Demoting the live NIF first would blank the God-View reasoning overlay.

## 1.10.5 — SHADOW mode (do this FIRST, before any NIF change)

1. Deploy the engine pod; confirm `signals.causal.predictions.*` flow into
   `ocsf_events` via the existing `CausalSignals` processor (no new inbound
   plumbing — `pipeline.ex` already routes `signals.causal.*`).
2. Keep the NIF render path authoritative. Add a diff probe that, for the same
   `(health_signals, edges)` snapshot, compares the NIF's
   `evaluate_causal_states_with_reasons` output against the engine's
   `god_view::evaluate_causal_states` (or the engine verdicts normalized to the
   4-bucket schema). Log mismatches with the snapshot id.
3. Run until mismatches are zero (or explained: the engine intentionally adds
   C1/C2/C6/C7/C8/C11/C12/C13 verdicts the NIF never produced — restrict the
   shadow diff to the root/affected/healthy/unknown bucketing the NIF covers).

## 1.10.6 — CUTOVER (one switch, reversible by flipping back)

Switch the God-View render to consume engine-produced
`signals.causal.predictions` → normalized `ocsf_events` → `GodViewSnapshot`
(4 buckets `root_cause|affected|healthy|unknown`, `@schema_version 2`). Keep the
NIF callable for one release as the rollback path.

## 1.10.2 — Demote the NIF to a renderer stub (after cutover proves out)

Delete `core/causality.rs` and the `evaluate_causal_states_with_reasons` export;
the NIF keeps only the UI accelerators that STAY: `layout.rs`, `arrow_serde.rs`,
`telemetry.rs`, `utils.rs`, and the `lib.rs` rustler bindings for those.

## 1.10.3 — Drop reasoning deps from the NIF crate

Remove `deep_causality` and `ultragraph` from
`elixir/web-ng/native/god_view_nif/Cargo.toml` (currently `ultragraph = "0.8"`)
now that reasoning lives in the engine on `ultragraph` 0.9.

## 1.10.4 — Rejoin the NIF crates to the workspace

Populate the empty `[workspace]` block at `elixir/web-ng/native/.../Cargo.toml`
so `god_view_nif` (and sibling `srql_nif`) build under the root workspace and
share the pinned dep graph. Re-run `bazel build` for the affected NIF targets and
confirm green (BUILD updates required when the NIF's dep set changes).

## Verification at each step

- `bazel build`/`bazel test` for the engine and the (eventually) rejoined NIF
  targets, `--config=ci`.
- God-View renders identical buckets pre/post cutover for a held-out snapshot.
