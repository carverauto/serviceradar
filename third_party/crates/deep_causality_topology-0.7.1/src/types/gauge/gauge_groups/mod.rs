/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Gauge group implementations for Standard Model + Gravity.
//!
//! This module provides marker types for fundamental gauge groups:
//!
//! | Group         | Lie Dim | Abelian | Physics               |
//! |---------------|---------|---------|------------------------|
//! | U1            | 1       | Yes     | Electromagnetism (QED) |
//! | SU2           | 3       | No      | Weak isospin           |
//! | SU3           | 8       | No      | Strong force (QCD)     |
//! | Electroweak   | 4       | No      | SU(2)×U(1) unified     |
//! | StandardModel | 12      | No      | Full SM (except gravity)|
//! | Lorentz       | 6       | No      | General Relativity     |
//! | SE(3)         | 6       | No      | Rigid Body Motions     |

mod se3;
mod so3_1;
mod su2;
mod su2_u1;
mod su3;
mod su3_su2_u1;
mod u1;

pub use se3::SE3;
pub use so3_1::SO3_1;
pub use su2::SU2;
pub use su2_u1::SU2_U1;
pub use su3::SU3;
pub use su3_su2_u1::SU3_SU2_U1;
pub use u1::U1;
