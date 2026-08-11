//! Projective arithmetic tests.

#![cfg(all(feature = "arithmetic", feature = "test-vectors"))]

use elliptic_curve::{
    group::ff::PrimeField,
    sec1::{self, ToEncodedPoint},
};
use p521::{
    test_vectors::group::{ADD_TEST_VECTORS, MUL_TEST_VECTORS},
    AffinePoint, ProjectivePoint, Scalar,
};
use primeorder::{impl_projective_arithmetic_tests, Double};

impl_projective_arithmetic_tests!(
    AffinePoint,
    ProjectivePoint,
    Scalar,
    ADD_TEST_VECTORS,
    MUL_TEST_VECTORS
);
