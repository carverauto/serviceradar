//! Operations related to computing the inverse of an [`Int`] modulo a [`Uint`].

use subtle::CtOption;

use crate::{ConstCtOption, Int, InvertMod, NonZero, Odd, Uint};

impl<const LIMBS: usize> Int<LIMBS> {
    /// Computes the multiplicative inverse of `self` mod `modulus`, where `modulus` is odd.
    pub fn invert_odd_mod(&self, modulus: &Odd<Uint<LIMBS>>) -> ConstCtOption<Uint<LIMBS>> {
        let (abs, sgn) = self.abs_sign();
        let maybe_inv = abs.invert_odd_mod(modulus);
        let (abs_inv, inv_is_some) = maybe_inv.components_ref();
        // Note: when `self` is negative and modulus is non-zero, then
        // self^{-1} % modulus = modulus - |self|^{-1} % modulus
        ConstCtOption::new(
            Uint::select(abs_inv, &modulus.wrapping_sub(abs_inv), sgn),
            inv_is_some,
        )
    }

    /// Computes the multiplicative inverse of `self` mod `modulus`.
    ///
    /// Returns some if an inverse exists, otherwise none.
    pub const fn invert_mod(&self, modulus: &NonZero<Uint<LIMBS>>) -> ConstCtOption<Uint<LIMBS>> {
        let (abs, sgn) = self.abs_sign();
        let maybe_inv = abs.invert_mod(modulus);
        let (abs_inv, inv_is_some) = maybe_inv.components_ref();
        // Note: when `self` is negative and modulus is non-zero, then
        // self^{-1} % modulus = modulus - |self|^{-1} % modulus
        ConstCtOption::new(
            Uint::select(abs_inv, &modulus.as_ref().wrapping_sub(abs_inv), sgn),
            inv_is_some,
        )
    }
}

impl<const LIMBS: usize> InvertMod<NonZero<Uint<LIMBS>>> for Int<LIMBS>
where
    Uint<LIMBS>: InvertMod<Output = Uint<LIMBS>>,
{
    type Output = Uint<LIMBS>;

    fn invert_mod(&self, modulus: &NonZero<Uint<LIMBS>>) -> CtOption<Self::Output> {
        Self::invert_mod(self, modulus).into()
    }
}

#[cfg(test)]
mod tests {
    use crate::{I1024, U1024};

    #[test]
    fn test_invert_odd() {
        let a = I1024::from_be_hex(concat![
            "FFFDDA166EAC4B985A4BAE6865C0BAE2510C4072939ADE2D05DB444E80D6ABB1",
            "CB85BED4F9A48A5CAE1568E61DBCF2DB884EE3363063E5291211D934EA0B9C07",
            "4338D107815CFD7716A5B75586DDD93136A6234F98D270627F5AB344157A3527",
            "C7D13DDB214D0A87B19D2F33D07E3D1952EB145419B92989B4CF3CD47897767B"
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
            "24D3C45CFFAF0D5C7620A469C3DC2F3313DDE78A0987F0CEF7EABFF4A5407219",
            "645BBF1E19580A3619798AAA545597FCA2496DAA2DF4685D313F98F52DD151C3",
            "48BF956F72C8BDA32FC3F3E5F955226B8D9138C6E64AA568075BA2AEDBE58ED2",
            "173B01FCA9E1905F9C74589FB3C36D55A4CBCB7FA86CC803BE979091D3F0C431"
        ]);

        let res = a.invert_odd_mod(&m).unwrap();
        assert_eq!(res, expected);

        // Even though it is less efficient, it still works
        let res = a.invert_mod(&m.to_nz().unwrap()).unwrap();
        assert_eq!(res, expected);
    }

    #[test]
    fn test_invert_even() {
        let a = I1024::from_be_hex(concat![
            "FFFDDA166EAC4B985A4BAE6865C0BAE2510C4072939ADE2D05DB444E80D6ABB1",
            "CB85BED4F9A48A5CAE1568E61DBCF2DB884EE3363063E5291211D934EA0B9C07",
            "4338D107815CFD7716A5B75586DDD93136A6234F98D270627F5AB344157A3527",
            "C7D13DDB214D0A87B19D2F33D07E3D1952EB145419B92989B4CF3CD47897767B",
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
            "B64AAE72443C49FD5BE587DDE82A265E8C1226D73E5AE3DC3081E6C5471EE917",
            "5BC37EF8AE73B8D7F0365652BC335F9BC375EA303381B08D4A15E0CBBF92FDF4",
            "D58AB97A48B1507553808DC84F9C6F656F39F81D9157AE2E1FD98C487D4D52F8",
            "F9F1107F0F4064B074637B983CB6672DAD75067A02F0E455DBB6E2CE7D7ED8B3",
        ]);

        let res = a.invert_mod(&m).unwrap();
        assert_eq!(res, expected);
    }
}
