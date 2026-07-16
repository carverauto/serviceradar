use crate::{FixedOutput, FixedOutputReset, Update};
use common::{Output, OutputSizeUser, Reset};

use common::typenum::Unsigned;
use core::fmt;
use ctutils::CtEq;

/// Marker trait for Message Authentication algorithms.
pub trait MacMarker {}

/// Convenience wrapper trait covering functionality of Message Authentication algorithms.
///
/// This trait wraps [`Update`], [`FixedOutput`], and [`MacMarker`] traits
/// and provides additional convenience methods.
pub trait Mac: OutputSizeUser + Sized {
    /// Update state using the provided data.
    fn update(&mut self, data: &[u8]);

    /// Process input data in a chained manner.
    #[must_use]
    fn chain_update(self, data: impl AsRef<[u8]>) -> Self;

    /// Obtain the result of a [`Mac`] computation as a [`CtOutput`] and consume
    /// [`Mac`] instance.
    fn finalize(self) -> CtOutput<Self>;

    /// Obtain the result of a [`Mac`] computation as a [`CtOutput`] and reset
    /// [`Mac`] instance.
    fn finalize_reset(&mut self) -> CtOutput<Self>
    where
        Self: FixedOutputReset;

    /// Reset MAC instance to its initial state.
    fn reset(&mut self)
    where
        Self: Reset;

    /// Check if tag/code value is correct for the processed input.
    ///
    /// # Errors
    /// Returns [`MacError`] if `tag` is not valid.
    fn verify(self, tag: &Output<Self>) -> Result<(), MacError>;

    /// Check if tag/code value is correct for the processed input and reset
    /// [`Mac`] instance.
    ///
    /// # Errors
    /// Returns [`MacError`] if `tag` is not valid.
    fn verify_reset(&mut self, tag: &Output<Self>) -> Result<(), MacError>
    where
        Self: FixedOutputReset;

    /// Check truncated tag correctness using all bytes
    /// of calculated tag.
    ///
    /// # Errors
    /// Returns [`MacError`] if `tag` is not valid or not equal in length to this MAC's output.
    fn verify_slice(self, tag: &[u8]) -> Result<(), MacError>;

    /// Check truncated tag correctness using all bytes
    /// of calculated tag and reset [`Mac`] instance.
    ///
    /// # Errors
    /// Returns [`MacError`] if `tag` is not valid or not equal in length to MAC's output.
    fn verify_slice_reset(&mut self, tag: &[u8]) -> Result<(), MacError>
    where
        Self: FixedOutputReset;

    /// Check truncated tag correctness using left side bytes
    /// (i.e. `tag[..n]`) of calculated tag.
    ///
    /// # Errors
    /// Returns `Error` if `tag` is not valid or empty.
    fn verify_truncated_left(self, tag: &[u8]) -> Result<(), MacError>;

    /// Check truncated tag correctness using right side bytes
    /// (i.e. `tag[n..]`) of calculated tag.
    ///
    /// # Errors
    /// Returns `Error` if `tag` is not valid or empty.
    fn verify_truncated_right(self, tag: &[u8]) -> Result<(), MacError>;
}

impl<T: Update + FixedOutput + MacMarker> Mac for T {
    #[inline]
    fn update(&mut self, data: &[u8]) {
        Update::update(self, data);
    }

    #[inline]
    fn chain_update(mut self, data: impl AsRef<[u8]>) -> Self {
        Update::update(&mut self, data.as_ref());
        self
    }

    #[inline]
    fn finalize(self) -> CtOutput<Self> {
        CtOutput::new(self.finalize_fixed())
    }

    #[inline(always)]
    fn finalize_reset(&mut self) -> CtOutput<Self>
    where
        Self: FixedOutputReset,
    {
        CtOutput::new(self.finalize_fixed_reset())
    }

    #[inline]
    fn reset(&mut self)
    where
        Self: Reset,
    {
        Reset::reset(self);
    }

    #[inline]
    fn verify(self, tag: &Output<Self>) -> Result<(), MacError> {
        if self.finalize() == tag.into() {
            Ok(())
        } else {
            Err(MacError)
        }
    }

