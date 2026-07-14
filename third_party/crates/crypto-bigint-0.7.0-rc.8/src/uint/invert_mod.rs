use super::Uint;
use crate::{
    ConstChoice, ConstCtOption, InvertMod, Limb, NonZero, Odd, U64, UintRef, modular::safegcd,
    mul::karatsuba,
};

use subtle::CtOption;

/// Perform a modified recursive Hensel quadratic modular inversion to calculate
/// `a^-1 mod w^p` given `a^-1 mod w^k` where `w` is the size of `Limb`.
/// For reference see Algorithm 2: <https://arxiv.org/pdf/1209.6626>
///
/// `p` is determined by the length of the in-out buffer `buf`, which must be
/// pre-populated with `a^-1 mod w^k` (constituting `k` limbs).
///
/// This method uses recursion, but the maximum depth is limited by
/// the bit-width of the number of limbs being inverted (`p`).
///
/// This method is variable time in `k` and `p` only.
///
/// `scratch` must be a pair of mutable buffers, each with capacity at least `p`.
#[inline]
pub(crate) const fn expand_invert_mod2k(
    a: &Odd<UintRef>,
    buf: &mut UintRef,
    mut k: usize,
    scratch: (&mut UintRef, &mut UintRef),
) {
    assert!(k > 0);
    let p = buf.nlimbs();
    let zs = p.trailing_zeros();

    // Calculate a target width at which we may need to trim the output of
    // the doubling loop. We reduce the size of `p` by eliminating multiple factors
    // of two or a single odd factor, recursing until the target width is small enough
    // to calculate by doubling without significant overhead.
    let mut target = if zs > 0 { p >> zs } else { p.div_ceil(2) };
    if target > 8 {
        expand_invert_mod2k(a, buf.leading_mut(target), k, (scratch.0, scratch.1));
        k = target;
        target = p;
    } else if target <= k {
        target = p;
    }

    // Perform the required number of doublings.
    while k < p {
        let mut k2 = k * 2;
        // `target` represents the point at which we may need to trim the output before
        // continuing with the doubling until we reach `p`.
        if k2 >= target {
            (k2, target) = (target, p);
        }
        expand_invert_mod2k_step(a, buf.leading_mut(k2), k, (scratch.0, scratch.1));
        k = k2;
    }
}

