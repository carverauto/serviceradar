//! Array-backed buffer for BER bytes.

/// Array-backed buffer for storing BER computed at compile-time.
#[derive(Copy, Clone, Eq, Hash, PartialEq, PartialOrd, Ord)]
pub struct Buffer<const SIZE: usize> {
    /// Length in bytes
    pub(crate) length: u8,

    /// Array containing BER/DER-serialized bytes (no header)
    pub(crate) bytes: [u8; SIZE],
}

impl<const SIZE: usize> Buffer<SIZE> {
    /// Borrow the inner byte slice.
    pub const fn as_bytes(&self) -> &[u8] {
        self.bytes.split_at(self.length as usize).0
    }

    /// Get the length of the BER message.
    pub const fn len(&self) -> usize {
        self.length as usize
    }

    /// Const comparison of two buffers.
    pub const fn eq(&self, rhs: &Self) -> bool {
        if self.length != rhs.length {
            return false;
        }

        let mut i = 0usize;

        while i < self.len() {
            if self.bytes[i] != rhs.bytes[i] {
                return false;
            }

            // Won't overflow due to `i < self.len()` check above
            #[allow(clippy::arithmetic_side_effects)]
            {
                i += 1;
            }
        }

        true
    }
}

impl<const SIZE: usize> AsRef<[u8]> for Buffer<SIZE> {
    fn as_ref(&self) -> &[u8] {
        self.as_bytes()
    }
}
