//! Karatsuba multiplication:
//!
//! This is a method which reduces the complexity of multiplication from O(n^2) to O(n^1.585).
//! For smaller numbers, it is best to stick to schoolbook multiplication, taking advantage
//! of better cache locality and avoiding recursion.
//!
//! In general, we consider the multiplication of two numbers of an equal size, `n` bits.
//! Setting b = 2^(n/2), then we can decompose the values:
//!   x•y = (x0 + x1•b)(y0 + y1•b)
//!
//! This equation is equivalent to a linear combination of three products of size `n/2`, which
//! may each be reduced by applying the same optimization.
//! Setting z0 = x0y0, z1 = (x0 + x1)(y1 + y0), z2 = x1y1:
//!   x•y = z0 + (z1 - z0 - z2)•b + z2•b^2
//!
//! Considering each sub-product as a tuple of integers `(lo, hi)`, the product is calculated as
//! follows (with appropriate carries):
//!   [z0.0, z0.1 + z1.0 - z0.0 - z2.0, z1.1 - z0.1 + z2.0 - z2.1, z2.1]
//!
//! Squaring uses a similar optimization, breaking the operation down into two half-size
//! squarings and a half-size multiplication:
//!
//!   x^2 = (x0 + x1•b)^2 = x0^2 + 2x0x1•b + (x1•b)^2
//!
//! The wrapping implementations of these methods employ variations on these algorithms. Because
//! the fixed-size implementations for power-of-two `Uint` sizes are optimized well by the
//! compiler, the dynamic implementations break down large multiplications into calls to these
//! optimized methods.

use super::schoolbook;
use crate::{Limb, Uint, UintRef};

pub const MIN_STARTING_LIMBS: usize = 16;