/// One step of the Hensel quadratic modular inverse calculation, doubling the width
/// of the inverted output, and wrapping at capacity of `buf`.
#[inline(always)]
const fn expand_invert_mod2k_step(
    a: &Odd<UintRef>,
    buf: &mut UintRef,
    buf_init_len: usize,
    scratch: (&mut UintRef, &mut UintRef),
) {
    let new_len = buf.nlimbs();
    assert!(
        scratch.0.nlimbs() >= new_len
            && scratch.1.nlimbs() >= new_len
            && buf_init_len < new_len
            && buf_init_len >= new_len / 2
    );

    // Calculate u0^2, wrapping at `new_len` words
    let u0_p2 = scratch.0.leading_mut(new_len);
    u0_p2.fill(Limb::ZERO);
    karatsuba::wrapping_square(buf.leading(buf_init_len), u0_p2);

    // tmp = u0^2•a
    let tmp = scratch.1.leading_mut(new_len);
    tmp.fill(Limb::ZERO);
    karatsuba::wrapping_mul(u0_p2, a.as_ref(), tmp, false);

    // u1 = u0 << 1
    buf.shl1_assign();
    // u1 -= u0^2•a
    buf.borrowing_sub_assign(tmp, Limb::ZERO);
}

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Computes 1/`self` mod `2^k`.
    /// This method is constant-time w.r.t. `self` but not `k`.
    ///
    /// If the inverse does not exist (`k > 0` and `self` is even),
    /// returns `ConstChoice::FALSE` as the second element of the tuple,
    /// otherwise returns `ConstChoice::TRUE`.
    #[deprecated(since = "0.7.0", note = "please use `invert_mod2k_vartime` instead")]
    pub const fn inv_mod2k_vartime(&self, k: u32) -> ConstCtOption<Self> {
        self.invert_mod2k_vartime(k)
    }

    /// Computes 1/`self` mod `2^k`.
    /// This method is constant-time w.r.t. `self` but not `k`.
    ///
    /// If the inverse does not exist (`k > 0` and `self` is even, or `k > Self::BITS`),
    /// returns `ConstCtOption::none`, otherwise returns `ConstCtOption::some`.
    pub const fn invert_mod2k_vartime(&self, k: u32) -> ConstCtOption<Self> {
        if k == 0 {
            ConstCtOption::some(Self::ZERO)
        } else if k > Self::BITS {
            ConstCtOption::none(Self::ZERO)
        } else {
            let is_some = self.is_odd();
            let inv = Odd(Uint::select(&Uint::ONE, self, is_some)).invert_mod2k_vartime(k);
            ConstCtOption::new(inv, is_some)
        }
    }

    /// Computes 1/`self` mod `2^k`.
    ///
    /// If the inverse does not exist (`k > 0` and `self` is even, `k > Self::BITS`),
    /// returns `ConstCtOption::none`, otherwise returns `ConstCtOption::some`.
    #[deprecated(since = "0.7.0", note = "please use `invert_mod2k` instead")]
    pub const fn inv_mod2k(&self, k: u32) -> ConstCtOption<Self> {
        self.invert_mod2k(k)
    }

    /// Computes 1/`self` mod `2^k`.
    ///
    /// If the inverse does not exist (`k > 0` and `self` is even, or `k > Self::BITS`),
    /// returns `ConstCtOption::none`, otherwise returns `ConstCtOption::some`.
    pub const fn invert_mod2k(&self, k: u32) -> ConstCtOption<Self> {
        let is_some = ConstChoice::from_u32_le(k, Self::BITS)
            .and(ConstChoice::from_u32_nonzero(k).not().or(self.is_odd()));
        let inv = Odd(Uint::select(&Uint::ONE, self, is_some)).invert_mod_precision();
        ConstCtOption::new(inv.restrict_bits(k), is_some)
    }

    /// Computes the multiplicative inverse of `self` mod `modulus`, where `modulus` is odd.
    #[deprecated(since = "0.7.0", note = "please use `invert_odd_mod` instead")]
    pub const fn inv_odd_mod(&self, modulus: &Odd<Self>) -> ConstCtOption<Self> {
        self.invert_odd_mod(modulus)
    }

    /// Computes the multiplicative inverse of `self` mod `modulus`, where `modulus` is odd.
    pub const fn invert_odd_mod(&self, modulus: &Odd<Self>) -> ConstCtOption<Self> {
        safegcd::invert_odd_mod::<LIMBS, false>(self, modulus)
    }

    /// Computes the multiplicative inverse of `self` mod `modulus`, where `modulus` is odd.
    pub const fn invert_odd_mod_vartime(&self, modulus: &Odd<Self>) -> ConstCtOption<Self> {
        safegcd::invert_odd_mod::<LIMBS, true>(self, modulus)
    }

    /// Computes the multiplicative inverse of `self` mod `modulus`.
    ///
    /// Returns some if an inverse exists, otherwise none.
    #[deprecated(since = "0.7.0", note = "please use `invert_mod` instead")]
    pub const fn inv_mod(&self, modulus: &Self) -> ConstCtOption<Self> {
        let is_nz = modulus.is_nonzero();
        let m = NonZero(Uint::select(&Uint::ONE, modulus, is_nz));
        self.invert_mod(&m).and_choice(is_nz)
    }

    /// Computes the multiplicative inverse of `self` mod `modulus`.
    ///
    /// Returns some if an inverse exists, otherwise none.
    pub const fn invert_mod(&self, modulus: &NonZero<Self>) -> ConstCtOption<Self> {
        // Decompose `modulus = s * 2^k` where `s` is odd
        let k = modulus.as_ref().trailing_zeros();
        let s = Odd(modulus.as_ref().shr(k));

        // Decompose `self` into RNS with moduli `2^k` and `s` and calculate the inverses.
        // Using the fact that `(z^{-1} mod (m1 * m2)) mod m1 == z^{-1} mod m1`
        let maybe_a = self.invert_odd_mod(&s);

        let maybe_b = self.invert_mod2k(k);
        let is_some = maybe_a.is_some().and(maybe_b.is_some());

        // Unwrap to avoid mapping through ConstCtOptions.
        // if `a` or `b` don't exist, the returned ConstCtOption will be None anyway.
        let a = maybe_a.unwrap_or(Uint::ZERO);
        let b = maybe_b.unwrap_or(Uint::ZERO);

        // Restore from RNS:
        // self^{-1} = a mod s = b mod 2^k
        // => self^{-1} = a + s * ((b - a) * s^(-1) mod 2^k)
        // (essentially one step of the Garner's algorithm for recovery from RNS).

        // `s` is odd, so this always exists
        let m_odd_inv = s.invert_mod_precision();

        // This part is mod 2^k
        let t = b.wrapping_sub(&a).wrapping_mul(&m_odd_inv).restrict_bits(k);

        // Will not overflow since `a <= s - 1`, `t <= 2^k - 1`,
        // so `a + s * t <= s * 2^k - 1 == modulus - 1`.
        let result = a.wrapping_add(&s.as_ref().wrapping_mul(&t));
        ConstCtOption::new(result, is_some)
    }
}

