/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # Context Types
//!
//! # Context Types: Space and Time Representations
//!
//! This module provides a robust and extensible system of spatial
//! and temporal context types for causal modeling across symbolic, physical, and hybrid domains.
//!
//! ---
//!
//! ## ⚖️ Why So Many Context Types?
//!
//! Not all causal systems operate in the same regime.
//!
//! Some are **relativistic**, others **discrete**.
//! Some use **geographic coordinates**, others rely on **symbolic logic**.
//!
//! Supporting multiple space and time types allows you to reason natively in each domain
//! without coercing your models into a single format or losing meaning through abstraction.
//!
//! ---
//!
//! ## 🧠 When to Use Which Context Type
//!
//! | **Domain** | **Time Type** | **Space Type** | **Use This When...** |
//! |--------------------------------------|------------------|---------------------------------------------|------------------------------------------------------------|
//! | Relativistic physics, MagNav | `LorentzianTime` | `MinkowskiSpacetime`, `LorentzianSpacetime` | You model causality, velocity, or lightcones |
//! | Quantum/statistical models | `EuclideanTime` | `EuclideanSpacetime` | You run simulations, QFT, or use Wick rotation |
//! | Symbolic AI, planning, rules | `SymbolicTime` | `SymbolicContext` or `SymbolicSpacetime` | You reason in logical or qualitative steps |
//! | Embedded / step-based systems | `DiscreteTime` | `EuclideanSpace`, `NedSpace` | Your systems run on ticks or control loops |
//! | Real-world navigation (MagNav, GNSS) | `LorentzianTime` | `GeoSpace`, `EcefSpace`, `NedSpace` | You use real sensors, location data, or earth-fixed frames |
//! | Robotics, attitude control | `LorentzianTime` | `QuaternionSpace` | You track orientation in 3D space |
//! | Simulation or animation engines | `DiscreteTime` | `EuclideanSpace` | You simulate systems frame-by-frame |
//! | Emergent/thermodynamic systems | `EntropicTime` | any | You care about time direction or entropy |
//! | Human-interpretable traces | `SymbolicTime` | any | You want readable timelines or explainability |
//!
//! ---
//!
//! ## 🔩 How It's Designed
//!
//! - All space types implement `Spatial<V>` and `Coordinate<V>`
//! - All time types implement `Temporal<VT>`
//! - `SpaceKind` and `TimeKind` enums allow polymorphic usage in core systems
//! - Contexts are statically typed, but composable
//!
//! This design supports:
//!
//! - Physical models (real-valued, time-aware)
//! - Symbolic models (label-driven, logic-first)
//! - Hybrid models (e.g., sensor fusion with symbolic constraints)
//!
//! ---
//!
//! ## 🧪 Example
//!
//! ```rust
//! // Assuming TimeKind, LorentzianTime, TimeScale, SpaceKind, GeoSpace exist in this context.
//! // For a real module, these would need to be defined or imported.
//!
//! // Placeholder types for the example to compile if run directly
//! #[derive(Debug)]
//! pub enum TimeScale { Seconds }
//!
//! #[derive(Debug)]
//! pub struct LorentzianTime { pub id: u32, pub scale: TimeScale, pub value: f64 }
//! impl LorentzianTime {
//!     pub fn new(id: u32, scale: TimeScale, value: f64) -> Self {
//!         LorentzianTime { id, scale, value }
//!     }
//! }
//!
//! #[derive(Debug)]
//! pub struct GeoSpace { pub id: u32, pub lat: f64, pub lon: f64, pub alt: f64 }
//! impl GeoSpace {
//!     pub fn new(id: u32, lat: f64, lon: f64, alt: f64) -> Self {
//!         GeoSpace { id, lat, lon, alt }
//!     }
//! }
//!
//! pub enum TimeKind {
//!     Lorentzian(LorentzianTime),
//!     // ... other time kinds
//! }
//!
//! impl TimeKind {
//!     pub fn id(&self) -> u32 {
//!         match self {
//!             TimeKind::Lorentzian(t) => t.id,
//!         }
//!     }
//!
//!     pub fn time_unit(&self) -> String {
//!         match self {
//!             TimeKind::Lorentzian(t) => format!("{:?}", t.scale),
//!         }
//!     }
//! }
//!
//! pub enum SpaceKind {
//!     Geo(GeoSpace),
//!     // ... other space kinds
//! }
//!
//! impl SpaceKind {
//!     pub fn dimension(&self) -> u8 {
//!         match self {
//!             SpaceKind::Geo(_) => 3, // GeoSpace typically 3D (lat, lon, alt)
//!         }
//!     }
//! }
//!
//! let t = TimeKind::Lorentzian(LorentzianTime::new(1, TimeScale::Seconds, 1.23));
//! let s = SpaceKind::Geo(GeoSpace::new(1, 48.85, 2.35, 35.0));
//!
//! println!("Time ID = {}, value = {}", t.id(), t.time_unit());
//! println!("Space dimension = {}", s.dimension());
//! ```
pub mod data;
pub mod data_uncertain;
pub mod root;
pub mod space;
pub mod space_time;
pub mod symbol;
pub mod symbol_spacetime;
pub mod time;