/// Compute a wide multiplication result for fixed-size arguments. Common power-of-two
/// limb counts are implemented explicitly and used as a basis for general multiplication.
///
/// The limb counts of `lhs` and `rhs` must be `LHS` and `RHS` respectively.
pub const fn widening_mul_fixed<const LHS: usize, const RHS: usize>(
    lhs: &UintRef,
    rhs: &UintRef,
) -> (Uint<LHS>, Uint<RHS>) {
    debug_assert!(lhs.nlimbs() == LHS && rhs.nlimbs() == RHS);

    // Perform the core Karatsuba multiplication for fixed-size arguments, returning
    // a wide result. The size of the arguments is halved on each recursion.
    #[inline]
    const fn reduce<const LHS: usize, const RHS: usize, const HALF: usize>(
        x: &UintRef,
        y: &UintRef,
    ) -> (Uint<LHS>, Uint<RHS>) {
        assert!(LHS <= RHS && LHS == HALF * 2);
        let (x0, x1) = x.split_at(HALF);
        let (y0, y1) = y.split_at(HALF);

        // Calculate z0 = x0•y0
        let z0 = widening_mul_fixed(x0, y0);
        // Calculate z2 = x1•y1
        let z2 = widening_mul_fixed(x1, y1);

        // Calculate z1 = (x0 + x1)(y0 + y1)
        let (mut l0, mut l1) = (Uint::<HALF>::ZERO, Uint::<HALF>::ZERO);
        let (mut l0c, mut l1c) = (Limb::ZERO, Limb::ZERO);
        let mut i = 0;
        while i < HALF {
            (l0.limbs[i], l0c) = x0.0[i].carrying_add(x1.0[i], l0c);
            (l1.limbs[i], l1c) = y0.0[i].carrying_add(y1.0[i], l1c);
            i += 1;
        }
        let z1 = widening_mul_fixed(l0.as_uint_ref(), l1.as_uint_ref());

        // Middle terms of the result
        let (mut s0, mut s1) = (z0.1, z2.0);
        let (mut c, mut carry);

        // Add z1•b
        (s0, c) = s0.carrying_add(&z1.0, Limb::ZERO);
        (s1, c) = s1.carrying_add(&z1.1, c);
        carry = c;
        // Correct for overflowing terms in z1 by adding (l0c•l1 + l1c•l0)•b^2
        (s1, c) = s1.carrying_add(
            &Uint::select(&Uint::ZERO, &l0, l1c.is_nonzero()),
            Limb::ZERO,
        );
        carry = carry.wrapping_add(c);
        (s1, c) = s1.carrying_add(
            &Uint::select(&Uint::ZERO, &l1, l0c.is_nonzero()),
            Limb::ZERO,
        );
        carry = carry.wrapping_add(c);
        carry = carry.wrapping_add(l0c.bitand(l1c));

        // Subtract (z0 + z2)•b
        (s0, c) = s0.borrowing_sub(&z0.0, Limb::ZERO);
        (s1, c) = s1.borrowing_sub(&z0.1, c);
        carry = carry.wrapping_add(c);
        (s0, c) = s0.borrowing_sub(&z2.0, Limb::ZERO);
        (s1, c) = s1.borrowing_sub(&z2.1, c);
        carry = carry.wrapping_add(c);

        (
            concat_wide(&z0.0, &s0),
            concat_wide(&s1, &z2.1.overflowing_add_limb(carry).0),
        )
    }

    // Handle relatively small integers
    if LHS < MIN_STARTING_LIMBS || RHS < MIN_STARTING_LIMBS {
        let (mut lo, mut hi) = (Uint::ZERO, Uint::ZERO);
        schoolbook::mul_wide(
            lhs.as_slice(),
            rhs.as_slice(),
            lo.as_mut_limbs(),
            hi.as_mut_limbs(),
        );
        (lo, hi)
    }
    // Handle optimized integer sizes. These calls are determined statically, so
    // only the relevant implementation should be inlined.
    else if LHS == RHS {
        match LHS {
            16 => reduce::<LHS, RHS, 8>(lhs, rhs),
            32 => reduce::<LHS, RHS, 16>(lhs, rhs),
            64 => reduce::<LHS, RHS, 32>(lhs, rhs),
            128 => reduce::<LHS, RHS, 64>(lhs, rhs),
            256 => reduce::<LHS, RHS, 128>(lhs, rhs),
            _ => {
                let mut lo_hi = [[Limb::ZERO; LHS]; 2];
                wrapping_mul(lhs, rhs, UintRef::new_flattened_mut(&mut lo_hi), false);
                (Uint::new(lo_hi[0]), Uint::new(lo_hi[1]).resize::<RHS>())
            }
        }
    }
    // If LHS < RHS, then multiply the evenly matched limbs (which may be optimized) and
    // add the product of the remaining RHS limbs with the LHS.
    else if LHS < RHS {
        let (y0, y1) = rhs.split_at(LHS);
        let (lo, mut hi) = resize_wide(widening_mul_fixed::<LHS, LHS>(lhs, y0));
        wrapping_mul(lhs, y1, hi.as_mut_uint_ref(), true);
        (lo, hi)
    }
    // When LHS > RHS, swap the arguments and adjust the result.
    else {
        // LHS > RHS, swap arguments
        let (lo, hi) = widening_mul_fixed::<RHS, LHS>(rhs, lhs);
        // Need to repartition from (RHS, LHS) to (LHS, RHS)
        let mut lo = lo.resize::<LHS>();
        lo.as_mut_uint_ref()
            .trailing_mut(RHS)
            .copy_from(hi.as_uint_ref().leading(LHS - RHS));
        (
            lo,
            hi.wrapping_shr_by_limbs_vartime((LHS - RHS) as u32)
                .resize::<RHS>(),
        )
    }
}

