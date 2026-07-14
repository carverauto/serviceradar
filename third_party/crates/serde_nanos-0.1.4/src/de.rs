use std::fmt;
use std::marker::PhantomData;

#[cfg(feature = "chrono")]
use chrono;

use serde::de::{Error, SeqAccess, Visitor};
use serde::Deserializer;

/// Types that can be deserialized via `#[serde(with = "serde_nanos")]`.
pub trait Deserialize<'de>: Sized {
    #[allow(missing_docs)]
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>;
}

impl<'de> Deserialize<'de> for std::time::Duration {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        serde::Deserialize::deserialize(deserializer)
            .map(|nanos| std::time::Duration::from_nanos(nanos))
    }
}

impl<'de> Deserialize<'de> for Option<std::time::Duration> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct OptionVisitor<T> {
            marker: PhantomData<T>,
        }

        impl<'de, T: Deserialize<'de>> Visitor<'de> for OptionVisitor<T> {
            type Value = Option<T>;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("option")
            }

            #[inline]
            fn visit_unit<E>(self) -> Result<Option<T>, E>
            where
                E: Error,
            {
                Ok(None)
            }

            #[inline]
            fn visit_none<E>(self) -> Result<Option<T>, E>
            where
                E: Error,
            {
                Ok(None)
            }

            #[inline]
            fn visit_some<D>(self, deserializer: D) -> Result<Option<T>, D::Error>
            where
                D: Deserializer<'de>,
            {
                T::deserialize(deserializer).map(Some)
            }
        }

        deserializer.deserialize_option(OptionVisitor {
            marker: PhantomData,
        })
    }
}

impl<'de> Deserialize<'de> for Vec<std::time::Duration> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct VecVisitor {
            marker: PhantomData<Vec<std::time::Duration>>,
        }
        impl<'de> Visitor<'de> for VecVisitor {
            type Value = Vec<std::time::Duration>;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("array of durations in nanoseconds")
            }

            fn visit_seq<S>(self, mut visitor: S) -> Result<Self::Value, S::Error>
            where
                S: SeqAccess<'de>,
            {
                let mut durations = Vec::with_capacity(visitor.size_hint().unwrap_or(0));
                while let Some(elem) = visitor.next_element()? {
                    durations.push(std::time::Duration::from_nanos(elem));
                }
                Ok(durations)
            }
        }
        deserializer.deserialize_seq(VecVisitor {
            marker: PhantomData,
        })
    }
}

#[cfg(feature = "chrono")]
impl<'de> Deserialize<'de> for chrono::Duration {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        serde::Deserialize::deserialize(deserializer)
            .map(|nanos| chrono::Duration::nanoseconds(nanos))
    }
}

#[cfg(feature = "chrono")]
impl<'de> Deserialize<'de> for Option<chrono::Duration> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct OptionVisitor<T> {
            marker: PhantomData<T>,
        }

        impl<'de, T: Deserialize<'de>> Visitor<'de> for OptionVisitor<T> {
            type Value = Option<T>;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("option")
            }

            #[inline]
            fn visit_unit<E>(self) -> Result<Option<T>, E>
            where
                E: Error,
            {
                Ok(None)
            }

            #[inline]
            fn visit_none<E>(self) -> Result<Option<T>, E>
            where
                E: Error,
            {
                Ok(None)
            }

            #[inline]
            fn visit_some<D>(self, deserializer: D) -> Result<Option<T>, D::Error>
            where
                D: Deserializer<'de>,
            {
                T::deserialize(deserializer).map(Some)
            }
        }

        deserializer.deserialize_option(OptionVisitor {
            marker: PhantomData,
        })
    }
}

#[cfg(feature = "chrono")]
impl<'de> Deserialize<'de> for Vec<chrono::Duration> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct VecVisitor {
            marker: PhantomData<Vec<Duration>>,
        }
        impl<'de> Visitor<'de> for VecVisitor {
            type Value = Vec<Duration>;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("array of durations in nanoseconds")
            }

            fn visit_seq<S>(self, mut visitor: S) -> Result<Self::Value, S::Error>
            where
                S: SeqAccess<'de>,
            {
                let mut durations = Vec::with_capacity(visitor.size_hint().unwrap_or(0));
                while let Some(elem) = visitor.next_element()? {
                    durations.push(Duration::from_nanos(elem));
                }
                Ok(durations)
            }
        }
        deserializer.deserialize_seq(VecVisitor {
            marker: PhantomData,
        })
    }
}