impl<const LIMBS: usize> Odd<Uint<LIMBS>> {
    /// Compute a full-width quadratic inversion, `self^-1 mod 2^Self::BITS`.
    #[inline]
    pub(crate) const fn invert_mod_precision(&self) -> Uint<LIMBS> {
        self.invert_mod2k_vartime(Self::BITS)
    }

    /// Compute a quadratic inversion, `self^-1 mod 2^k` where `k <= Self::BITS`.
    ///
    /// This method is variable-time in `k` only.
    pub(crate) const fn invert_mod2k_vartime(&self, k: u32) -> Uint<LIMBS> {
        assert!(k <= Self::BITS);

        let k_limbs = k.div_ceil(Limb::BITS) as usize;
        let mut inv = U64::from_u64(self.as_uint_ref().invert_mod_u64()).resize::<LIMBS>();

        if k_limbs <= U64::LIMBS {
            // trim to k_limbs
            inv.as_mut_uint_ref().trailing_mut(k_limbs).fill(Limb::ZERO);
        } else {
            // expand to k_limbs
            let mut scratch = (Uint::<LIMBS>::ZERO, Uint::<LIMBS>::ZERO);
            expand_invert_mod2k(
                self.as_uint_ref(),
                inv.as_mut_uint_ref().leading_mut(k_limbs),
                U64::LIMBS,
                (scratch.0.as_mut_uint_ref(), scratch.1.as_mut_uint_ref()),
            );
        }

        // clear bits in the high limb if necessary
        let k_bits = k % Limb::BITS;
        if k_bits > 0 {
            inv.limbs[k_limbs - 1] = inv.limbs[k_limbs - 1].restrict_bits(k_bits);
        }

        inv
    }
}

impl<const LIMBS: usize> InvertMod for Uint<LIMBS> {
    type Output = Self;

    fn invert_mod(&self, modulus: &NonZero<Self>) -> CtOption<Self> {
        self.invert_mod(modulus).into()
    }
}

#[cfg(test)]
mod tests {
    use crate::{Odd, U64, U256, U1024, Uint};