/// Compute a wrapping multiplication result for a fixed LHS and dynamic RHS argument. Common
/// power-of-two limb counts are implemented explicitly and used as a basis for general multiplication.
///
/// The limb count of `lhs` must be `LHS`.
#[inline]
pub const fn wrapping_mul_fixed<const LHS: usize>(
    lhs: &UintRef,
    rhs: &UintRef,
) -> (Uint<LHS>, Limb) {
    debug_assert!(lhs.nlimbs() == LHS);

    // Perform an optimized Karatsuba multiplication returning the lower half of the limbs
    // of the product.
    //   x•y = (x0 + x1•b)(y0 + y1•b)
    //       = x0y0 + x0y1•b + y0x1•b + x1y1•b^2
    // For the wrapped product, computing the upper half of (x0y1•b + 0x1•b) and x1y1•b^2
    // can be skipped, resulting in two more half-size wrapping multiplications.
    #[inline]
    const fn reduce<const LHS: usize, const HALF: usize>(
        x: &UintRef,
        y: &UintRef,
    ) -> (Uint<LHS>, Limb) {
        debug_assert!(LHS == HALF * 2);
        let (x0, x1) = x.split_at(HALF);
        let (y0, y1) = y.leading(LHS).split_at(HALF);

        // Calculate z0 = x0•y0
        let z0 = widening_mul_fixed::<HALF, HALF>(x0, y0);
        // Calculate z1 = x0•y1
        let (z1, z1c) = wrapping_mul_fixed::<HALF>(x0, y1);
        // Calculate z2 = x1•y0
        let (z2, z2c) = wrapping_mul_fixed::<HALF>(x1, y0);

        let (hi, c1) = z0.1.carrying_add(&z1, Limb::ZERO);
        let (hi, c2) = hi.carrying_add(&z2, Limb::ZERO);
        let carry = z1c.wrapping_add(z2c).wrapping_add(c1).wrapping_add(c2);

        (concat_wide(&z0.0, &hi), carry)
    }

    // Handle smaller integer sizes
    if LHS < MIN_STARTING_LIMBS || rhs.nlimbs() < MIN_STARTING_LIMBS {
        let mut lo = Uint::ZERO;
        let carry = schoolbook::wrapping_mul_add(lhs.as_slice(), rhs.as_slice(), lo.as_mut_limbs());
        return (lo, carry);
    }
    // Because only matching limbs are considered, any LHS <= RHS is treated as a fixed-size
    // wrapping multiplication.
    else if LHS <= rhs.nlimbs() {
        match LHS {
            16 => return reduce::<LHS, 8>(lhs, rhs),
            32 => return reduce::<LHS, 16>(lhs, rhs),
            64 => return reduce::<LHS, 32>(lhs, rhs),
            128 => return reduce::<LHS, 64>(lhs, rhs),
            256 => return reduce::<LHS, 128>(lhs, rhs),
            _ => {}
        }
    }

    // For LHS > RHS and less optimized sizes, defer to the dynamic implementation.
    let mut lo = Uint::ZERO;
    let carry = wrapping_mul(lhs, rhs, lo.as_mut_uint_ref(), false);
    (lo, carry)
}

/// Compute a wide squaring result for a fixed-size argument. Common power-of-two limb counts
/// are implemented explicitly and used as a basis for general squaring.
///
/// The limb count of `uint` must be `LIMBS`.
pub const fn widening_square_fixed<const LIMBS: usize>(
    uint: &UintRef,
) -> (Uint<LIMBS>, Uint<LIMBS>) {
    debug_assert!(
        uint.nlimbs() == LIMBS,
        "invalid arguments to widening_square_fixed"
    );

    // Perform an optimized Karatsuba squaring returning the a wide result.
    // The size of the arguments is halved on each recursion.
    #[inline]
    const fn reduce<const LIMBS: usize, const HALF: usize>(
        x: &UintRef,
    ) -> (Uint<LIMBS>, Uint<LIMBS>) {
        debug_assert!(LIMBS == HALF * 2);
        let (x0, x1) = x.split_at(HALF);

        // Calculate z0 = x0^2
        let z0 = widening_square_fixed::<HALF>(x0);
        // Calculate z1 = x0•x1
        let mut z1 = widening_mul_fixed::<HALF, HALF>(x0, x1);
        // Calculate z2 = x1^2
        let z2 = widening_square_fixed::<HALF>(x1);

        let (mut c, mut carry);
        // Double z1
        (z1.0, c) = z1.0.overflowing_shl1();
        (z1.1, carry) = z1.1.carrying_shl1(c);
        // Add z0.1, z2.0 to z1
        (z1.0, c) = z1.0.carrying_add(&z0.1, Limb::ZERO);
        (z1.1, c) = z1.1.carrying_add(&z2.0, c);
        carry = carry.wrapping_add(c);

        (
            concat_wide(&z0.0, &z1.0),
            concat_wide(&z1.1, &z2.1.overflowing_add_limb(carry).0),
        )
    }

    // Handle smaller integer sizes
    if LIMBS < MIN_STARTING_LIMBS {
        let (mut lo, mut hi) = (Uint::ZERO, Uint::ZERO);
        schoolbook::square_wide(uint.as_slice(), lo.as_mut_limbs(), hi.as_mut_limbs());
        (lo, hi)
    }
    // Forward to optimized implementations or the dynamic implementation. This choice should
    // be determined statically, resulting in an optimized method for each integer size.
    else {
        match LIMBS {
            16 => reduce::<LIMBS, 8>(uint),
            32 => reduce::<LIMBS, 16>(uint),
            64 => reduce::<LIMBS, 32>(uint),
            128 => reduce::<LIMBS, 64>(uint),
            256 => reduce::<LIMBS, 128>(uint),
            _ => {
                let mut lo_hi = [[Limb::ZERO; LIMBS]; 2];
                wrapping_square(uint, UintRef::new_flattened_mut(&mut lo_hi));
                (Uint::new(lo_hi[0]), Uint::new(lo_hi[1]))
            }
        }
    }
}

