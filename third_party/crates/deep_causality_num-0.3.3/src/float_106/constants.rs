/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Float106;

// =============================================================================
// High-Precision Constants
// =============================================================================

impl Float106 {
    /// π to ~31 decimal digits
    /// 3.14159265358979323846264338327950288...
    pub const PI: Self = Self {
        hi: core::f64::consts::PI,
        lo: 1.2246467991473532e-16,
    };

    /// 2π to ~31 decimal digits
    pub const TWO_PI: Self = Self {
        hi: core::f64::consts::TAU,
        lo: 2.4492935982947064e-16,
    };

    /// π/2 to ~31 decimal digits
    pub const FRAC_PI_2: Self = Self {
        hi: core::f64::consts::FRAC_PI_2,
        lo: 6.123233995736766e-17,
    };

    /// π/4 to ~31 decimal digits
    pub const FRAC_PI_4: Self = Self {
        hi: core::f64::consts::FRAC_PI_4,
        lo: 3.061616997868383e-17,
    };

    /// e (Euler's number) to ~31 decimal digits
    /// 2.71828182845904523536028747135266249...
    pub const E: Self = Self {
        hi: core::f64::consts::E,
        lo: 1.4456468917292502e-16,
    };

    /// ln(2) to ~31 decimal digits
    pub const LN_2: Self = Self {
        hi: core::f64::consts::LN_2,
        lo: 2.3190468138462996e-17,
    };

    /// ln(10) to ~31 decimal digits
    pub const LN_10: Self = Self {
        hi: core::f64::consts::LN_10,
        lo: -2.1707562233822494e-16,
    };

    /// Machine epsilon for DoubleFloat (~2^-106)
    pub const EPSILON: Self = Self {
        hi: 4.930380657631324e-32,
        lo: 0.0,
    };
}
