use super::FieldElement;
use crate::{AffinePoint, FieldBytes, NistP384, ProjectivePoint, Scalar};
use elliptic_curve::{
    array::Array,
    bigint::{ArrayEncoding, U384},
    consts::{U24, U72},
    ops::Reduce,
    subtle::Choice,
};
use hash2curve::MapToCurve;
use primeorder::osswu::{AffineOsswuMap, OsswuMap, OsswuMapParams, Sgn0};

#[cfg(feature = "group-digest")]
impl hash2curve::GroupDigest for NistP384 {
    const HASH_TO_CURVE_ID: &[u8] = b"P384_XMD:SHA-384_SSWU_RO_";
    const ENCODE_TO_CURVE_ID: &[u8] = b"P384_XMD:SHA-384_SSWU_NU_";

    type ExpandMsg = hash2curve::ExpandMsgXmd<sha2::Sha384>;
}

impl Reduce<Array<u8, U72>> for FieldElement {
    fn reduce(value: &Array<u8, U72>) -> Self {
        const F_2_288: FieldElement = FieldElement::from_hex_vartime(
            "000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000",
        );

        let mut d0 = FieldBytes::default();
        d0[12..].copy_from_slice(&value[0..36]);
        let d0 = FieldElement::from_uint_unchecked(U384::from_be_byte_array(d0));

        let mut d1 = FieldBytes::default();
        d1[12..].copy_from_slice(&value[36..]);
        let d1 = FieldElement::from_uint_unchecked(U384::from_be_byte_array(d1));

        d0 * F_2_288 + d1
    }
}

impl Sgn0 for FieldElement {
    fn sgn0(&self) -> Choice {
        self.is_odd()
    }
}

impl OsswuMap for FieldElement {
    const PARAMS: OsswuMapParams<Self> = OsswuMapParams {
        c1: &[
            0x0000_0000_3fff_ffff,
            0xbfff_ffff_c000_0000,
            0xffff_ffff_ffff_ffff,
            0xffff_ffff_ffff_ffff,
            0xffff_ffff_ffff_ffff,
            0x3fff_ffff_ffff_ffff,
        ],
        c2: FieldElement::from_hex_vartime(
            "2accb4a656b0249c71f0500e83da2fdd7f98e383d68b53871f872fcb9ccb80c53c0de1f8a80f7e1914e2ec69f5a626b3",
        ),
        map_a: FieldElement::from_u64(3).neg(),
        map_b: FieldElement::from_hex_vartime(
            "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
        ),
        z: FieldElement::from_u64(12).neg(),
    };
}

impl MapToCurve for NistP384 {
    type SecurityLevel = U24;
    type FieldElement = FieldElement;
    type Length = U72;

    fn map_to_curve(element: FieldElement) -> ProjectivePoint {
        AffinePoint::osswu(&element).into()
    }
}

impl Reduce<Array<u8, U72>> for Scalar {
    fn reduce(value: &Array<u8, U72>) -> Self {
        const F_2_288: Scalar = Scalar::from_hex_vartime(
            "000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000",
        );

        let mut d0 = FieldBytes::default();
        d0[12..].copy_from_slice(&value[0..36]);
        let d0 = Scalar::reduce(&U384::from_be_byte_array(d0));

        let mut d1 = FieldBytes::default();
        d1[12..].copy_from_slice(&value[36..]);
        let d1 = Scalar::reduce(&U384::from_be_byte_array(d1));

        d0 * F_2_288 + d1
    }
}

#[cfg(test)]
mod tests {
    use crate::{NistP384, Scalar, arithmetic::field::FieldElement};
    use elliptic_curve::{
        Curve,
        array::Array,
        bigint::{ArrayEncoding, CheckedSub, NonZero, U384, U576},
        consts::U72,
        group::cofactor::CofactorGroup,
        ops::Reduce,
        sec1::{self, ToEncodedPoint},
    };
    use hash2curve::{self, ExpandMsgXmd, MapToCurve};
    use hex_literal::hex;
    use primeorder::osswu::OsswuMap;
    use proptest::{num::u64::ANY, prelude::ProptestConfig, proptest};
    use sha2::Sha384;

    #[test]
    fn params() {
        let params = <FieldElement as OsswuMap>::PARAMS;

        let c1 = FieldElement::PARAMS
            .modulus()
            .checked_sub(&U384::from_u8(3))
            .unwrap()
            / NonZero::new(U384::from_u8(4)).unwrap();
        assert_eq!(
            Array::from_iter(params.c1.iter().rev().flat_map(|v| v.to_be_bytes())),
            c1.to_be_byte_array()
        );

        let c2 = FieldElement::from_u64(12).sqrt().unwrap();
        assert_eq!(params.c2, c2);
    }

