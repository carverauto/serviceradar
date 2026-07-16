use core::fmt;
use core::marker::PhantomData;

use common::array::ArraySize;
use common::hazmat::SerializableState;
use common::{BlockSizeUser, KeyInit, KeySizeUser, OutputSizeUser, Reset};

use crate::{
    CollisionResistance, CustomizedInit, ExtendableOutput, ExtendableOutputReset, FixedOutput,
    FixedOutputReset, HashMarker, Update,
};

/// Wrapper around [`ExtendableOutput`] types adding [`OutputSizeUser`] with the given size of `S`.
pub struct XofFixedWrapper<T: ExtendableOutput, S: ArraySize> {
    hash: T,
    size: PhantomData<S>,
}

impl<T: ExtendableOutput + Clone, S: ArraySize> Clone for XofFixedWrapper<T, S> {
    fn clone(&self) -> Self {
        Self {
            hash: self.hash.clone(),
            size: PhantomData,
        }
    }
}

impl<T: ExtendableOutput + fmt::Debug, S: ArraySize> fmt::Debug for XofFixedWrapper<T, S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("XofFixedWrapper")
            .field("hash", &self.hash)
            .field("_size", &self.size)
            .finish()
    }
}

impl<T: ExtendableOutput + Default, S: ArraySize> Default for XofFixedWrapper<T, S> {
    fn default() -> Self {
        Self {
            hash: Default::default(),
            size: PhantomData,
        }
    }
}

impl<T: ExtendableOutput + HashMarker, S: ArraySize> HashMarker for XofFixedWrapper<T, S> {}

#[cfg(feature = "mac")]
impl<T: ExtendableOutput + crate::MacMarker, S: ArraySize> crate::MacMarker
    for XofFixedWrapper<T, S>
{
}

impl<T: ExtendableOutput + CollisionResistance, S: ArraySize> CollisionResistance
    for XofFixedWrapper<T, S>
{
    type CollisionResistance = T::CollisionResistance;
}

// this blanket impl is needed for HMAC
impl<T: ExtendableOutput + BlockSizeUser, S: ArraySize> BlockSizeUser for XofFixedWrapper<T, S> {
    type BlockSize = T::BlockSize;
}

impl<T: ExtendableOutput + KeySizeUser, S: ArraySize> KeySizeUser for XofFixedWrapper<T, S> {
    type KeySize = T::KeySize;
}

impl<T: ExtendableOutput + KeyInit, S: ArraySize> KeyInit for XofFixedWrapper<T, S> {
    fn new(key: &common::Key<Self>) -> Self {
        Self {
            hash: T::new(key),
            size: PhantomData,
        }
    }
}

impl<T: ExtendableOutput + Reset, S: ArraySize> Reset for XofFixedWrapper<T, S> {
    fn reset(&mut self) {
        self.hash.reset();
    }
}

impl<T: ExtendableOutput + Update, S: ArraySize> Update for XofFixedWrapper<T, S> {
    fn update(&mut self, data: &[u8]) {
        self.hash.update(data);
    }
}

impl<T: ExtendableOutput, S: ArraySize> OutputSizeUser for XofFixedWrapper<T, S> {
    type OutputSize = S;
}

impl<T: ExtendableOutput + Update, S: ArraySize> FixedOutput for XofFixedWrapper<T, S> {
    fn finalize_into(self, out: &mut common::Output<Self>) {
        self.hash.finalize_xof_into(out);
    }
}

impl<T: ExtendableOutputReset, S: ArraySize> FixedOutputReset for XofFixedWrapper<T, S> {
    fn finalize_into_reset(&mut self, out: &mut common::Output<Self>) {
        self.hash.finalize_xof_reset_into(out);
    }
}

impl<T: ExtendableOutput, S: ArraySize> ExtendableOutput for XofFixedWrapper<T, S> {
    type Reader = T::Reader;

    fn finalize_xof(self) -> Self::Reader {
        self.hash.finalize_xof()
    }
}

impl<T: ExtendableOutputReset, S: ArraySize> ExtendableOutputReset for XofFixedWrapper<T, S> {
    fn finalize_xof_reset(&mut self) -> Self::Reader {
        self.hash.finalize_xof_reset()
    }
}

#[cfg(feature = "zeroize")]
impl<T: ExtendableOutput + zeroize::ZeroizeOnDrop, S: ArraySize> zeroize::ZeroizeOnDrop
    for XofFixedWrapper<T, S>
{
}

impl<T: ExtendableOutput + CustomizedInit, S: ArraySize> CustomizedInit for XofFixedWrapper<T, S> {
    fn new_customized(customization: &[u8]) -> Self {
        Self {
            hash: T::new_customized(customization),
            size: PhantomData,
        }
    }
}

impl<T: ExtendableOutput + SerializableState, S: ArraySize> SerializableState
    for XofFixedWrapper<T, S>
{
    type SerializedStateSize = T::SerializedStateSize;

    fn serialize(&self) -> common::hazmat::SerializedState<Self> {
        self.hash.serialize()
    }

    fn deserialize(
        serialized_state: &common::hazmat::SerializedState<Self>,
    ) -> Result<Self, common::hazmat::DeserializeStateError> {
        T::deserialize(serialized_state).map(|hash| Self {
            hash,
            size: PhantomData,
        })
    }
}
