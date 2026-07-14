//! BGP attribute structs
mod aspath;
mod nlri;
mod origin;

use crate::models::network::*;
use bitflags::bitflags;
use num_enum::{FromPrimitive, IntoPrimitive};
use std::cmp::Ordering;
use std::iter::{FromIterator, Map};
use std::net::IpAddr;
use std::slice::Iter;
use std::vec::IntoIter;

use crate::error::BgpValidationWarning;
use crate::models::*;

pub use aspath::*;
pub use nlri::*;
pub use origin::*;

bitflags! {
    /// The high-order bit (bit 0) of the Attribute Flags octet is the
    /// Optional bit.  It defines whether the attribute is optional (if
    /// set to 1) or well-known (if set to 0).
    ///
    /// The second high-order bit (bit 1) of the Attribute Flags octet
    /// is the Transitive bit.  It defines whether an optional
    /// attribute is transitive (if set to 1) or non-transitive (if set
    /// to 0).
    ///
    /// For well-known attributes, the Transitive bit MUST be set to 1.
    /// (See Section 5 for a discussion of transitive attributes.)
    ///
    /// The third high-order bit (bit 2) of the Attribute Flags octet
    /// is the Partial bit.  It defines whether the information
    /// contained in the optional transitive attribute is partial (if
    /// set to 1) or complete (if set to 0).  For well-known attributes
    /// and for optional non-transitive attributes, the Partial bit
    /// MUST be set to 0.
    ///
    /// The fourth high-order bit (bit 3) of the Attribute Flags octet
    /// is the Extended Length bit.  It defines whether the Attribute
    /// Length is one octet (if set to 0) or two octets (if set to 1).
    #[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
    #[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
    pub struct AttrFlags: u8 {
        const OPTIONAL   = 0b10000000;
        const TRANSITIVE = 0b01000000;
        const PARTIAL    = 0b00100000;
        const EXTENDED   = 0b00010000;
    }
}

/// Attribute types.
///
/// All attributes currently defined and not Unassigned or Deprecated are included here.
/// To see the full list, check out IANA at:
/// <https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-2>
#[allow(non_camel_case_types)]
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum AttrType {
    RESERVED = 0,
    ORIGIN = 1,
    AS_PATH = 2,
    NEXT_HOP = 3,
    MULTI_EXIT_DISCRIMINATOR = 4,
    LOCAL_PREFERENCE = 5,
    ATOMIC_AGGREGATE = 6,
    AGGREGATOR = 7,
    COMMUNITIES = 8,
    /// <https://tools.ietf.org/html/rfc4456>
    ORIGINATOR_ID = 9,
    CLUSTER_LIST = 10,
    /// <https://tools.ietf.org/html/rfc4760>
    CLUSTER_ID = 13,
    MP_REACHABLE_NLRI = 14,
    MP_UNREACHABLE_NLRI = 15,
    /// <https://datatracker.ietf.org/doc/html/rfc4360>
    EXTENDED_COMMUNITIES = 16,
    AS4_PATH = 17,
    AS4_AGGREGATOR = 18,
    PMSI_TUNNEL = 22,
    TUNNEL_ENCAPSULATION = 23,
    TRAFFIC_ENGINEERING = 24,
    IPV6_ADDRESS_SPECIFIC_EXTENDED_COMMUNITIES = 25,
    AIGP = 26,
    PE_DISTINGUISHER_LABELS = 27,
    BGP_LS_ATTRIBUTE = 29,
    LARGE_COMMUNITIES = 32,
    BGPSEC_PATH = 33,
    ONLY_TO_CUSTOMER = 35,
    SFP_ATTRIBUTE = 37,
    BFD_DISCRIMINATOR = 38,
    BGP_PREFIX_SID = 40,
    ATTR_SET = 128,
    /// <https://datatracker.ietf.org/doc/html/rfc2042>
    DEVELOPMENT = 255,

    /// Catch all for any unknown attribute types
    #[num_enum(catch_all)]
    // We have to explicitly assign this variant a number, otherwise the compiler will attempt to
    // assign it to 256 (previous + 1) and overflow the type.
    Unknown(u8) = 254,
}

