use crate::array::{
    Array, ArraySize, sizes,
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
    ///
    /// # Errors
    /// If the serialized state could not be deserialized successfully.
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
    ($($n: ident),*) => {
        $(
            impl SerializableState for [u8; sizes::$n::USIZE] {
                type SerializedStateSize = sizes::$n;

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
    ($type: ty, $type_size: ty, $n: ident) => {
        impl SerializableState for [$type; sizes::$n::USIZE] {
            type SerializedStateSize = Prod<sizes::$n, $type_size>;

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
                let mut array = [0; sizes::$n::USIZE];
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
    ($($n: ident),*) => {
        $(
            impl_serializable_state_type_array!(u16, U2, $n);
        )*
    };
}

macro_rules! impl_serializable_state_u32_array {
    ($($n: ident),*) => {
        $(
            impl_serializable_state_type_array!(u32, U4, $n);
        )*
    };
}

macro_rules! impl_serializable_state_u64_array {
    ($($n: ident),*) => {
        $(
            impl_serializable_state_type_array!(u64, U8, $n);
        )*
    };
}

macro_rules! impl_serializable_state_u128_array {
    ($($n: ident),*) => {
        $(
            impl_serializable_state_type_array!(u128, U8, $n);
        )*
    };
}

impl_serializable_state_u8_array! {
    U1,
    U2,
    U3,
    U4,
    U5,
    U6,
    U7,
    U8,
    U9,
    U10,
    U11,
    U12,
    U13,
    U14,
    U15,
    U16,
    U17,
    U18,
    U19,
    U20,
    U21,
    U22,
    U23,
    U24,
    U25,
    U26,
    U27,
    U28,
    U29,
    U30,
    U31,
    U32,
    U33,
    U34,
    U35,
    U36,
    U37,
    U38,
    U39,
    U40,
    U41,
    U42,
    U43,
    U44,
    U45,
    U46,
    U47,
    U48,
    U49,
    U50,
    U51,
    U52,
    U53,
    U54,
    U55,
    U56,
    U57,
    U58,
    U59,
    U60,
    U61,
    U62,
    U63,
    U64,
    U96,
    U128,
    U192,
    U256,
    U384,
    U448,
    U512,
    U768,
    U896,
    U1024,
    U2048,
    U4096,
    U8192
}

impl_serializable_state_u16_array! {
    U1,
    U2,
    U3,
    U4,
    U5,
    U6,
    U7,
    U8,
    U9,
    U10,
    U11,
    U12,
    U13,
    U14,
    U15,
    U16,
    U17,
    U18,
    U19,
    U20,
    U21,
    U22,
    U23,
    U24,
    U25,
    U26,
    U27,
    U28,
    U29,
    U30,
    U31,
    U32,
    U48,
    U96,
    U128,
    U192,
    U256,
    U384,
    U448,
    U512,
    U2048,
    U4096
}

impl_serializable_state_u32_array! {
    U1,
    U2,
    U3,
    U4,
    U5,
    U6,
    U7,
    U8,
    U9,
    U10,
    U11,
    U12,
    U13,
    U14,
    U15,
    U16,
    U24,
    U32,
    U48,
    U64,
    U96,
    U128,
    U192,
    U256,
    U512,
    U1024,
    U2048
}

impl_serializable_state_u64_array! {
    U1,
    U2,
    U3,
    U4,
    U5,
    U6,
    U7,
    U8,
    U12,
    U16,
    U24,
    U32,
    U48,
    U64,
    U96,
    U128,
    U256,
    U512,
    U1024
}

impl_serializable_state_u128_array! {
    U1,
    U2,
    U3,
    U4,
    U6,
    U8,
    U12,
    U16,
    U24,
    U32,
    U48,
    U64,
    U128,
    U256,
    U512
}