    #[test]
    fn hash_to_curve() {
        struct TestVector {
            msg: &'static [u8],
            p_x: [u8; 48],
            p_y: [u8; 48],
            u_0: [u8; 48],
            u_1: [u8; 48],
            q0_x: [u8; 48],
            q0_y: [u8; 48],
            q1_x: [u8; 48],
            q1_y: [u8; 48],
        }

        const DST: &[u8] = b"QUUX-V01-CS02-with-P384_XMD:SHA-384_SSWU_RO_";

        const TEST_VECTORS: &[TestVector] = &[
            TestVector {
                msg: b"",
                p_x: hex!("eb9fe1b4f4e14e7140803c1d99d0a93cd823d2b024040f9c067a8eca1f5a2eeac9ad604973527a356f3fa3aeff0e4d83"),
                p_y: hex!("0c21708cff382b7f4643c07b105c2eaec2cead93a917d825601e63c8f21f6abd9abc22c93c2bed6f235954b25048bb1a"),
                u_0: hex!("25c8d7dc1acd4ee617766693f7f8829396065d1b447eedb155871feffd9c6653279ac7e5c46edb7010a0e4ff64c9f3b4"),
                u_1: hex!("59428be4ed69131df59a0c6a8e188d2d4ece3f1b2a3a02602962b47efa4d7905945b1e2cc80b36aa35c99451073521ac"),
                q0_x: hex!("e4717e29eef38d862bee4902a7d21b44efb58c464e3e1f0d03894d94de310f8ffc6de86786dd3e15a1541b18d4eb2846"),
                q0_y: hex!("6b95a6e639822312298a47526bb77d9cd7bcf76244c991c8cd70075e2ee6e8b9a135c4a37e3c0768c7ca871c0ceb53d4"),
                q1_x: hex!("509527cfc0750eedc53147e6d5f78596c8a3b7360e0608e2fab0563a1670d58d8ae107c9f04bcf90e89489ace5650efd"),
                q1_y: hex!("33337b13cb35e173fdea4cb9e8cce915d836ff57803dbbeb7998aa49d17df2ff09b67031773039d09fbd9305a1566bc4"),
            },
            TestVector {
                msg: b"abc",
                p_x: hex!("e02fc1a5f44a7519419dd314e29863f30df55a514da2d655775a81d413003c4d4e7fd59af0826dfaad4200ac6f60abe1"),
                p_y: hex!("01f638d04d98677d65bef99aef1a12a70a4cbb9270ec55248c04530d8bc1f8f90f8a6a859a7c1f1ddccedf8f96d675f6"),
                u_0: hex!("53350214cb6bef0b51abb791b1c4209a2b4c16a0c67e1ab1401017fad774cd3b3f9a8bcdf7f6229dd8dd5a075cb149a0"),
                u_1: hex!("c0473083898f63e03f26f14877a2407bd60c75ad491e7d26cbc6cc5ce815654075ec6b6898c7a41d74ceaf720a10c02e"),
                q0_x: hex!("fc853b69437aee9a19d5acf96a4ee4c5e04cf7b53406dfaa2afbdd7ad2351b7f554e4bbc6f5db4177d4d44f933a8f6ee"),
                q0_y: hex!("7e042547e01834c9043b10f3a8221c4a879cb156f04f72bfccab0c047a304e30f2aa8b2e260d34c4592c0c33dd0c6482"),
                q1_x: hex!("57912293709b3556b43a2dfb137a315d256d573b82ded120ef8c782d607c05d930d958e50cb6dc1cc480b9afc38c45f1"),
                q1_y: hex!("de9387dab0eef0bda219c6f168a92645a84665c4f2137c14270fb424b7532ff84843c3da383ceea24c47fa343c227bb8"),
            },
            TestVector {
                msg: b"abcdef0123456789",
                p_x: hex!("bdecc1c1d870624965f19505be50459d363c71a699a496ab672f9a5d6b78676400926fbceee6fcd1780fe86e62b2aa89"),
                p_y: hex!("57cf1f99b5ee00f3c201139b3bfe4dd30a653193778d89a0accc5e0f47e46e4e4b85a0595da29c9494c1814acafe183c"),
                u_0: hex!("aab7fb87238cf6b2ab56cdcca7e028959bb2ea599d34f68484139dde85ec6548a6e48771d17956421bdb7790598ea52e"),
                u_1: hex!("26e8d833552d7844d167833ca5a87c35bcfaa5a0d86023479fb28e5cd6075c18b168bf1f5d2a0ea146d057971336d8d1"),
                q0_x: hex!("0ceece45b73f89844671df962ad2932122e878ad2259e650626924e4e7f132589341dec1480ebcbbbe3509d11fb570b7"),
                q0_y: hex!("fafd71a3115298f6be4ae5c6dfc96c400cfb55760f185b7b03f3fa45f3f91eb65d27628b3c705cafd0466fafa54883ce"),
                q1_x: hex!("dea1be8d3f9be4cbf4fab9d71d549dde76875b5d9b876832313a083ec81e528cbc2a0a1d0596b3bcb0ba77866b129776"),
                q1_y: hex!("eb15fe71662214fb03b65541f40d3eb0f4cf5c3b559f647da138c9f9b7484c48a08760e02c16f1992762cb7298fa52cf"),
            },
            TestVector {
                msg: b"q128_qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
                p_x: hex!("03c3a9f401b78c6c36a52f07eeee0ec1289f178adf78448f43a3850e0456f5dd7f7633dd31676d990eda32882ab486c0"),
                p_y: hex!("cc183d0d7bdfd0a3af05f50e16a3f2de4abbc523215bf57c848d5ea662482b8c1f43dc453a93b94a8026db58f3f5d878"),
                u_0: hex!("04c00051b0de6e726d228c85bf243bf5f4789efb512b22b498cde3821db9da667199b74bd5a09a79583c6d353a3bb41c"),
                u_1: hex!("97580f218255f899f9204db64cd15e6a312cb4d8182375d1e5157c8f80f41d6a1a4b77fb1ded9dce56c32058b8d5202b"),
                q0_x: hex!("051a22105e0817a35d66196338c8d85bd52690d79bba373ead8a86dd9899411513bb9f75273f6483395a7847fb21edb4"),
                q0_y: hex!("f168295c1bbcff5f8b01248e9dbc885335d6d6a04aea960f7384f746ba6502ce477e624151cc1d1392b00df0f5400c06"),
                q1_x: hex!("6ad7bc8ed8b841efd8ad0765c8a23d0b968ec9aa360a558ff33500f164faa02bee6c704f5f91507c4c5aad2b0dc5b943"),
                q1_y: hex!("47313cc0a873ade774048338fc34ca5313f96bbf6ae22ac6ef475d85f03d24792dc6afba8d0b4a70170c1b4f0f716629"),
            },
            TestVector {
                msg: b"a512_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                p_x: hex!("7b18d210b1f090ac701f65f606f6ca18fb8d081e3bc6cbd937c5604325f1cdea4c15c10a54ef303aabf2ea58bd9947a4"),
                p_y: hex!("ea857285a33abb516732915c353c75c576bf82ccc96adb63c094dde580021eddeafd91f8c0bfee6f636528f3d0c47fd2"),
                u_0: hex!("480cb3ac2c389db7f9dac9c396d2647ae946db844598971c26d1afd53912a1491199c0a5902811e4b809c26fcd37a014"),
                u_1: hex!("d28435eb34680e148bf3908536e42231cba9e1f73ae2c6902a222a89db5c49c97db2f8fa4d4cd6e424b17ac60bdb9bb6"),
                q0_x: hex!("42e6666f505e854187186bad3011598d9278b9d6e3e4d2503c3d236381a56748dec5d139c223129b324df53fa147c4df"),
                q0_y: hex!("8ee51dbda46413bf621838cc935d18d617881c6f33f3838a79c767a1e5618e34b22f79142df708d2432f75c7366c8512"),
                q1_x: hex!("4ff01ceeba60484fa1bc0d825fe1e5e383d8f79f1e5bb78e5fb26b7a7ef758153e31e78b9d60ce75c5e32e43869d4e12"),
                q1_y: hex!("0f84b978fac8ceda7304b47e229d6037d32062e597dc7a9b95bcd9af441f3c56c619a901d21635f9ec6ab4710b9fcd0e"),
            },
        ];

        for test_vector in TEST_VECTORS {
            // in parts
            let u = hash2curve::hash_to_field::<
                2,
                ExpandMsgXmd<Sha384>,
                <NistP384 as MapToCurve>::SecurityLevel,
                FieldElement,
                <NistP384 as MapToCurve>::Length,
            >(&[test_vector.msg], &[DST])
            .unwrap();

            /// Assert that the provided projective point matches the given test vector.
            // TODO(tarcieri): use coordinate APIs. See zkcrypto/group#30
            macro_rules! assert_point_eq {
                ($actual:expr, $expected_x:expr, $expected_y:expr) => {
                    let point = $actual.to_affine().to_encoded_point(false);
                    let (actual_x, actual_y) = match point.coordinates() {
                        sec1::Coordinates::Uncompressed { x, y } => (x, y),
                        _ => unreachable!(),
                    };

                    assert_eq!(&$expected_x, actual_x.as_slice());
                    assert_eq!(&$expected_y, actual_y.as_slice());
                };
            }

            assert_eq!(u[0].to_bytes().as_slice(), test_vector.u_0);
            assert_eq!(u[1].to_bytes().as_slice(), test_vector.u_1);

            let q0 = NistP384::map_to_curve(u[0]);
            assert_point_eq!(q0, test_vector.q0_x, test_vector.q0_y);

            let q1 = NistP384::map_to_curve(u[1]);
            assert_point_eq!(q1, test_vector.q1_x, test_vector.q1_y);

            let p = (q0 + q1).clear_cofactor();
            assert_point_eq!(p, test_vector.p_x, test_vector.p_y);

            // complete run
            let pt = hash2curve::hash_from_bytes::<NistP384, ExpandMsgXmd<Sha384>>(
                &[test_vector.msg],
                &[DST],
            )
            .unwrap();
            assert_point_eq!(pt, test_vector.p_x, test_vector.p_y);
        }
    }

