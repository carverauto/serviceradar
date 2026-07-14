/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{AbelianGroup, Associative, Commutative, Distributive, Dual, Real};

// | Type | `Distributive` | `Associative` | `Commutative` | lands at |
// | :--- | :---: | :---: | :---: | :--- |
// | **Dual** | ✅ | ✅ | ✅ | `CommutativeRing` (NOT `Field`: ε is a zero divisor) |

// Marker traits — `T[ε]/(ε²)` is a quotient of the commutative ring `T[x]`, so it is
// associative, commutative, and distributive.
impl<T: Real> Associative for Dual<T> {}
impl<T: Real> Commutative for Dual<T> {}
impl<T: Real> Distributive for Dual<T> {}
impl<T: Real> AbelianGroup for Dual<T> {}

// `Dual<T>` is a module over its scalar ring `T` (scalar multiplication by `T`) — provided
// automatically by the blanket `Module` impl, since `Dual<T>` is an `AbelianGroup` with
// `Mul<T>`/`MulAssign<T>`.
//
// The blanket impls for `Ring`, `AssociativeRing`, and `CommutativeRing` apply
// automatically now that `Dual<T>` satisfies their super-traits (AbelianGroup +
// MulMonoid + the markers).
//
// `Dual<T>` deliberately does NOT implement `Field`/`RealField`: `ε` is a zero divisor
// (`ε·ε = 0`), so there is no total multiplicative inverse. Concretely, `Dual` implements
// `Div` but not `DivAssign`, so the `InvMonoid`/`Field` blankets (which require both) do
// not fire.