/// Compute a wrapping square for a fixed-size argument. This method defers to the dynamic
/// implementation, but inlining results in the selection of an efficient algorithm.
///
/// The limb count of `uint` must be `LIMBS`.
#[inline]
pub const fn wrapping_square_fixed<const LIMBS: usize>(uint: &UintRef) -> Uint<LIMBS> {
    let mut lo = Uint::ZERO;
    wrapping_square(uint, lo.as_mut_uint_ref());
    lo
}

/// Multiply two limb slices, placing the potentially-truncated result in `out`.
///
/// `lhs` and `rhs` may have different lengths.
/// `out` must have a limb count less than or equal to the width of the wide product of `lhs` and `rhs`.
/// `add` determines whether the result is simply written to `out`, or added to its current value.
///
/// The return value is the carry result of the wrapped multiplication (and addition, if performed).
#[inline]
pub const fn wrapping_mul(lhs: &UintRef, rhs: &UintRef, out: &mut UintRef, add: bool) -> Limb {
    assert!(
        lhs.nlimbs() + rhs.nlimbs() >= out.nlimbs(),
        "invalid arguments to wrapping_mul"
    );

    // Use the optimized multiplication for `LIMBS` limbs to break down the calculation of the product.
    const fn reduce<const LIMBS: usize>(
        x: &UintRef,
        y: &UintRef,
        out: &mut UintRef,
        add: bool,
    ) -> Limb {
        let out_len = out.nlimbs();

        // Perform a wrapping multiplication, returning up to the limb count of `x`.
        // The inputs `x` and `y` are split such that the products of their terms line up nicely
        // with the boundary of the wrapped result.
        // The product is computed as:
        //   x•y = (x0 + x1•b)(y0 + y1•c)
        //       = x0y + x1y0•b + x1y1•bc
        // where x1 and y0 have the same (power-of-two) size, the product `x1y0•b` wraps evenly at
        // the boundary of x's limb count, and `x1y1•bc` is entirely outside the wrapped result.
        if out_len <= x.nlimbs() {
            let (x0, x1) = x.leading(out_len).split_at(out_len - LIMBS);
            let y0 = y.leading(LIMBS);

            // Compute `x1y0` and place it at the end of the output buffer.
            let (z1, mut carry) = wrapping_mul_fixed::<LIMBS>(x1, y0);
            let assign = out.trailing_mut(out_len - LIMBS);
            if add {
                let c = assign.carrying_add_assign(z1.as_uint_ref(), Limb::ZERO);
                carry = carry.wrapping_add(c);
            } else {
                assign.copy_from(z1.as_uint_ref());
            }

            // Add `x0y` if necessary.
            if !x0.is_empty() {
                let c = wrapping_mul(x0, y, out, true);
                carry = carry.wrapping_add(c)
            }
            carry
        }
        // Perform a wide (but possibly truncated) multiplication, returning up the limb count of `x•y`.
        // The product is computed as:
        //   x•y = (x0 + x1•b)(y0 + y1•b)
        //       = x0y0 + x1y•b + x0y1•b
        else {
            let (x0, x1) = x.split_at(LIMBS);
            let y_len = if y.nlimbs() < out_len {
                y.nlimbs()
            } else {
                out_len
            };
            let (y0, y1) = y.leading(y_len).split_at(LIMBS);

            let z0 = widening_mul_fixed::<LIMBS, LIMBS>(x0, y0);
            let (assign, tail) = out.split_at_mut(if out.nlimbs() < LIMBS * 2 {
                out.nlimbs()
            } else {
                LIMBS * 2
            });
            let (lo, hi) = assign.split_at_mut(LIMBS);
            let mut carry = if add {
                let mut carry = lo.carrying_add_assign(z0.0.as_uint_ref(), Limb::ZERO);
                carry = hi.carrying_add_assign(z0.1.as_uint_ref().leading(hi.nlimbs()), carry);
                tail.add_assign_limb(carry)
            } else {
                lo.copy_from(z0.0.as_uint_ref());
                hi.copy_from(z0.1.as_uint_ref().leading(hi.nlimbs()));
                Limb::ZERO
            };

            // Add x1y•b if necessary.
            if !x1.is_empty() {
                let c = wrapping_mul(x1, y, out.trailing_mut(LIMBS), true);
                carry = carry.wrapping_add(c);
            }
            // Add x0y1•b if necessary.
            if !y1.is_empty() {
                let tail_len = out_len - LIMBS;
                let assign_len = if y_len < tail_len { y_len } else { tail_len };
                let (assign, tail) = out.trailing_mut(LIMBS).split_at_mut(assign_len);
                let c = wrapping_mul(y1, x0, assign, true);
                let c = tail.add_assign_limb(c);
                carry = carry.wrapping_add(c);
            }
            carry
        }
    }

    let overlap = if lhs.nlimbs() < rhs.nlimbs() {
        lhs.nlimbs()
    } else {
        rhs.nlimbs()
    };
    let overlap = if overlap < out.nlimbs() {
        overlap
    } else {
        out.nlimbs()
    };
    let split = previous_power_of_2(overlap);

    // Handle smaller sized integers
    if split < MIN_STARTING_LIMBS {
        return schoolbook::wrapping_mul_add(lhs.as_slice(), rhs.as_slice(), out.as_mut_slice());
    }

    // Select an optimized implementation for a fixed number of limbs
    match split {
        16 => reduce::<16>(lhs, rhs, out, add),
        32 => reduce::<32>(lhs, rhs, out, add),
        64 => reduce::<64>(lhs, rhs, out, add),
        128 => reduce::<128>(lhs, rhs, out, add),
        _ => reduce::<256>(lhs, rhs, out, add),
    }
}

