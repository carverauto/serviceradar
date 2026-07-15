<!--
SPDX-License-Identifier: MIT
Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
-->

# Lean Verification Status — `deep_causality_core`

Status as of 2026-07-10. This note summarizes the machine-checked formalization of the core
crate; it is the crate-local view of the program described in
[`openspec/notes/causal-algebra/Formalization.md`](../openspec/notes/archive/causal-algebra/Formalization.md),
mirroring [`deep_causality_haft/LEAN_HAFT.md`](../deep_causality_haft/LEAN_HAFT.md).

## Summary

Every causal/categorical mechanism in this crate is formalized in Lean 4 and linked back to the
Rust implementation by a per-theorem witness test:

- **Lean proofs (L1):** 9 files under
  [`lean/DeepCausalityFormal/Core/`](../lean/DeepCausalityFormal/Core/), one per mechanism,
  mirroring the crate's module layout. Every theorem is closed — **zero `sorry`**. Each file is
  self-contained (no imports, core Lean only), so it typechecks standalone with bare `lean <file>`;
  no Mathlib dependency in this layer.
- **Rust witnesses (L2):** one `#[test]` per theorem id under
  [`tests/formalization_lean/`](tests/formalization_lean/), a directory that mirrors the Lean tree
  (`Core/EffectLog.lean` ↔ `effect_log_tests.rs`, …). Lean proves ∀; the witness pins the actual
  Rust implementation to the same statement at representative inputs. The `core.causal_arrow.*`
  witnesses live alongside the arrow type in `tests/types/causal_arrow/`.
- **Bounded model checking (L3):** [`tests/kani_proofs.rs`](tests/kani_proofs.rs) carries Kani
  harnesses for the load-bearing monad laws (`left_id`/`right_id`/`assoc`/`left_zero`, log
  monotonicity) and the arrow right-identity — first-order bounded checks over all carrier shapes
  with fixed continuations. Gated on `#![cfg(kani)]`; **not run in CI** (a full run took ~2h and is
  too costly to schedule) — run locally on demand (`cargo kani --tests -p deep_causality_core`).
- **The bridge:** each theorem carries a shared id (e.g. `core.causal_monad.lawful`) recorded in
  [`lean/THEOREM_MAP.md`](../lean/THEOREM_MAP.md) — **26 core ids, all proved and witnessed**. CI
  (`.github/workflows/formalization.yml`) runs `lake build`, the witness tests, and a consistency
  gate that fails if any Lean id lacks a Rust witness or a manifest row.
