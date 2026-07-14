//! Development-related functionality.

// TODO(tarcieri): implement full set of tests from ECDSA2VS
// <https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/dss2/ecdsa2vs.pdf>

use crate::EcdsaCurve;
use elliptic_curve::dev::MockCurve;

impl EcdsaCurve for MockCurve {
    const NORMALIZE_S: bool = false;
}

/// ECDSA test vector
pub struct TestVector {
    /// Private scalar
    pub d: &'static [u8],

    /// Public key x-coordinate (`Qx`)
    pub q_x: &'static [u8],

    /// Public key y-coordinate (`Qy`)
    pub q_y: &'static [u8],

    /// Ephemeral scalar (a.k.a. nonce)
    pub k: &'static [u8],

    /// Message digest (prehashed)
    pub m: &'static [u8],

    /// Signature `r` component
    pub r: &'static [u8],

    /// Signature `s` component
    pub s: &'static [u8],
}

/// Define ECDSA signing test.
#[macro_export]
macro_rules! new_signing_test {
    ($curve:path, $vectors:expr) => {
        use $crate::{
            elliptic_curve::{
                Curve, CurveArithmetic, FieldBytes, NonZeroScalar, Scalar,
                array::{Array, typenum::Unsigned},
                bigint::Encoding,
                group::ff::PrimeField,
            },
            hazmat::sign_prehashed,
        };

        fn decode_scalar(bytes: &[u8]) -> Option<NonZeroScalar<$curve>> {
            if bytes.len() == <$curve as Curve>::FieldBytesSize::USIZE {
                NonZeroScalar::<$curve>::from_repr(bytes.try_into().unwrap()).into()
            } else {
                None
            }
        }

        #[test]
        fn ecdsa_signing() {
            for vector in $vectors {
                let d = decode_scalar(vector.d).expect("invalid vector.d");
                let k = decode_scalar(vector.k).expect("invalid vector.m");

                assert_eq!(
                    <$curve as Curve>::FieldBytesSize::USIZE,
                    vector.m.len(),
                    "invalid vector.m (must be field-sized digest)"
                );
                let z = FieldBytes::<$curve>::try_from(vector.m).unwrap();
                let sig = sign_prehashed::<$curve>(&d, &k, &z)
                    .expect("ECDSA sign failed")
                    .0;

                assert_eq!(vector.r, sig.r().to_bytes().as_slice());
                assert_eq!(vector.s, sig.s().to_bytes().as_slice());
            }
        }
    };
}

/// Define ECDSA verification test.
#[macro_export]
macro_rules! new_verification_test {
    ($curve:path, $vectors:expr) => {
        use $crate::{
            Signature, VerifyingKey,
            elliptic_curve::{
                AffinePoint, CurveArithmetic, Scalar,
                array::Array,
                group::ff::PrimeField,
                sec1::{EncodedPoint, FromEncodedPoint},
            },
            signature::hazmat::PrehashVerifier,
        };

        #[test]
        fn ecdsa_verify_success() {
            for vector in $vectors {
                let q_encoded = EncodedPoint::<$curve>::from_affine_coordinates(
                    &Array::try_from(vector.q_x).unwrap(),
                    &Array::try_from(vector.q_y).unwrap(),
                    false,
                );

                let q = VerifyingKey::<$curve>::from_encoded_point(&q_encoded).unwrap();

                let sig = Signature::from_scalars(
                    Array::try_from(vector.r).unwrap(),
                    Array::try_from(vector.s).unwrap(),
                )
                .unwrap();

                let result = q.verify_prehash(vector.m, &sig);
                assert!(result.is_ok());
            }
        }

        #[test]
        fn ecdsa_verify_invalid_s() {
            for vector in $vectors {
                let q_encoded = EncodedPoint::<$curve>::from_affine_coordinates(
                    &Array::try_from(vector.q_x).unwrap(),
                    &Array::try_from(vector.q_y).unwrap(),
                    false,
                );

                let q = VerifyingKey::<$curve>::from_encoded_point(&q_encoded).unwrap();
                let r = Array::try_from(vector.r).unwrap();

                // Flip a bit in `s`
                let mut s_tweaked = Array::try_from(vector.s).unwrap();
                s_tweaked[0] ^= 1;

                let sig = Signature::from_scalars(r, s_tweaked).unwrap();
                let result = q.verify_prehash(vector.m, &sig);
                assert!(result.is_err());
            }
        }

        // TODO(tarcieri): test invalid Q, invalid r, invalid m
    };
}

