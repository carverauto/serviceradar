<!--
SPDX-License-Identifier: MIT
Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
-->

# Lean Verification Status — `deep_causality_num_dual`

Status as of 2026-07-10. This note summarizes the machine-checked formalization of the dual-number
crate — `R[ε]` with `ε² = 0`, the carrier for forward-mode automatic differentiation. It is the
crate-local view of the program described in
[`openspec/notes/causal-algebra/Formalization.md`](../openspec/notes/archive/causal-algebra/Formalization.md),
mirroring [`deep_causality_core/LEAN_CORE.md`](../deep_causality_core/LEAN_CORE.md) and
[`deep_causality_haft/LEAN_HAFT.md`](../deep_causality_haft/LEAN_HAFT.md).

## Summary

Every law of the crate's `Dual` number type is formalized in Lean 4 and linked back to the Rust
implementation by a per-theorem witness test:

- **Lean proofs (L1):** one file,
  [`lean/DeepCausalityFormal/Dual/Dual.lean`](../lean/DeepCausalityFormal/Dual/Dual.lean), carrying
  **6 theorems**. Every theorem is closed — **zero `sorry`**. Unlike the core/haft layers, this file
  is **not** self-contained: it `import Mathlib.Algebra.DualNumber` and reuses Mathlib's
  `DualNumber R` (defined as `TrivSqZeroExt R R`), discharging each law by the corresponding Mathlib
  lemma (`mul_comm`, `DualNumber.eps_mul_eps`, `TrivSqZeroExt.fst_add`, `TrivSqZeroExt.fst_mul`,
  `DualNumber.snd_mul`, `DualNumber.snd_eps`). It therefore typechecks under `lake build` (which
  supplies Mathlib), not with a bare standalone `lean <file>`.
- **Rust witnesses (L2):** one `#[test]` per theorem id under
  [`tests/formalization_lean/dual_tests.rs`](tests/formalization_lean/dual_tests.rs)
  (`test_mul_comm`, `test_eps_sq_zero`, `test_real_projection_add`, `test_real_projection_mul`,
  `test_leibniz_product_rule`, `test_not_field_zero_divisor`). Lean proves ∀; the witness pins the
  crate's real `Dual` type to the same statement at representative inputs.
- **The bridge:** each theorem carries a shared id (e.g. `dual.leibniz.product_rule`) recorded in
  [`lean/THEOREM_MAP.md`](../lean/THEOREM_MAP.md) — **6 dual ids, all proved and witnessed**. CI
  (`.github/workflows/formalization.yml`) runs `lake build`, the witness tests, and a consistency
  gate that fails if any Lean id lacks a Rust witness or a manifest row.
- **Model fidelity:** the Lean carrier is Mathlib's `DualNumber R`, the ring `R[ε]` with `ε² = 0`.
  The real projection `TrivSqZeroExt.fst` mirrors `Dual::value()` and the dual (tangent) projection
  `TrivSqZeroExt.snd` mirrors `Dual::derivative()`. The formalized facts are: `DualNumber R` is a
  **commutative ring** whenever `R` is; the dual unit satisfies **`ε² = 0`**; the real projection is
  a **ring homomorphism** for `+` and `×`; the tangent part satisfies the **Leibniz product rule**
  `snd(a·b) = fst a · snd b + snd a · fst b` — the defining equation of forward-mode AD; and `ε` is a
  **nonzero zero-divisor**, so `DualNumber R` is **not a field** (nor an integral domain) over a
  nontrivial `R`.

## How to check

```bash
# Lean proofs (from lean/): full project build (supplies Mathlib — this file imports it)
lake build

# Rust witnesses (one #[test] per theorem id)
cargo test -p deep_causality_num_dual --test mod formalization_lean

# Whole workspace (much faster than cargo across all crates)
bazel test //...
```

## Verified correct as documented

| Mechanism (id) | Reference | Status |
|---|---|---|
| `dual.comm_ring.mul_comm` — `a·b = b·a` in `R[ε]`; `DualNumber R` is a `CommRing` when `R` is | Mathlib `mul_comm` (`Mathlib.Algebra.DualNumber`) | proved & witnessed |
| `dual.eps_sq_zero` — `ε·ε = 0`, the defining relation of the dual numbers | Mathlib `DualNumber.eps_mul_eps` | proved & witnessed |
| `dual.real_projection.add` — `fst(a+b) = fst a + fst b`; `Dual::value()` is additive | Mathlib `TrivSqZeroExt.fst_add` | proved & witnessed |
| `dual.real_projection.mul` — `fst(a·b) = fst a · fst b`; the value multiplies, undisturbed by the tangent | Mathlib `TrivSqZeroExt.fst_mul` | proved & witnessed |
| `dual.leibniz.product_rule` — `snd(a·b) = fst a · snd b + snd a · fst b`; forward-mode AD product rule | Mathlib `DualNumber.snd_mul` | proved & witnessed |
| `dual.not_field.zero_divisor` — `ε ≠ 0 ∧ ε·ε = 0`; a nonzero zero-divisor ⇒ `R[ε]` is not a field | Mathlib `DualNumber.eps_mul_eps` / `DualNumber.snd_eps` | proved & witnessed |

## Outstanding issues

1. **Laws are proved per canonical carrier, not per generic instance.** The Lean statements hold for
   Mathlib's `DualNumber R` over an arbitrary `CommRing R` (with `Nontrivial R` for the zero-divisor
   theorem); the Rust witness is the concrete `f64`-backed `Dual`. The witnesses check representative
   inputs (Lean proves ∀).
2. **Only first-order, single-variable AD is formalized.** The `ε² = 0` model is first-order
   forward-mode differentiation in one tangent direction. Higher-order (truncated jets, `εⁿ⁺¹ = 0`)
   and multivariate (several independent duals `εᵢ`) automatic differentiation are outside the scope
   of this file.
