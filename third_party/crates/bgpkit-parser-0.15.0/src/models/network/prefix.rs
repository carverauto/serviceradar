use crate::models::BgpModelsError;
#[cfg(feature = "parser")]
use bytes::{BufMut, Bytes, BytesMut};
use ipnet::IpNet;
use std::fmt::{Debug, Display, Formatter};
use std::str::FromStr;

/// A representation of a network prefix with an optional path ID.
#[derive(PartialEq, Eq, Clone, Copy, Hash)]
pub struct NetworkPrefix {
    pub prefix: IpNet,
    pub path_id: Option<u32>,
}

// Attempt to reduce the size of the debug output
impl Debug for NetworkPrefix {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self.path_id {
            Some(path_id) => write!(f, "{}#{}", self.prefix, path_id),
            None => write!(f, "{}", self.prefix),
        }
    }
}

impl FromStr for NetworkPrefix {
    type Err = BgpModelsError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let prefix = IpNet::from_str(s)?;
        Ok(NetworkPrefix {
            prefix,
            path_id: None,
        })
    }
}

impl NetworkPrefix {
    pub fn new(prefix: IpNet, path_id: Option<u32>) -> NetworkPrefix {
        NetworkPrefix { prefix, path_id }
    }

    #[cfg(feature = "parser")]
    /// Encodes the IPNet prefix into a byte slice.
    ///
    /// # Arguments
    ///
    /// * `add_path` - A bool indicating whether to include the path identifier in the encoded bytes.
    ///
    /// # Returns
    ///
    /// A `Bytes` slice containing the encoded IPNet prefix.
    ///
    /// # Example
    ///
    /// ```rust
    /// use std::str::FromStr;
    /// use bytes::Bytes;
    /// use ipnet::{IpNet, Ipv4Net};
    /// use bgpkit_parser::models::NetworkPrefix;
    ///
    /// let prefix = NetworkPrefix::from_str("192.168.0.0/24").unwrap();
    /// let encoded_bytes = prefix.encode();
    ///
    /// assert_eq!(encoded_bytes.iter().as_slice(), &[24, 192, 168, 0]);
    /// ```
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::new();

        // encode path identifier if it exists
        if let Some(path_id) = self.path_id {
            // encode path identifier
            bytes.put_u32(path_id);
        }

        // encode prefix

        let bit_len = self.prefix.prefix_len();
        let byte_len = bit_len.div_ceil(8) as usize;
        bytes.put_u8(bit_len);

        match self.prefix {
            IpNet::V4(prefix) => {
                bytes.put_slice(&prefix.addr().octets()[0..byte_len]);
            }
            IpNet::V6(prefix) => {
                bytes.put_slice(&prefix.addr().octets()[0..byte_len]);
            }
        };
        bytes.freeze()
    }
}

impl Display for NetworkPrefix {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.prefix)
    }
}

#[cfg(feature = "serde")]
mod serde_impl {
    use super::*;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    #[derive(Serialize, Deserialize)]
    #[serde(untagged, deny_unknown_fields)]
    enum SerdeNetworkPrefixRepr {
        PlainPrefix(IpNet),
        WithPathId { prefix: IpNet, path_id: u32 },
    }

    impl Serialize for NetworkPrefix {
        fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: Serializer,
        {
            match self.path_id {
                Some(path_id) => SerdeNetworkPrefixRepr::WithPathId {
                    prefix: self.prefix,
                    path_id,
                }
                .serialize(serializer),
                None => self.prefix.serialize(serializer),
            }
        }
    }

    impl<'de> Deserialize<'de> for NetworkPrefix {
        fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
        where
            D: Deserializer<'de>,
        {
            match SerdeNetworkPrefixRepr::deserialize(deserializer)? {
                SerdeNetworkPrefixRepr::PlainPrefix(prefix) => Ok(NetworkPrefix {
                    prefix,
                    path_id: None,
                }),
                SerdeNetworkPrefixRepr::WithPathId { prefix, path_id } => Ok(NetworkPrefix {
                    prefix,
                    path_id: Some(path_id),
                }),
            }
        }
    }
}

// Here's the test code appended at the end of your source code
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fromstr() {
        let prefix_str = "192.168.0.0/24";
        let network_prefix = NetworkPrefix::from_str(prefix_str).unwrap();
        assert_eq!(
            network_prefix.prefix,
            IpNet::from_str("192.168.0.0/24").unwrap()
        );
        assert_eq!(network_prefix.path_id, None);
    }

    #[test]
    #[cfg(feature = "parser")]
    fn test_encode() {
        let prefix = IpNet::from_str("192.168.0.0/24").unwrap();
        let network_prefix = NetworkPrefix::new(prefix, Some(1));
        let _encoded = network_prefix.encode();
    }

    #[test]
    fn test_display() {
        let prefix = IpNet::from_str("192.168.0.0/24").unwrap();
        let network_prefix = NetworkPrefix::new(prefix, Some(1));
        assert_eq!(network_prefix.to_string(), "192.168.0.0/24");
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serialization() {
        let prefix = IpNet::from_str("192.168.0.0/24").unwrap();
        let network_prefix = NetworkPrefix::new(prefix, Some(1));
        let serialized = serde_json::to_string(&network_prefix).unwrap();
        assert_eq!(serialized, "{\"prefix\":\"192.168.0.0/24\",\"path_id\":1}");
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_deserialization() {
        let serialized = "{\"prefix\":\"192.168.0.0/24\",\"path_id\":1}";
        let deserialized: NetworkPrefix = serde_json::from_str(serialized).unwrap();
        assert_eq!(
            deserialized.prefix,
            IpNet::from_str("192.168.0.0/24").unwrap()
        );
        assert_eq!(deserialized.path_id, Some(1));
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_binary_serialization_with_path_id() {
        let prefix = IpNet::from_str("192.168.0.0/24").unwrap();
        let network_prefix = NetworkPrefix::new(prefix, Some(42));
        // Test non-human readable serialization (binary-like)
        let serialized = serde_json::to_vec(&network_prefix).unwrap();
        let deserialized: NetworkPrefix = serde_json::from_slice(&serialized).unwrap();
        assert_eq!(deserialized.prefix, prefix);
        assert_eq!(deserialized.path_id, Some(42));
    }

    #[test]
    fn test_debug() {
        let prefix = IpNet::from_str("192.168.0.0/24").unwrap();
        let network_prefix = NetworkPrefix::new(prefix, Some(1));
        assert_eq!(format!("{network_prefix:?}"), "192.168.0.0/24#1");
    }
}
