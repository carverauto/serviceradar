/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod adjustable;
mod coordinate;
mod display;
mod getters;
mod identifiable;
mod metric;
mod spatial;

/// A non-Euclidean spatial context based on geodetic coordinates (WGS84).
///
/// `GeoSpace` represents a geographic location on Earth using the [WGS84](https://en.wikipedia.org/wiki/World_Geodetic_System) standard.
/// It stores **latitude**, **longitude**, and **altitude**, and is commonly used in systems that need to model real-world positions,
/// such as navigation, mapping, remote sensing, and sensor fusion applications.
///
/// Unlike Euclidean coordinates, geodetic coordinates model the Earth's surface as a **curved ellipsoid** rather than a flat plane.
/// This makes `GeoSpace` a simple yet powerful non-Euclidean spatial representation that integrates naturally with GPS and global datasets.
///
/// # Fields
/// - `id`: A unique numeric identifier for the location (e.g., sensor ID, region ID)
/// - `lat`: Latitude in degrees (positive north, negative south)
/// - `lon`: Longitude in degrees (positive east, negative west)
/// - `alt`: Altitude in meters above the WGS84 ellipsoid (not above sea level)
///
/// # Trait Implementations
/// This type implements:
/// - `Identifiable`
/// - `Coordinate<f64>`
/// - `Metric` using the Haversine approximation
/// - `Spatial<f64>`
/// - `Display` for human-readable output
///
/// # Common Use Cases
/// - Geographic sensor modeling (e.g., magnetometers on aircraft, buoys, satellites)
/// - Location-aware causal contexts (e.g., MagNav, remote sensing calibration)
/// - Contextualizing non-Euclidean geospatial data in DeepCausality graphs
///
/// # Example
/// ```
/// use deep_causality::*;
///
/// let g1 = GeoSpace::new(1, 52.520008, 13.404954, 34.0); // Berlin, Germany
/// let g2 = GeoSpace::new(2, 48.856613, 2.352222, 35.0);   // Paris, France
///
/// println!("{}", g1);
///
/// let distance = g1.distance(&g2);
/// println!("Distance (approx): {:.2} km", distance / 1000.0);
/// ```
///
/// # Output
/// ```text
/// GeoSpace(id="1", lat=52.520008, lon=13.404954, alt=34m)
/// Distance (approx): 878.84 km
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct GeoSpace {
    /// Unique numeric ID for the spatial context
    id: u64,
    /// Latitude in decimal degrees (positive north, negative south)
    lat: f64,
    /// Longitude in decimal degrees (positive east, negative west)
    lon: f64,
    /// Altitude in meters above the WGS84 ellipsoid
    alt: f64,
}

impl GeoSpace {
    pub fn new(id: u64, lat: f64, lon: f64, alt: f64) -> Self {
        Self { id, lat, lon, alt }
    }
}
