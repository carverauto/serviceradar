<!--
SPDX-License-Identifier: MIT
Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
-->

# Lean Verification Status — `deep_causality`

Status as of 2026-07-10. This note summarizes the machine-checked formalization of the **main
crate** — the Causaloid, the Collection, the graph-reasoning engine, and the Context hypergraph. It
is the crate-local view of the program described in
[`openspec/notes/causal-algebra/causaloid-formalization-roadmap.md`](../openspec/notes/archive/causal-algebra/causaloid-formalization-roadmap.md),
mirroring [`deep_causality_core/LEAN_CORE.md`](../deep_causality_core/LEAN_CORE.md) and
[`deep_causality_haft/LEAN_HAFT.md`](../deep_causality_haft/LEAN_HAFT.md). The core-crate causal
monad / Kleisli-arrow / free-monad laws this layer builds ON are in `LEAN_CORE.md`.

## Summary

The organizing theorem is `Causaloid ≅ μX.F(X)` with
`F(X) = Atom(I→ᴹO) + Coll(Bag X, AggLogic) + Graph(Hyper X, Λ-edges)`, and `evaluate` is its unique
F-algebra catamorphism into the Kleisli category of the causal monad. Every load-bearing surface of
the crate — the three causaloid forms, the collection fold, the schedule-invariant graph engine, the
adaptive relay loop, and the context-graph parent-set threading — is formalized in Lean 4 and pinned
to the Rust implementation by a per-theorem witness test.

- **Lean proofs (L1):** the causaloid-layer files under
  [`lean/DeepCausalityFormal/Core/`](../lean/DeepCausalityFormal/Core/) —
  `Causaloid.lean`, `VerdictClosure.lean`, `GraphAlgebra.lean`, `Catamorphism.lean`,
  `CommandInput.lean`, `ContextGraph.lean`, and the relay-round-composition section of
  `CausalEffect.lean`. Every theorem is closed — **zero `sorry`** (CI-guarded). Each file is
  self-contained (no imports, core Lean only), so it typechecks standalone with bare `lean <file>`;
  no Mathlib dependency in this layer.
- **Rust witnesses (L2):** one `#[test]` per theorem id under
  [`tests/formalization_lean/`](tests/formalization_lean/), a directory that mirrors the Lean tree.
  Lean proves ∀; the witness pins the actual `Causaloid` / `CausaloidGraph` / `Context`
  implementation to the same statement at representative inputs (and, for the graph engine, at
  pinned corpus inputs — the `#10` characterization corpus).
- **The bridge:** each theorem carries a shared id (e.g. `core.causaloid.catamorphism_unique`)
  recorded in [`lean/THEOREM_MAP.md`](../lean/THEOREM_MAP.md) — **13 main-crate ids, all proved and
  witnessed**. CI (`.github/workflows/formalization.yml`) runs `lake build`, the witness tests, the
  `sorry`-guard, and a consistency gate that fails if any Lean id lacks a Rust witness or a manifest
  row.
- **Model fidelity:** the Lean carriers are the crate's own canonical structures — the `Causaloid`
  fixpoint (with the sealed three-form `CausaloidType`), the `AggregateLogic` verdict fold over the
  `Verdict` carrier, the Kahn ready-set graph fold with the identity-keyed `LambdaEdges` join
  `∇ ∘ (Λ₁ ⊗ Λ₂)`, the fuel-bounded `'rounds` relay loop, and the `fired[child][parent]` /
  `LambdaEdges (source,target)` wire surface of the Context hypergraph — each transcribed from the
  Rust source.

## How to check

```bash
# Lean proofs (from lean/): full project build, or any single Core file standalone
lake build
lean DeepCausalityFormal/Core/Catamorphism.lean

# Rust witnesses (one #[test] per theorem id)
cargo test -p deep_causality --test mod formalization_lean

# Whole workspace (much faster than cargo across all crates)
bazel test //...
```

## Verified correct as documented

