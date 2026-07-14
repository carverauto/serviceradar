//! Projective arithmetic tests.

#![cfg(all(feature = "arithmetic", feature = "test-vectors"))]

use elliptic_curve::{
    group::ff::PrimeField,
    sec1::{self, ToEncodedPoint},
};
use p521::{
    AffinePoint, ProjectivePoint, Scalar,
    test_vectors::group::{ADD_TEST_VECTORS, MUL_TEST_VECTORS},
};
use primeorder::{Double, test_projective_arithmetic};

test_projective_arithmetic!(
    AffinePoint,
    ProjectivePoint,
    Scalar,
    ADD_TEST_VECTORS,
    MUL_TEST_VECTORS
);