impl PartialOrd for AttrType {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for AttrType {
    fn cmp(&self, other: &Self) -> Ordering {
        u8::from(*self).cmp(&u8::from(*other))
    }
}

pub fn get_deprecated_attr_type(attr_type: u8) -> Option<&'static str> {
    match attr_type {
        11 => Some("DPA"),
        12 => Some("ADVERTISER"),
        13 => Some("RCID_PATH"),
        19 => Some("SAFI Specific Attribute"),
        20 => Some("Connector Attribute"),
        21 => Some("AS_PATHLIMIT"),
        28 => Some("BGP Entropy Label Capability"),
        30 | 31 | 129 | 241 | 242 | 243 => Some("RFC8093"),

        _ => None,
    }
}

/// Convenience wrapper for a list of attributes
#[derive(Debug, PartialEq, Clone, Default, Eq)]
pub struct Attributes {
    // Black box type to allow for later changes/optimizations. The most common attributes could be
    // added as fields to allow for easier lookup.
    pub(crate) inner: Vec<Attribute>,
    /// RFC 7606 validation warnings collected during parsing
    pub(crate) validation_warnings: Vec<BgpValidationWarning>,
}

impl Attributes {
    pub fn has_attr(&self, ty: AttrType) -> bool {
        self.inner.iter().any(|x| x.value.attr_type() == ty)
    }

    pub fn get_attr(&self, ty: AttrType) -> Option<Attribute> {
        self.inner
            .iter()
            .find(|x| x.value.attr_type() == ty)
            .cloned()
    }

    pub fn add_attr(&mut self, attr: Attribute) {
        self.inner.push(attr);
    }

    /// Add a validation warning to the attributes
    pub fn add_validation_warning(&mut self, warning: BgpValidationWarning) {
        self.validation_warnings.push(warning);
    }

    /// Get all validation warnings for these attributes
    pub fn validation_warnings(&self) -> &[BgpValidationWarning] {
        &self.validation_warnings
    }

    /// Check if there are any validation warnings
    pub fn has_validation_warnings(&self) -> bool {
        !self.validation_warnings.is_empty()
    }

    /// Get the `ORIGIN` attribute. In the event that this attribute is not present,
    /// [Origin::INCOMPLETE] will be returned instead.
    pub fn origin(&self) -> Origin {
        self.inner
            .iter()
            .find_map(|x| match &x.value {
                AttributeValue::Origin(x) => Some(*x),
                _ => None,
            })
            .unwrap_or(Origin::INCOMPLETE)
    }

    /// Get the `ORIGINATOR_ID` attribute if present.
    pub fn origin_id(&self) -> Option<BgpIdentifier> {
        self.inner.iter().find_map(|x| match &x.value {
            AttributeValue::OriginatorId(x) => Some(*x),
            _ => None,
        })
    }

    /// Get the `NEXT_HOP` attribute if present.
    ///
    /// **Note**: Even when this attribute is not present, the next hop address may still be
    /// attainable from the `MP_REACH_NLRI` attribute.
    pub fn next_hop(&self) -> Option<IpAddr> {
        self.inner.iter().find_map(|x| match &x.value {
            AttributeValue::NextHop(x) => Some(*x),
            _ => None,
        })
    }

    pub fn multi_exit_discriminator(&self) -> Option<u32> {
        self.inner.iter().find_map(|x| match &x.value {
            AttributeValue::MultiExitDiscriminator(x) => Some(*x),
            _ => None,
        })
    }

    pub fn local_preference(&self) -> Option<u32> {
        self.inner.iter().find_map(|x| match &x.value {
            AttributeValue::LocalPreference(x) => Some(*x),
            _ => None,
        })
    }

    pub fn only_to_customer(&self) -> Option<Asn> {
        self.inner.iter().find_map(|x| match &x.value {
            AttributeValue::OnlyToCustomer(x) => Some(*x),
            _ => None,
        })
    }

