//! [`BoxedUint`] modular inverse (i.e. reciprocal) operations.

use crate::{
    BoxedUint, ConstantTimeSelect, Integer, InvertMod, Limb, NonZero, Odd, U64, modular::safegcd,
    uint::invert_mod::expand_invert_mod2k,
};
use subtle::{Choice, ConstantTimeEq, ConstantTimeLess, CtOption};

impl BoxedUint {
    /// Computes the multiplicative inverse of `self` mod `modulus`, where `modulus` is odd.
    #[deprecated(since = "0.7.0", note = "please use `invert_odd_mod` instead")]
    pub fn inv_odd_mod(&self, modulus: &Odd<Self>) -> CtOption<Self> {
        self.invert_odd_mod(modulus)
    }

    /// Computes the multiplicative inverse of `self` mod `modulus`, where `modulus` is odd.
    pub fn invert_odd_mod(&self, modulus: &Odd<Self>) -> CtOption<Self> {
        safegcd::boxed::invert_odd_mod::<false>(self, modulus)
    }

    /// Computes the multiplicative inverse of `self` mod `modulus`, where `modulus` is odd.
    pub fn invert_odd_mod_vartime(&self, modulus: &Odd<Self>) -> CtOption<Self> {
        safegcd::boxed::invert_odd_mod::<true>(self, modulus)
    }

    /// Computes 1/`self` mod `2^k`.
    /// This method is constant-time w.r.t. `self` but not `k`.
    ///
    /// If the inverse does not exist (`k > 0` and `self` is even, or `k > bits_precision()`),
    /// returns `Choice::FALSE` as the second element of the tuple, otherwise returns `Choice::TRUE`.
    #[deprecated(since = "0.7.0", note = "please use `invert_mod2k_vartime` instead")]
    pub fn inv_mod2k_vartime(&self, k: u32) -> (Self, Choice) {
        self.invert_mod2k_vartime(k)
    }

    /// Computes 1/`self` mod `2^k`.
    /// This method is constant-time w.r.t. `self` but not `k`.
    ///
    /// If the inverse does not exist (`k > 0` and `self` is even, or `k > bits_precision()`),
    /// returns `Choice::FALSE` as the second element of the tuple, otherwise returns `Choice::TRUE`.
    pub fn invert_mod2k_vartime(&self, k: u32) -> (Self, Choice) {
        let bits = self.bits_precision();

        if k == 0 {
            (Self::zero_with_precision(bits), Choice::from(1))
        } else if k > bits {
            (Self::zero_with_precision(bits), Choice::from(0))
        } else {
            let is_some = self.is_odd();
            let inv = Odd(Self::ct_select(
                &Self::one_with_precision(bits),
                self,
                is_some,
            ))
            .invert_mod2k_vartime(k);
            (inv, is_some)
        }
    }

    /// Computes 1/`self` mod `2^k`.
    ///
    /// If the inverse does not exist (`k > 0` and `self` is even, or `k > bits_precision()`),
    /// returns `Choice::FALSE` as the second element of the tuple, otherwise returns `Choice::TRUE`.
    #[deprecated(since = "0.7.0", note = "please use `invert_mod2k` instead")]
    pub fn inv_mod2k(&self, k: u32) -> (Self, Choice) {
        self.invert_mod2k(k)
    }

    /// Computes 1/`self` mod `2^k`.
    ///
    /// If the inverse does not exist (`k > 0` and `self` is even, or `k > bits_precision()`),
    /// returns `Choice::FALSE` as the second element of the tuple, otherwise returns `Choice::TRUE`.
    pub fn invert_mod2k(&self, k: u32) -> (Self, Choice) {
        let bits = self.bits_precision();
        let is_some = k.ct_lt(&(bits + 1)) & (k.ct_eq(&0) | self.is_odd());
        let mut inv = Odd(Self::ct_select(
            &Self::one_with_precision(bits),
            self,
            is_some,
        ))
        .invert_mod_precision();
        inv.restrict_bits(k);
        (inv, is_some)
    }

