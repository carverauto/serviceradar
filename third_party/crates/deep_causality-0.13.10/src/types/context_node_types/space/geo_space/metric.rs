/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{GeoSpace, Metric};

// Metric (with simple haversine approximation)
impl Metric<f64> for GeoSpace {
    fn distance(&self, other: &Self) -> f64 {
        let radius = 6_371_000.0; // Earth's mean radius in meters

        let dlat = (other.lat - self.lat).to_radians();
        let dlon = (other.lon - self.lon).to_radians();

        let a = (dlat / 2.0).sin().powi(2)
            + self.lat.to_radians().cos()
                * other.lat.to_radians().cos()
                * (dlon / 2.0).sin().powi(2);

        let c = 2.0 * a.sqrt().atan2((1.0 - a).sqrt());
        let surface_distance = radius * c;
        let alt_diff = other.alt - self.alt;

        (surface_distance.powi(2) + alt_diff.powi(2)).sqrt()
    }
}