/// Square a limb slice, placing the potentially-truncated result in `out`.
///
/// `out` must have a limb count less than or equal to the width of the wide squaring of `uint`.
#[inline]
pub(crate) const fn wrapping_square(uint: &UintRef, out: &mut UintRef) {
    assert!(
        out.nlimbs() <= uint.nlimbs() * 2,
        "invalid arguments to wrapping_square"
    );

    // Use the optimized squaring for `LIMBS` limbs to break down the calculation of the product.
    const fn reduce<const LIMBS: usize>(x: &UintRef, out: &mut UintRef) {
        let (x0, x1) = x.split_at(LIMBS);
        let (lo, hi) = out.split_at_mut(LIMBS);

        // Add z0 = x0^2
        let z0 = widening_square_fixed::<LIMBS>(x0);
        lo.copy_from(z0.0.as_uint_ref());

        // Add z1 = 2x0•x1•b
        if hi.nlimbs() <= LIMBS {
            let (z1, _carry) = wrapping_mul_fixed::<LIMBS>(x0, x1);
            let z1 = z1.overflowing_shl1().0;
            hi.copy_from(z0.1.wrapping_add(&z1).as_uint_ref().leading(hi.nlimbs()));
        } else {
            let (z01, z2) = hi.split_at_mut(LIMBS);
            z01.copy_from(z0.1.as_uint_ref());
            wrapping_square(x1, z2);
            let mut dx0 = Uint::<LIMBS>::ZERO;
            dx0.as_mut_uint_ref().copy_from(x0);
            let (dx0, dx0_hi) = dx0.overflowing_shl1();
            let z2_len = if z2.nlimbs() < x1.nlimbs() {
                z2.nlimbs()
            } else {
                x1.nlimbs()
            };
            let mut carry = z2.leading_mut(z2_len).conditional_add_assign(
                x1.leading(z2_len),
                Limb::ZERO,
                dx0_hi.is_nonzero(),
            );
            let (z1, z1tail) = hi.split_at_mut(LIMBS + z2_len);
            let c = wrapping_mul(dx0.as_uint_ref(), x1, z1, true);
            carry = carry.wrapping_add(c);
            z1tail.add_assign_limb(carry);
        }
    }

    // Restrict the size of the input to the size of the output
    let x = if uint.nlimbs() >= out.nlimbs() {
        uint.leading(out.nlimbs())
    } else {
        uint
    };

    // Handle smaller integer sizes
    if x.nlimbs() <= MIN_STARTING_LIMBS {
        schoolbook::wrapping_square(x.as_slice(), out.as_mut_slice());
        return;
    }

    // Select an optimized 'split' such that a wide multiplication will not
    // calculate too many unnecessary limbs. We select the largest power of 2
    // <= the output size, and step back to the previous power if it exceeds the
    // input size or more than MIN_STARTING_LIMBS limbs would be truncated.
    let mut split = previous_power_of_2(out.nlimbs());
    if split > x.nlimbs() || 2 * split >= out.nlimbs() + MIN_STARTING_LIMBS {
        split /= 2;
    }

    // Select an optimized implementation for a fixed number of limbs
    match split {
        16 => reduce::<16>(x, out),
        32 => reduce::<32>(x, out),
        64 => reduce::<64>(x, out),
        128 => reduce::<128>(x, out),
        _ => reduce::<256>(x, out),
    }
}

