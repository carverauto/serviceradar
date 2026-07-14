//! [`Uint`] modular addition operations.

use crate::{AddMod, Limb, NonZero, Uint};

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Computes `self + rhs mod p`.
    ///
    /// Assumes `self + rhs` as unbounded integer is `< 2p`.
    pub const fn add_mod(&self, rhs: &Self, p: &NonZero<Self>) -> Self {
        let (w, carry) = self.carrying_add(rhs, Limb::ZERO);
        w.sub_mod_with_carry(carry, p.as_ref(), p.as_ref())
    }

    /// Computes `self + rhs mod p` for the special modulus
    /// `p = MAX+1-c` where `c` is small enough to fit in a single [`Limb`].
    ///
    /// Assumes `self + rhs` as unbounded integer is `< 2p`.
    pub const fn add_mod_special(&self, rhs: &Self, c: Limb) -> Self {
        // `Uint::carrying_add` also works with a carry greater than 1.
        let (out, carry) = self.carrying_add(rhs, c);

        // If overflow occurred, then above addition of `c` already accounts
        // for the overflow. Otherwise, we need to subtract `c` again, which
        // in that case cannot underflow.
        let l = carry.0.wrapping_sub(1) & c.0;
        out.wrapping_sub(&Self::from_word(l))
    }

    /// Computes `self + self mod p`.
    ///
    /// Assumes `self` as unbounded integer is `< p`.
    pub const fn double_mod(&self, p: &NonZero<Self>) -> Self {
        let (w, carry) = self.overflowing_shl1();
        w.sub_mod_with_carry(carry, p.as_ref(), p.as_ref())
    }
}

impl<const LIMBS: usize> AddMod for Uint<LIMBS> {
    type Output = Self;

    fn add_mod(&self, rhs: &Self, p: &NonZero<Self>) -> Self {
        debug_assert!(self < p.as_ref());
        debug_assert!(rhs < p.as_ref());
        self.add_mod(rhs, p)
    }
}

#[cfg(all(test, feature = "rand"))]
mod tests {
    use crate::{Limb, NonZero, Random, RandomMod, U256, Uint};
    use rand_core::SeedableRng;

    #[test]
    fn add_mod_nist_p256() {
        let a =
            U256::from_be_hex("44acf6b7e36c1342c2c5897204fe09504e1e2efb1a900377dbc4e7a6a133ec56");
        let b =
            U256::from_be_hex("d5777c45019673125ad240f83094d4252d829516fac8601ed01979ec1ec1a251");
        let n =
            U256::from_be_hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
                .to_nz()
                .unwrap();

        let actual = a.add_mod(&b, &n);
        let expected =
            U256::from_be_hex("1a2472fde50286541d97ca6a3592dd75beb9c9646e40c511b82496cfc3926956");

        assert_eq!(expected, actual);
    }

    #[test]
    fn double_mod_expected() {
        let a =
            U256::from_be_hex("44acf6b7e36c1342c2c5897204fe09504e1e2efb1a900377dbc4e7a6a133ec56");
        let n =
            U256::from_be_hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
                .to_nz()
                .unwrap();

        assert_eq!(a.add_mod(&a, &n), a.double_mod(&n));
    }

    macro_rules! test_add_mod_special {
        ($size:expr, $test_name:ident) => {
            #[test]
            fn $test_name() {
                let mut rng = rand_chacha::ChaCha8Rng::seed_from_u64(1);
                let moduli = [
                    NonZero::<Limb>::random(&mut rng),
                    NonZero::<Limb>::random(&mut rng),
                ];

                for special in &moduli {
                    let p =
                        &NonZero::new(Uint::ZERO.wrapping_sub(&Uint::from(special.get()))).unwrap();

                    let minus_one = p.wrapping_sub(&Uint::ONE);

                    let base_cases = [
                        (Uint::ZERO, Uint::ZERO, Uint::ZERO),
                        (Uint::ONE, Uint::ZERO, Uint::ONE),
                        (Uint::ZERO, Uint::ONE, Uint::ONE),
                        (minus_one, Uint::ONE, Uint::ZERO),
                        (Uint::ONE, minus_one, Uint::ZERO),
                    ];
                    for (a, b, c) in &base_cases {
                        let x = a.add_mod_special(b, *special.as_ref());
                        assert_eq!(*c, x, "{} + {} mod {} = {} != {}", a, b, p, x, c);
                    }

                    for _i in 0..100 {
                        let a = Uint::<$size>::random_mod(&mut rng, p);
                        let b = Uint::<$size>::random_mod(&mut rng, p);

                        let c = a.add_mod_special(&b, *special.as_ref());
                        assert!(c < **p, "not reduced: {} >= {} ", c, p);

                        let expected = a.add_mod(&b, p);
                        assert_eq!(c, expected, "incorrect result");
                    }
                }
            }
        };
    }

    test_add_mod_special!(1, add_mod_special_1);
    test_add_mod_special!(2, add_mod_special_2);
    test_add_mod_special!(3, add_mod_special_3);
    test_add_mod_special!(4, add_mod_special_4);
    test_add_mod_special!(5, add_mod_special_5);
    test_add_mod_special!(6, add_mod_special_6);
    test_add_mod_special!(7, add_mod_special_7);
    test_add_mod_special!(8, add_mod_special_8);
    test_add_mod_special!(9, add_mod_special_9);
    test_add_mod_special!(10, add_mod_special_10);
    test_add_mod_special!(11, add_mod_special_11);
    test_add_mod_special!(12, add_mod_special_12);
}
