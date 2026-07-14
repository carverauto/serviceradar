use crate::{Int, Limb, Uint};

impl<const LIMBS: usize> Int<LIMBS> {
    /// Resize the representation of `self` to an [`Int<T>`].
    /// Warning: this operation may lead to loss of information.
    #[inline(always)]
    pub const fn resize<const T: usize>(&self) -> Int<T> {
        let mut limbs = [Limb::select(Limb::ZERO, Limb::MAX, self.is_negative()); T];
        let mut i = 0;
        let dim = if T < LIMBS { T } else { LIMBS };
        while i < dim {
            limbs[i] = self.0.limbs[i];
            i += 1;
        }
        *Uint { limbs }.as_int()
    }
}

#[cfg(test)]
mod tests {

    use crate::{I128, I256};

    #[test]
    fn scale_down() {
        assert_eq!(I256::MIN.resize::<{ I128::LIMBS }>(), I128::ZERO);
        assert_eq!(I256::MINUS_ONE.resize::<{ I128::LIMBS }>(), I128::MINUS_ONE);
        assert_eq!(I256::ZERO.resize::<{ I128::LIMBS }>(), I128::ZERO);
        assert_eq!(I256::ONE.resize::<{ I128::LIMBS }>(), I128::ONE);
        assert_eq!(I256::MAX.resize::<{ I128::LIMBS }>(), I128::MINUS_ONE);
    }

    #[test]
    fn scale_up() {
        assert_eq!(
            I128::MIN.resize::<{ I256::LIMBS }>(),
            I256::ZERO.wrapping_sub(&I256 {
                0: I128::MIN.0.resize()
            })
        );
        assert_eq!(I128::MINUS_ONE.resize::<{ I256::LIMBS }>(), I256::MINUS_ONE);
        assert_eq!(I128::ZERO.resize::<{ I256::LIMBS }>(), I256::ZERO);
        assert_eq!(I128::ONE.resize::<{ I256::LIMBS }>(), I256::ONE);
        assert_eq!(
            I128::MAX.resize::<{ I256::LIMBS }>(),
            *I128::MAX.0.resize().as_int()
        );
    }
}
