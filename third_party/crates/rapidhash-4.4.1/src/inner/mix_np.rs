//! Internal module that provides the folded multiply.

/// NON-PORTABLE 64*64 to 128 bit multiply
///
/// Returns the (low, high) 64 bits of the 128 bit result.
///
/// # Non-portable version
/// This version is not portable across all architectures and is intended for use only on the
/// in-memory hash functions.
///
/// # From the C code:
/// Calculates 128-bit C = *A * *B.
///
/// When RAPIDHASH_FAST is defined:
/// Overwrites A contents with C's low 64 bits.
/// Overwrites B contents with C's high 64 bits.
///
/// When RAPIDHASH_PROTECTED is defined:
/// Xors and overwrites A contents with C's low 64 bits.
/// Xors and overwrites B contents with C's high 64 bits.
#[inline(always)]
#[must_use]
pub(super) const fn rapid_mum_np<const PROTECTED: bool>(a: u64, b: u64) -> (u64, u64) {
    #[cfg(any(
        all(
            target_pointer_width = "64",
            not(any(target_arch = "sparc64", target_arch = "wasm64")),
        ),
        target_arch = "aarch64",
        target_arch = "x86_64",
        all(target_family = "wasm", target_feature = "wide-arithmetic"),
    ))]
    {
        let r = (a as u128).wrapping_mul(b as u128);

        if !PROTECTED {
            (r as u64, (r >> 64) as u64)
        } else {
            (a ^ r as u64, b ^ (r >> 64) as u64)
        }
    }

    #[cfg(not(any(
        all(
            target_pointer_width = "64",
            not(any(target_arch = "sparc64", target_arch = "wasm64")),
        ),
        target_arch = "aarch64",
        target_arch = "x86_64",
        all(target_family = "wasm", target_feature = "wide-arithmetic"),
    )))]
    {
        // u64 x u64 -> u128 product is quite expensive on 32-bit.
        // We approximate it by expanding the multiplication and eliminating
        // carries by replacing additions with XORs:
        //    (2^32 hx + lx)*(2^32 hy + ly) =
        //    2^64 hx*hy + 2^32 (hx*ly + lx*hy) + lx*ly ~=
        //    2^64 hx*hy ^ 2^32 (hx*ly ^ lx*hy) ^ lx*ly
        // Which when folded becomes:
        //    (hx*hy ^ lx*ly) ^ (hx*ly ^ lx*hy).rotate_right(32)

        let lx = a as u32;
        let ly = b as u32;
        let hx = (a >> 32) as u32;
        let hy = (b >> 32) as u32;

        let ll = (lx as u64).wrapping_mul(ly as u64);
        let lh = (lx as u64).wrapping_mul(hy as u64);
        let hl = (hx as u64).wrapping_mul(ly as u64);
        let hh = (hx as u64).wrapping_mul(hy as u64);

        if !PROTECTED {
            ((hh ^ ll), (hl ^ lh).rotate_right(32))
        } else {
            // If protected, we XOR the inputs with the results.
            // This is to ensure that the inputs are not recoverable from the output.
            ((a ^ hh ^ ll), (b ^ hl ^ lh).rotate_right(32))
        }
    }
}

/// NON-PORTABLE Folded 64-bit multiply. [rapid_mum] then XOR the results together.
///
/// # Non-portable version
/// This version is not portable across all architectures and is intended for use only on the
/// in-memory hash functions.
#[inline(always)]
#[must_use]
pub(super) const fn rapid_mix_np<const PROTECTED: bool>(a: u64, b: u64) -> u64 {
    #[cfg(any(
        all(
            target_pointer_width = "64",
            not(any(target_arch = "sparc64", target_arch = "wasm64")),
        ),
        target_arch = "aarch64",
        target_arch = "x86_64",
        all(target_family = "wasm", target_feature = "wide-arithmetic"),
    ))]
    {
        let r = (a as u128).wrapping_mul(b as u128);

        if !PROTECTED {
            (r as u64) ^ (r >> 64) as u64
        } else {
            (a ^ r as u64) ^ (b ^ (r >> 64) as u64)
        }
    }

    #[cfg(not(any(
        all(
            target_pointer_width = "64",
            not(any(target_arch = "sparc64", target_arch = "wasm64")),
        ),
        target_arch = "aarch64",
        target_arch = "x86_64",
        all(target_family = "wasm", target_feature = "wide-arithmetic"),
    )))]
    {
        // u64 x u64 -> u128 product is quite expensive on 32-bit.
        // We approximate it by expanding the multiplication and eliminating
        // carries by replacing additions with XORs:
        //    (2^32 hx + lx)*(2^32 hy + ly) =
        //    2^64 hx*hy + 2^32 (hx*ly + lx*hy) + lx*ly ~=
        //    2^64 hx*hy ^ 2^32 (hx*ly ^ lx*hy) ^ lx*ly
        // Which when folded becomes:
        //    (hx*hy ^ lx*ly) ^ (hx*ly ^ lx*hy).rotate_right(32)

        let lx = a as u32;
        let ly = b as u32;
        let hx = (a >> 32) as u32;
        let hy = (b >> 32) as u32;

        let ll = (lx as u64).wrapping_mul(ly as u64);
        let lh = (lx as u64).wrapping_mul(hy as u64);
        let hl = (hx as u64).wrapping_mul(ly as u64);
        let hh = (hx as u64).wrapping_mul(hy as u64);

        if !PROTECTED {
            (hh ^ ll) ^ (hl ^ lh).rotate_right(32)
        } else {
            // If protected, we XOR the inputs with the results.
            // This is to ensure that the inputs are not recoverable from the output.
            (a ^ hh ^ ll) ^ (b ^ hl ^ lh).rotate_right(32)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(any(
        all(
            target_pointer_width = "64",
            not(any(target_arch = "sparc64", target_arch = "wasm64")),
        ),
        target_arch = "aarch64",
        target_arch = "x86_64",
        all(target_family = "wasm", target_feature = "wide-arithmetic"),
    ))]
    fn test_rapid_mum() {
        let (a, b) = rapid_mum_np::<false>(0, 0);
        assert_eq!(a, 0);
        assert_eq!(b, 0);

        let (a, b) = rapid_mum_np::<false>(100, 100);
        assert_eq!(a, 10000);
        assert_eq!(b, 0);

        let (a, b) = rapid_mum_np::<false>(u64::MAX, 2);
        assert_eq!(a, u64::MAX - 1);
        assert_eq!(b, 1);
    }
}