/// Join two `Uints` into an output `Uint`, potentially larger than both in size.
#[inline]
const fn concat_wide<const LIMBS: usize, const HALF: usize>(
    lo: &Uint<HALF>,
    hi: &Uint<HALF>,
) -> Uint<LIMBS> {
    assert!(LIMBS >= HALF * 2);
    let mut res = Uint::<LIMBS>::ZERO;
    let (lo_mut, hi_mut) = res
        .as_mut_uint_ref()
        .leading_mut(HALF * 2)
        .split_at_mut(HALF);
    lo_mut.copy_from_slice(lo.as_limbs());
    hi_mut.copy_from_slice(hi.as_limbs());
    res
}

/// Resize a pair of `Uint`s.
#[inline(always)]
const fn resize_wide<const LIMBS: usize, const LHS: usize, const RHS: usize>(
    (lo, hi): (Uint<LIMBS>, Uint<LIMBS>),
) -> (Uint<LHS>, Uint<RHS>) {
    assert!(LHS == LIMBS && RHS >= LIMBS);
    (lo.resize(), hi.resize())
}

/// Compute the power of 2 `p` such that `p <= value < p*2`.
#[inline]
const fn previous_power_of_2(value: usize) -> usize {
    if value == 0 {
        0
    } else {
        1usize << value.ilog2()
    }
}

#[cfg(feature = "rand_core")]
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Limb, Uint};
    use rand_core::{RngCore, SeedableRng};

    #[test]
    fn wrapping_mul_sizes() {
        const SIZE: usize = 200;
        let mut rng = rand_chacha::ChaCha8Rng::seed_from_u64(1);
        for n in 0..100 {
            use crate::Random;

            let a = Uint::<SIZE>::random(&mut rng);
            let b = Uint::<SIZE>::random(&mut rng);
            let size_a = rng.next_u32() as usize % SIZE;
            let size_b = rng.next_u32() as usize % SIZE;
            let a = a.as_uint_ref().leading(size_a);
            let b = b.as_uint_ref().leading(size_b);
            let mut wide = [Limb::ZERO; SIZE * 2];
            wrapping_mul(a, b, UintRef::new_mut(&mut wide[..size_a + size_b]), false);
            for size in 0..size_a + size_b {
                let mut check = [Limb::ZERO; SIZE * 2];
                let wrapped = UintRef::new_mut(&mut check[..size]);
                wrapping_mul(b, a, wrapped, false);
                assert_eq!(
                    wrapped,
                    UintRef::new(&wide[..size]),
                    "comparison failed n={n}, a={a}, b={b}, size={size}"
                );
            }
        }
    }

    #[test]
    fn wrapping_square_sizes() {
        const SIZE: usize = 200;
        let mut rng = rand_chacha::ChaCha8Rng::seed_from_u64(1);
        for n in 0..100 {
            use crate::Random;

            let a = Uint::<SIZE>::random(&mut rng);
            let size_a = rng.next_u32() as usize % SIZE;
            let a = a.as_uint_ref().leading(size_a);
            let mut wide = [Limb::ZERO; SIZE * 2];
            wrapping_mul(a, a, UintRef::new_mut(&mut wide[..size_a * 2]), false);

            for size in 0..=size_a * 2 {
                let mut check = [Limb::ZERO; SIZE * 2];
                let wrapped = UintRef::new_mut(&mut check[..size]);
                wrapping_square(a, wrapped);
                assert_eq!(
                    wrapped,
                    UintRef::new(&wide[..size]),
                    "comparison failed n={n}, a={a}, size={size}"
                );
            }
        }
    }
}