    pub fn atomic_aggregate(&self) -> bool {
        self.inner
            .iter()
            .any(|x| matches!(&x.value, AttributeValue::AtomicAggregate))
    }

    pub fn aggregator(&self) -> Option<(Asn, BgpIdentifier)> {
        // Begin searching at the end of the attributes to increase the odds of finding an AS4
        // attribute first.
        self.inner.iter().rev().find_map(|x| match &x.value {
            AttributeValue::Aggregator { asn, id, .. } => Some((*asn, *id)),
            _ => None,
        })
    }

    pub fn clusters(&self) -> Option<&[u32]> {
        self.inner.iter().find_map(|x| match &x.value {
            AttributeValue::Clusters(x) => Some(x.as_ref()),
            _ => None,
        })
    }

    // These implementations are horribly inefficient, but they were super easy to write and use
    pub fn as_path(&self) -> Option<&AsPath> {
        // Begin searching at the end of the attributes to increase the odds of finding an AS4
        // attribute first.
        self.inner.iter().rev().find_map(|x| match &x.value {
            AttributeValue::AsPath { path, .. } => Some(path),
            _ => None,
        })
    }

    pub fn get_reachable_nlri(&self) -> Option<&Nlri> {
        self.inner.iter().find_map(|x| match &x.value {
            AttributeValue::MpReachNlri(x) => Some(x),
            _ => None,
        })
    }

    pub fn get_unreachable_nlri(&self) -> Option<&Nlri> {
        self.inner.iter().find_map(|x| match &x.value {
            AttributeValue::MpUnreachNlri(x) => Some(x),
            _ => None,
        })
    }

    pub fn iter_communities(&self) -> MetaCommunitiesIter<'_> {
        MetaCommunitiesIter {
            attributes: &self.inner,
            index: 0,
        }
    }

    /// Get an iterator over the held [AttributeValue]s. If you also need attribute flags, consider
    /// using [Attributes::into_attributes_iter] instead.
    pub fn iter(&self) -> <&'_ Self as IntoIterator>::IntoIter {
        self.into_iter()
    }

    /// Get an iterator over the held [Attribute]s. If you do no not need attribute flags, consider
    /// using [Attributes::iter] instead.
    pub fn into_attributes_iter(self) -> impl Iterator<Item = Attribute> {
        self.inner.into_iter()
    }
}

pub struct MetaCommunitiesIter<'a> {
    attributes: &'a [Attribute],
    index: usize,
}

impl Iterator for MetaCommunitiesIter<'_> {
    type Item = MetaCommunity;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            match &self.attributes.first()?.value {
                AttributeValue::Communities(x) if self.index < x.len() => {
                    self.index += 1;
                    return Some(MetaCommunity::Plain(x[self.index - 1]));
                }
                AttributeValue::ExtendedCommunities(x) if self.index < x.len() => {
                    self.index += 1;
                    return Some(MetaCommunity::Extended(x[self.index - 1]));
                }
                AttributeValue::LargeCommunities(x) if self.index < x.len() => {
                    self.index += 1;
                    return Some(MetaCommunity::Large(x[self.index - 1]));
                }
                _ => {
                    self.attributes = &self.attributes[1..];
                    self.index = 0;
                }
            }
        }
    }
}

impl FromIterator<Attribute> for Attributes {
    fn from_iter<T: IntoIterator<Item = Attribute>>(iter: T) -> Self {
        Attributes {
            inner: iter.into_iter().collect(),
            validation_warnings: Vec::new(),
        }
    }
}

impl From<Vec<Attribute>> for Attributes {
    fn from(value: Vec<Attribute>) -> Self {
        Attributes {
            inner: value,
            validation_warnings: Vec::new(),
        }
    }
}

impl Extend<Attribute> for Attributes {
    fn extend<T: IntoIterator<Item = Attribute>>(&mut self, iter: T) {
        self.inner.extend(iter)
    }
}

