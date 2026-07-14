//! Precomputed basepoint tables for accelerating fixed-base scalar multiplication.

#![cfg(feature = "basepoint-table")]
#![allow(clippy::cast_possible_truncation, clippy::needless_range_loop)]

#[cfg(not(any(feature = "critical-section", feature = "std")))]
compile_error!("`basepoint-table` feature requires either `critical-section` or `std`");

use crate::point::LookupTable;
use group::Group;
use subtle::ConditionallySelectable;
use {core::ops::Deref, ff::PrimeField};

#[cfg(feature = "critical-section")]
use once_cell::sync::Lazy as LazyLock;
#[cfg(all(feature = "std", not(feature = "critical-section")))]
use std::sync::LazyLock;

/// Precomputed lookup table of multiples of a base point, a.k.a. generator.
///
/// This type leverages lazy computation, and requires one of the following crate features to be
/// enabled in order to work:
/// - `std`: leverages `std::sync::LazyLock`
/// - `critical-section`: leverages `once_cell::sync::Lazy` via the `critical-section` crate,
///   enabling the feature to be used in `no_std` contexts.
#[derive(Debug)]
pub struct BasepointTable<Point, const N: usize> {
    tables: LazyLock<[LookupTable<Point>; N]>,
}

impl<Point, const N: usize> BasepointTable<Point, N>
where
    Point: ConditionallySelectable + Default + Group,
{
    /// Create a new [`BasepointTable`] which is lazily initialized on first use and can be bound
    /// to a constant.
    ///
    /// Computed using the `Point`'s [`Group::generator`] as the base point.
    pub const fn new() -> Self {
        /// Inner function to initialize the table.
        fn init_table<Point, const N: usize>() -> [LookupTable<Point>; N]
        where
            Point: ConditionallySelectable + Default + Group,
        {
            let mut generator = Point::generator();
            let mut res = [LookupTable::<Point>::default(); N];

            for i in 0..N {
                res[i] = LookupTable::new(generator);
                // We are storing tables spaced by two radix steps,
                // to decrease the size of the precomputed data.
                for _ in 0..8 {
                    generator = generator.double();
                }
            }

            res
        }

        // Ensure basepoint table contains the expected number of entries for the scalar's size
        assert!(
            N as u32 == 1 + Point::Scalar::NUM_BITS / 8,
            "incorrectly sized basepoint table"
        );

        Self {
            tables: LazyLock::new(init_table),
        }
    }
}

impl<Point, const N: usize> Default for BasepointTable<Point, N>
where
    Point: ConditionallySelectable + Default + Group,
{
    fn default() -> Self {
        Self::new()
    }
}

impl<Point, const N: usize> Deref for BasepointTable<Point, N> {
    type Target = [LookupTable<Point>; N];

    #[inline]
    fn deref(&self) -> &[LookupTable<Point>; N] {
        &self.tables
    }
}
