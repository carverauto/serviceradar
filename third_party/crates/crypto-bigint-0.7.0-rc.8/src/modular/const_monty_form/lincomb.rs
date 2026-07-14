//! Linear combinations of integers n Montgomery form with a constant modulus.

use core::marker::PhantomData;

use super::{ConstMontyForm, ConstMontyParams};
use crate::modular::lincomb::lincomb_const_monty_form;

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> ConstMontyForm<MOD, LIMBS> {
    /// Calculate the sum of products of pairs `(a, b)` in `products`.
    pub const fn lincomb(products: &[(Self, Self)]) -> Self {
        Self {
            montgomery_form: lincomb_const_monty_form(
                products,
                &MOD::PARAMS.modulus,
                MOD::PARAMS.mod_neg_inv(),
            ),
            phantom: PhantomData,
        }
    }
}

#[cfg(test)]
mod tests {

    #[cfg(feature = "rand")]
    #[test]
    fn lincomb_expected() {
        use super::{ConstMontyForm, ConstMontyParams};
        use crate::{RandomMod, U256, const_monty_params};
        use rand_core::SeedableRng;
        const_monty_params!(
            P,
            U256,
            "7fffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
        );
        let modulus = P::PARAMS.modulus.as_nz_ref();

        let mut rng = rand_chacha::ChaCha8Rng::seed_from_u64(1);
        for n in 0..1000 {
            let a = U256::random_mod(&mut rng, modulus);
            let b = U256::random_mod(&mut rng, modulus);
            let c = U256::random_mod(&mut rng, modulus);
            let d = U256::random_mod(&mut rng, modulus);
            let e = U256::random_mod(&mut rng, modulus);
            let f = U256::random_mod(&mut rng, modulus);

            assert_eq!(
                a.mul_mod(&b, modulus)
                    .add_mod(&c.mul_mod(&d, modulus), modulus)
                    .add_mod(&e.mul_mod(&f, modulus), modulus),
                ConstMontyForm::<P, { P::LIMBS }>::lincomb(&[
                    (ConstMontyForm::new(&a), ConstMontyForm::new(&b)),
                    (ConstMontyForm::new(&c), ConstMontyForm::new(&d)),
                    (ConstMontyForm::new(&e), ConstMontyForm::new(&f)),
                ])
                .retrieve(),
                "n={n}"
            )
        }
    }
}
