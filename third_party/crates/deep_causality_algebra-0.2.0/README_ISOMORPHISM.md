[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# Isomorphism Traits

`deep_causality_algebra` ships a type-checked vocabulary for **isomorphisms** between algebraic structures. An iso is a bijection that preserves the relevant operations: `f(x) = y` and `g(y) = x` and `f(a + b) = f(a) + f(b)`, `f(a * b) = f(a) * f(b)`, and so on for whatever structure the two types share. Wiring this through the trait system turns "these two types are interchangeable" into a compiler-enforced guarantee. Generic code can then accept either representation without re-deriving every operation.

The design has three tiers. They scale from concrete types to type constructors.

| Tier | Module | Foundation | Iso between |
|---|---|---|---|
| **Tier 1** | `deep_causality_algebra::iso` | `From` / `Into` | Concrete types in the same crate |
| **Tier 2** | `deep_causality_algebra::iso::witness` | Witness-typed `Iso<S, T>` | Concrete types across crates (orphan-rule safe) |
| **Tier 3** | `deep_causality_haft::iso` | Witness-typed `NaturalIso<F, G>` | HKT type constructors |

Tiers 1 and 2 live in this crate. Tier 3 (`NaturalIso` through `NaturalIso5`) lives in [`deep_causality_haft`](../deep_causality_haft/README.md#natural-isomorphisms-tier-3-iso-traits).

---

## Tier 1: `From`-Based Marker Subtraits

Tier 1 builds on Rust's standard `From` / `Into` machinery. If you have bidirectional `From` impls between two types, you can opt in to the marker subtrait that matches the algebraic structure they share. Generic code parameterised over that subtrait then swaps representations transparently.

### Trait hierarchy

```text
GroupIso<T>            // Group homomorphism (preserves +)
  |- RingIso<T>        // Ring homomorphism (preserves + and *)
      |- FieldIso<T>   // Field iso (preserves +, *, and inv)

AlgebraIso<T, R>                  // Preserves scalar multiplication
  |- DivisionAlgebraIso<T, R>     // Preserves conjugation
```

All traits are empty marker subtraits. They demand nothing at the type level beyond the named structure plus bidirectional `From`. The laws (homomorphism, round-trip) are pinned by the test helpers in `iso::test_support`.

### Example: declaring an iso between two `Field`s

```rust,ignore
use deep_causality_algebra::{Field, FieldIso, GroupIso, RingIso};

// Two structurally-equivalent representations of the rationals
#[derive(Clone, PartialEq, Debug)]
struct RatA { num: i64, den: i64 }

#[derive(Clone, PartialEq, Debug)]
struct RatB(i64, i64);

// ... (assume both impl `Field` and bidirectional `From`)

impl GroupIso<RatB> for RatA {}
impl RingIso<RatB> for RatA {}
impl FieldIso<RatB> for RatA {}
```

Once declared, generic code can write `where A: FieldIso<B>` and accept either side as the canonical representation. The reverse impl is symmetric.

### Verifying the laws

`deep_causality_algebra::iso::test_support` exports six helpers, one per marker subtrait. Each exercises only that subtrait's own contribution to the homomorphism chain.

| Helper | Law checked |
|---|---|
| `assert_iso_from_round_trip(s, t)` | Round-trip in both directions (independent inputs) |
| `assert_group_iso_from_law(a, b)` | `T::from(a + b) == T::from(a) + T::from(b)` |
| `assert_ring_iso_from_laws(a, b)` | Addition and multiplication homomorphism |
| `assert_field_iso_from_laws(a)` | Multiplicative-inverse preservation (field-specific only) |
| `assert_algebra_iso_from_law(a, r)` | Scalar-multiplication preservation |
| `assert_division_algebra_iso_from_law(a)` | Conjugation preservation |

Each helper takes owned representative inputs. To verify a deeper marker like `FieldIso<T>`, compose the parent helpers; they cover the inherited laws.

```rust,ignore
use deep_causality_algebra::iso::test_support::*;

#[test]
fn rat_a_b_is_a_field_iso() {
    assert_iso_from_round_trip::<RatA, RatB>(RatA::new(3, 4), RatB(3, 4));
    assert_group_iso_from_law::<RatA, RatB>(RatA::new(1, 2), RatA::new(1, 3));
    assert_ring_iso_from_laws::<RatA, RatB>(RatA::new(1, 2), RatA::new(1, 3));
    assert_field_iso_from_laws::<RatA, RatB>(RatA::new(2, 5));
}
```

### When Tier 1 doesn't fit

The orphan rule blocks bidirectional `From` between types whose crates have an asymmetric dependency. The downstream crate can impl `From<Upstream>`, but not the reverse. For those cases, drop down to Tier 2.

---

## Tier 2: Witness-Typed `Iso<S, T>`

Tier 2 introduces a **witness type**: a separate marker (typically zero-sized) that carries the iso impl. The trait `Iso<S, T>` is parameterised over both source and target, with `to_target` / `to_source` methods. Because the impl lives on the witness rather than on `S` or `T`, the orphan rule no longer applies. Any crate can ship a witness for any type pair.

### Method names

Why `to_target` / `to_source`? Two reasons. `forward` / `backward` clashes with the EPP temporal vocabulary used elsewhere in this codebase. `from` / `into` clashes with std semantics. The chosen pair sidesteps both.

### Trait hierarchy

The shape mirrors Tier 1, lifted to witness types:

```text
Iso<S, T>                              // Base: to_target + to_source
  |- GroupIso<S, T>                    // Where S, T : Group
  |   |- RingIso<S, T>                 // Where S, T : Ring
  |       |- FieldIso<S, T>            // Where S, T : Field
  |- AlgebraIso<S, T, R>               // Where S, T : Algebra<R>
      |- DivisionAlgebraIso<S, T, R>   // Where S, T : DivisionAlgebra<R>
```

All Tier 2 traits live under `deep_causality_algebra::iso::witness`. They are not re-exported at `deep_causality_algebra::iso::*`; consumers disambiguate Tier 1 vs Tier 2 by module path.

### `StandardIso<S, T>`: automatic blanket impl

For the common case where bidirectional `From` already exists (and you simply have no place to land a Tier 1 marker), `StandardIso<S, T>` is a zero-sized witness with blanket impls for every Tier 2 marker. You get the full subtrait chain for free.

```rust,ignore
use deep_causality_algebra::iso::witness::{Iso, StandardIso};

// Bidirectional `From` already exists:
//   impl From<FloatWrap> for f64 { ... }
//   impl From<f64> for FloatWrap { ... }

let t: f64 = StandardIso::<FloatWrap, f64>::to_target(FloatWrap(2.5));
let s: FloatWrap = StandardIso::<FloatWrap, f64>::to_source(2.5);
```

`StandardIso<S, T>` auto-derives every marker subtrait it has the bounds for. Declare your types as `Group`, `Ring`, `Field`, etc., and `StandardIso<S, T>` immediately satisfies `GroupIso<S, T>`, `RingIso<S, T>`, `FieldIso<S, T>` without any extra `impl` blocks.

### Example: manual witness

When `StandardIso` doesn't apply (no bidirectional `From`, or you want a domain-specific name), declare your own witness:

```rust,ignore
use deep_causality_algebra::iso::witness::{Iso, GroupIso, RingIso, FieldIso};

struct MyDomainIso;

impl Iso<TypeA, TypeB> for MyDomainIso {
    fn to_target(s: TypeA) -> TypeB { /* ... */ }
    fn to_source(t: TypeB) -> TypeA { /* ... */ }
}

impl GroupIso<TypeA, TypeB> for MyDomainIso {}
impl RingIso<TypeA, TypeB> for MyDomainIso {}
impl FieldIso<TypeA, TypeB> for MyDomainIso {}
```

### Verifying the laws

`deep_causality_algebra::iso::witness::test_support` mirrors the Tier 1 helpers, parameterised over the witness:

| Helper | Law checked |
|---|---|
| `assert_witness_iso_round_trip::<W>(s, t)` | Round-trip in both directions (independent inputs) |
| `assert_witness_group_iso_law::<W>(a, b)` | Addition homomorphism |
| `assert_witness_ring_iso_laws::<W>(a, b)` | Addition and multiplication homomorphism |
| `assert_witness_field_iso_laws::<W>(a)` | Multiplicative-inverse preservation |
| `assert_witness_algebra_iso_law::<W>(a, r)` | Scalar-multiplication preservation |
| `assert_witness_division_algebra_iso_law::<W>(a)` | Conjugation preservation |

The round-trip helper takes an independent `(s, t)` pair on purpose. Deriving `t` from `s` via `to_target` only exercises the image of `to_target`; witnesses where `to_source` is many-to-one (i.e. `T` values outside that image collapse to a single `S`) would slip through undetected. Pass two genuinely independent inputs.

```rust,ignore
use deep_causality_algebra::iso::witness::test_support::*;
use deep_causality_algebra::iso::witness::StandardIso;

#[test]
fn float_wrap_f64_is_a_field_iso() {
    type W = StandardIso<FloatWrap, f64>;

    assert_witness_iso_round_trip::<W, FloatWrap, f64>(FloatWrap(2.5), 2.5);
    assert_witness_group_iso_law::<W, FloatWrap, f64>(FloatWrap(1.0), FloatWrap(2.0));
    assert_witness_ring_iso_laws::<W, FloatWrap, f64>(FloatWrap(1.5), FloatWrap(2.5));
    assert_witness_field_iso_laws::<W, FloatWrap, f64>(FloatWrap(3.0));
}
```

---

## Tier 1 vs Tier 2: When to Use Which

| Situation | Use |
|---|---|
| Both types live in your crate (or you control the upstream) | **Tier 1**. Cleaner; reuses standard `From` |
| Cross-crate types with asymmetric dependency (orphan rule blocks reverse `From`) | **Tier 2** witness in the dependent crate |
| You want a domain-specific name for the iso (`PropEffectProcessIso`, etc.) | **Tier 2** named witness |

A common pattern is mixed-tier. Forward direction as a Tier 1 `From` impl (where the orphan rule allows it), reverse direction as a Tier 2 `Iso` impl on a witness in the dependent crate. This is the recommended pattern for `CausalTensor<F>` <-> `CsrMatrix<F>` (sparse-tensor representation), where `deep_causality_sparse` depends on `deep_causality_tensor` but not vice versa.

---

## Tier 3: `NaturalIso<F, G>` Between HKT Witnesses

Tier 3 lifts the iso vocabulary from concrete types to *type constructors*. It lives in [`deep_causality_haft`](../deep_causality_haft/README.md#natural-isomorphisms-tier-3-iso-traits) (the crate that owns the HKT machinery) but is included here for completeness.

### Why a separate tier

Tiers 1 and 2 both bottom out in some form of value-level conversion. `From::from` consumes an `S` and returns a `T`; `Iso::to_target` does the same on a witness. Both presume that values exist. At the HKT level, that presumption fails. An HKT witness like `OptionWitness` or `VecWitness` is a zero-sized marker with no instances; you cannot apply `From` to something that has no values. The conversion has to operate on `F::Type<T>` (e.g. `Option<T>`) for every `T`, which is a different shape of trait.

### Trait family

```text
NaturalIso<F, G>                       // F: HKT             (1 free type param)
NaturalIso2<F, G>                      // F: HKT2Unbound     (2 free type params)
NaturalIso3<F, G>                      // F: HKT3Unbound     (3 free type params)
NaturalIso4<F, G>                      // F: HKT4Unbound     (4 free type params)
NaturalIso5<F, G>                      // F: HKT5Unbound     (5 free type params)
```

Each carries `to_target` and `to_source` with the appropriate number of free generics. `NaturalIso5` is the natural fit for the propagating-effect carrier `<V, S, C, E, L>`.

### Laws

Every implementer must satisfy two laws:

1. **Round-trip per type parameter**, in both directions independently:
   * `to_source(to_target(fa)) == fa`
   * `to_target(to_source(ga)) == ga`
2. **Naturality** with respect to `fmap`: `to_target(F::fmap(fa, h)) == G::fmap(to_target(fa), h)` for any function `h: T -> U`.

Naturality is the law that distinguishes a *structure-preserving* iso from a mere bijection of carriers. It means the iso commutes with every later transformation; once you've crossed over to `G`, mapping behaves the same as it would have on `F`.

### Example: `Option` and a structurally-equivalent twin

```rust,ignore
use deep_causality_haft::{HKT, NaturalIso, NoConstraint, OptionWitness, Satisfies};

#[derive(Debug, Clone, PartialEq)]
enum MyOption<T> { MySome(T), MyNone }

struct MyOptionWitness;
impl HKT for MyOptionWitness {
    type Constraint = NoConstraint;
    type Type<T> = MyOption<T>;
}

struct OptionMyOptionIso;
impl NaturalIso<OptionWitness, MyOptionWitness> for OptionMyOptionIso {
    fn to_target<T>(fa: Option<T>) -> MyOption<T>
    where T: Satisfies<NoConstraint> + Satisfies<NoConstraint> {
        match fa { Some(t) => MyOption::MySome(t), None => MyOption::MyNone }
    }
    fn to_source<T>(ga: MyOption<T>) -> Option<T>
    where T: Satisfies<NoConstraint> + Satisfies<NoConstraint> {
        match ga { MyOption::MySome(t) => Some(t), MyOption::MyNone => None }
    }
}
```

### Verifying the laws

`deep_causality_haft::iso::test_support` provides two helpers:

| Helper | Law checked |
|---|---|
| `assert_natural_iso_round_trip::<W, F, G, T>(fa, ga)` | Round-trip in both directions (independent inputs) |
| `assert_natural_iso_naturality::<W, F, G, A, B, Func>(fa, h)` | Naturality against a caller-supplied function `h` |

The round-trip helper inherits the same independent-input discipline used at Tiers 1 and 2; pass an `fa: F::Type<T>` and an `ga: G::Type<T>` that are not derived from each other.

```rust,ignore
use deep_causality_haft::iso::test_support::*;

#[test]
fn option_my_option_iso_is_natural() {
    assert_natural_iso_round_trip::<OptionMyOptionIso, OptionWitness, MyOptionWitness, i32>(
        Some(42),
        MyOption::MySome(42),
    );
    assert_natural_iso_naturality::<OptionMyOptionIso, OptionWitness, MyOptionWitness, i32, i32, _>(
        Some(3),
        |x: i32| x * 2,
    );
}
```

### Use cases

* **Carrier-shape refactors**. Two representations of the same conceptual container (e.g. `Option<T>` vs a domain-specific `Maybe<T>` newtype) become interchangeable without re-deriving each `Functor`/`Monad` impl.
* **Effect-system migration**. `NaturalIso5` is the natural fit for swapping the propagating-effect carrier `<V, S, C, E, L>` with an equivalent shape (a logging-only specialisation, for instance); naturality guarantees any pipeline written against the old carrier still composes against the new one.
* **Theory-side equivalences**. "These two functors are the same" becomes a checked law rather than a comment.

For the full trait declarations, see the [`deep_causality_haft` README section](../deep_causality_haft/README.md#natural-isomorphisms-tier-3-iso-traits).

---

## Three-Tier Summary

```text
+-----------------------------------------------------------------------------+
| Tier 1: deep_causality_algebra::iso                                             |
|         GroupIso<T> -> RingIso<T> -> FieldIso<T>                            |
|         AlgebraIso<T, R> -> DivisionAlgebraIso<T, R>                        |
|         Bidirectional `From` + empty marker subtraits.                      |
|         Use when both types live in (or are controllable from) your crate.  |
+-----------------------------------------------------------------------------+
| Tier 2: deep_causality_algebra::iso::witness                                    |
|         Iso<S, T> with to_target / to_source on a witness type.             |
|         GroupIso<S, T> -> RingIso<S, T> -> FieldIso<S, T>                   |
|         AlgebraIso<S, T, R> -> DivisionAlgebraIso<S, T, R>                  |
|         StandardIso<S, T> provides blanket impls when bidir `From` exists.  |
|         Use for cross-crate isos that the orphan rule blocks.               |
+-----------------------------------------------------------------------------+
| Tier 3: deep_causality_haft::iso                                            |
|         NaturalIso<F, G> through NaturalIso5<F, G>.                         |
|         Natural isomorphisms between HKT witnesses, respecting `fmap`.      |
|         Use to swap type-constructor shapes (Option <-> alternative, etc.). |
+-----------------------------------------------------------------------------+
```

---

## Module reference

* **Tier 1 traits**: [`src/iso/group_iso.rs`](src/iso/group_iso.rs), [`ring_iso.rs`](src/iso/ring_iso.rs), [`field_iso.rs`](src/iso/field_iso.rs), [`algebra_iso.rs`](src/iso/algebra_iso.rs), [`division_algebra_iso.rs`](src/iso/division_algebra_iso.rs)
* **Tier 1 helpers**: [`src/iso/test_support.rs`](src/iso/test_support.rs)
* **Tier 2 traits**: [`src/iso/witness/iso.rs`](src/iso/witness/iso.rs), [`group_iso.rs`](src/iso/witness/group_iso.rs), [`ring_iso.rs`](src/iso/witness/ring_iso.rs), [`field_iso.rs`](src/iso/witness/field_iso.rs), [`algebra_iso.rs`](src/iso/witness/algebra_iso.rs), [`division_algebra_iso.rs`](src/iso/witness/division_algebra_iso.rs)
* **Tier 2 generic witness**: [`src/iso/witness/standard.rs`](src/iso/witness/standard.rs)
* **Tier 2 helpers**: [`src/iso/witness/test_support.rs`](src/iso/witness/test_support.rs)
* **Tier 3** (HKT): [`deep_causality_haft/src/iso/`](../deep_causality_haft/src/iso/)
