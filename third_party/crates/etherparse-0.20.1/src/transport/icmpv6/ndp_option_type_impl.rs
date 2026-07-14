/// Identifiers for Neighbor Discovery option `Type` values.
///
/// You can access the underlying `u8` value via `.0`, and any `u8` can
/// be converted into an `NdpOptionType`:
///
/// ```
/// use etherparse::icmpv6::NdpOptionType;
///
/// assert_eq!(NdpOptionType::SOURCE_LINK_LAYER_ADDRESS.0, 1);
/// assert_eq!(NdpOptionType::SOURCE_LINK_LAYER_ADDRESS, NdpOptionType(1));
///
/// let option_type: NdpOptionType = 3u8.into();
/// assert_eq!(NdpOptionType::PREFIX_INFORMATION, option_type);
///
/// let raw: u8 = NdpOptionType::MTU.into();
/// assert_eq!(5, raw);
/// ```
#[derive(PartialEq, Eq, Clone, Copy, Hash, Ord, PartialOrd)]
pub struct NdpOptionType(pub u8);

impl NdpOptionType {
    /// Source Link-Layer Address option \[[RFC4861](https://datatracker.ietf.org/doc/html/rfc4861#section-4.6.1)\].
    pub const SOURCE_LINK_LAYER_ADDRESS: Self = Self(1);
    /// Target Link-Layer Address option \[[RFC4861](https://datatracker.ietf.org/doc/html/rfc4861#section-4.6.1)\].
    pub const TARGET_LINK_LAYER_ADDRESS: Self = Self(2);
    /// Prefix Information option \[[RFC4861](https://datatracker.ietf.org/doc/html/rfc4861#section-4.6.2)\].
    pub const PREFIX_INFORMATION: Self = Self(3);
    /// Redirected Header option \[[RFC4861](https://datatracker.ietf.org/doc/html/rfc4861#section-4.6.3)\].
    pub const REDIRECTED_HEADER: Self = Self(4);
    /// MTU option \[[RFC4861](https://datatracker.ietf.org/doc/html/rfc4861#section-4.6.4)\].
    pub const MTU: Self = Self(5);

    /// Human-readable name for known option types.
    pub const fn keyword_str(self) -> Option<&'static str> {
        match self.0 {
            1 => Some("Source Link-Layer Address"),
            2 => Some("Target Link-Layer Address"),
            3 => Some("Prefix Information"),
            4 => Some("Redirected Header"),
            5 => Some("MTU"),
            _ => None,
        }
    }
}

impl From<u8> for NdpOptionType {
    #[inline]
    fn from(val: u8) -> Self {
        Self(val)
    }
}

impl From<NdpOptionType> for u8 {
    #[inline]
    fn from(val: NdpOptionType) -> Self {
        val.0
    }
}

impl core::fmt::Debug for NdpOptionType {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        if let Some(keyword) = self.keyword_str() {
            write!(f, "{} ({})", self.0, keyword)
        } else {
            write!(f, "{}", self.0)
        }
    }
}
