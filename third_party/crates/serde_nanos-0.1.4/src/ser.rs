#[cfg(feature = "chrono")]
use chrono;

use serde::ser::SerializeSeq;
use serde::Serializer;

/// Types that can be serialized via `#[serde(with = "serde_nanos")]`.
pub trait Serialize {
    #[allow(missing_docs)]
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer;
}

impl Serialize for std::time::Duration {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let nanoseconds = self.as_nanos() as i64;
        serializer.serialize_i64(nanoseconds)
    }
}

impl Serialize for Option<std::time::Duration> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        struct Data<'a, V: 'a>(&'a V)
        where
            V: Serialize;

        impl<'a, V: Serialize + 'a> serde::Serialize for Data<'a, V> {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                self.0.serialize(serializer)
            }
        }

        match *self {
            Some(ref value) => serializer.serialize_some(&Data(value)),
            None => serializer.serialize_none(),
        }
    }
}

impl Serialize for Vec<std::time::Duration> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut seq = serializer.serialize_seq(Some(self.len()))?;
        for e in self {
            let nanos = e.as_nanos() as i64;
            seq.serialize_element(&nanos)?;
        }
        seq.end()
    }
}

#[cfg(feature = "chrono")]
impl Serialize for chrono::Duration {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let nanoseconds = self.num_nanoseconds().unwrap();
        serializer.serialize_i64(nanoseconds)
    }
}

#[cfg(feature = "chrono")]
impl Serialize for Option<chrono::Duration> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        struct Data<'a, V: 'a>(&'a V)
        where
            V: Serialize;

        impl<'a, V: Serialize + 'a> serde::Serialize for Data<'a, V> {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                self.0.serialize(serializer)
            }
        }

        match *self {
            Some(ref value) => serializer.serialize_some(&Data(value)),
            None => serializer.serialize_none(),
        }
    }
}

#[cfg(feature = "chrono")]
impl Serialize for Vec<chrono::Duration> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut seq = serializer.serialize_seq(Some(self.len()))?;
        for e in self {
            let nanos = e.as_nanos() as i64;
            seq.serialize_element(&nanos)?;
        }
        seq.end()
    }
}
