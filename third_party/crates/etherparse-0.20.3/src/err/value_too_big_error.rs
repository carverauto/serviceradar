use crate::err;
use core::{cmp::Eq, cmp::PartialEq, fmt::Debug, fmt::Display, hash::Hash};

/// Error if a value exceeds the maximum allowed value.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct ValueTooBigError<T: Sized + Clone + Display + Debug + Eq + PartialEq + Hash> {
    /// Value that was disallowed.
    pub actual: T,

    /// Maximum allowed value (inclusive).
    pub max_allowed: T,

    /// Type of value.
    pub value_type: err::ValueType,
}

impl<T> core::fmt::Display for ValueTooBigError<T>
where
    T: Sized + Clone + Display + Debug + Eq + PartialEq + Hash,
{
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(
            f,
            "Error '{}' is too big to be a '{}' (maximum allowed value is '{}')",
            self.actual, self.value_type, self.max_allowed
        )
    }
}

impl<T> core::error::Error for ValueTooBigError<T>
where
    T: Sized + Clone + Display + Debug + Eq + PartialEq + Hash,
{
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use std::{collections::hash_map::DefaultHasher, error::Error, format, hash::Hasher};

    #[test]
    fn fmt() {
        assert_eq!(
            format!(
                "{}",
                ValueTooBigError {
                    actual: 3,
                    max_allowed: 2,
                    value_type: err::ValueType::IpFragmentOffset
                }
            ),
            "Error '3' is too big to be a 'IP Fragment Offset' (maximum allowed value is '2')"
        );
    }

    #[test]
    fn dbg() {
        assert_eq!(
            format!(
                "{:?}",
                ValueTooBigError {
                    actual: 3,
                    max_allowed: 2,
                    value_type: err::ValueType::IpFragmentOffset
                }
            ),
            format!(
                "ValueTooBigError {{ actual: {}, max_allowed: {}, value_type: {:?} }}",
                3,
                2,
                err::ValueType::IpFragmentOffset
            )
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = ValueTooBigError {
            actual: 3,
            max_allowed: 2,
            value_type: err::ValueType::IpFragmentOffset,
        };
        assert_eq!(err, err.clone());
        let hash_a = {
            let mut hasher = DefaultHasher::new();
            err.hash(&mut hasher);
            hasher.finish()
        };
        let hash_b = {
            let mut hasher = DefaultHasher::new();
            err.clone().hash(&mut hasher);
            hasher.finish()
        };
        assert_eq!(hash_a, hash_b);
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(ValueTooBigError {
            actual: 3,
            max_allowed: 2,
            value_type: err::ValueType::IpFragmentOffset
        }
        .source()
        .is_none());
    }
}