impl Extend<AttributeValue> for Attributes {
    fn extend<T: IntoIterator<Item = AttributeValue>>(&mut self, iter: T) {
        self.extend(iter.into_iter().map(Attribute::from))
    }
}

impl FromIterator<AttributeValue> for Attributes {
    fn from_iter<T: IntoIterator<Item = AttributeValue>>(iter: T) -> Self {
        Attributes {
            inner: iter
                .into_iter()
                .map(|value| Attribute {
                    value,
                    flag: AttrFlags::empty(),
                })
                .collect(),
            validation_warnings: Vec::new(),
        }
    }
}

impl IntoIterator for Attributes {
    type Item = AttributeValue;
    type IntoIter = Map<IntoIter<Attribute>, fn(Attribute) -> AttributeValue>;

    fn into_iter(self) -> Self::IntoIter {
        self.inner.into_iter().map(|x| x.value)
    }
}

impl<'a> IntoIterator for &'a Attributes {
    type Item = &'a AttributeValue;
    type IntoIter = Map<Iter<'a, Attribute>, fn(&Attribute) -> &AttributeValue>;

    fn into_iter(self) -> Self::IntoIter {
        self.inner.iter().map(|x| &x.value)
    }
}

#[cfg(feature = "serde")]
mod serde_impl {
    use super::*;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    impl Serialize for Attributes {
        fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: Serializer,
        {
            self.inner.serialize(serializer)
        }
    }

    impl<'de> Deserialize<'de> for Attributes {
        fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
        where
            D: Deserializer<'de>,
        {
            Ok(Attributes {
                inner: <Vec<Attribute>>::deserialize(deserializer)?,
                validation_warnings: Vec::new(),
            })
        }
    }
}

/// BGP Attribute struct with attribute value and flag
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Attribute {
    pub value: AttributeValue,
    pub flag: AttrFlags,
}

impl Attribute {
    pub const fn is_optional(&self) -> bool {
        self.flag.contains(AttrFlags::OPTIONAL)
    }

    pub const fn is_transitive(&self) -> bool {
        self.flag.contains(AttrFlags::TRANSITIVE)
    }

    pub const fn is_partial(&self) -> bool {
        self.flag.contains(AttrFlags::PARTIAL)
    }

    pub const fn is_extended(&self) -> bool {
        self.flag.contains(AttrFlags::EXTENDED)
    }
}

impl From<AttributeValue> for Attribute {
    fn from(value: AttributeValue) -> Self {
        Attribute {
            flag: value.default_flags(),
            value,
        }
    }
}

/// The `AttributeValue` enum represents different kinds of Attribute values.
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum AttributeValue {
    Origin(Origin),
    AsPath {
        path: AsPath,
        is_as4: bool,
    },
    NextHop(IpAddr),
    MultiExitDiscriminator(u32),
    LocalPreference(u32),
    OnlyToCustomer(Asn),
    AtomicAggregate,
    Aggregator {
        asn: Asn,
        id: BgpIdentifier,
        is_as4: bool,
    },
    Communities(Vec<Community>),
    ExtendedCommunities(Vec<ExtendedCommunity>),
    Ipv6AddressSpecificExtendedCommunities(Vec<Ipv6AddrExtCommunity>),
    LargeCommunities(Vec<LargeCommunity>),
    OriginatorId(BgpIdentifier),
    Clusters(Vec<u32>),
    MpReachNlri(Nlri),
    MpUnreachNlri(Nlri),
    /// BGP Link-State attribute - RFC 7752
    LinkState(crate::models::bgp::linkstate::LinkStateAttribute),
    /// BGP Tunnel Encapsulation attribute - RFC 9012
    TunnelEncapsulation(crate::models::bgp::tunnel_encap::TunnelEncapAttribute),
    Development(Vec<u8>),
    Deprecated(AttrRaw),
    Unknown(AttrRaw),
}

impl From<Origin> for AttributeValue {
    fn from(value: Origin) -> Self {
        AttributeValue::Origin(value)
    }
}

