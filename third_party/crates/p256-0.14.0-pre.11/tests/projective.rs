//! Projective arithmetic tests.

#![cfg(all(feature = "arithmetic", feature = "test-vectors"))]

use elliptic_curve::{
    BatchNormalize, Group,
    array::Array,
    consts::U32,
    group::{GroupEncoding, ff::PrimeField},
    ops::{LinearCombination, Reduce, ReduceNonZero},
    point::NonIdentity,
    sec1::{self, ToEncodedPoint},
};
use p256::{
    AffinePoint, FieldBytes, NonZeroScalar, ProjectivePoint, Scalar,
    test_vectors::group::{ADD_TEST_VECTORS, MUL_TEST_VECTORS},
};
use primeorder::test_projective_arithmetic;
use proptest::{prelude::any, prop_compose, proptest};

test_projective_arithmetic!(
    AffinePoint,
    ProjectivePoint,
    Scalar,
    ADD_TEST_VECTORS,
    MUL_TEST_VECTORS
);

#[test]
fn projective_identity_to_bytes() {
    // This is technically an invalid SEC1 encoding, but is preferable to panicking.
    assert_eq!([0; 33], ProjectivePoint::IDENTITY.to_bytes().as_slice());
}

prop_compose! {
    fn non_identity()(bytes in any::<[u8; 32]>()) -> NonIdentity<ProjectivePoint> {
        NonIdentity::mul_by_generator(&NonZeroScalar::reduce_nonzero(&FieldBytes::from(bytes)))
    }
}

prop_compose! {
    fn projective()(bytes in any::<[u8; 32]>()) -> ProjectivePoint {
        ProjectivePoint::mul_by_generator(&Scalar::reduce(&Array::<u8, U32>::from(bytes)))
    }
}

prop_compose! {
    fn scalar()(bytes in any::<[u8; 32]>()) -> Scalar {
        Scalar::reduce(&Array::<u8, U32>::from(bytes))
    }
}

// TODO: move to `primeorder::test_projective_arithmetic`.
proptest! {
    #[test]
    fn batch_normalize(
        a in non_identity(),
        b in non_identity(),
    ) {
        let points: [NonIdentity<ProjectivePoint>; 2] = [a, b];

        let affine_points = NonIdentity::batch_normalize(&points);

        for (point, affine_point) in points.into_iter().zip(affine_points) {
            assert_eq!(affine_point, point.to_affine());
        }
    }

    #[test]
    #[cfg(feature = "alloc")]
    fn batch_normalize_alloc(
        a in non_identity(),
        b in non_identity(),
    ) {
        let points = vec![a, b];

        let affine_points = NonIdentity::batch_normalize(points.as_slice());

        for (point, affine_point) in points.into_iter().zip(affine_points) {
            assert_eq!(affine_point, point.to_affine());
        }
    }

    #[test]
    fn lincomb(
        p1 in projective(),
        s1 in scalar(),
        p2 in projective(),
        s2 in scalar(),
    ) {
        let reference = p1 * s1 + p2 * s2;
        let test = ProjectivePoint::lincomb(&[(p1, s1), (p2, s2)]);
        assert_eq!(reference, test);
    }

    #[test]
    #[cfg(feature = "alloc")]
    fn lincomb_alloc(
        p1 in projective(),
        s1 in scalar(),
        p2 in projective(),
        s2 in scalar(),
    ) {
        let reference = p1 * s1 + p2 * s2;
        let test = ProjectivePoint::lincomb(vec![(p1, s1), (p2, s2)].as_slice());
        assert_eq!(reference, test);
    }
}
