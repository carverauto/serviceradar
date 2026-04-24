# Tasks: Add Temporal Context Hypergraph

## Phase 1: Infrastructure & Integration
- [ ] 1.1 Create `rust/temporal_context` crate.
- [ ] 1.2 Add `deep_causality` dependency to the new crate.
- [ ] 1.3 Scaffold `elixir/web-ng/native/temporal_context_nif` using Rustler.
- [ ] 1.4 Implement `ResourceArc` for the Context Hypergraph.

## Phase 2: Core Implementation
- [ ] 2.1 Implement `TimeIndexable` for Hypergraph nodes.
- [ ] 2.2 Implement `RelativeIndexable` and `Indexable` traits.
- [ ] 2.3 Develop the relative indexing update logic (continuous updates).
- [ ] 2.4 Implement NIF functions for node addition and relative access.

## Phase 3: Elixir Integration
- [ ] 3.1 Create `ServiceRadarWebNG.TemporalContext.Native` module in Elixir.
- [ ] 3.2 Implement an `AshOban` trigger on a relevant Ash resource to call `update_indices/0`.
- [ ] 3.3 Configure the `AshOban` scheduler in `core-elx` to run the update job periodically.
- [ ] 3.4 Integrate temporal context lookups into the NetFlow data pipeline.

## Phase 4: Verification & Documentation
- [ ] 4.1 Write Rust unit tests for hypergraph indexing logic.
- [ ] 4.2 Write Elixir integration tests for NIF calls.
- [ ] 4.3 Document the hypergraph structure and traversal API in `docs/`.