/// Defaults to using `AS_PATH` (as opposed to `AS4_PATH`) when choosing attribute type.
impl From<AsPath> for AttributeValue {
    fn from(path: AsPath) -> Self {
        AttributeValue::AsPath {
            path,
            is_as4: false,
        }
    }
}

/// Category of an attribute.
///
/// <https://datatracker.ietf.org/doc/html/rfc4271#section-5>
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum AttributeCategory {
    WellKnownMandatory,
    WellKnownDiscretionary,
    OptionalTransitive,
    OptionalNonTransitive,
}

impl AttributeValue {
    pub const fn attr_type(&self) -> AttrType {
        match self {
            AttributeValue::Origin(_) => AttrType::ORIGIN,
            AttributeValue::AsPath { is_as4: false, .. } => AttrType::AS_PATH,
            AttributeValue::AsPath { is_as4: true, .. } => AttrType::AS4_PATH,
            AttributeValue::NextHop(_) => AttrType::NEXT_HOP,
            AttributeValue::MultiExitDiscriminator(_) => AttrType::MULTI_EXIT_DISCRIMINATOR,
            AttributeValue::LocalPreference(_) => AttrType::LOCAL_PREFERENCE,
            AttributeValue::OnlyToCustomer(_) => AttrType::ONLY_TO_CUSTOMER,
            AttributeValue::AtomicAggregate => AttrType::ATOMIC_AGGREGATE,
            AttributeValue::Aggregator { is_as4: false, .. } => AttrType::AGGREGATOR,
            AttributeValue::Aggregator { is_as4: true, .. } => AttrType::AS4_AGGREGATOR,
            AttributeValue::Communities(_) => AttrType::COMMUNITIES,
            AttributeValue::ExtendedCommunities(_) => AttrType::EXTENDED_COMMUNITIES,
            AttributeValue::Ipv6AddressSpecificExtendedCommunities(_) => {
                AttrType::IPV6_ADDRESS_SPECIFIC_EXTENDED_COMMUNITIES
            }
            AttributeValue::LargeCommunities(_) => AttrType::LARGE_COMMUNITIES,
            AttributeValue::OriginatorId(_) => AttrType::ORIGINATOR_ID,
            AttributeValue::Clusters(_) => AttrType::CLUSTER_LIST,
            AttributeValue::MpReachNlri(_) => AttrType::MP_REACHABLE_NLRI,
            AttributeValue::MpUnreachNlri(_) => AttrType::MP_UNREACHABLE_NLRI,
            AttributeValue::LinkState(_) => AttrType::BGP_LS_ATTRIBUTE,
            AttributeValue::TunnelEncapsulation(_) => AttrType::TUNNEL_ENCAPSULATION,
            AttributeValue::Development(_) => AttrType::DEVELOPMENT,
            AttributeValue::Deprecated(x) | AttributeValue::Unknown(x) => x.attr_type,
        }
    }

    pub fn attr_category(&self) -> Option<AttributeCategory> {
        use AttributeCategory::*;

        match self {
            AttributeValue::Origin(_) => Some(WellKnownMandatory),
            AttributeValue::AsPath { is_as4: false, .. } => Some(WellKnownMandatory),
            AttributeValue::AsPath { is_as4: true, .. } => Some(OptionalTransitive),
            AttributeValue::NextHop(_) => Some(WellKnownMandatory),
            AttributeValue::MultiExitDiscriminator(_) => Some(OptionalNonTransitive),
            // If we receive this attribute we must be in IBGP so it is required
            AttributeValue::LocalPreference(_) => Some(WellKnownMandatory),
            AttributeValue::OnlyToCustomer(_) => Some(OptionalTransitive),
            AttributeValue::AtomicAggregate => Some(WellKnownDiscretionary),
            AttributeValue::Aggregator { .. } => Some(OptionalTransitive),
            AttributeValue::Communities(_) => Some(OptionalTransitive),
            AttributeValue::ExtendedCommunities(_) => Some(OptionalTransitive),
            AttributeValue::LargeCommunities(_) => Some(OptionalTransitive),
            AttributeValue::OriginatorId(_) => Some(OptionalNonTransitive),
            AttributeValue::Clusters(_) => Some(OptionalNonTransitive),
            AttributeValue::MpReachNlri(_) => Some(OptionalNonTransitive),
            AttributeValue::MpUnreachNlri(_) => Some(OptionalNonTransitive),
            AttributeValue::LinkState(_) => Some(OptionalNonTransitive),
            _ => None,
        }
    }

