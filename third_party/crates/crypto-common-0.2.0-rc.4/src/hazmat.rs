use crate::array::{
    self, Array, ArraySize,
    typenum::{Diff, Prod, Sum, U1, U2, U4, U8, U16, Unsigned},
};
use core::{convert::TryInto, default::Default, fmt};

/// Serialized internal state.
pub type SerializedState<T> = Array<u8, <T as SerializableState>::SerializedStateSize>;

/// Alias for `AddSerializedStateSize<T, S> = Sum<T, S::SerializedStateSize>`
pub type AddSerializedStateSize<T, S> = Sum<T, <S as SerializableState>::SerializedStateSize>;

/// Alias for `SubSerializedStateSize<T, S> = Diff<T, S::SerializedStateSize>`
pub type SubSerializedStateSize<T, S> = Diff<T, <S as SerializableState>::SerializedStateSize>;

/// The error type returned when an object cannot be deserialized from the state.
#[derive(Copy, Clone, Eq, PartialEq, Debug)]
pub struct DeserializeStateError;

impl fmt::Display for DeserializeStateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        f.write_str("Deserialization error")
    }
}

impl core::error::Error for DeserializeStateError {}

/// Types which can serialize the internal state and be restored from it.
///
/// # Compatibility
///
/// Serialized state can be assumed to be stable across backwards compatible
/// versions of an implementation crate, i.e. any `0.x.y` version of a crate
/// should be able to decode data serialized with any other `0.x.z` version,
/// but it may not be able to correctly decode data serialized with a non-`x`
/// version.
///
/// This guarantee is a subject to issues such as security fixes.
///
/// # SECURITY WARNING
///
/// Serialized state may contain sensitive data.
pub trait SerializableState
where
    Self: Sized,
{
    /// Size of serialized internal state.
    type SerializedStateSize: ArraySize;

    /// Serialize and return internal state.
    fn serialize(&self) -> SerializedState<Self>;
    /// Create an object from serialized internal state.
    fn deserialize(serialized_state: &SerializedState<Self>)
    -> Result<Self, DeserializeStateError>;
}

macro_rules! impl_seializable_state_unsigned {
    ($type: ty, $type_size: ty) => {
        impl SerializableState for $type {
            type SerializedStateSize = $type_size;

            fn serialize(&self) -> SerializedState<Self> {
                self.to_le_bytes().into()
            }

            fn deserialize(
                serialized_state: &SerializedState<Self>,
            ) -> Result<Self, DeserializeStateError> {
                Ok(<$type>::from_le_bytes((*serialized_state).into()))
            }
        }
    };
}

impl_seializable_state_unsigned!(u8, U1);
impl_seializable_state_unsigned!(u16, U2);
impl_seializable_state_unsigned!(u32, U4);
impl_seializable_state_unsigned!(u64, U8);
impl_seializable_state_unsigned!(u128, U16);

macro_rules! impl_serializable_state_u8_array {
    ($($n: ty),*) => {
        $(
            impl SerializableState for [u8; <$n>::USIZE] {
                type SerializedStateSize = $n;

                fn serialize(&self) -> SerializedState<Self> {
                    (*self).into()
                }

                fn deserialize(
                    serialized_state: &SerializedState<Self>,
                ) -> Result<Self, DeserializeStateError> {
                    Ok((*serialized_state).into())
                }
            }
        )*
    };
}

macro_rules! impl_serializable_state_type_array {
    ($type: ty, $type_size: ty, $n: ty) => {
        impl SerializableState for [$type; <$n>::USIZE] {
            type SerializedStateSize = Prod<$n, $type_size>;

            fn serialize(&self) -> SerializedState<Self> {
                let mut serialized_state = SerializedState::<Self>::default();
                for (val, chunk) in self
                    .iter()
                    .zip(serialized_state.chunks_exact_mut(<$type_size>::USIZE))
                {
                    chunk.copy_from_slice(&val.to_le_bytes());
                }

                serialized_state
            }

            fn deserialize(
                serialized_state: &SerializedState<Self>,
            ) -> Result<Self, DeserializeStateError> {
                let mut array = [0; <$n>::USIZE];
                for (val, chunk) in array
                    .iter_mut()
                    .zip(serialized_state.chunks_exact(<$type_size>::USIZE))
                {
                    *val = <$type>::from_le_bytes(chunk.try_into().unwrap());
                }
                Ok(array)
            }
        }
    };
}

macro_rules! impl_serializable_state_u16_array {
    ($($n: ty),*) => {
        $(
            impl_serializable_state_type_array!(u16, U2, $n);
        )*
    };
}

macro_rules! impl_serializable_state_u32_array {
    ($($n: ty),*) => {
        $(
            impl_serializable_state_type_array!(u32, U4, $n);
        )*
    };
}

macro_rules! impl_serializable_state_u64_array {
    ($($n: ty),*) => {
        $(
            impl_serializable_state_type_array!(u64, U8, $n);
        )*
    };
}

macro_rules! impl_serializable_state_u128_array {
    ($($n: ty),*) => {
        $(
            impl_serializable_state_type_array!(u128, U8, $n);
        )*
    };
}

