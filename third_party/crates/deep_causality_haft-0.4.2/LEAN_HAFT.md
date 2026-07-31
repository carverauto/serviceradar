<!--
SPDX-License-Identifier: MIT
Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
-->

# Lean Verification Status — `deep_causality_haft`

Status as of 2026-07-05. This note summarizes the machine-checked formalization of the haft
crate; it is the crate-local view of the program described in
[`openspec/notes/causal-algebra/Formalization.md`](../openspec/notes/archive/causal-algebra/Formalization.md).

## Summary

Every categorical mechanism in this crate is formalized in Lean 4 and linked back to the Rust
implementation by a per-theorem witness test:

- **Lean proofs (L1):** 21 files under
  [`lean/DeepCausalityFormal/Haft/`](../lean/DeepCausalityFormal/Haft/), one per structure,
  mirroring the crate's module layout. Every theorem is closed — **zero `sorry`**. Each file
  is self-contained (no imports, core Lean only), so it typechecks standalone with bare
  `lean <file>`; no Mathlib dependency in this layer.
- **Rust witnesses (L2):** one `#[test]` per theorem id under
  [`tests/formalization_lean/`](tests/formalization_lean/), a directory that mirrors the Lean
  tree one-to-one (`Haft/Functor.lean` ↔ `functor_tests.rs`, …). Lean proves ∀; the witness
  pins the actual Rust implementation to the same statement at representative inputs.
- **The bridge:** each theorem carries a shared id (e.g. `haft.monad.laws`) recorded in
  [`lean/THEOREM_MAP.md`](../lean/THEOREM_MAP.md) — 28 haft ids, all proved and witnessed.
  CI (`.github/workflows/formalization.yml`) runs `lake build`, the witness tests, and a
  consistency gate that fails if any Lean id lacks a Rust witness or a manifest row.
- **Model fidelity:** the Lean carriers are the crate's own canonical instances
  (`OptionWitness` for the functor→monad hierarchy, `BoxWitness`/Env for the comonad, the
  function profunctor, indexed state for `ParametricMonad`, the currying adjunction,
  `Except × List` for `Effect3`, the `run` denotation for `IoAction` and `Arrow`), with each
  `fmap`/`bind`/`run` body transcribed literally from the Rust source.

The audit against the accepted literature found ten deviations (misstated or missing law
docs, one misnamed trait, one unlawful reference implementation, two structural defects).
**All ten are resolved** — including the executed structural proposals P-1 (`Promonad` →
`MonoidalMerge`, `fuse` removed), P-2 (`U: Default` dropped from `MonadEffect3/4/5::bind`),
and P-3 (curvature laws stated at the concrete `CurvatureTensor` in
`deep_causality_topology`). The full audit trail with per-deviation resolution status lives in
[`openspec/notes/causal-algebra/haft-formalization-deviations.md`](../openspec/notes/archive/causal-algebra/haft-formalization-deviations.md).

## How to check

```bash
# Lean proofs (from lean/): full project build, or any single Haft file standalone
lake build
lean DeepCausalityFormal/Haft/Monad.lean

# Rust witnesses (28 tests, one per theorem id)
cargo test -p deep_causality_haft --test '*' formalization_lean
```

## Verified correct as documented