    #[inline]
    fn verify_reset(&mut self, tag: &Output<Self>) -> Result<(), MacError>
    where
        Self: FixedOutputReset,
    {
        if self.finalize_reset() == tag.into() {
            Ok(())
        } else {
            Err(MacError)
        }
    }

    #[inline]
    fn verify_slice(self, tag: &[u8]) -> Result<(), MacError> {
        let n = tag.len();
        if n != Self::OutputSize::USIZE {
            return Err(MacError);
        }
        let choice = self.finalize_fixed().as_slice().ct_eq(tag);
        if choice.into() { Ok(()) } else { Err(MacError) }
    }

    #[inline]
    fn verify_slice_reset(&mut self, tag: &[u8]) -> Result<(), MacError>
    where
        Self: FixedOutputReset,
    {
        let n = tag.len();
        if n != Self::OutputSize::USIZE {
            return Err(MacError);
        }
        let choice = self.finalize_fixed_reset().as_slice().ct_eq(tag);
        if choice.into() { Ok(()) } else { Err(MacError) }
    }

    fn verify_truncated_left(self, tag: &[u8]) -> Result<(), MacError> {
        let n = tag.len();
        if n == 0 || n > Self::OutputSize::USIZE {
            return Err(MacError);
        }
        let choice = self.finalize_fixed()[..n].ct_eq(tag);

        if choice.into() { Ok(()) } else { Err(MacError) }
    }

    fn verify_truncated_right(self, tag: &[u8]) -> Result<(), MacError> {
        let n = tag.len();
        if n == 0 || n > Self::OutputSize::USIZE {
            return Err(MacError);
        }
        let m = Self::OutputSize::USIZE - n;
        let choice = self.finalize_fixed()[m..].ct_eq(tag);

        if choice.into() { Ok(()) } else { Err(MacError) }
    }
}

/// Fixed size output value which provides a safe [`Eq`] implementation that
/// runs in constant time.
///
/// It is useful for implementing Message Authentication Codes (MACs).
#[derive(Clone)]
pub struct CtOutput<T: OutputSizeUser> {
    bytes: Output<T>,
}

impl<T: OutputSizeUser> CtOutput<T> {
    /// Create a new [`CtOutput`] value.
    #[inline(always)]
    pub fn new(bytes: Output<T>) -> Self {
        Self { bytes }
    }

    /// Get reference to the inner [`Output`] array this type wraps.
    #[inline(always)]
    pub fn as_bytes(&self) -> &Output<T> {
        &self.bytes
    }

    /// Get the inner [`Output`] array this type wraps.
    #[inline(always)]
    pub fn into_bytes(&self) -> Output<T> {
        self.bytes.clone()
    }
}

impl<T: OutputSizeUser> From<Output<T>> for CtOutput<T> {
    #[inline(always)]
    fn from(bytes: Output<T>) -> Self {
        Self { bytes }
    }
}

impl<'a, T: OutputSizeUser> From<&'a Output<T>> for CtOutput<T> {
    #[inline(always)]
    fn from(bytes: &'a Output<T>) -> Self {
        bytes.clone().into()
    }
}

impl<T: OutputSizeUser> PartialEq for CtOutput<T> {
    #[inline(always)]
    fn eq(&self, other: &CtOutput<T>) -> bool {
        self.bytes.ct_eq(&other.bytes).into()
    }
}

impl<T: OutputSizeUser> Eq for CtOutput<T> {}

impl<T: OutputSizeUser> fmt::Debug for CtOutput<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CtOutput { ... }")
    }
}

impl<T: OutputSizeUser> Drop for CtOutput<T> {
    #[inline]
    fn drop(&mut self) {
        #[cfg(feature = "zeroize")]
        {
            use zeroize::Zeroize;
            self.bytes.zeroize();
        }
    }
}

#[cfg(feature = "zeroize")]
impl<T: OutputSizeUser> zeroize::ZeroizeOnDrop for CtOutput<T> {}

/// Error type for when the [`Output`] of a [`Mac`]
/// is not equal to the expected value.
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct MacError;

impl fmt::Display for MacError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("MAC tag mismatch")
    }
}

impl core::error::Error for MacError {}
