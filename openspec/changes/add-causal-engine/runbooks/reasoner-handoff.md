# Reasoner hand-off (for the DeepCausality author)

> The ServiceRadar-owned V1 engine plumbing in `rust/causal-engine` is complete and
> green (cargo clippy `-D warnings`, tests, `bazel build --config=ci`). What remains
> — the **Context graph (CausaloidGraph) and the causaloid reasoning** — is the
> DeepCausality side. This note maps the seams so the reasoner drops in with no
> ServiceRadar-side changes.

## The one function to implement

`rust/causal-engine/src/reasoner.rs` — `Reasoner::evaluate`:

```rust
impl Reasoner {
    pub fn evaluate(&self, ctx: &Context) -> Result<Vec<Verdict>> { /* TODO: CausaloidGraph */ }
}
```

The fused tick loop (`main.rs`) already does: **hydrate → `reasoner.evaluate(&ctx)` → `emitter.emit(&verdicts)`**. The reasoner only computes verdicts; everything around it is built.

## What feeds you (input) — `ContextStore`

`context_hydrator.rs` maintains the hydrated world-state and hands it to the reasoner via the `ContextStore` trait (`current_context() -> Context`). It is:
- seeded from CNPG via `EmbeddedSrql` (`in:devices`, `in:services`) on connect + a periodic `refresh()`,
- kept current by the live `signals.state.>` subscriber (applies device/service transition deltas),
- restored from an on-disk snapshot on restart.

`domain_model::Context` (V1): `devices: Vec<Device>` (uid, is_available, is_managed, **risk_score**), `services: Vec<Service>` (composite id, available). **Extend `Context`/`domain_model` freely** as the causaloids need more entities (interfaces, agents, gateways, flows, virt, BGP, MTR, health) — that is the hydrator↔reasoner seam and is expected to grow. The hydrator can add SRQL queries (`graph_cypher` for AGE topology) to populate them.

Identity: every entity is the canonical `sr:`-prefixed id (`ocsf_devices.uid == AGE Device.id == ocsf_events.device.uid`). Do **not** invent a parallel ID space.

## What you emit (output) — already wired

Return `Vec<Verdict>` from `evaluate`:

```rust
pub struct Verdict { pub entity_id: String, pub classification: Classification, pub reason: String }
pub enum Classification { RootCause, Affected, Healthy, Unknown }   // == God-View 4 buckets
```

`emitter.rs` publishes each to `signals.causal.predictions.<entity>` over JetStream with a **deterministic** `event_identity` (`pred:<entity>:<classification>`) in the OCSF envelope the `CausalSignals` processor already normalizes into `ocsf_events` — which re-enters `StatefulAlertEngine` (alerts) and drives the God-View render. No new ServiceRadar plumbing needed.

## Building the reasoner

- Add deps to `rust/causal-engine/Cargo.toml` (task 1.1.3): `deep_causality 0.13`, `deep_causality_sparse 0.1`, `deep_causality_tensor 0.4`, `deep_causality_topology 0.5`, **`ultragraph = "0.9"`**. (crate_universe is `from_cargo`; after editing Cargo.toml run a build so `//:Cargo.lock` + `MODULE.bazel.lock` update, then commit both — no repin needed.)
- **Gap G is already in `ultragraph 0.9`** (no upstream work): `StructuralGraphAlgorithms` (articulation_points / bridges / biconnected_components / strongly_connected_components), `pathway_betweenness_centrality(pathways, directed, normalized)`, `is_reachable`, `freeze`/`unfreeze`. See `runbooks/gap-g-resolution.md`.
- Build the `CausaloidGraph` on a `CsmGraph` (CSR); `freeze()` per tick, `unfreeze()` only on topology change (task 1.3).
- Causaloid catalog C1–C13: `specs/causal-reasoning/spec.md`. Six are direct ultragraph calls — C4/C7/C8 `is_reachable`, C5/C5b `articulation_points`/`bridges`, C9 `pathway_betweenness_centrality`.
- **Risk composition (task 1.5):** read `Device.risk_score` (MAX-wins composite already written by the inventory feature's `DeviceRiskReducer`, source `endpoint_inventory`, CVSS-scored) and the AGE `Device` `pkg_*` scalars (via `graph_cypher`) as numeric observations into C5/C7/C10.

## Follows the reasoner (do after verdicts flow)

- **1.10 god_view_nif refactor:** extract the NIF's 244-line `core/causality.rs` (betweenness + 3-hop BFS) into the engine as the basis of the reasoner, then demote the NIF to a ~50-line renderer stub reading verdicts from `ocsf_events`, drop `deep_causality*`/`ultragraph` from the NIF Cargo.toml, and rejoin the workspace. Cutover is gated on the engine producing real verdicts (else the God-View renders empty) — hence after the reasoner.
- **1.2 feed-2:** if the reasoner wants live causal signals (`signals.causal.>` BMP/SIEM/MTR) faster than the SRQL snapshot, add a second subscriber — but guard against consuming the engine's own `signals.causal.predictions` (feedback loop), and define where those signals land in the `Context`.

## Division of labor (settled)

ServiceRadar feeds the Context (hydrator + state-change feed + inventory risk) and emits/renders verdicts; DeepCausality owns the Context graph and the causaloid reasoning. The `Context`/`ContextStore`/`Verdict` types are the seam.