/// Define a Wycheproof verification test.
#[macro_export]
macro_rules! new_wycheproof_test {
    ($name:ident, $test_name: expr, $curve:path) => {
        use $crate::{
            Signature,
            elliptic_curve::{bigint::Integer, sec1::EncodedPoint},
            signature::Verifier,
        };

        #[test]
        fn $name() {
            use blobby::Blob5Iterator;
            use elliptic_curve::{array::typenum::Unsigned, bigint::Encoding as _};

            // Build a field element but allow for too-short input (left pad with zeros)
            // or too-long input (check excess leftmost bytes are zeros).
            fn element_from_padded_slice<C: elliptic_curve::Curve>(
                data: &[u8],
            ) -> elliptic_curve::FieldBytes<C> {
                let point_len = C::FieldBytesSize::USIZE;
                if data.len() >= point_len {
                    let offset = data.len() - point_len;
                    for v in data.iter().take(offset) {
                        assert_eq!(*v, 0, "EcdsaVerifier: point too large");
                    }
                    elliptic_curve::FieldBytes::<C>::try_from(&data[offset..]).unwrap()
                } else {
                    // Provided slice is too short and needs to be padded with zeros
                    // on the left.  Build a combined exact iterator to do this.
                    let iter = core::iter::repeat(0)
                        .take(point_len - data.len())
                        .chain(data.iter().cloned());
                    elliptic_curve::FieldBytes::<C>::from_iter(iter)
                }
            }

            fn run_test(
                wx: &[u8],
                wy: &[u8],
                msg: &[u8],
                sig: &[u8],
                pass: bool,
            ) -> Option<&'static str> {
                let x = element_from_padded_slice::<$curve>(wx);
                let y = element_from_padded_slice::<$curve>(wy);
                let q_encoded = EncodedPoint::<$curve>::from_affine_coordinates(
                    &x, &y, /* compress= */ false,
                );
                let verifying_key =
                    $crate::VerifyingKey::<$curve>::from_encoded_point(&q_encoded).unwrap();

                let sig = match Signature::from_der(sig) {
                    Ok(s) => s,
                    Err(_) if !pass => return None,
                    Err(_) => return Some("failed to parse signature ASN.1"),
                };

                match verifying_key.verify(msg, &sig) {
                    Ok(_) if pass => None,
                    Ok(_) => Some("signature verify unexpectedly succeeded"),
                    Err(_) if !pass => None,
                    Err(_) => Some("signature verify failed"),
                }
            }

            let data = include_bytes!(concat!("test_vectors/data/", $test_name, ".blb"));

            for (i, row) in Blob5Iterator::new(data).unwrap().enumerate() {
                let [wx, wy, msg, sig, status] = row.unwrap();
                let pass = match status[0] {
                    0 => false,
                    1 => true,
                    _ => panic!("invalid value for pass flag"),
                };
                if let Some(desc) = run_test(wx, wy, msg, sig, pass) {
                    panic!(
                        "\n\
                                 Failed test №{}: {}\n\
                                 wx:\t{:?}\n\
                                 wy:\t{:?}\n\
                                 msg:\t{:?}\n\
                                 sig:\t{:?}\n\
                                 pass:\t{}\n",
                        i, desc, wx, wy, msg, sig, pass,
                    );
                }
            }
        }
    };
}
