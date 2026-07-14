use crate::Limb;

/// Schoolbook multiplication a.k.a. long multiplication, i.e. the traditional method taught in
/// schools.
///
/// The most efficient method for small numbers.
#[inline(always)]
#[track_caller]
pub const fn mul_wide(lhs: &[Limb], rhs: &[Limb], lo: &mut [Limb], hi: &mut [Limb]) {
    assert!(
        lhs.len() == lo.len() && rhs.len() == hi.len(),
        "schoolbook multiplication length mismatch"
    );

    let mut i = 0;

    while i < lhs.len() {
        let mut carry = Limb::ZERO;
        let xi = lhs[i];
        let mut j = 0;

        while j < rhs.len() {
            let k = i + j;

            if k >= lhs.len() {
                (hi[k - lhs.len()], carry) = xi.carrying_mul_add(rhs[j], hi[k - lhs.len()], carry);
            } else {
                (lo[k], carry) = xi.carrying_mul_add(rhs[j], lo[k], carry);
            }

            j += 1;
        }

        if i + j >= lhs.len() {
            hi[i + j - lhs.len()] = carry;
        } else {
            lo[i + j] = carry;
        }
        i += 1;
    }
}

/// Schoolbook multiplication which only calculates the lower limbs of the product.
#[inline(always)]
#[track_caller]
pub const fn wrapping_mul_add(lhs: &[Limb], rhs: &[Limb], out: &mut [Limb]) -> Limb {
    assert!(
        lhs.len() + rhs.len() >= out.len(),
        "wrapping schoolbook multiplication length mismatch"
    );

    let mut i = 0;
    let mut meta_carry = Limb::ZERO;

    while i < lhs.len() {
        let mut carry = Limb::ZERO;
        let xi = lhs[i];
        let mut k = i;

        loop {
            let j = k - i;
            if k >= out.len() {
                meta_carry = meta_carry.wrapping_add(carry);
                break;
            } else if j == rhs.len() {
                (out[k], meta_carry) = out[k].carrying_add(carry, meta_carry);
                break;
            }
            (out[k], carry) = xi.carrying_mul_add(rhs[j], out[k], carry);
            k += 1;
        }

        i += 1;
    }

    meta_carry
}

/// Schoolbook method of squaring.
///
/// Like schoolbook multiplication, but only considering half of the multiplication grid.
#[inline(always)]
#[track_caller]
pub const fn square_wide(limbs: &[Limb], lo: &mut [Limb], hi: &mut [Limb]) {
    // Translated from https://github.com/ucbrise/jedi-pairing/blob/c4bf151/include/core/bigint.hpp#L410
    //
    // Permission to relicense the resulting translation as Apache 2.0 + MIT was given
    // by the original author Sam Kumar: https://github.com/RustCrypto/crypto-bigint/pull/133#discussion_r1056870411

    assert!(
        limbs.len() == lo.len() && lo.len() == hi.len(),
        "schoolbook squaring length mismatch"
    );

    let mut i = 1;
    while i < limbs.len() {
        let mut j = 0;
        let mut carry = Limb::ZERO;
        let xi = limbs[i];

        while j < i {
            let k = i + j;

            if k >= limbs.len() {
                (hi[k - limbs.len()], carry) =
                    xi.carrying_mul_add(limbs[j], hi[k - limbs.len()], carry);
            } else {
                (lo[k], carry) = xi.carrying_mul_add(limbs[j], lo[k], carry);
            }

            j += 1;
        }

        if (2 * i) < limbs.len() {
            lo[2 * i] = carry;
        } else {
            hi[2 * i - limbs.len()] = carry;
        }

        i += 1;
    }

    // Double the current result, this accounts for the other half of the multiplication grid.
    // The top word is empty, so we use a special purpose shl.
    let mut carry = Limb::ZERO;
    let mut i = 0;
    while i < limbs.len() {
        (lo[i].0, carry) = ((lo[i].0 << 1) | carry.0, lo[i].shr(Limb::BITS - 1));
        i += 1;
    }

    let mut i = 0;
    while i < limbs.len() - 1 {
        (hi[i].0, carry) = ((hi[i].0 << 1) | carry.0, hi[i].shr(Limb::BITS - 1));
        i += 1;
    }
    hi[limbs.len() - 1] = carry;

    // Handle the diagonal of the multiplication grid, which finishes the multiplication grid.
    let mut carry = Limb::ZERO;
    let mut i = 0;
    while i < limbs.len() {
        let xi = limbs[i];
        if (i * 2) < limbs.len() {
            (lo[i * 2], carry) = xi.carrying_mul_add(xi, lo[i * 2], carry);
        } else {
            (hi[i * 2 - limbs.len()], carry) =
                xi.carrying_mul_add(xi, hi[i * 2 - limbs.len()], carry);
        }

        if (i * 2 + 1) < limbs.len() {
            (lo[i * 2 + 1], carry) = lo[i * 2 + 1].overflowing_add(carry);
        } else {
            (hi[i * 2 + 1 - limbs.len()], carry) =
                hi[i * 2 + 1 - limbs.len()].overflowing_add(carry);
        }

        i += 1;
    }
}

/// Schoolbook squaring which may calculate a limited number of limbs of the product.
#[inline(always)]
#[track_caller]
pub const fn wrapping_square(limbs: &[Limb], out: &mut [Limb]) {
    assert!(
        limbs.len() * 2 >= out.len(),
        "schoolbook wrapping squaring length mismatch"
    );

    let mut i = 1;

    while i < limbs.len() {
        let mut carry = Limb::ZERO;
        let xi = limbs[i];
        let mut k = i;

        while k < 2 * i && k < out.len() {
            (out[k], carry) = xi.carrying_mul_add(limbs[k - i], out[k], carry);
            k += 1;
        }

        if k < out.len() {
            out[k] = carry;
        }
        i += 1;
    }

    // Double the current result and fill in the diagonal terms.
    let mut carry = Limb::ZERO;
    let mut limb;
    let mut hi_bit = Limb::ZERO;
    i = 0;
    while i < out.len() {
        (limb, hi_bit) = (out[i].shl(1).bitor(hi_bit), out[i].shr(Limb::HI_BIT));
        (out[i], carry) = if i & 1 == 0 {
            limbs[i / 2].carrying_mul_add(limbs[i / 2], limb, carry)
        } else {
            limb.overflowing_add(carry)
        };
        i += 1;
    }
}
