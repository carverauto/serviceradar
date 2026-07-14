use crate::models::*;
use itertools::Itertools;
use std::cmp::Ordering;
use std::fmt::{Display, Formatter};
use std::net::IpAddr;
use std::str::FromStr;

// TODO(jmeggitt): BgpElem can be converted to an enum. Apply this change during performance PR.

/// # ElemType
///
/// `ElemType` is an enumeration that represents the type of an element.
/// It has two possible values:
///
/// - `ANNOUNCE`: Indicates an announcement/reachable prefix.
/// - `WITHDRAW`: Indicates a withdrawn/unreachable prefix.
///
/// The enumeration derives the traits `Debug`, `Clone`, `Copy`, `PartialEq`, `Eq`, and `Hash`.
///
/// It also has the following attributes:
///
/// - `#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]`
///     - This attribute is conditionally applied when the `"serde"` feature is enabled. It allows
///       the enumeration to be serialized and deserialized using serde.
/// - `#[cfg_attr(feature = "serde", serde(rename = "lowercase"))]`
///     - This attribute is conditionally applied when the `"serde"` feature is enabled. It specifies
///       that the serialized form of the enumeration should be in lowercase.
///
/// Example usage:
///
/// ```
/// use bgpkit_parser::models::ElemType;
///
/// let announce_type = ElemType::ANNOUNCE;
/// let withdraw_type = ElemType::WITHDRAW;
///
/// assert_eq!(announce_type, ElemType::ANNOUNCE);
/// assert_eq!(withdraw_type, ElemType::WITHDRAW);
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename = "lowercase"))]
pub enum ElemType {
    ANNOUNCE,
    WITHDRAW,
}

impl ElemType {
    /// Checks if the `ElemType` is an announce.
    ///
    /// Returns `true` if `ElemType` is `ANNOUNCE`, and `false` if it is `WITHDRAW`.
    ///
    /// # Examples
    ///
    /// ```
    /// use bgpkit_parser::models::ElemType;
    ///
    /// let elem = ElemType::ANNOUNCE;
    /// assert_eq!(elem.is_announce(), true);
    ///
    /// let elem = ElemType::WITHDRAW;
    /// assert_eq!(elem.is_announce(), false);
    /// ```
    pub fn is_announce(&self) -> bool {
        match self {
            ElemType::ANNOUNCE => true,
            ElemType::WITHDRAW => false,
        }
    }
}

/// BgpElem represents a per-prefix BGP element.
///
/// This struct contains information about an announced/withdrawn prefix.
///
/// Fields:
/// - `timestamp`: The time when the BGP element was received.
/// - `elem_type`: The type of BGP element.
/// - `peer_ip`: The IP address of the BGP peer.
/// - `peer_asn`: The ASN of the BGP peer.
/// - `prefix`: The network prefix.
/// - `next_hop`: The next hop IP address.
/// - `as_path`: The AS path.
/// - `origin_asns`: The list of origin ASNs.
/// - `origin`: The origin attribute, i.e. IGP, EGP, or INCOMPLETE.
/// - `local_pref`: The local preference value.
/// - `med`: The multi-exit discriminator value.
/// - `communities`: The list of BGP communities.
/// - `atomic`: Flag indicating if the announcement is atomic.
/// - `aggr_asn`: The aggregated ASN.
/// - `aggr_ip`: The aggregated IP address.
/// - `only_to_customer`: The AS number to which the prefix is only announced.
/// - `unknown`: Unknown attributes formatted as (TYPE, RAW_BYTES).
/// - `deprecated`: Deprecated attributes formatted as (TYPE, RAW_BYTES).
///
/// Note: Constructing BGP elements consumes more memory due to duplicate information
/// shared between multiple elements of one MRT record.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BgpElem {
    /// The timestamp of the item in floating-point format.
    pub timestamp: f64,
    /// The element type of an item.
    #[cfg_attr(feature = "serde", serde(rename = "type"))]
    pub elem_type: ElemType,
    /// The IP address of the peer associated with the item.
    pub peer_ip: IpAddr,
    /// The peer ASN (Autonomous System Number) of the item.
    pub peer_asn: Asn,
    /// The network prefix of the item.
    pub prefix: NetworkPrefix,
    /// The next hop IP address for the item, if available.
    pub next_hop: Option<IpAddr>,
    /// The optional path representation of the item.
    ///
    /// This field is of type `Option<AsPath>`, which means it can either contain
    /// a value of type `AsPath` or be `None`.
    pub as_path: Option<AsPath>,
    /// The origin ASNs associated with the prefix, if available.
    ///
    /// # Remarks
    /// An `Option` type is used to indicate that the `origin_asns` field may or may not have a value.
    /// If it has a value, it will be a `Vec` (vector) of `Asn` objects representing the ASNs.
    /// If it does not have a value, it will be `None`.
    pub origin_asns: Option<Vec<Asn>>,
    /// The origin of the item (IGP, EGP, INCOMPLETE), if known. Can be `None` if the origin is not available.
    pub origin: Option<Origin>,
    /// The local preference of the item, if available, represented as an option of unsigned 32-bit integer.
    pub local_pref: Option<u32>,
    /// The number of medical items in an option format.
    pub med: Option<u32>,
    /// A vector of optional `MetaCommunity` values.
    ///
    /// # Remarks
    /// `MetaCommunity` represents a community metadata.
    /// The `Option` type indicates that the vector can be empty or contain [MetaCommunity] values.
    /// When the `Option` is `Some`, it means the vector is not empty and contains [MetaCommunity] values.
    /// When the `Option` is `None`, it means the vector is empty.
    pub communities: Option<Vec<MetaCommunity>>,
    /// Indicates whether the item is atomic aggreagte or not.
    pub atomic: bool,
    /// The aggregated ASN of the item, represented as an optional [Asn] type.
    pub aggr_asn: Option<Asn>,
    /// The aggregated IP address of the item, represented as an optional [BgpIdentifier], i.e. `Ipv4Addr`.
    pub aggr_ip: Option<BgpIdentifier>,
    pub only_to_customer: Option<Asn>,
    /// unknown attributes formatted as (TYPE, RAW_BYTES)
    pub unknown: Option<Vec<AttrRaw>>,
    /// deprecated attributes formatted as (TYPE, RAW_BYTES)
    pub deprecated: Option<Vec<AttrRaw>>,
}