| Structure | Reference | Status |
|---|---|---|
| `Functor` (fmap identity + composition) | Mac Lane, *CWM* §I.3 | laws stated & hold |
| `Pure` (pointed functor; naturality of η) | Mac Lane §I.4 | laws stated & hold |
| `Applicative` (identity, composition, homomorphism, interchange + fmap-compat) | McBride–Paterson, JFP 18(1) 2008 | laws stated & hold |
| `Monad` (3 Kleisli laws; `join = bind id`; applicative coherence) | Moggi 1991; Wadler 1995 | laws stated & hold |
| `CoMonad` (coKleisli laws) | Uustalu–Vene, ENTCS 203(5) 2008 | laws stated & hold |
| `Bifunctor` (identity + composition; first/second decomposition) | Mac Lane §II.3 | laws stated & hold |
| `Profunctor` (dimap identity + contravariant-twist composition) | Loregian, *(Co)end Calculus* §5 | laws stated & hold |
| `ParametricMonad` (indexed Kleisli laws) | Atkey, JFP 19 2009 | laws stated & hold |
| `MonoidalMerge` (binaturality of `merge`; renamed from `Promonad`) | McBride–Paterson 2008 §7 | law stated & holds |
| `Arrow` (category + `arr` functoriality + 5 strength laws + derived `second`/`***`/`&&&`) | Hughes, SCP 37 2000; Paterson, ICFP 2001 | law stated & holds|
| `Morphism` / `Endomorphism` (identity law; `End(T)` monoid; power law `f^(m+n) = f^n ∘ f^m`) | Mac Lane §I.1 | laws stated & hold |
| `Adjunction` (triangle identities + adjunct bijection) | Mac Lane §IV.1 | laws stated & hold |
| `Foldable` (fold–pure compatibility) | — (catamorphism folklore) | law stated & holds |
| `Traversable` (Identity-applicative law + naturality for applicative morphisms) | McBride–Paterson 2008 §3; Jaskelioff–Rypacek 2012 | laws stated & hold (composition deferred, see below) |
| `NaturalIso` (component round-trips + naturality square) | Mac Lane §I.4 | laws stated & hold |
| `Either` (binary coproduct universal property) | Mac Lane §III.3 | universal property holds |
| `Effect3/4/5` + `MonadEffect3/4/5` (monad laws + raise-left-zero on the sum carrier) | Moggi 1991; Wadler 1995 §2.7 | laws stated & hold |
| `IoAction` (monad laws on the `run` denotation) | Moggi 1991 | laws stated & hold |
| `RiemannMap` / `CyberneticLoop` | do Carmo Ch. 4 / — | typed signatures by design; curvature laws proved at the concrete impl (Topology layer, `topology.curvature.*`); `control_step` = Kleisli composite proved |
| HKT witness pattern, `Satisfies`, `Placeholder`, `Adjunction`'s `Context` | Reynolds 1972 (defunctionalization) | Rust-necessitated encodings, mathematically transparent (documented in `Haft/Hkt.lean`) |

## Outstanding issues

1. **Deferred theorems** (tracked in `THEOREM_MAP.md`, "Not yet on the map"):
   - `haft.traversable.composition` — `sequence` at a composite applicative `M ∘ N`; needs
     lawful-applicative hypotheses for both `M` and `N` in the model.
   - `haft.effect_unbound.laws` — the indexed-monad laws for `MonadEffect3/4/5Unbound` are
     the same shape as `haft.parametric_monad.laws` (proved); a dedicated carrier model is
     scaling work.
2. **Laws are proved per canonical carrier, not per witness.** The trait laws are obligations
   on every implementor; the Lean proofs discharge them for the canonical instances listed
   above. Other shipped witnesses (`VecWitness`, `ResultWitness`, `LinkedListWitness`,
   `BTreeMapWitness`, …) are covered by example-based tests only — extending the Lean models
   to them is mechanical scaling work.
3. **One knowingly non-conforming implementation downstream:**
   `GaugeFieldWitness::merge` in `deep_causality_topology` ignores the passed combiner and
   element-wise averages instead (documented in its source as an ACKNOWLEDGED placeholder —
   the trait lacks the `'static` bounds needed for safe dispatch). It therefore does **not**
   satisfy `merge`-binaturality with respect to the combiner. Resolution options are recorded
   at the impl; the type-safe `merge_fields()` is the production path.
4. **Purity is a precondition, not a guarantee.** All law-bearing signatures accept `FnMut`;
   the laws hold only for pure closures. This is documented on every trait but cannot be
   enforced by Rust's type system.
5. **Bounded model checking (L3) is not applied to haft.** Kani harnesses currently exist only
   for `deep_causality_core`. Per `Formalization.md`, L1 + L2 is the claim made for haft:
   *laws machine-checked in Lean; implementation pinned to the same statements by tests* — not
   "proved correct."
6. **Self-contained Lean files duplicate tiny model definitions** (e.g. `optFmap` appears in
   several files). Deliberate — it keeps every proof file standalone-checkable with bare
   `lean` — but a shared prelude module is worth revisiting once the lake build is the only
   check that matters.
7. **`Haft/Hkt.lean` contains no theorems by design.** It is the definitional bridge
   (witness pattern ↔ native type constructors); there is nothing to prove about an encoding,
   only a denotation to document.
