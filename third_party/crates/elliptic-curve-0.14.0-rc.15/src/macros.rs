//! Macros for writing common patterns that interact with this crate.

/// Writes all impls for scalar field types.
#[macro_export]
macro_rules! scalar_impls {
    ($curve:path, $scalar:ty) => {
        $crate::scalar_from_impls!($curve, $scalar);
        $crate::scalar_mul_impls!($curve, $scalar);
    };
}

/// Writes a series of `From` impls for scalar field types.
#[macro_export]
macro_rules! scalar_from_impls {
    ($curve:path, $scalar:ty) => {
        impl From<$crate::NonZeroScalar<$curve>> for $scalar {
            fn from(scalar: $crate::NonZeroScalar<$curve>) -> Self {
                *scalar.as_ref()
            }
        }

        impl From<&$crate::NonZeroScalar<$curve>> for $scalar {
            fn from(scalar: &$crate::NonZeroScalar<$curve>) -> Self {
                *scalar.as_ref()
            }
        }

        impl From<$crate::ScalarValue<$curve>> for $scalar {
            fn from(w: $crate::ScalarValue<$curve>) -> Self {
                <$scalar>::from(&w)
            }
        }

        impl From<&$crate::ScalarValue<$curve>> for $scalar {
            fn from(w: &$crate::ScalarValue<$curve>) -> $scalar {
                <$scalar>::from_uint_unchecked(*w.as_uint())
            }
        }

        impl From<$scalar> for $crate::ScalarValue<$curve> {
            fn from(scalar: $scalar) -> $crate::ScalarValue<$curve> {
                $crate::ScalarValue::from(&scalar)
            }
        }

        impl From<&$scalar> for $crate::ScalarValue<$curve> {
            fn from(scalar: &$scalar) -> $crate::ScalarValue<$curve> {
                $crate::ScalarValue::new(scalar.into()).unwrap()
            }
        }

        impl From<&$crate::SecretKey<$curve>> for $scalar {
            fn from(secret_key: &$crate::SecretKey<$curve>) -> $scalar {
                *secret_key.to_nonzero_scalar()
            }
        }

        /// The constant-time alternative is available at
        #[doc = concat!("[`", stringify!(elliptic_curve), "::NonZeroScalar<", stringify!($curve), ">::new()`].")]
        impl TryFrom<$scalar> for $crate::NonZeroScalar<$curve> {
            type Error = $crate::Error;

            fn try_from(scalar: $scalar) -> $crate::Result<Self> {
                $crate::NonZeroScalar::new(scalar)
                    .into_option()
                    .ok_or($crate::Error)
            }
        }
    };
}

/// Writes a series of `Mul` impls for an elliptic curve's scalar field
#[macro_export]
macro_rules! scalar_mul_impls {
    ($curve:path, $scalar:ty) => {
        impl ::core::ops::Mul<$crate::AffinePoint<$curve>> for $scalar {
            type Output = $crate::ProjectivePoint<$curve>;

            #[inline]
            fn mul(self, rhs: $crate::AffinePoint<$curve>) -> $crate::ProjectivePoint<$curve> {
                rhs * self
            }
        }

        impl ::core::ops::Mul<&$crate::AffinePoint<$curve>> for $scalar {
            type Output = $crate::ProjectivePoint<$curve>;

            #[inline]
            fn mul(self, rhs: &$crate::AffinePoint<$curve>) -> $crate::ProjectivePoint<$curve> {
                *rhs * self
            }
        }

        impl ::core::ops::Mul<$crate::AffinePoint<$curve>> for &$scalar {
            type Output = $crate::ProjectivePoint<$curve>;

            #[inline]
            fn mul(self, rhs: $crate::AffinePoint<$curve>) -> $crate::ProjectivePoint<$curve> {
                rhs * self
            }
        }

        impl ::core::ops::Mul<&$crate::AffinePoint<$curve>> for &$scalar {
            type Output = $crate::ProjectivePoint<$curve>;

            #[inline]
            fn mul(self, rhs: &$crate::AffinePoint<$curve>) -> $crate::ProjectivePoint<$curve> {
                *rhs * self
            }
        }

        impl ::core::ops::Mul<$crate::ProjectivePoint<$curve>> for $scalar {
            type Output = $crate::ProjectivePoint<$curve>;

            #[inline]
            fn mul(self, rhs: $crate::ProjectivePoint<$curve>) -> $crate::ProjectivePoint<$curve> {
                rhs * self
            }
        }

        impl ::core::ops::Mul<&$crate::ProjectivePoint<$curve>> for $scalar {
            type Output = $crate::ProjectivePoint<$curve>;

            #[inline]
            fn mul(self, rhs: &$crate::ProjectivePoint<$curve>) -> $crate::ProjectivePoint<$curve> {
                rhs * &self
            }
        }

        impl ::core::ops::Mul<$crate::ProjectivePoint<$curve>> for &$scalar {
            type Output = $crate::ProjectivePoint<$curve>;

            #[inline]
            fn mul(self, rhs: $crate::ProjectivePoint<$curve>) -> $crate::ProjectivePoint<$curve> {
                rhs * self
            }
        }

        impl ::core::ops::Mul<&$crate::ProjectivePoint<$curve>> for &$scalar {
            type Output = $crate::ProjectivePoint<$curve>;

            #[inline]
            fn mul(self, rhs: &$crate::ProjectivePoint<$curve>) -> $crate::ProjectivePoint<$curve> {
                rhs * self
            }
        }
    };
}