impl Eq for BgpElem {}

impl PartialOrd<Self> for BgpElem {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for BgpElem {
    fn cmp(&self, other: &Self) -> Ordering {
        self.timestamp
            .partial_cmp(&other.timestamp)
            .unwrap()
            .then_with(|| self.peer_ip.cmp(&other.peer_ip))
    }
}

impl Default for BgpElem {
    fn default() -> Self {
        BgpElem {
            timestamp: 0.0,
            elem_type: ElemType::ANNOUNCE,
            peer_ip: IpAddr::from_str("0.0.0.0").unwrap(),
            peer_asn: 0.into(),
            prefix: NetworkPrefix::from_str("0.0.0.0/0").unwrap(),
            next_hop: Some(IpAddr::from_str("0.0.0.0").unwrap()),
            as_path: None,
            origin_asns: None,
            origin: None,
            local_pref: None,
            med: None,
            communities: None,
            atomic: false,
            aggr_asn: None,
            aggr_ip: None,
            only_to_customer: None,
            unknown: None,
            deprecated: None,
        }
    }
}

/// `OptionToStr` is a helper struct that wraps an `Option` and provides a convenient
/// way to convert its value to a string representation.
///
/// # Generic Parameters
///
/// - `'a`: The lifetime parameter that represents the lifetime of the wrapped `Option` value.
///
/// # Fields
///
/// - `0: &'a Option<T>`: The reference to the wrapped `Option` value.
struct OptionToStr<'a, T>(&'a Option<T>);

impl<T: Display> Display for OptionToStr<'_, T> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self.0 {
            None => Ok(()),
            Some(x) => write!(f, "{x}"),
        }
    }
}

/// Helper struct to convert Option<Vec<T>> to Vec<String>
///
/// This struct provides a convenient way to convert an `Option<Vec<T>>` into a `Vec<String>`.
/// It is used for converting the `Option<Vec<MetaCommunity>>` and `Option<Vec<AttrRaw>>` fields
/// of the `BgpElem` struct into a printable format.
struct OptionToStrVec<'a, T>(&'a Option<Vec<T>>);

impl<T: Display> Display for OptionToStrVec<'_, T> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self.0 {
            None => Ok(()),
            Some(v) => write!(
                f,
                "{}",
                v.iter()
                    .map(|e| e.to_string())
                    .collect::<Vec<String>>()
                    .join(" ")
            ),
        }
    }
}

#[inline(always)]
pub fn option_to_string_communities(o: &Option<Vec<MetaCommunity>>) -> String {
    if let Some(v) = o {
        v.iter().join(" ")
    } else {
        String::new()
    }
}

impl Display for BgpElem {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let t = match self.elem_type {
            ElemType::ANNOUNCE => "A",
            ElemType::WITHDRAW => "W",
        };
        write!(
            f,
            "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
            t,
            &self.timestamp,
            &self.peer_ip,
            &self.peer_asn,
            &self.prefix,
            OptionToStr(&self.as_path),
            OptionToStr(&self.origin),
            OptionToStr(&self.next_hop),
            OptionToStr(&self.local_pref),
            OptionToStr(&self.med),
            option_to_string_communities(&self.communities),
            self.atomic,
            OptionToStr(&self.aggr_asn),
            OptionToStr(&self.aggr_ip),
        )
    }
}

impl BgpElem {
    /// Returns true if the element is an announcement.
    ///
    /// Most of the time, users do not really need to get the type out, only needs to know if it is
    /// an announcement or a withdrawal.
    pub fn is_announcement(&self) -> bool {
        self.elem_type == ElemType::ANNOUNCE
    }

    /// Returns the origin AS number as u32. Returns None if the origin AS number is not present or
    /// it's a AS set.
    pub fn get_origin_asn_opt(&self) -> Option<u32> {
        let origin_asns = self.origin_asns.as_ref()?;
        (origin_asns.len() == 1).then(|| origin_asns[0].into())
    }

