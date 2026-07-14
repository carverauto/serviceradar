/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{MinkowskiSpacetime, SpaceTemporalInterval, TimeScale};

impl SpaceTemporalInterval for MinkowskiSpacetime {
    fn time(&self) -> f64 {
        // Convert time to seconds based on time_scale
        // SpaceTemporalInterval trait contract requires time in seconds
        match self.time_scale {
            TimeScale::Nanoseconds => self.t / 1_000_000_000.0,
            TimeScale::Microseconds => self.t / 1_000_000.0,
            TimeScale::Millisecond => self.t / 1_000.0,
            TimeScale::Second => self.t,
            TimeScale::Minute => self.t * 60.0,
            TimeScale::Hour => self.t * 3_600.0,
            TimeScale::Day => self.t * 86_400.0,
            TimeScale::Week => self.t * 604_800.0,
            TimeScale::Month => self.t * 2_629_746.0, // Average month (365.25 days / 12)
            TimeScale::Quarter => self.t * 7_889_238.0, // 3 months
            TimeScale::Year => self.t * 31_556_952.0, // Average year (365.25 days)
            // For non-physical time scales, return raw value
            TimeScale::NoScale | TimeScale::Steps | TimeScale::Symbolic => self.t,
        }
    }
    fn position(&self) -> [f64; 3] {
        [self.x, self.y, self.z]
    }
    // No need to override `interval_squared()` unless you want a custom metric for curved spacetime
}