    /// Get flags based on the attribute type. The [AttrFlags::EXTENDED] is not taken into account
    /// when determining the correct flags.
    pub fn default_flags(&self) -> AttrFlags {
        match self.attr_category() {
            None => AttrFlags::OPTIONAL | AttrFlags::PARTIAL | AttrFlags::TRANSITIVE,
            Some(AttributeCategory::WellKnownMandatory) => AttrFlags::TRANSITIVE,
            Some(AttributeCategory::WellKnownDiscretionary) => AttrFlags::TRANSITIVE,
            Some(AttributeCategory::OptionalTransitive) => {
                AttrFlags::OPTIONAL | AttrFlags::TRANSITIVE
            }
            Some(AttributeCategory::OptionalNonTransitive) => AttrFlags::OPTIONAL,
        }
    }
}

#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct AttrRaw {
    pub attr_type: AttrType,
    pub bytes: Vec<u8>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;
    use std::str::FromStr;

    #[test]
    fn test_attr_type() {
        let attr_value = AttributeValue::Origin(Origin::IGP);
        assert_eq!(attr_value.attr_type(), AttrType::ORIGIN);
    }

    #[test]
    fn test_attr_category() {
        let attr_value = AttributeValue::Origin(Origin::IGP);
        let category = attr_value.attr_category().unwrap();
        assert_eq!(category, AttributeCategory::WellKnownMandatory);
    }

    #[test]
    fn test_default_flags() {
        let attr_value = AttributeValue::Origin(Origin::IGP);
        let flags = attr_value.default_flags();
        assert_eq!(flags, AttrFlags::TRANSITIVE);
    }

    #[test]
    fn test_get_attr() {
        let attribute = Attribute {
            value: AttributeValue::Origin(Origin::IGP),
            flag: AttrFlags::TRANSITIVE,
        };

        let mut attributes = Attributes::default();
        attributes.add_attr(attribute.clone());

        assert_eq!(attributes.get_attr(AttrType::ORIGIN), Some(attribute));
    }

    #[test]
    fn test_has_attr() {
        let attribute = Attribute {
            value: AttributeValue::Origin(Origin::IGP),
            flag: AttrFlags::TRANSITIVE,
        };

        let mut attributes = Attributes::default();
        attributes.add_attr(attribute);

        assert!(attributes.has_attr(AttrType::ORIGIN));
    }

    #[test]
    fn test_getting_all_attributes() {
        let mut attributes = Attributes::default();
        attributes.add_attr(Attribute {
            value: AttributeValue::Origin(Origin::IGP),
            flag: AttrFlags::TRANSITIVE,
        });
        attributes.add_attr(Attribute {
            value: AttributeValue::AsPath {
                path: AsPath::new(),
                is_as4: false,
            },
            flag: AttrFlags::TRANSITIVE,
        });
        attributes.add_attr(Attribute {
            value: AttributeValue::NextHop(IpAddr::from_str("10.0.0.0").unwrap()),
            flag: AttrFlags::TRANSITIVE,
        });
        attributes.add_attr(Attribute {
            value: AttributeValue::MultiExitDiscriminator(1),
            flag: AttrFlags::TRANSITIVE,
        });

        attributes.add_attr(Attribute {
            value: AttributeValue::LocalPreference(1),
            flag: AttrFlags::TRANSITIVE,
        });
        attributes.add_attr(Attribute {
            value: AttributeValue::OnlyToCustomer(Asn::new_32bit(1)),
            flag: AttrFlags::TRANSITIVE,
        });
        attributes.add_attr(Attribute {
            value: AttributeValue::AtomicAggregate,
            flag: AttrFlags::TRANSITIVE,
        });
        attributes.add_attr(Attribute {
            value: AttributeValue::Clusters(vec![1, 2, 3]),
            flag: AttrFlags::TRANSITIVE,
        });
        attributes.add_attr(Attribute {
            value: AttributeValue::Aggregator {
                asn: Asn::new_32bit(1),
                id: Ipv4Addr::from_str("0.0.0.0").unwrap(),
                is_as4: false,
            },
            flag: AttrFlags::TRANSITIVE,
        });
        attributes.add_attr(Attribute {
            value: AttributeValue::OriginatorId(Ipv4Addr::from_str("0.0.0.0").unwrap()),
            flag: AttrFlags::TRANSITIVE,
        });

        assert_eq!(attributes.origin(), Origin::IGP);
        assert_eq!(attributes.as_path(), Some(&AsPath::new()));
        assert_eq!(
            attributes.next_hop(),
            Some(IpAddr::from_str("10.0.0.0").unwrap())
        );
        assert_eq!(attributes.multi_exit_discriminator(), Some(1));
        assert_eq!(attributes.local_preference(), Some(1));
        assert_eq!(attributes.only_to_customer(), Some(Asn::new_32bit(1)));
        assert!(attributes.atomic_aggregate());
        assert_eq!(attributes.clusters(), Some(vec![1_u32, 2, 3].as_slice()));
        assert_eq!(
            attributes.aggregator(),
            Some((Asn::new_32bit(1), Ipv4Addr::from_str("0.0.0.0").unwrap()))
        );
        assert_eq!(
            attributes.origin_id(),
            Some(Ipv4Addr::from_str("0.0.0.0").unwrap())
        );

        let aspath_attr = attributes.get_attr(AttrType::AS_PATH).unwrap();
        assert!(aspath_attr.is_transitive());
        assert!(!aspath_attr.is_extended());
        assert!(!aspath_attr.is_partial());
        assert!(!aspath_attr.is_optional());

        for attr in attributes.iter() {
            println!("{attr:?}");
        }
    }

    #[test]
    fn test_from() {
        let origin = Origin::IGP;
        let attr_value = AttributeValue::from(origin);
        assert_eq!(attr_value, AttributeValue::Origin(Origin::IGP));

        let aspath = AsPath::new();
        let attr_value = AttributeValue::from(aspath);
        assert_eq!(
            attr_value,
            AttributeValue::AsPath {
                path: AsPath::new(),
                is_as4: false
            }
        );
    }

    #[test]
    fn test_well_known_mandatory_attrs() {
        let origin_attr = AttributeValue::Origin(Origin::IGP);
        assert_eq!(
            origin_attr.attr_category(),
            Some(AttributeCategory::WellKnownMandatory)
        );
        let as_path_attr = AttributeValue::AsPath {
            path: AsPath::new(),
            is_as4: false,
        };
        assert_eq!(
            as_path_attr.attr_category(),
            Some(AttributeCategory::WellKnownMandatory)
        );
        let next_hop_attr = AttributeValue::NextHop(IpAddr::from_str("10.0.0.0").unwrap());
        assert_eq!(
            next_hop_attr.attr_category(),
            Some(AttributeCategory::WellKnownMandatory)
        );
        let local_preference_attr = AttributeValue::LocalPreference(1);
        assert_eq!(
            local_preference_attr.attr_category(),
            Some(AttributeCategory::WellKnownMandatory)
        );
    }

    #[test]
    fn test_well_known_discretionary_attrs() {
        let atomic_aggregate_attr = AttributeValue::AtomicAggregate;
        assert_eq!(
            atomic_aggregate_attr.attr_category(),
            Some(AttributeCategory::WellKnownDiscretionary)
        );
    }

    #[test]
    fn test_optional_transitive_attrs() {
        let as_path_attr = AttributeValue::AsPath {
            path: AsPath::new(),
            is_as4: true,
        };
        assert_eq!(
            as_path_attr.attr_category(),
            Some(AttributeCategory::OptionalTransitive)
        );
        let aggregator_attr = AttributeValue::Aggregator {
            asn: Asn::new_32bit(1),
            id: Ipv4Addr::from_str("0.0.0.0").unwrap(),
            is_as4: false,
        };
        assert_eq!(
            aggregator_attr.attr_category(),
            Some(AttributeCategory::OptionalTransitive)
        );
        let only_to_customer_attr = AttributeValue::OnlyToCustomer(Asn::new_32bit(1));
        assert_eq!(
            only_to_customer_attr.attr_category(),
            Some(AttributeCategory::OptionalTransitive)
        );
        let communities_attr =
            AttributeValue::Communities(vec![Community::Custom(Asn::new_32bit(1), 1)]);
        assert_eq!(
            communities_attr.attr_category(),
            Some(AttributeCategory::OptionalTransitive)
        );
        let extended_communities_attr =
            AttributeValue::ExtendedCommunities(vec![ExtendedCommunity::Raw([0; 8])]);
        assert_eq!(
            extended_communities_attr.attr_category(),
            Some(AttributeCategory::OptionalTransitive)
        );
        let large_communities_attr =
            AttributeValue::LargeCommunities(vec![LargeCommunity::new(1, [1, 1])]);
        assert_eq!(
            large_communities_attr.attr_category(),
            Some(AttributeCategory::OptionalTransitive)
        );
        let aggregator_attr = AttributeValue::Aggregator {
            asn: Asn::new_32bit(1),
            id: Ipv4Addr::from_str("0.0.0.0").unwrap(),
            is_as4: true,
        };
        assert_eq!(
            aggregator_attr.attr_category(),
            Some(AttributeCategory::OptionalTransitive)
        );
    }

    #[test]
    fn test_optional_non_transitive_attrs() {
        let multi_exit_discriminator_attr = AttributeValue::MultiExitDiscriminator(1);
        assert_eq!(
            multi_exit_discriminator_attr.attr_category(),
            Some(AttributeCategory::OptionalNonTransitive)
        );
        let originator_id_attr =
            AttributeValue::OriginatorId(Ipv4Addr::from_str("0.0.0.0").unwrap());
        assert_eq!(
            originator_id_attr.attr_category(),
            Some(AttributeCategory::OptionalNonTransitive)
        );
        let clusters_attr = AttributeValue::Clusters(vec![1, 2, 3]);
        assert_eq!(
            clusters_attr.attr_category(),
            Some(AttributeCategory::OptionalNonTransitive)
        );
        let mp_unreach_nlri_attr = AttributeValue::MpReachNlri(Nlri::new_unreachable(
            NetworkPrefix::from_str("10.0.0.0/24").unwrap(),
        ));
        assert_eq!(
            mp_unreach_nlri_attr.attr_category(),
            Some(AttributeCategory::OptionalNonTransitive)
        );

        let mp_reach_nlri_attr = AttributeValue::MpUnreachNlri(Nlri::new_unreachable(
            NetworkPrefix::from_str("10.0.0.0/24").unwrap(),
        ));
        assert_eq!(
            mp_reach_nlri_attr.attr_category(),
            Some(AttributeCategory::OptionalNonTransitive)
        );
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serde() {
        let attributes = Attributes::from_iter(vec![
            Attribute {
                value: AttributeValue::Origin(Origin::IGP),
                flag: AttrFlags::TRANSITIVE,
            },
            Attribute {
                value: AttributeValue::AsPath {
                    path: AsPath::new(),
                    is_as4: false,
                },
                flag: AttrFlags::TRANSITIVE,
            },
        ]);

        let serialized = serde_json::to_string(&attributes).unwrap();
        let deserialized: Attributes = serde_json::from_str(&serialized).unwrap();

        assert_eq!(attributes, deserialized);
    }
}
