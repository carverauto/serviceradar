use super::FieldElement;
use crate::{AffinePoint, NistP521, ProjectivePoint, Scalar};
use elliptic_curve::{
    bigint::{ArrayEncoding, U576},
    consts::U98,
    generic_array::GenericArray,
    hash2curve::{FromOkm, GroupDigest, MapToCurve, OsswuMap, OsswuMapParams, Sgn0},
    ops::Reduce,
    point::DecompressPoint,
    subtle::Choice,
};

impl GroupDigest for NistP521 {
    type FieldElement = FieldElement;
}

impl FromOkm for FieldElement {
    type Length = U98;

    fn from_okm(data: &GenericArray<u8, Self::Length>) -> Self {
        const F_2_392: FieldElement = FieldElement::from_hex(
            "000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        );

        let mut d0 = GenericArray::default();
        d0[23..].copy_from_slice(&data[0..49]);
        let d0 = FieldElement::from_uint_unchecked(U576::from_be_byte_array(d0));

        let mut d1 = GenericArray::default();
        d1[23..].copy_from_slice(&data[49..]);
        let d1 = FieldElement::from_uint_unchecked(U576::from_be_byte_array(d1));

        d0 * F_2_392 + d1
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
            0xffff_ffff_ffff_ffff,
            0xffff_ffff_ffff_ffff,
            0xffff_ffff_ffff_ffff,
            0xffff_ffff_ffff_ffff,
            0xffff_ffff_ffff_ffff,
            0xffff_ffff_ffff_ffff,
            0xffff_ffff_ffff_ffff,
            0xffff_ffff_ffff_ffff,
            0x0000_0000_0000_007f,
        ],
        c2: FieldElement::from_hex(
            "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002",
        ),
        map_a: FieldElement::from_u64(3).neg(),
        map_b: FieldElement::from_hex(
            "0000000000000051953eb9618e1c9a1f929a21a0b68540eea2da725b99b315f3b8b489918ef109e156193951ec7e937b1652c0bd3bb1bf073573df883d2c34f1ef451fd46b503f00",
        ),
        z: FieldElement::from_u64(4).neg(),
    };
}

impl MapToCurve for FieldElement {
    type Output = ProjectivePoint;

    fn map_to_curve(&self) -> Self::Output {
        let (qx, qy) = self.osswu();

        // TODO(tarcieri): assert that `qy` is correct? less circuitous conversion?
        AffinePoint::decompress(&qx.to_bytes(), qy.is_odd())
            .unwrap()
            .into()
    }
}

impl FromOkm for Scalar {
    type Length = U98;

