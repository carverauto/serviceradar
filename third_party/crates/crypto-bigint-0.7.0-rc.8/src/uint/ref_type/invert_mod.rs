use super::UintRef;
use crate::Odd;

impl Odd<UintRef> {
    /// Returns the multiplicative inverse of the argument modulo 2^64. The implementation is based
    /// on the Hurchalla's method for computing the multiplicative inverse modulo a power of two.
    ///
    /// For better understanding the implementation, the following paper is recommended:
    /// J. Hurchalla, "An Improved Integer Multiplicative Inverse (modulo 2^w)",
    /// <https://arxiv.org/pdf/2204.04342.pdf>
    ///
    /// Variable time with respect to the number of words in `value`, however that number will be
    /// fixed for a given integer size.
    pub const fn invert_mod_u64(&self) -> u64 {
        let value = self.as_ref().lowest_u64();
        let x = value.wrapping_mul(3) ^ 2;
        let y = 1u64.wrapping_sub(x.wrapping_mul(value));
        let (x, y) = (x.wrapping_mul(y.wrapping_add(1)), y.wrapping_mul(y));
        let (x, y) = (x.wrapping_mul(y.wrapping_add(1)), y.wrapping_mul(y));
        let (x, y) = (x.wrapping_mul(y.wrapping_add(1)), y.wrapping_mul(y));
        x.wrapping_mul(y.wrapping_add(1))
    }
}

impl UintRef {
    #[inline(always)]
    pub const fn lowest_u64(&self) -> u64 {
        #[cfg(target_pointer_width = "32")]
        {
            debug_assert!(self.nlimbs() >= 1);
            let mut ret = self.0[0].0 as u64;

            if self.nlimbs() >= 2 {
                ret |= (self.0[1].0 as u64) << 32;
            }

            ret
        }

        #[cfg(target_pointer_width = "64")]
        {
            self.0[0].0
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::U128;

    #[test]
    fn invert_mod_u64() {
        let q = U128::ONE.to_odd().unwrap();
        let inv = q.as_uint_ref().invert_mod_u64();
        assert_eq!(inv, 0x1);

        let q = U128::from(3u64).to_odd().unwrap();
        let inv = q.as_uint_ref().invert_mod_u64();
        assert_eq!(inv, 0xaaaaaaaaaaaaaaab);

        let q = U128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD")
            .to_odd()
            .unwrap();
        let inv = q.as_uint_ref().invert_mod_u64();
        assert_eq!(inv, 0xa6a0916b76276275);
    }
}