    /// Taken from <https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-voprf#appendix-A.4>.
    #[test]
    fn hash_to_scalar_voprf() {
        struct TestVector {
            dst: &'static [u8],
            key_info: &'static [u8],
            seed: &'static [u8],
            sk_sm: &'static [u8],
        }

        const TEST_VECTORS: &[TestVector] = &[
            TestVector {
                dst: b"DeriveKeyPairOPRFV1-\x00-P384-SHA384",
                key_info: b"test key",
                seed: &hex!("a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3"),
                sk_sm: &hex!(
                    "dfe7ddc41a4646901184f2b432616c8ba6d452f9bcd0c4f75a5150ef2b2ed02ef40b8b92f60ae591bcabd72a6518f188"
                ),
            },
            TestVector {
                dst: b"DeriveKeyPairOPRFV1-\x01-P384-SHA384",
                key_info: b"test key",
                seed: &hex!("a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3"),
                sk_sm: &hex!(
                    "051646b9e6e7a71ae27c1e1d0b87b4381db6d3595eeeb1adb41579adbf992f4278f9016eafc944edaa2b43183581779d"
                ),
            },
            TestVector {
                dst: b"DeriveKeyPairOPRFV1-\x02-P384-SHA384",
                key_info: b"test key",
                seed: &hex!("a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3"),
                sk_sm: &hex!(
                    "5b2690d6954b8fbb159f19935d64133f12770c00b68422559c65431942d721ff79d47d7a75906c30b7818ec0f38b7fb2"
                ),
            },
        ];

        'outer: for test_vector in TEST_VECTORS {
            let key_info_len = u16::try_from(test_vector.key_info.len())
                .unwrap()
                .to_be_bytes();

            for counter in 0_u8..=u8::MAX {
                let scalar = hash2curve::hash_to_scalar::<NistP384, ExpandMsgXmd<Sha384>, U72>(
                    &[
                        test_vector.seed,
                        &key_info_len,
                        test_vector.key_info,
                        &counter.to_be_bytes(),
                    ],
                    &[test_vector.dst],
                )
                .unwrap();

                if !bool::from(scalar.is_zero()) {
                    assert_eq!(scalar.to_bytes().as_slice(), test_vector.sk_sm);
                    continue 'outer;
                }
            }

            panic!("deriving key failed");
        }
    }

    #[test]
    fn from_okm_fuzz() {
        let mut wide_order = Array::default();
        wide_order[24..].copy_from_slice(&NistP384::ORDER.to_be_byte_array());
        let wide_order = NonZero::<U576>::from_be_byte_array(wide_order).unwrap();

        let simple_from_okm = move |data: Array<u8, U72>| -> Scalar {
            let data = U576::from_be_slice(&data);

            let scalar = data % wide_order;
            let reduced_scalar = U384::from_be_slice(&scalar.to_be_byte_array()[24..]);

            Scalar::reduce(&reduced_scalar)
        };

        proptest!(ProptestConfig::with_cases(1000), |(b0 in ANY, b1 in ANY, b2 in ANY, b3 in ANY, b4 in ANY, b5 in ANY, b6 in ANY, b7 in ANY, b8 in ANY)| {
            let mut data = Array::default();
            data[..8].copy_from_slice(&b0.to_be_bytes());
            data[8..16].copy_from_slice(&b1.to_be_bytes());
            data[16..24].copy_from_slice(&b2.to_be_bytes());
            data[24..32].copy_from_slice(&b3.to_be_bytes());
            data[32..40].copy_from_slice(&b4.to_be_bytes());
            data[40..48].copy_from_slice(&b5.to_be_bytes());
            data[48..56].copy_from_slice(&b6.to_be_bytes());
            data[56..64].copy_from_slice(&b7.to_be_bytes());
            data[64..].copy_from_slice(&b8.to_be_bytes());

            let from_okm = Scalar::reduce(&data);
            let simple_from_okm = simple_from_okm(data);
            assert_eq!(from_okm, simple_from_okm);
        });
    }
}