    /// Returns the PSV header as a string.
    ///
    /// The PSV header is a pipe-separated string that represents the fields
    /// present in PSV (Prefix Statement Format) records. PSV records are used
    /// to describe BGP (Border Gateway Protocol) routing information.
    ///
    /// # Example
    ///
    /// ```
    /// use bgpkit_parser::BgpElem;
    ///
    /// let header = BgpElem::get_psv_header();
    /// assert_eq!(header, "type|timestamp|peer_ip|peer_asn|prefix|as_path|origin_asns|origin|next_hop|local_pref|med|communities|atomic|aggr_asn|aggr_ip|only_to_customer");
    /// ```
    pub fn get_psv_header() -> String {
        let fields = [
            "type",
            "timestamp",
            "peer_ip",
            "peer_asn",
            "prefix",
            "as_path",
            "origin_asns",
            "origin",
            "next_hop",
            "local_pref",
            "med",
            "communities",
            "atomic",
            "aggr_asn",
            "aggr_ip",
            "only_to_customer",
        ];
        fields.join("|")
    }

    /// Converts the struct fields into a pipe-separated values (PSV) formatted string.
    ///
    /// # Returns
    ///
    /// Returns a `String` representing the struct fields in PSV format.
    ///
    /// # Example
    ///
    /// ```
    /// use crate::bgpkit_parser::BgpElem;
    ///
    /// let psv_string = BgpElem::default().to_psv();
    ///
    /// println!("{}", psv_string);
    /// ```
    pub fn to_psv(&self) -> String {
        let t = match self.elem_type {
            ElemType::ANNOUNCE => "A",
            ElemType::WITHDRAW => "W",
        };
        format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
            t,
            &self.timestamp,
            &self.peer_ip,
            &self.peer_asn,
            &self.prefix,
            OptionToStr(&self.as_path),
            OptionToStrVec(&self.origin_asns),
            OptionToStr(&self.origin),
            OptionToStr(&self.next_hop),
            OptionToStr(&self.local_pref),
            OptionToStr(&self.med),
            option_to_string_communities(&self.communities),
            self.atomic,
            OptionToStr(&self.aggr_asn),
            OptionToStr(&self.aggr_ip),
            OptionToStr(&self.only_to_customer),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::default::Default;
    use std::str::FromStr;

    #[test]
    #[cfg(feature = "serde")]
    fn test_default() {
        let elem = BgpElem {
            timestamp: 0.0,
            elem_type: ElemType::ANNOUNCE,
            peer_ip: IpAddr::from_str("192.168.1.1").unwrap(),
            peer_asn: 0.into(),
            prefix: NetworkPrefix::from_str("8.8.8.0/24").unwrap(),
            ..Default::default()
        };
        println!("{}", serde_json::json!(elem));
    }

    #[test]
    fn test_sorting() {
        let elem1 = BgpElem {
            timestamp: 1.1,
            elem_type: ElemType::ANNOUNCE,
            peer_ip: IpAddr::from_str("192.168.1.1").unwrap(),
            peer_asn: 0.into(),
            prefix: NetworkPrefix::from_str("8.8.8.0/24").unwrap(),
            ..Default::default()
        };
        let elem2 = BgpElem {
            timestamp: 1.2,
            elem_type: ElemType::ANNOUNCE,
            peer_ip: IpAddr::from_str("192.168.1.1").unwrap(),
            peer_asn: 0.into(),
            prefix: NetworkPrefix::from_str("8.8.8.0/24").unwrap(),
            ..Default::default()
        };
        let elem3 = BgpElem {
            timestamp: 1.2,
            elem_type: ElemType::ANNOUNCE,
            peer_ip: IpAddr::from_str("192.168.1.2").unwrap(),
            peer_asn: 0.into(),
            prefix: NetworkPrefix::from_str("8.8.8.0/24").unwrap(),
            ..Default::default()
        };

        assert!(elem1 < elem2);
        assert!(elem2 < elem3);
    }

    #[test]
    fn test_psv() {
        assert_eq!(
            BgpElem::get_psv_header().as_str(),
            "type|timestamp|peer_ip|peer_asn|prefix|as_path|origin_asns|origin|next_hop|local_pref|med|communities|atomic|aggr_asn|aggr_ip|only_to_customer"
        );
        let elem = BgpElem::default();
        assert_eq!(
            elem.to_psv().as_str(),
            "A|0|0.0.0.0|0|0.0.0.0/0||||0.0.0.0||||false|||"
        );
    }

    #[test]
    fn test_option_to_str() {
        let asn_opt: Option<u32> = Some(12);
        assert_eq!(OptionToStr(&asn_opt).to_string(), "12");
        let none_opt: Option<u32> = None;
        assert_eq!(OptionToStr(&none_opt).to_string(), "");
        let asns_opt = Some(vec![12, 34]);
        assert_eq!(OptionToStrVec(&asns_opt).to_string(), "12 34");
        assert_eq!(OptionToStrVec(&None::<Vec<u32>>).to_string(), "");
    }
}
