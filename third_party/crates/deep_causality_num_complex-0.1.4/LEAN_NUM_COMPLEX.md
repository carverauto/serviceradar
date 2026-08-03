<!--
SPDX-License-Identifier: MIT
Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
-->

# Lean Verification Status — `deep_causality_num_complex`

Status as of 2026-07-10. This note summarizes the machine-checked formalization of the
complex-number and quaternion algebras in this crate; it is the crate-local view of the program
described in
[`openspec/notes/causal-algebra/Formalization.md`](../openspec/notes/archive/causal-algebra/Formalization.md),
mirroring [`deep_causality_core/LEAN_CORE.md`](../deep_causality_core/LEAN_CORE.md) and
[`deep_causality_haft/LEAN_HAFT.md`](../deep_causality_haft/LEAN_HAFT.md).

## Summary

The two division algebras of this crate — ℂ as a field and ℍ as a division ring — are formalized in
Lean 4 and linked back to the Rust implementation by a per-theorem witness test:

- **Lean proofs (L1):** 2 files under
  [`lean/DeepCausalityFormal/Complex/`](../lean/DeepCausalityFormal/Complex/) —
  `Complex.lean` (5 theorems) and `Quaternion.lean` (4 theorems). Every theorem is closed —
  **zero `sorry`**. Unlike the `Haft/` and `Core/` layers, these files are **Mathlib-backed**:
  the laws are stated on Mathlib's canonical carriers (`import Mathlib.Analysis.Complex.Basic`;
  `import Mathlib.Algebra.Quaternion` + `import Mathlib.Analysis.Quaternion`), so they are checked
  as part of the `lake build` (Mathlib `v4.15.0`), not standalone with bare `lean`.
- **Rust witnesses (L2):** one `#[test]` per theorem id under
  [`tests/formalization_lean/`](tests/formalization_lean/), a directory that mirrors the Lean tree
  one-to-one (`Complex/Complex.lean` ↔ `complex_tests.rs`, `Complex/Quaternion.lean` ↔
  `quaternion_tests.rs`). Lean proves ∀ over Mathlib's ℂ / ℍ[ℝ]; the witness pins the crate's real
  `Complex<f64>` / `Quaternion<f64>` types to the same statement at representative inputs (float
  comparisons use an epsilon tolerance).
- **The bridge:** each theorem carries a shared id (e.g. `complex.norm.mul`,
  `quaternion.noncomm`) recorded in [`lean/THEOREM_MAP.md`](../lean/THEOREM_MAP.md) —
  **9 ids (5 complex + 4 quaternion), all proved and witnessed**. CI
  (`.github/workflows/formalization.yml`) runs `lake build`, the witness tests, and a consistency
  gate that fails if any Lean id lacks a Rust witness or a manifest row.
- **Model fidelity:** the Lean carriers are the standard mathematical models of the crate's own
  types. **ℂ** (Mathlib `Complex`) is a field with an involutive, multiplicative conjugation whose
  squared norm is multiplicative — matching the crate's `Complex` type. **ℍ[ℝ]** (Mathlib
  `Quaternion ℝ`) is a non-commutative division ring with an order-reversing (antihomomorphic)
  conjugation and a multiplicative squared norm, and `quaternion.noncomm` pins the defining
  non-commutativity via the Hamilton relations `i·j = k`, `j·i = -k` — matching the crate's
  `Quaternion` product. The L2 witnesses check these on the concrete `Complex<f64>` /
  `Quaternion<f64>`.

## How to check

```bash
# Lean proofs (from lean/): full project build (pulls Mathlib v4.15.0)
lake build

# A single Complex file — Mathlib must be on the path, so run it through lake's env
lake env lean DeepCausalityFormal/Complex/Complex.lean
lake env lean DeepCausalityFormal/Complex/Quaternion.lean

# Rust witnesses (one #[test] per theorem id)
cargo test -p deep_causality_num_complex --test mod formalization_lean

# Whole workspace (much faster than cargo across all crates)
bazel test //...
```

## Verified correct as documented

| Mechanism (id) | Reference | Status |
|---|---|---|
| `complex.field.mul_inv` — `z ≠ 0 → z * z⁻¹ = 1` (ℂ is a field) | Mathlib `Complex` (`Analysis.Complex.Basic`) | proved & witnessed |
| `complex.conj.involutive` — `conj (conj z) = z` | Mathlib `Complex` (`Analysis.Complex.Basic`) | proved & witnessed |
| `complex.conj.mul` — `conj (z * w) = conj z * conj w` | Mathlib `Complex` (`Analysis.Complex.Basic`) | proved & witnessed |
| `complex.norm_sq.mul` — `normSq (z * w) = normSq z * normSq w` | Mathlib `Complex` (`Analysis.Complex.Basic`) | proved & witnessed |
| `complex.norm.mul` — `‖z * w‖ = ‖z‖ * ‖w‖` | Mathlib `Complex` (`Analysis.Complex.Basic`) | proved & witnessed |
| `quaternion.division_ring.mul_inv` — `q ≠ 0 → q * q⁻¹ = 1` (ℍ is a division ring) | Mathlib `Quaternion ℝ` (`Algebra.Quaternion`, `Analysis.Quaternion`) | proved & witnessed |
| `quaternion.norm_sq.mul` — `normSq (q * p) = normSq q * normSq p` | Mathlib `Quaternion ℝ` (`Algebra.Quaternion`, `Analysis.Quaternion`) | proved & witnessed |
| `quaternion.conj.mul` — `star (q * p) = star p * star q` (order reverses) | Mathlib `Quaternion ℝ` (`Algebra.Quaternion`, `Analysis.Quaternion`) | proved & witnessed |
| `quaternion.noncomm` — `∃ q p, q * p ≠ p * q`; the Hamilton units give `i·j = k`, `j·i = -k` | Mathlib `Quaternion ℝ` (`Algebra.Quaternion`, `Analysis.Quaternion`) | proved & witnessed |

## Outstanding issues

1. **Octonions are out of L1 scope, covered by Rust tests only.** The crate ships an octonion type
   (`src/complex/octonion_number/`) with its own test suite (`tests/complex/octonion_number/`), but
   it has **no Lean theorem**: octonions are non-associative and absent from Mathlib, so they are
   intentionally excluded from the formalized layer (documented in both Lean file headers). Their
   correctness rests on the example-based Rust tests, not on a machine-checked proof.
2. **Laws are proved on the canonical Mathlib carrier, not on the Rust type itself.** L1 states the
   algebra laws over Mathlib's ℂ / ℍ[ℝ]; the bridge to the crate's `Complex<f64>` / `Quaternion<f64>`
   is the L2 witness tests at representative inputs (with epsilon tolerance for float rounding), not a Lean-level identification of the two carriers.
