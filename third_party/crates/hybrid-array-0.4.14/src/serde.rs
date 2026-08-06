//! Support for serializing and deserializing `Array` using `serde`.

use crate::{Array, ArraySize};
use core::{fmt, marker::PhantomData};
use serde::{
    de::{self, Deserialize, Deserializer, SeqAccess, Visitor},
    ser::{Serialize, SerializeTuple, Serializer},
};

impl<'de, T, U> Deserialize<'de> for Array<T, U>
where
    T: Deserialize<'de>,
    U: ArraySize,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
        T: Deserialize<'de>,
    {
        struct ArrayVisitor<T> {
            element: PhantomData<T>,
        }

        impl<'de, T, U> Visitor<'de> for ArrayVisitor<Array<T, U>>
        where
            T: Deserialize<'de>,
            U: ArraySize,
        {
            type Value = Array<T, U>;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(formatter, "an array of length {}", U::USIZE)
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Array<T, U>, A::Error>
            where
                A: SeqAccess<'de>,
            {
                Array::<T, U>::try_from_fn(|i| {
                    seq.next_element()?
                        .ok_or_else(|| de::Error::invalid_length(i, &self))
                })
            }
        }

        let visitor = ArrayVisitor {
            element: PhantomData,
        };

        deserializer.deserialize_tuple(U::USIZE, visitor)
    }
}

impl<T, U> Serialize for Array<T, U>
where
    T: Serialize,
    U: ArraySize,
{
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut seq = serializer.serialize_tuple(U::USIZE)?;

        for elem in self {
            seq.serialize_element(elem)?;
        }

        seq.end()
    }
}

#[cfg(test)]
mod tests {
    use crate::{Array, sizes::U3};
    type A = Array<u8, U3>;

    #[test]
    #[cfg(feature = "alloc")]
    fn expecting() {
        use alloc::string::ToString;
        let err = serde_json::from_str::<A>("true").unwrap_err();
        assert!(err.to_string().contains("expected an array of length 3"));
    }

    #[test]
    fn round_trip() {
        let example: A = Array([1, 2, 3]);
        let s = serde_json::to_string(&example).unwrap();
        let deserialized: A = serde_json::from_str(&s).unwrap();
        assert_eq!(example, deserialized);
    }
}
