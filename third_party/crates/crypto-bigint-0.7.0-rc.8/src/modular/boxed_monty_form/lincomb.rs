//! Linear combinations of integers in Montgomery form with a modulus set at runtime.

use super::BoxedMontyForm;
use crate::modular::lincomb::lincomb_boxed_monty_form;

impl BoxedMontyForm {
    /// Calculate the sum of products of pairs `(a, b)` in `products`.
    ///
    /// This method is variable time only with the value of the modulus.
    /// For a modulus with leading zeros, this method is more efficient than a naive sum of products.
    ///
    /// This method will panic if `products` is empty. All terms must be associated
    /// with equivalent `MontyParams`.
    pub fn lincomb_vartime(products: &[(&Self, &Self)]) -> Self {
        assert!(!products.is_empty(), "empty products");
        let params = &products[0].0.params;
        Self {
            montgomery_form: lincomb_boxed_monty_form(
                products,
                params.modulus(),
                params.mod_neg_inv(),
                params.mod_leading_zeros(),
            ),
            params: products[0].0.params.clone(),
        }
    }
}

#[cfg(test)]
mod tests {

    #[cfg(feature = "rand")]
    #[test]
    fn lincomb_expected() {
        use crate::modular::{BoxedMontyForm, BoxedMontyParams};
        use crate::{BoxedUint, Odd, RandomMod};
        use rand_core::SeedableRng;

        const SIZE: u32 = 511;

        let mut rng = rand_chacha::ChaCha8Rng::seed_from_u64(1);
        for n in 0..100 {
            let modulus = Odd::<BoxedUint>::random(&mut rng, SIZE);
            let params = BoxedMontyParams::new(modulus.clone());
            let a = BoxedUint::random_mod(&mut rng, modulus.as_nz_ref());
            let b = BoxedUint::random_mod(&mut rng, modulus.as_nz_ref());
            let c = BoxedUint::random_mod(&mut rng, modulus.as_nz_ref());
            let d = BoxedUint::random_mod(&mut rng, modulus.as_nz_ref());
            let e = BoxedUint::random_mod(&mut rng, modulus.as_nz_ref());
            let f = BoxedUint::random_mod(&mut rng, modulus.as_nz_ref());

            let std = a
                .mul_mod(&b, modulus.as_nz_ref())
                .add_mod(&c.mul_mod(&d, modulus.as_nz_ref()), modulus.as_nz_ref())
                .add_mod(&e.mul_mod(&f, modulus.as_nz_ref()), modulus.as_nz_ref());

            let lincomb = BoxedMontyForm::lincomb_vartime(&[
                (
                    &BoxedMontyForm::new(a, params.clone()),
                    &BoxedMontyForm::new(b, params.clone()),
                ),
                (
                    &BoxedMontyForm::new(c, params.clone()),
                    &BoxedMontyForm::new(d, params.clone()),
                ),
                (
                    &BoxedMontyForm::new(e, params.clone()),
                    &BoxedMontyForm::new(f, params.clone()),
                ),
            ]);

            assert_eq!(std, lincomb.retrieve(), "n={n}");
        }
    }
}
