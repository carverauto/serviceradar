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

    /// π/16 to ~31 decimal digits (an exact 2⁻⁴ scaling of `PI`).
    pub(crate) const FRAC_PI_16: Self = Self {
        hi: 0.19634954084936207,
        lo: 7.654042494670958e-18,
    };

    /// sin(k·π/16) for k = 0..=16, used by the table-based `sin_cos` fast
    /// path. Values computed with mpmath at 50 decimal digits and split into
    /// hi/lo double-double components; the k = 16 entry (sin π) is exactly 0.
    pub(crate) const SIN_K_PI_16: [Self; 17] = [
        Self { hi: 0.0, lo: 0.0 },
        Self {
            hi: 0.19509032201612828,
            lo: -7.991079068461731e-18,
        },
        Self {
            hi: 0.3826834323650898,
            lo: -1.0050772696461588e-17,
        },
        Self {
            hi: 0.5555702330196022,
            lo: 4.709410940561677e-17,
        },
        Self {
            hi: core::f64::consts::FRAC_1_SQRT_2,
            lo: -4.833646656726457e-17,
        },
        Self {
            hi: 0.8314696123025452,
            lo: 1.4073856984728024e-18,
        },
        Self {
            hi: 0.9238795325112867,
            lo: 1.7645047084336677e-17,
        },
        Self {
            hi: 0.9807852804032304,
            lo: 1.8546939997825006e-17,
        },
        Self { hi: 1.0, lo: 0.0 },
        Self {
            hi: 0.9807852804032304,
            lo: 1.8546939997825006e-17,
        },
        Self {
            hi: 0.9238795325112867,
            lo: 1.7645047084336677e-17,
        },
        Self {
            hi: 0.8314696123025452,
            lo: 1.4073856984728024e-18,
        },
        Self {
            hi: core::f64::consts::FRAC_1_SQRT_2,
            lo: -4.833646656726457e-17,
        },
        Self {
            hi: 0.5555702330196022,
            lo: 4.709410940561677e-17,
        },
        Self {
            hi: 0.3826834323650898,
            lo: -1.0050772696461588e-17,
        },
        Self {
            hi: 0.19509032201612828,
            lo: -7.991079068461731e-18,
        },
        Self { hi: 0.0, lo: 0.0 },
    ];

    /// cos(k·π/16) for k = 0..=16, companion to `SIN_K_PI_16`. The k = 8
    /// entry (cos π/2) is exactly 0.
    pub(crate) const COS_K_PI_16: [Self; 17] = [
        Self { hi: 1.0, lo: 0.0 },
        Self {
            hi: 0.9807852804032304,
            lo: 1.8546939997825006e-17,
        },
        Self {
            hi: 0.9238795325112867,
            lo: 1.7645047084336677e-17,
        },
        Self {
            hi: 0.8314696123025452,
            lo: 1.4073856984728024e-18,
        },
        Self {
            hi: core::f64::consts::FRAC_1_SQRT_2,
            lo: -4.833646656726457e-17,
        },
        Self {
            hi: 0.5555702330196022,
            lo: 4.709410940561677e-17,
        },
        Self {
            hi: 0.3826834323650898,
            lo: -1.0050772696461588e-17,
        },
        Self {
            hi: 0.19509032201612828,
            lo: -7.991079068461731e-18,
        },
        Self { hi: 0.0, lo: 0.0 },
        Self {
            hi: -0.19509032201612828,
            lo: 7.991079068461731e-18,
        },
        Self {
            hi: -0.3826834323650898,
            lo: 1.0050772696461588e-17,
        },
        Self {
            hi: -0.5555702330196022,
            lo: -4.709410940561677e-17,
        },
        Self {
            hi: -core::f64::consts::FRAC_1_SQRT_2,
            lo: 4.833646656726457e-17,
        },
        Self {
            hi: -0.8314696123025452,
            lo: -1.4073856984728024e-18,
        },
        Self {
            hi: -0.9238795325112867,
            lo: -1.7645047084336677e-17,
        },
        Self {
            hi: -0.9807852804032304,
            lo: -1.8546939997825006e-17,
        },
        Self { hi: -1.0, lo: 0.0 },
    ];
}
