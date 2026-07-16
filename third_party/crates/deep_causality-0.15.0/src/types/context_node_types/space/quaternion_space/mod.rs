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

/// A spatial context representing 3D orientation using unit quaternions.
///
/// `QuaternionSpace` models the rotational state of an object in 3D space
/// using a quaternion `[w, x, y, z]`, which encodes a rotation around an axis
/// without the risk of gimbal lock. This is especially useful in applications
/// that require smooth, continuous rotation or orientation tracking.
///
/// The quaternion should be normalized (unit length) to represent a valid rotation.
///
/// # Fields
/// - `id`: A unique identifier for the orientation context (e.g., sensor ID)
/// - `quat`: A 4-element array representing the quaternion in `[w, x, y, z]` order:
///   - `w`: scalar component (cos(θ/2))
///   - `x, y, z`: vector part representing the axis of rotation (unit vector scaled by sin(θ/2))
///
///
/// # Coordinate Index Mapping
/// When used with the `Coordinate` trait, the following index mapping applies:
/// - `0 => w`
/// - `1 => x`
/// - `2 => y`
/// - `3 => z`
///
/// # Background
/// Quaternions are an extension of complex numbers used to represent
/// rotations in three-dimensional space. Unlike Euler angles or axis-angle representations,
/// quaternions avoid singularities (gimbal lock), allow smooth interpolation (slerp),
/// and are computationally stable for tracking cumulative orientation over time.
///
/// Quaternions are commonly used in:
/// - Aerospace and inertial navigation (IMUs, magnetometers, gyroscopes)
/// - Robotics and drone control
/// - Virtual and augmented reality (VR/AR head tracking)
/// - 3D game engines and computer graphics
///
/// # Example
/// ```
/// use deep_causality::*;
///
/// // Represents a 90-degree rotation around the Z-axis
/// let q = QuaternionSpace::new(1, std::f64::consts::FRAC_1_SQRT_2, 0.0, 0.0, std::f64::consts::FRAC_1_SQRT_2);
///
/// println!("{}", q);
/// assert_eq!(q.dimension(), 4);
/// assert!((q.distance(&q) - 0.0).abs() < 1e-9);
/// ```
///
/// # Notes
/// - All components are assumed to be in floating-point units (unitless)
/// - Input quaternions should be normalized before use (||q|| = 1.0)
/// - For multi-sensor fusion, make sure quaternions follow the same handedness convention (e.g., right-handed)
#[derive(Debug, Clone, PartialEq)]
pub struct QuaternionSpace {
    /// Unique identifier for this orientation context
    id: u64,
    /// The quaternion representing the rotation in [w, x, y, z] order
    w: f64,
    x: f64,
    y: f64,
    z: f64,
}

impl QuaternionSpace {
    pub fn new(id: u64, w: f64, x: f64, y: f64, z: f64) -> Self {
        Self { id, w, x, y, z }
    }
}