    /// Computes the multiplicaitve inverse of `self` mod `modulus`
    ///
    /// `self` and `modulus` must have the same number of limbs, or the function will panic
    ///
    /// TODO: maybe some better documentation is needed
    #[deprecated(since = "0.7.0", note = "please use `invert_mod` instead")]
    pub fn inv_mod(&self, modulus: &Self) -> CtOption<Self> {
        let is_nz = modulus.is_nonzero();
        let m = NonZero(Self::ct_select(
            &Self::one_with_precision(self.bits_precision()),
            modulus,
            is_nz,
        ));
        let inv_mod_s = self.invert_mod(&m);
        let is_some = inv_mod_s.is_some();
        let result =
            Option::from(inv_mod_s).unwrap_or(Self::zero_with_precision(self.bits_precision()));
        CtOption::new(result, is_some & is_nz)
    }

    /// Computes the multiplicaitve inverse of `self` mod `modulus`
    ///
    /// `self` and `modulus` must have the same number of limbs, or the function will panic
    ///
    /// TODO: maybe some better documentation is needed
    pub fn invert_mod(&self, modulus: &NonZero<Self>) -> CtOption<Self> {
        debug_assert_eq!(self.bits_precision(), modulus.bits_precision());
        let k = modulus.trailing_zeros();
        let s = Odd(modulus.shr(k));

        let inv_mod_s = self.invert_odd_mod(&s);
        let invertible_mod_s = inv_mod_s.is_some();
        // NOTE: this is some strange acrobatics to get around BoxedUint not supporting
        // ConditionallySelectable
        let inv_mod_s =
            Option::from(inv_mod_s).unwrap_or(Self::zero_with_precision(self.bits_precision()));

        let (inverse_mod2k, invertible_mod_2k) = self.invert_mod2k(k);
        let is_some = invertible_mod_s & invertible_mod_2k;

        let s_inverse_mod2k = s.invert_mod_precision();
        let mut t = inverse_mod2k
            .wrapping_sub(&inv_mod_s)
            .wrapping_mul(&s_inverse_mod2k);
        t.restrict_bits(k);
        let result = inv_mod_s.wrapping_add(&s.wrapping_mul(&t));

        CtOption::new(result, is_some)
    }
}

impl Odd<BoxedUint> {
    /// Compute a full-width quadratic inversion, `self^-1 mod 2^bits_precision()`.
    #[inline]
    pub(crate) fn invert_mod_precision(&self) -> BoxedUint {
        self.invert_mod2k_vartime(self.bits_precision())
    }

