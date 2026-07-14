//! Precomputed lookup tables which allow multiples of an elliptic curve point to be selected in
//! constant time.

#![cfg(feature = "arithmetic")]

use group::Group;
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq};

/// Internal constant for the number of entries in a [`LookupTable`].
///
/// This is defined separately from `LookupTable::SIZE` because we can't use an inherent associated
/// constant of a generic type in generic contexts, and this doesn't vary depending on `Point`.
const LUT_SIZE: usize = 8;

/// Lookup table containing precomputed values `[p, 2p, 3p, ..., 8p]`
#[derive(Clone, Copy, Debug, Default)]
pub struct LookupTable<Point> {
    points: [Point; LUT_SIZE],
}

impl<Point> LookupTable<Point>
where
    Point: ConditionallySelectable + Group,
{
    /// Number of entries in the lookup table.
    pub const SIZE: usize = LUT_SIZE;

    /// Compute a new lookup table from the given point.
    pub fn new(p: Point) -> Self {
        let mut points = [p; LUT_SIZE];

        for j in 0..(LUT_SIZE - 1) {
            points[j + 1] = p + points[j];
        }

        Self { points }
    }

    /// Given `-8 <= x <= 8`, returns `x * p` in constant time.
    #[allow(clippy::cast_sign_loss)]
    pub fn select(&self, x: i8) -> Point {
        debug_assert!((-8..=8).contains(&x));

        // Compute xabs = |x|
        let xmask = x >> 7;
        let xabs = (x + xmask) ^ xmask;

        // Get an array element in constant time
        let mut t = Point::identity();

        #[allow(clippy::cast_possible_truncation)]
        for j in 1..(LUT_SIZE + 1) {
            let c = (xabs as u8).ct_eq(&(j as u8));
            t.conditional_assign(&self.points[j - 1], c);
        }
        // Now t == |x| * p.

        let neg_mask = Choice::from((xmask & 1) as u8);
        t.conditional_assign(&-t, neg_mask);
        // Now t == x * p.

        t
    }
}