| Mechanism (id) | Reference | Status |
|---|---|---|
| Causaloid fixpoint `core.causaloid.fixpoint` — `Causaloid ≅ μX.F(X)`, the `roll`/`unroll` Lambek isomorphism; the three summands ↔ the three sealed `CausaloidType` forms; well-founded (μ, not ν) | Lambek 1968; Bird & de Moor 1997 | proved & witnessed (closes tracker #9) |
| Hardy inversion `core.causaloid.inversion` — `evaluate = wiring ∘ element-map`; the element map is pointwise and bag-symmetric; Λ-edges are identity-keyed connection data | Hardy 2005 (arXiv:gr-qc/0509120) | proved & witnessed |
| Verdict closure `core.verdict.closure` — `All`/`Any`/`None`/`Some(k)` are closed operations in the Verdict algebra ⇒ `Coll : Causaloid → Causaloid` | Davey & Priestley; Birkhoff | proved & witnessed (closes tracker #5) |
| Verdict carriers `core.verdict.carriers` — `bool` Boolean (distributive), `Prob`/`f64` MV on `[0,1]` (min/max/1−p, excluded middle fails), lifted pointwise to the uncertain carriers; orthomodular projection lattice planned (quantum), general effects excluded | — | proved & witnessed |
| Collection permutation-invariance `core.verdict.perm_invariance` — the `#1` scoped order-invariance theorem: each mode's aggregate **value** is invariant under bag permutation | — | proved & witnessed (value channel; stateless; all-success — scoped, see below) |
| Graph fold order-invariance `core.causaloid.graph_fold_order_invariant` — the topological fold with `∇ ∘ (Λ₁ ⊗ Λ₂)` is invariant under every schedule consistent with the causal order; preconditions checked at freeze | Kahn 1974 | proved & witnessed (closes tracker #2 Q1) |
| Catamorphism uniqueness `core.causaloid.catamorphism_unique` — the keystone: `evaluate` is the UNIQUE interpreter satisfying the algebra's case equations, **per fixed carrier** | Lambek 1968; Goguen et al. 1977 | proved & witnessed (#6 scoped; goal B2) |
| Encapsulation flat `core.causaloid.encapsulation_flat` — nested fold = flat fold (catamorphism fusion): wrapping a subgraph in a causaloid does not change the semantics | Bird & de Moor 1997 | proved & witnessed |
| Arrow fragment `core.causaloid.arrow_fragment` — the `Atom`/`compose` fragment ≅ the reified `ArrowTerm` language, extended to the ⊕-enlarged set; interpretation factors through `T/≈` | Hughes 2000 | proved & witnessed (closes tracker #8) |
| Command input F-3 `core.causaloid.command_input` — a command (`RelayTo`) on a singleton's input channel yields a specific, named error, never a silent `None`, distinct from the absence error | — | proved & witnessed (`evaluate` + `evaluate_stateful`) |
| Relay-round composition `core.causal_effect.relay_round_composition` — multi-round adaptive evaluation is the sequential (Kleisli) composition of its rounds; the fuel bound composes, inheriting `core.causal_effect.relay_termination` | — | proved & witnessed (`Core/CausalEffect.lean`, the main-crate `'rounds` engine) |
| Context threading = bind `core.context_graph.threading_bind` — parent-set (hyperedge) semantics keyed by identity; hyperedge threading IS the causal monad `bind`; encapsulation = flat inherited from `core.causal_monad.assoc` | Pearl 2009; Koller & Friedman 2009 | proved & witnessed |
| Context acyclicity separable `core.context_graph.acyclicity_separable` — acyclicity is a separable, freeze-enforceable parameter (`ultragraph::has_cycle`/`freeze_dag`); a cycle has no rank certificate; the same apparatus serves the cyclic case | Oreshkov–Costa–Brukner 2012 | proved & witnessed |

## Outstanding issues

1. **Order-invariance is scoped to the value channel (the `#1` ruling).** `core.verdict.perm_invariance`
   proves invariance for the aggregate **value** on the stateless, all-success path. The **log
   channel** is a multiset invariant only up to permutation (a `Vec`-append/free monoid, order-
   sensitive by construction), and the **stateful** path is excluded by statement.
2. **Laws are proved per fixed carrier, not across carriers.** `core.causaloid.catamorphism_unique`
   is per-carrier initiality (assumption #6, correctly scoped); the Verdict carrier classes
   (Boolean, MV, planned orthomodular) are distinct instances, not one universal claim.
3. **The stateful graph-fold / collection path is guarded but unformalized (D8).** There is no
   state-merge semantics at a reconvergent join to prove (single-writer, checked at freeze); the
   value-channel model is what is formalized. The stateful engine is exercised by regression tests,
   not by a Lean theorem.
4.  **The claim is L1 + L2, not "proved correct."** Laws are machine-checked in Lean and the
   implementation is pinned to the same statements by witness tests over representative (and pinned-
   corpus) inputs. Purity of caller closures is a precondition, not a type-enforced guarantee.