    #[test]
    fn invert_mod2k() {
        let v =
            U256::from_be_hex("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f");
        let e =
            U256::from_be_hex("3642e6faeaac7c6663b93d3d6a0d489e434ddc0123db5fa627c7f6e22ddacacf");
        let a = v.invert_mod2k(256).unwrap();
        assert_eq!(e, a);

        let a = v.invert_mod2k_vartime(256).unwrap();
        assert_eq!(e, a);

        let v =
            U256::from_be_hex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");
        let e =
            U256::from_be_hex("261776f29b6b106c7680cf3ed83054a1af5ae537cb4613dbb4f20099aa774ec1");
        let a = v.invert_mod2k(256).unwrap();
        assert_eq!(e, a);

        let a = v.invert_mod2k_vartime(256).unwrap();
        assert_eq!(e, a);

        // Check that even if the number is >= 2^k, the inverse is still correct.

        let v =
            U256::from_be_hex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");
        let e =
            U256::from_be_hex("0000000000000000000000000000000000000000034613dbb4f20099aa774ec1");
        let a = v.invert_mod2k(90).unwrap();
        assert_eq!(e, a);

        let a = v.invert_mod2k_vartime(90).unwrap();
        assert_eq!(e, a);

        // An inverse of an even number does not exist.

        let a = U256::from(10u64).invert_mod2k(4);
        assert!(a.is_none().is_true_vartime());

        let a = U256::from(10u64).invert_mod2k_vartime(4);
        assert!(a.is_none().is_true_vartime());

        // A degenerate case. An inverse mod 2^0 == 1 always exists even for even numbers.

        let a = U256::from(10u64).invert_mod2k_vartime(0).unwrap();
        assert_eq!(a, U256::ZERO);
    }

    #[test]
    fn test_invert_odd() {
        let a = U1024::from_be_hex(concat![
            "000225E99153B467A5B451979A3F451DAEF3BF8D6C6521D2FA24BBB17F29544E",
            "347A412B065B75A351EA9719E2430D2477B11CC9CF9C1AD6EDEE26CB15F463F8",
            "BCC72EF87EA30288E95A48AA792226CEC959DCB0672D8F9D80A54CBBEA85CAD8",
            "382EC224DEB2F5784E62D0CC2F81C2E6AD14EBABE646D6764B30C32B87688985"
        ]);
        let m = U1024::from_be_hex(concat![
            "D509E7854ABDC81921F669F1DC6F61359523F3949803E58ED4EA8BC16483DC6F",
            "37BFE27A9AC9EEA2969B357ABC5C0EE214BE16A7D4C58FC620D5B5A20AFF001A",
            "D198D3155E5799DC4EA76652D64983A7E130B5EACEBAC768D28D589C36EC749C",
            "558D0B64E37CD0775C0D0104AE7D98BA23C815185DD43CD8B16292FD94156767"
        ])
        .to_odd()
        .unwrap();
        let expected = U1024::from_be_hex(concat![
            "B03623284B0EBABCABD5C5881893320281460C0A8E7BF4BFDCFFCBCCBF436A55",
            "D364235C8171E46C7D21AAD0680676E57274A8FDA6D12768EF961CACDD2DAE57",
            "88D93DA5EB8EDC391EE3726CDCF4613C539F7D23E8702200CB31B5ED5B06E5CA",
            "3E520968399B4017BF98A864FABA2B647EFC4998B56774D4F2CB026BC024A336"
        ]);

        let res = a.invert_odd_mod(&m).unwrap();
        assert_eq!(res, expected);

        // Even though it is less efficient, it still works
        let res = a.invert_mod(m.as_nz_ref()).unwrap();
        assert_eq!(res, expected);
    }

    #[test]
    fn test_invert_odd_no_inverse() {
        // 2^128 - 159, a prime
        let p1 =
            U256::from_be_hex("00000000000000000000000000000000ffffffffffffffffffffffffffffff61");
        // 2^128 - 173, a prime
        let p2 =
            U256::from_be_hex("00000000000000000000000000000000ffffffffffffffffffffffffffffff53");

        let m = p1.wrapping_mul(&p2).to_odd().unwrap();

        // `m` is a multiple of `p1`, so no inverse exists
        let res = p1.invert_odd_mod(&m);
        assert!(res.is_none().is_true_vartime());
    }