    /// Compute a quadratic inversion, `self^-1 mod 2^k` where `k <= bits_precision()`.
    ///
    /// This method is variable-time in `k` only.
    pub(crate) fn invert_mod2k_vartime(&self, k: u32) -> BoxedUint {
        let bits = self.bits_precision();
        assert!(k <= bits);

        let k_limbs = k.div_ceil(Limb::BITS) as usize;
        let inv_64 = U64::from_u64(self.as_uint_ref().invert_mod_u64());
        let mut inv = BoxedUint::from_words_with_precision(*inv_64.as_words(), bits);

        if k_limbs <= U64::LIMBS {
            // trim to k_limbs
            inv.as_mut_uint_ref().trailing_mut(k_limbs).fill(Limb::ZERO);
        } else {
            // expand to k_limbs
            let mut scratch = BoxedUint::zero_with_precision(k_limbs as u32 * 2 * Limb::BITS);
            expand_invert_mod2k(
                self.as_uint_ref(),
                inv.as_mut_uint_ref().leading_mut(k_limbs),
                U64::LIMBS,
                scratch.as_mut_uint_ref().split_at_mut(k_limbs),
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

impl InvertMod for BoxedUint {
    type Output = Self;

    fn invert_mod(&self, modulus: &NonZero<Self>) -> CtOption<Self> {
        self.invert_mod(modulus)
    }
}

#[cfg(test)]
mod tests {
    use crate::{Limb, Odd, Resize, U256};

    use super::BoxedUint;
    use hex_literal::hex;

    #[test]
    fn invert_mod2k() {
        let v = BoxedUint::from_be_slice(
            &hex!("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f"),
            256,
        )
        .unwrap();
        let e = BoxedUint::from_be_slice(
            &hex!("3642e6faeaac7c6663b93d3d6a0d489e434ddc0123db5fa627c7f6e22ddacacf"),
            256,
        )
        .unwrap();
        let (a, is_some) = v.invert_mod2k(256);
        assert_eq!(e, a);
        assert!(bool::from(is_some));

        let v = BoxedUint::from_be_slice(
            &hex!("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"),
            256,
        )
        .unwrap();
        let e = BoxedUint::from_be_slice(
            &hex!("261776f29b6b106c7680cf3ed83054a1af5ae537cb4613dbb4f20099aa774ec1"),
            256,
        )
        .unwrap();
        let (a, is_some) = v.invert_mod2k(256);
        assert_eq!(e, a);
        assert!(bool::from(is_some));
    }

    #[test]
    fn inv_odd() {
        let a = BoxedUint::from_be_hex(
            concat![
                "000225E99153B467A5B451979A3F451DAEF3BF8D6C6521D2FA24BBB17F29544E",
                "347A412B065B75A351EA9719E2430D2477B11CC9CF9C1AD6EDEE26CB15F463F8",
                "BCC72EF87EA30288E95A48AA792226CEC959DCB0672D8F9D80A54CBBEA85CAD8",
                "382EC224DEB2F5784E62D0CC2F81C2E6AD14EBABE646D6764B30C32B87688985"
            ],
            1024,
        )
        .unwrap();
        let m = BoxedUint::from_be_hex(
            concat![
                "D509E7854ABDC81921F669F1DC6F61359523F3949803E58ED4EA8BC16483DC6F",
                "37BFE27A9AC9EEA2969B357ABC5C0EE214BE16A7D4C58FC620D5B5A20AFF001A",
                "D198D3155E5799DC4EA76652D64983A7E130B5EACEBAC768D28D589C36EC749C",
                "558D0B64E37CD0775C0D0104AE7D98BA23C815185DD43CD8B16292FD94156767"
            ],
            1024,
        )
        .unwrap()
        .to_odd()
        .unwrap();
        let expected = BoxedUint::from_be_hex(
            concat![
                "B03623284B0EBABCABD5C5881893320281460C0A8E7BF4BFDCFFCBCCBF436A55",
                "D364235C8171E46C7D21AAD0680676E57274A8FDA6D12768EF961CACDD2DAE57",
                "88D93DA5EB8EDC391EE3726CDCF4613C539F7D23E8702200CB31B5ED5B06E5CA",
                "3E520968399B4017BF98A864FABA2B647EFC4998B56774D4F2CB026BC024A336"
            ],
            1024,
        )
        .unwrap();
        assert_eq!(a.invert_odd_mod(&m).unwrap(), expected);

        assert_eq!(a.invert_mod(m.as_nz_ref()).unwrap(), expected);
    }

    #[test]
    fn test_invert_odd_no_inverse() {
        // 2^128 - 159, a prime
        let p1 = BoxedUint::from_be_hex(
            "00000000000000000000000000000000ffffffffffffffffffffffffffffff61",
            256,
        )
        .unwrap();
        // 2^128 - 173, a prime
        let p2 = BoxedUint::from_be_hex(
            "00000000000000000000000000000000ffffffffffffffffffffffffffffff53",
            256,
        )
        .unwrap();

        let m = p1.wrapping_mul(&p2).to_odd().unwrap();

        // `m` is a multiple of `p1`, so no inverse exists
        let res = p1.invert_odd_mod(&m);
        let is_none: bool = res.is_none().into();
        assert!(is_none);
    }

    #[test]
    fn test_invert_even() {
        let a = BoxedUint::from_be_hex(
            concat![
                "000225E99153B467A5B451979A3F451DAEF3BF8D6C6521D2FA24BBB17F29544E",
                "347A412B065B75A351EA9719E2430D2477B11CC9CF9C1AD6EDEE26CB15F463F8",
                "BCC72EF87EA30288E95A48AA792226CEC959DCB0672D8F9D80A54CBBEA85CAD8",
                "382EC224DEB2F5784E62D0CC2F81C2E6AD14EBABE646D6764B30C32B87688985"
            ],
            1024,
        )
        .unwrap();
        let m = BoxedUint::from_be_hex(
            concat![
                "D509E7854ABDC81921F669F1DC6F61359523F3949803E58ED4EA8BC16483DC6F",
                "37BFE27A9AC9EEA2969B357ABC5C0EE214BE16A7D4C58FC620D5B5A20AFF001A",
                "D198D3155E5799DC4EA76652D64983A7E130B5EACEBAC768D28D589C36EC749C",
                "558D0B64E37CD0775C0D0104AE7D98BA23C815185DD43CD8B16292FD94156000"
            ],
            1024,
        )
        .unwrap()
        .to_nz()
        .unwrap();
        let expected = BoxedUint::from_be_hex(
            concat![
                "1EBF391306817E1BC610E213F4453AD70911CCBD59A901B2A468A4FC1D64F357",
                "DBFC6381EC5635CAA664DF280028AF4651482C77A143DF38D6BFD4D64B6C0225",
                "FC0E199B15A64966FB26D88A86AD144271F6BDCD3D63193AB2B3CC53B99F21A3",
                "5B9BFAE5D43C6BC6E7A9856C71C7318C76530E9E5AE35882D5ABB02F1696874D",
            ],
            1024,
        )
        .unwrap();

        let res = a.invert_mod(&m).unwrap();
        assert_eq!(res, expected);
    }

    #[test]
    fn test_invert_small() {
        let a = BoxedUint::from(3u64);
        let m = BoxedUint::from(13u64).to_odd().unwrap();

        let res = a.invert_odd_mod(&m).unwrap();
        assert_eq!(BoxedUint::from(9u64), res);
    }

    #[test]
    fn test_no_inverse_small() {
        let a = BoxedUint::from(14u64);
        let m = BoxedUint::from(49u64).to_odd().unwrap();

        let res = a.invert_odd_mod(&m);
        let is_none: bool = res.is_none().into();
        assert!(is_none);
    }

    #[test]
    fn test_invert_edge() {
        assert!(bool::from(
            BoxedUint::zero()
                .invert_odd_mod(&BoxedUint::one().to_odd().unwrap())
                .is_none()
        ));
        assert_eq!(
            BoxedUint::one()
                .invert_odd_mod(&BoxedUint::one().to_odd().unwrap())
                .unwrap(),
            BoxedUint::zero()
        );
        assert_eq!(
            BoxedUint::one()
                .invert_odd_mod(&BoxedUint::from(U256::MAX).to_odd().unwrap())
                .unwrap(),
            BoxedUint::one()
        );
        assert!(bool::from(
            BoxedUint::from(U256::MAX)
                .invert_odd_mod(&BoxedUint::from(U256::MAX).to_odd().unwrap())
                .is_none()
        ));
    }

    #[test]
    fn invert_mod_precision() {
        const PRECISION: u32 = 8 * Limb::BITS;

        for limbs in 1..10 {
            let a = Odd(BoxedUint::max(PRECISION).resize_unchecked(limbs));
            let a_inv = a.invert_mod_precision();
            assert_eq!(a.as_ref().wrapping_mul(&a_inv), BoxedUint::one());
        }
    }
}