impl_serializable_state_u8_array! {
    array::typenum::U1,
    array::typenum::U2,
    array::typenum::U3,
    array::typenum::U4,
    array::typenum::U5,
    array::typenum::U6,
    array::typenum::U7,
    array::typenum::U8,
    array::typenum::U9,
    array::typenum::U10,
    array::typenum::U11,
    array::typenum::U12,
    array::typenum::U13,
    array::typenum::U14,
    array::typenum::U15,
    array::typenum::U16,
    array::typenum::U17,
    array::typenum::U18,
    array::typenum::U19,
    array::typenum::U20,
    array::typenum::U21,
    array::typenum::U22,
    array::typenum::U23,
    array::typenum::U24,
    array::typenum::U25,
    array::typenum::U26,
    array::typenum::U27,
    array::typenum::U28,
    array::typenum::U29,
    array::typenum::U30,
    array::typenum::U31,
    array::typenum::U32,
    array::typenum::U33,
    array::typenum::U34,
    array::typenum::U35,
    array::typenum::U36,
    array::typenum::U37,
    array::typenum::U38,
    array::typenum::U39,
    array::typenum::U40,
    array::typenum::U41,
    array::typenum::U42,
    array::typenum::U43,
    array::typenum::U44,
    array::typenum::U45,
    array::typenum::U46,
    array::typenum::U47,
    array::typenum::U48,
    array::typenum::U49,
    array::typenum::U50,
    array::typenum::U51,
    array::typenum::U52,
    array::typenum::U53,
    array::typenum::U54,
    array::typenum::U55,
    array::typenum::U56,
    array::typenum::U57,
    array::typenum::U58,
    array::typenum::U59,
    array::typenum::U60,
    array::typenum::U61,
    array::typenum::U62,
    array::typenum::U63,
    array::typenum::U64,
    array::typenum::U96,
    array::typenum::U128,
    array::typenum::U192,
    array::typenum::U256,
    array::typenum::U384,
    array::typenum::U448,
    array::typenum::U512,
    array::typenum::U768,
    array::typenum::U896,
    array::typenum::U1024,
    array::typenum::U2048,
    array::typenum::U4096,
    array::typenum::U8192
}

impl_serializable_state_u16_array! {
    array::typenum::U1,
    array::typenum::U2,
    array::typenum::U3,
    array::typenum::U4,
    array::typenum::U5,
    array::typenum::U6,
    array::typenum::U7,
    array::typenum::U8,
    array::typenum::U9,
    array::typenum::U10,
    array::typenum::U11,
    array::typenum::U12,
    array::typenum::U13,
    array::typenum::U14,
    array::typenum::U15,
    array::typenum::U16,
    array::typenum::U17,
    array::typenum::U18,
    array::typenum::U19,
    array::typenum::U20,
    array::typenum::U21,
    array::typenum::U22,
    array::typenum::U23,
    array::typenum::U24,
    array::typenum::U25,
    array::typenum::U26,
    array::typenum::U27,
    array::typenum::U28,
    array::typenum::U29,
    array::typenum::U30,
    array::typenum::U31,
    array::typenum::U32,
    array::typenum::U48,
    array::typenum::U96,
    array::typenum::U128,
    array::typenum::U192,
    array::typenum::U256,
    array::typenum::U384,
    array::typenum::U448,
    array::typenum::U512,
    array::typenum::U2048,
    array::typenum::U4096
}

impl_serializable_state_u32_array! {
    array::typenum::U1,
    array::typenum::U2,
    array::typenum::U3,
    array::typenum::U4,
    array::typenum::U5,
    array::typenum::U6,
    array::typenum::U7,
    array::typenum::U8,
    array::typenum::U9,
    array::typenum::U10,
    array::typenum::U11,
    array::typenum::U12,
    array::typenum::U13,
    array::typenum::U14,
    array::typenum::U15,
    array::typenum::U16,
    array::typenum::U24,
    array::typenum::U32,
    array::typenum::U48,
    array::typenum::U64,
    array::typenum::U96,
    array::typenum::U128,
    array::typenum::U192,
    array::typenum::U256,
    array::typenum::U512,
    array::typenum::U1024,
    array::typenum::U2048
}

impl_serializable_state_u64_array! {
    array::typenum::U1,
    array::typenum::U2,
    array::typenum::U3,
    array::typenum::U4,
    array::typenum::U5,
    array::typenum::U6,
    array::typenum::U7,
    array::typenum::U8,
    array::typenum::U12,
    array::typenum::U16,
    array::typenum::U24,
    array::typenum::U32,
    array::typenum::U48,
    array::typenum::U64,
    array::typenum::U96,
    array::typenum::U128,
    array::typenum::U256,
    array::typenum::U512,
    array::typenum::U1024
}

impl_serializable_state_u128_array! {
    array::typenum::U1,
    array::typenum::U2,
    array::typenum::U3,
    array::typenum::U4,
    array::typenum::U6,
    array::typenum::U8,
    array::typenum::U12,
    array::typenum::U16,
    array::typenum::U24,
    array::typenum::U32,
    array::typenum::U48,
    array::typenum::U64,
    array::typenum::U128,
    array::typenum::U256,
    array::typenum::U512
}