    #[test]
    fn test_invert_even() {
        let a = U1024::from_be_hex(concat![
            "000225E99153B467A5B451979A3F451DAEF3BF8D6C6521D2FA24BBB17F29544E",
            "347A412B065B75A351EA9719E2430D2477B11CC9CF9C1AD6EDEE26CB15F463F8",
            "BCC72EF87EA30288E95A48AA792226CEC959DCB0672D8F9D80A54CBBEA85CAD8",
            "382EC224DEB2F5784E62D0CC2F81C2E6AD14EBABE646D6764B30C32B87688985"
        ]);
        let m = U1024::from_be_hex(concat![
            "D509E7854ABDC81921F669F1DC6F61359523F3949803E58ED4EA8BC16483DC6F",
            "37BFE27A9AC9EEA2969B357ABC5C0EE214BE16A7D4C58FC620D5B5A20AFF001A",
            "D198D3155E5799DC4EA76652D64983A7E130B5EACEBAC768D28D589C36EC749C",
            "558D0B64E37CD0775C0D0104AE7D98BA23C815185DD43CD8B16292FD94156000"
        ])
        .to_nz()
        .unwrap();
        let expected = U1024::from_be_hex(concat![
            "1EBF391306817E1BC610E213F4453AD70911CCBD59A901B2A468A4FC1D64F357",
            "DBFC6381EC5635CAA664DF280028AF4651482C77A143DF38D6BFD4D64B6C0225",
            "FC0E199B15A64966FB26D88A86AD144271F6BDCD3D63193AB2B3CC53B99F21A3",
            "5B9BFAE5D43C6BC6E7A9856C71C7318C76530E9E5AE35882D5ABB02F1696874D",
        ]);

        let res = a.invert_mod(&m).unwrap();
        assert_eq!(res, expected);
    }

    #[test]
    fn test_invert_small() {
        let a = U64::from(3u64);
        let m = U64::from(13u64).to_odd().unwrap();

        let res = a.invert_odd_mod(&m).unwrap();
        assert_eq!(U64::from(9u64), res);
    }

    #[test]
    fn test_no_inverse_small() {
        let a = U64::from(14u64);
        let m = U64::from(49u64).to_odd().unwrap();

        let res = a.invert_odd_mod(&m);
        assert!(res.is_none().is_true_vartime());
    }

    #[test]
    fn test_invert_edge() {
        assert!(
            U256::ZERO
                .invert_odd_mod(&U256::ONE.to_odd().unwrap())
                .is_none()
                .to_bool_vartime()
        );
        assert_eq!(
            U256::ONE
                .invert_odd_mod(&U256::ONE.to_odd().unwrap())
                .unwrap(),
            U256::ZERO
        );
        assert_eq!(
            U256::ONE
                .invert_odd_mod(&U256::MAX.to_odd().unwrap())
                .unwrap(),
            U256::ONE
        );
        assert!(
            U256::MAX
                .invert_odd_mod(&U256::MAX.to_odd().unwrap())
                .is_none()
                .to_bool_vartime()
        );
        assert_eq!(
            U256::MAX
                .invert_odd_mod(&U256::ONE.to_odd().unwrap())
                .unwrap(),
            U256::ZERO
        );
    }

    #[test]
    fn invert_mod_precision() {
        const BIG: Odd<Uint<8>> = Odd(Uint::MAX);

        fn test_invert_size<const LIMBS: usize>() {
            let a = BIG.resize::<LIMBS>();
            let a_inv = a.invert_mod_precision();
            assert_eq!(a.as_ref().wrapping_mul(&a_inv), Uint::ONE);
        }

        test_invert_size::<1>();
        test_invert_size::<2>();
        test_invert_size::<3>();
        test_invert_size::<4>();
        test_invert_size::<5>();
        test_invert_size::<6>();
        test_invert_size::<7>();
        test_invert_size::<8>();
        test_invert_size::<9>();
        test_invert_size::<10>();
    }
}