    fn from_okm(data: &GenericArray<u8, Self::Length>) -> Self {
        const F_2_392: Scalar = Scalar::from_hex(
            "000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        );

        let mut d0 = GenericArray::default();
        d0[23..].copy_from_slice(&data[0..49]);
        let d0 = Scalar::reduce(U576::from_be_byte_array(d0));

        let mut d1 = GenericArray::default();
        d1[23..].copy_from_slice(&data[49..]);
        let d1 = Scalar::reduce(U576::from_be_byte_array(d1));

        d0 * F_2_392 + d1
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        arithmetic::field::{FieldElement, MODULUS},
        NistP521, Scalar,
    };
    use elliptic_curve::{
        bigint::{ArrayEncoding, CheckedSub, NonZero, U576, U896},
        consts::U98,
        generic_array::GenericArray,
        group::cofactor::CofactorGroup,
        hash2curve::{self, ExpandMsgXmd, FromOkm, GroupDigest, MapToCurve, OsswuMap},
        ops::Reduce,
        sec1::{self, ToEncodedPoint},
        Curve,
    };
    use hex_literal::hex;
    use proptest::{num, prelude::ProptestConfig, proptest};
    use sha2::Sha512;

    #[test]
    fn params() {
        let params = <FieldElement as OsswuMap>::PARAMS;

        let c1 = MODULUS.checked_sub(&U576::from_u8(3)).unwrap()
            / NonZero::new(U576::from_u8(4)).unwrap();
        assert_eq!(
            GenericArray::from_iter(params.c1.iter().rev().flat_map(|v| v.to_be_bytes())),
            c1.to_be_byte_array()
        );

        let c2 = FieldElement::from_u64(4).sqrt().unwrap();
        assert_eq!(params.c2, c2);
    }

    #[test]
    fn hash_to_curve() {
        struct TestVector {
            msg: &'static [u8],
            p_x: [u8; 66],
            p_y: [u8; 66],
            u_0: [u8; 66],
            u_1: [u8; 66],
            q0_x: [u8; 66],
            q0_y: [u8; 66],
            q1_x: [u8; 66],
            q1_y: [u8; 66],
        }

        const DST: &[u8] = b"QUUX-V01-CS02-with-P521_XMD:SHA-512_SSWU_RO_";

        const TEST_VECTORS: &[TestVector] = &[
            TestVector {
                msg: b"",
                p_x: hex!("00fd767cebb2452030358d0e9cf907f525f50920c8f607889a6a35680727f64f4d66b161fafeb2654bea0d35086bec0a10b30b14adef3556ed9f7f1bc23cecc9c088"),
                p_y: hex!("0169ba78d8d851e930680322596e39c78f4fe31b97e57629ef6460ddd68f8763fd7bd767a4e94a80d3d21a3c2ee98347e024fc73ee1c27166dc3fe5eeef782be411d"),
                u_0: hex!("01e5f09974e5724f25286763f00ce76238c7a6e03dc396600350ee2c4135fb17dc555be99a4a4bae0fd303d4f66d984ed7b6a3ba386093752a855d26d559d69e7e9e"),
                u_1: hex!("00ae593b42ca2ef93ac488e9e09a5fe5a2f6fb330d18913734ff602f2a761fcaaf5f596e790bcc572c9140ec03f6cccc38f767f1c1975a0b4d70b392d95a0c7278aa"),
                q0_x: hex!("00b70ae99b6339fffac19cb9bfde2098b84f75e50ac1e80d6acb954e4534af5f0e9c4a5b8a9c10317b8e6421574bae2b133b4f2b8c6ce4b3063da1d91d34fa2b3a3c"),
                q0_y: hex!("007f368d98a4ddbf381fb354de40e44b19e43bb11a1278759f4ea7b485e1b6db33e750507c071250e3e443c1aaed61f2c28541bb54b1b456843eda1eb15ec2a9b36e"),
                q1_x: hex!("01143d0e9cddcdacd6a9aafe1bcf8d218c0afc45d4451239e821f5d2a56df92be942660b532b2aa59a9c635ae6b30e803c45a6ac871432452e685d661cd41cf67214"),
                q1_y: hex!("00ff75515df265e996d702a5380defffab1a6d2bc232234c7bcffa433cd8aa791fbc8dcf667f08818bffa739ae25773b32073213cae9a0f2a917a0b1301a242dda0c"),
            },
            TestVector {
                msg: b"abc",
                p_x: hex!("002f89a1677b28054b50d15e1f81ed6669b5a2158211118ebdef8a6efc77f8ccaa528f698214e4340155abc1fa08f8f613ef14a043717503d57e267d57155cf784a4"),
                p_y: hex!("010e0be5dc8e753da8ce51091908b72396d3deed14ae166f66d8ebf0a4e7059ead169ea4bead0232e9b700dd380b316e9361cfdba55a08c73545563a80966ecbb86d"),
                u_0: hex!("003d00c37e95f19f358adeeaa47288ec39998039c3256e13c2a4c00a7cb61a34c8969472960150a27276f2390eb5e53e47ab193351c2d2d9f164a85c6a5696d94fe8"),
                u_1: hex!("01f3cbd3df3893a45a2f1fecdac4d525eb16f345b03e2820d69bc580f5cbe9cb89196fdf720ef933c4c0361fcfe29940fd0db0a5da6bafb0bee8876b589c41365f15"),
                q0_x: hex!("01b254e1c99c835836f0aceebba7d77750c48366ecb07fb658e4f5b76e229ae6ca5d271bb0006ffcc42324e15a6d3daae587f9049de2dbb0494378ffb60279406f56"),
                q0_y: hex!("01845f4af72fc2b1a5a2fe966f6a97298614288b456cfc385a425b686048b25c952fbb5674057e1eb055d04568c0679a8e2dda3158dc16ac598dbb1d006f5ad915b0"),
                q1_x: hex!("007f08e813c620e527c961b717ffc74aac7afccb9158cebc347d5715d5c2214f952c97e194f11d114d80d3481ed766ac0a3dba3eb73f6ff9ccb9304ad10bbd7b4a36"),
                q1_y: hex!("0022468f92041f9970a7cc025d71d5b647f822784d29ca7b3bc3b0829d6bb8581e745f8d0cc9dc6279d0450e779ac2275c4c3608064ad6779108a7828ebd9954caeb"),
            },
            TestVector {
                msg: b"abcdef0123456789",
                p_x: hex!("006e200e276a4a81760099677814d7f8794a4a5f3658442de63c18d2244dcc957c645e94cb0754f95fcf103b2aeaf94411847c24187b89fb7462ad3679066337cbc4"),
                p_y: hex!("001dd8dfa9775b60b1614f6f169089d8140d4b3e4012949b52f98db2deff3e1d97bf73a1fa4d437d1dcdf39b6360cc518d8ebcc0f899018206fded7617b654f6b168"),
                u_0: hex!("00183ee1a9bbdc37181b09ec336bcaa34095f91ef14b66b1485c166720523dfb81d5c470d44afcb52a87b704dbc5c9bc9d0ef524dec29884a4795f55c1359945baf3"),
                u_1: hex!("00504064fd137f06c81a7cf0f84aa7e92b6b3d56c2368f0a08f44776aa8930480da1582d01d7f52df31dca35ee0a7876500ece3d8fe0293cd285f790c9881c998d5e"),
                q0_x: hex!("0021482e8622aac14da60e656043f79a6a110cbae5012268a62dd6a152c41594549f373910ebed170ade892dd5a19f5d687fae7095a461d583f8c4295f7aaf8cd7da"),
                q0_y: hex!("0177e2d8c6356b7de06e0b5712d8387d529b848748e54a8bc0ef5f1475aa569f8f492fa85c3ad1c5edc51faf7911f11359bfa2a12d2ef0bd73df9cb5abd1b101c8b1"),
                q1_x: hex!("00abeafb16fdbb5eb95095678d5a65c1f293291dfd20a3751dbe05d0a9bfe2d2eef19449fe59ec32cdd4a4adc3411177c0f2dffd0159438706159a1bbd0567d9b3d0"),
                q1_y: hex!("007cc657f847db9db651d91c801741060d63dab4056d0a1d3524e2eb0e819954d8f677aa353bd056244a88f00017e00c3ce8beeedb4382d83d74418bd48930c6c182"),
            },
            TestVector {
                msg: b"q128_qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
                p_x: hex!("01b264a630bd6555be537b000b99a06761a9325c53322b65bdc41bf196711f9708d58d34b3b90faf12640c27b91c70a507998e55940648caa8e71098bf2bc8d24664"),
                p_y: hex!("01ea9f445bee198b3ee4c812dcf7b0f91e0881f0251aab272a12201fd89b1a95733fd2a699c162b639e9acdcc54fdc2f6536129b6beb0432be01aa8da02df5e59aaa"),
                u_0: hex!("0159871e222689aad7694dc4c3480a49807b1eedd9c8cb4ae1b219d5ba51655ea5b38e2e4f56b36bf3e3da44a7b139849d28f598c816fe1bc7ed15893b22f63363c3"),
                u_1: hex!("004ef0cffd475152f3858c0a8ccbdf7902d8261da92744e98df9b7fadb0a5502f29c5086e76e2cf498f47321434a40b1504911552ce44ad7356a04e08729ad9411f5"),
                q0_x: hex!("0005eac7b0b81e38727efcab1e375f6779aea949c3e409b53a1d37aa2acbac87a7e6ad24aafbf3c52f82f7f0e21b872e88c55e17b7fa21ce08a94ea2121c42c2eb73"),
                q0_y: hex!("00a173b6a53a7420dbd61d4a21a7c0a52de7a5c6ce05f31403bef747d16cc8604a039a73bdd6e114340e55dacd6bea8e217ffbadfb8c292afa3e1b2afc839a6ce7bb"),
                q1_x: hex!("01881e3c193a69e4d88d8180a6879b74782a0bc7e529233e9f84bf7f17d2f319c36920ffba26f9e57a1e045cc7822c834c239593b6e142a694aa00c757b0db79e5e8"),
                q1_y: hex!("01558b16d396d866e476e001f2dd0758927655450b84e12f154032c7c2a6db837942cd9f44b814f79b4d729996ced61eec61d85c675139cbffe3fbf071d2c21cfecb"),
            },
            TestVector {
                msg: b"a512_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                p_x: hex!("00c12bc3e28db07b6b4d2a2b1167ab9e26fc2fa85c7b0498a17b0347edf52392856d7e28b8fa7a2dd004611159505835b687ecf1a764857e27e9745848c436ef3925"),
                p_y: hex!("01cd287df9a50c22a9231beb452346720bb163344a41c5f5a24e8335b6ccc595fd436aea89737b1281aecb411eb835f0b939073fdd1dd4d5a2492e91ef4a3c55bcbd"),
                u_0: hex!("0033d06d17bc3b9a3efc081a05d65805a14a3050a0dd4dfb4884618eb5c73980a59c5a246b18f58ad022dd3630faa22889fbb8ba1593466515e6ab4aeb7381c26334"),
                u_1: hex!("0092290ab99c3fea1a5b8fb2ca49f859994a04faee3301cefab312d34227f6a2d0c3322cf76861c6a3683bdaa2dd2a6daa5d6906c663e065338b2344d20e313f1114"),
                q0_x: hex!("00041f6eb92af8777260718e4c22328a7d74203350c6c8f5794d99d5789766698f459b83d5068276716f01429934e40af3d1111a22780b1e07e72238d2207e5386be"),
                q0_y: hex!("001c712f0182813942b87cab8e72337db017126f52ed797dd234584ac9ae7e80dfe7abea11db02cf1855312eae1447dbaecc9d7e8c880a5e76a39f6258074e1bc2e0"),
                q1_x: hex!("0125c0b69bcf55eab49280b14f707883405028e05c927cd7625d4e04115bd0e0e6323b12f5d43d0d6d2eff16dbcf244542f84ec058911260dc3bb6512ab5db285fbd"),
                q1_y: hex!("008bddfb803b3f4c761458eb5f8a0aee3e1f7f68e9d7424405fa69172919899317fb6ac1d6903a432d967d14e0f80af63e7035aaae0c123e56862ce969456f99f102"),
            },
        ];

        for test_vector in TEST_VECTORS {
            // in parts
            let mut u = [FieldElement::default(), FieldElement::default()];
            hash2curve::hash_to_field::<ExpandMsgXmd<Sha512>, FieldElement>(
                &[test_vector.msg],
                &[DST],
                &mut u,
            )
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

            let q0 = u[0].map_to_curve();
            assert_point_eq!(q0, test_vector.q0_x, test_vector.q0_y);

            let q1 = u[1].map_to_curve();
            assert_point_eq!(q1, test_vector.q1_x, test_vector.q1_y);

            let p = q0.clear_cofactor() + q1.clear_cofactor();
            assert_point_eq!(p, test_vector.p_x, test_vector.p_y);

            // complete run
            let pt = NistP521::hash_from_bytes::<ExpandMsgXmd<Sha512>>(&[test_vector.msg], &[DST])
                .unwrap();
            assert_point_eq!(pt, test_vector.p_x, test_vector.p_y);
        }
    }

    /// Taken from <https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-voprf#appendix-A.5>.
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
                dst: b"DeriveKeyPairOPRFV1-\x00-P521-SHA512",
                key_info: &hex!("74657374206b6579"),
                seed: &hex!("a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3"),
                sk_sm: &hex!("0153441b8faedb0340439036d6aed06d1217b34c42f17f8db4c5cc610a4a955d698a688831b16d0dc7713a1aa3611ec60703bffc7dc9c84e3ed673b3dbe1d5fccea6"),
            },
            TestVector {
                dst: b"DeriveKeyPairOPRFV1-\x01-P521-SHA512",
                key_info: b"test key",
                seed: &hex!("a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3"),
                sk_sm: &hex!("015c7fc1b4a0b1390925bae915bd9f3d72009d44d9241b962428aad5d13f22803311e7102632a39addc61ea440810222715c9d2f61f03ea424ec9ab1fe5e31cf9238"),
            },
            TestVector {
                dst: b"DeriveKeyPairOPRFV1-\x02-P521-SHA512",
                key_info: b"test key",
                seed: &hex!("a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3"),
                sk_sm: &hex!("014893130030ce69cf714f536498a02ff6b396888f9bb507985c32928c4427d6d39de10ef509aca4240e8569e3a88debc0d392e3361bcd934cb9bdd59e339dff7b27"),
            },
        ];

        'outer: for test_vector in TEST_VECTORS {
            let key_info_len = u16::try_from(test_vector.key_info.len())
                .unwrap()
                .to_be_bytes();

            for counter in 0_u8..=u8::MAX {
                let scalar = NistP521::hash_to_scalar::<ExpandMsgXmd<Sha512>>(
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
        let mut wide_order = GenericArray::default();
        wide_order[40..].copy_from_slice(NistP521::ORDER.to_be_byte_array().as_slice());
        // TODO: This could be reduced to `U832` when `crypto-bigint` implements `ArrayEncoding`.
        let wide_order = NonZero::new(U896::from_be_byte_array(wide_order)).unwrap();

        let simple_from_okm = move |data: GenericArray<u8, U98>| -> Scalar {
            let mut wide_data = GenericArray::default();
            wide_data[14..].copy_from_slice(data.as_slice());
            let wide_data = U896::from_be_byte_array(wide_data);

            let scalar = wide_data % wide_order;
            let reduced_scalar = U576::from_be_slice(&scalar.to_be_byte_array()[40..]);

            Scalar::reduce(reduced_scalar)
        };

        proptest!(
            ProptestConfig::with_cases(1000),
            |(
                b0 in num::u64::ANY,
                b1 in num::u64::ANY,
                b2 in num::u64::ANY,
                b3 in num::u64::ANY,
                b4 in num::u64::ANY,
                b5 in num::u64::ANY,
                b6 in num::u64::ANY,
                b7 in num::u64::ANY,
                b8 in num::u64::ANY,
                b9 in num::u64::ANY,
                b10 in num::u64::ANY,
                b11 in num::u64::ANY,
                b12 in num::u16::ANY,
            )| {
                let mut data = GenericArray::default();
                data[..8].copy_from_slice(&b0.to_be_bytes());
                data[8..16].copy_from_slice(&b1.to_be_bytes());
                data[16..24].copy_from_slice(&b2.to_be_bytes());
                data[24..32].copy_from_slice(&b3.to_be_bytes());
                data[32..40].copy_from_slice(&b4.to_be_bytes());
                data[40..48].copy_from_slice(&b5.to_be_bytes());
                data[48..56].copy_from_slice(&b6.to_be_bytes());
                data[56..64].copy_from_slice(&b7.to_be_bytes());
                data[64..72].copy_from_slice(&b8.to_be_bytes());
                data[72..80].copy_from_slice(&b9.to_be_bytes());
                data[80..88].copy_from_slice(&b10.to_be_bytes());
                data[88..96].copy_from_slice(&b11.to_be_bytes());
                data[96..].copy_from_slice(&b12.to_be_bytes());

                let from_okm = Scalar::from_okm(&data);
                let simple_from_okm = simple_from_okm(data);
                assert_eq!(from_okm, simple_from_okm);
            }
        );
    }
}