- **Model fidelity:** the Lean carriers are the crate's own canonical instances — the value
  fragment `Except E (Option V)` of `CausalEffectPropagationProcess` (state/context/log threaded by
  `bind'`), `CausalEffect = Free CausalCommand (Option V)`, the `List Λ` log abstraction (timestamps
  quotiented exactly as `EffectLog`'s `PartialEq`), and the char-level CSV codec — with each
  `bind`/`fmap`/`map`/`render` body transcribed literally from the Rust source.
- **Cross-crate additions (2026-07-10, `formalize-main-crate`):** `Core/CausalEffect.lean`
  additionally carries `core.causal_effect.relay_round_composition` — multi-round adaptive
  evaluation is the sequential (Kleisli) composition of its rounds — witnessed by the **main-crate**
  graph engine (`run`'s realization is the `deep_causality` `'rounds` loop), so its witness lives in
  `deep_causality/tests/`, not this crate. The `Core/` Lean directory also hosts the `deep_causality`
  main crate's causaloid-layer formalization —
  `Core/{Causaloid, VerdictClosure, GraphAlgebra, Catamorphism, CommandInput, ContextGraph}.lean` —
  whose witnesses live in `deep_causality/tests/formalization_lean/` and whose ids are recorded in
  `THEOREM_MAP.md` and the causaloid-formalization roadmap; those are outside this core-crate
  summary's 26-id count.

The audit against the accepted literature found 17 deviations between the code and its accepted
definition. **All are resolved** — the two structural corrections (`separate-control-channel`,
`causal-arrow-state-threading`) landed and are archived, so the proofs describe the faithful
implementation, and the long-blocked `core.causal_monad.lawful` claim is now closed (P1 resolved:
control is separated into `CausalCommand`/`CausalEffect`; the carrier is the transformer stack
`Except ∘ Free ∘ Maybe` of already-proven monads). The full audit trail with per-deviation
resolution status lives in
[`openspec/notes/causal-algebra/core-formalization-deviations.md`](../openspec/notes/archive/causal-algebra/core-formalization-deviations.md).

## How to check

```bash
# Lean proofs (from lean/): full project build, or any single Core file standalone
lake build
lean DeepCausalityFormal/Core/CausalMonad.lean

# Rust witnesses (one #[test] per theorem id)
cargo test -p deep_causality_core --test mod formalization_lean

# Bounded model checking (local / on demand — not run in CI)
cargo kani --tests -p deep_causality_core
```

## Verified correct as documented

| Mechanism | Reference | Status |
|---|---|---|
| `CausalMonad` (left/right identity, associativity, error left-zero) | Moggi 1991; Wadler 1995 | laws stated & hold; base `haft.monad.laws` |
| `CausalMonad` **lawful** (all three co-hold on one carrier — P1 unblocked) | Moggi 1991 | `LawfulMonad`-with-effect, closed |
| `CausalEffect` (success channel; `into_value` = honest `Maybe` projection) | Swierstra 2008 | value functor = `Option` (`haft.functor.laws`); total `map` |
| `CausalCommand` (single-hole control operation functor; free monad over it) | Plotkin–Power 2003; Swierstra 2008 | functor laws + `haft.free_monad.*`; structural `RelayTo`-tree equality |
| `EffectLog` (free monoid / Writer output; append-only) | Mac Lane §I.1; Wadler 1995 §3 | 4 laws stated & hold (bridged) |
| `CausalArrow` (Kleisli category with full state/context threading) | Mac Lane §VI.5 | category laws + left-zero; unconditional right identity |
| `Alternatable` (value/state/context lenses up-to-log; `clear_context`) | Foster et al., POPL 2005 | set-get / set-set (proj) / channel independence / error no-op; log-growth caveat (D9) |
| `CausalFlow` (facade `≅ Process`; total `map`; `map = and_then(pure∘f)`) | Moggi 1991 | `flow_iso`/`map_id`/`map_comp`/`map_eq_andThen` (holds on `None` too — D14) |
| `CausalFlow` extensions — `recover`, `iterate_*`, `finish` | — | documented extensions with their own contracts (catch law; `MaxStepsExceeded`; terminal projection) |
| `Csv` IO codec (round-trip under no-`','`/`'\n'` precondition) | — (cites `haft.io.laws`) | conditional round-trip; precondition is a theorem hypothesis (D16) |
| Witness/inherent functor+applicative **agreement** (`core.witness.agree`) | — | all three witnesses + inherent `fmap` compute the same total success-channel functor; `apply` total too (value-less/command ↦ `None`, never `InternalLogicError`); no `Ok(Value _)` restriction, no reachable panic (D15 fully retired) |

## Outstanding issues

1. **Pearl do-operator (D8) is out of scope here.** Value-level substitution is `alternate_value`
   (the lens family, proved); the true do-operator (graph surgery / variable isolation) belongs to
   the `deep_causality` Causaloid + hypergraph layer. The `Alternatable.lean` docstring points
   forward to it; this crate proves only the lens laws.
2. **CSV round-trip is conditional (D16, accepted).** The theorem holds under the explicit
   hypothesis that no field contains `','` or `'\n'` (the codec applies no quoting/escaping);
   RFC-4180 quoting is a possible future hardening.
3. **Laws are proved per canonical carrier, not per generic instance.** The Lean carriers are the
   crate's own representative instances (as in haft); extending to every shipped parameterization is
   mechanical scaling work. The witnesses check representative inputs (Lean proves ∀; Kani bounds
   the load-bearing monad/arrow laws).
4. **Purity is a precondition, not a guarantee.** Law-bearing signatures accept `FnMut`/`FnOnce`;
   the laws hold only for pure closures — documented, but not enforceable by Rust's type system.
5. **The claim is L1 + L2 (+ L3 on the load-bearing laws), not "proved correct."** Per
   `Formalization.md`: *laws machine-checked in Lean; implementation pinned to the same statements by
   tests and bounded model checking (Kani)* — not a proof that the shipped Rust code is correct.
