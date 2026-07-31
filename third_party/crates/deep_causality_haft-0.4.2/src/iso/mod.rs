/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tier 3 isomorphism traits — natural isomorphisms between HKT witnesses.
//!
//! This module sits at the top of the three-tier isomorphism design
//! introduced by the `2026-05-20-add-iso-traits` change:
//!
//! - **Tier 1** (in `deep_causality_num::iso`): `From`/`Into`-based marker
//!   subtraits for concrete types (`GroupIso<T>`, `RingIso<T>`, ...).
//! - **Tier 2** (in `deep_causality_num::iso::witness`): witness-typed
//!   `Iso<S, T>` plus the generic `StandardIso<S, T>` blanket impl, for
//!   cross-crate concrete-type isos that the orphan rule blocks at Tier 1.
//! - **Tier 3** (here): [`NaturalIso<F, G>`] and [`NaturalIso5<F, G>`] for
//!   isomorphisms between *type constructors*. `From`/`Into` cannot apply
//!   at this level — HKT witnesses are zero-sized markers without values,
//!   so a witness-typed trait is required.

pub mod natural_iso;
pub mod natural_iso_2;
pub mod natural_iso_3;
pub mod natural_iso_4;
pub mod natural_iso_5;
pub mod test_support;

pub use natural_iso::NaturalIso;
pub use natural_iso_2::NaturalIso2;
pub use natural_iso_3::NaturalIso3;
pub use natural_iso_4::NaturalIso4;
pub use natural_iso_5::NaturalIso5;
