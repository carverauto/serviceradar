use crate::icmpv6::NdpOptionType;

mod mtu_option_slice;
pub use mtu_option_slice::*;

mod ndp_option_header;
pub use ndp_option_header::*;

mod prefix_information_option_slice;
pub use prefix_information_option_slice::*;

mod redirected_header_option_slice;
pub use redirected_header_option_slice::*;

mod source_link_layer_address_option_slice;
pub use source_link_layer_address_option_slice::*;

mod target_link_layer_address_option_slice;
pub use target_link_layer_address_option_slice::*;

mod unknown_ndp_option_slice;
pub use unknown_ndp_option_slice::*;

pub mod prefix_information;

/// Length in bytes of the common Neighbor Discovery option header
/// (`Type` + `Length`).
pub(super) const NDP_OPTION_HEADER_LEN: usize = 2;

/// Neighbor Discovery option decoded from an ICMPv6 payload.
#[derive(Clone, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum NdpOptionSlice<'a> {
    /// Source link-layer address option (type 1).
    SourceLinkLayerAddress(SourceLinkLayerAddressOptionSlice<'a>),
    /// Target link-layer address option (type 2).
    TargetLinkLayerAddress(TargetLinkLayerAddressOptionSlice<'a>),
    /// Prefix information option (type 3).
    PrefixInformation(PrefixInformationOptionSlice<'a>),
    /// Redirected header option (type 4).
    RedirectedHeader(RedirectedHeaderOptionSlice<'a>),
    /// MTU option (type 5).
    Mtu(MtuOptionSlice<'a>),
    /// Unknown option type.
    Unknown(UnknownNdpOptionSlice<'a>),
}

impl<'a> NdpOptionSlice<'a> {
    /// Returns the serialized bytes of the option.
    pub fn as_bytes(&self) -> &'a [u8] {
        match self {
            NdpOptionSlice::SourceLinkLayerAddress(value) => value.as_bytes(),
            NdpOptionSlice::TargetLinkLayerAddress(value) => value.as_bytes(),
            NdpOptionSlice::PrefixInformation(value) => value.as_bytes(),
            NdpOptionSlice::RedirectedHeader(value) => value.as_bytes(),
            NdpOptionSlice::Mtu(value) => value.as_bytes(),
            NdpOptionSlice::Unknown(value) => value.as_bytes(),
        }
    }

    /// Returns the option type value.
    pub fn option_type(&self) -> NdpOptionType {
        match self {
            NdpOptionSlice::SourceLinkLayerAddress(value) => value.option_type(),
            NdpOptionSlice::TargetLinkLayerAddress(value) => value.option_type(),
            NdpOptionSlice::PrefixInformation(value) => value.option_type(),
            NdpOptionSlice::RedirectedHeader(value) => value.option_type(),
            NdpOptionSlice::Mtu(value) => value.option_type(),
            NdpOptionSlice::Unknown(value) => value.option_type(),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::icmpv6::{NdpOptionReadError, NdpOptionType, PrefixInformation};
    use alloc::format;

    #[test]
    fn debug() {
        assert_eq!(
            "Mtu(MtuOptionSlice { slice: [5, 1, 0, 0, 0, 0, 5, 220] })",
            format!(
                "{:?}",
                NdpOptionSlice::Mtu(
                    MtuOptionSlice::from_slice(&[5, 1, 0, 0, 0, 0, 5, 220]).unwrap()
                )
            )
        );
    }

    #[test]
    fn option_type_and_as_bytes() {
        let source =
            SourceLinkLayerAddressOptionSlice::from_slice(&[1, 1, 1, 2, 3, 4, 5, 6]).unwrap();
        assert_eq!(
            NdpOptionType::SOURCE_LINK_LAYER_ADDRESS,
            source.option_type()
        );
        assert_eq!(&[1, 1, 1, 2, 3, 4, 5, 6], source.as_bytes());
        assert_eq!(&[1, 2, 3, 4, 5, 6], source.link_layer_address());

        let target =
            TargetLinkLayerAddressOptionSlice::from_slice(&[2, 1, 6, 5, 4, 3, 2, 1]).unwrap();
        assert_eq!(
            NdpOptionType::TARGET_LINK_LAYER_ADDRESS,
            target.option_type()
        );
        assert_eq!(&[2, 1, 6, 5, 4, 3, 2, 1], target.as_bytes());
        assert_eq!(&[6, 5, 4, 3, 2, 1], target.link_layer_address());

        let prefix = PrefixInformation {
            prefix_length: 64,
            on_link: true,
            autonomous_address_configuration: true,
            valid_lifetime: 1,
            preferred_lifetime: 2,
            prefix: [3; 16],
        };
        let prefix_bytes = prefix.to_bytes();
        let prefix_slice = PrefixInformationOptionSlice::from_slice(&prefix_bytes).unwrap();
        assert_eq!(
            NdpOptionType::PREFIX_INFORMATION,
            prefix_slice.option_type()
        );
        assert_eq!(&prefix_bytes, prefix_slice.as_bytes());
        assert_eq!(prefix.prefix_length, prefix_slice.prefix_length());
        assert_eq!(prefix.on_link, prefix_slice.on_link());
        assert_eq!(
            prefix.autonomous_address_configuration,
            prefix_slice.autonomous_address_configuration()
        );
        assert_eq!(prefix.valid_lifetime, prefix_slice.valid_lifetime());
        assert_eq!(prefix.preferred_lifetime, prefix_slice.preferred_lifetime());
        assert_eq!(prefix.prefix, prefix_slice.prefix());
        assert_eq!(prefix, prefix_slice.prefix_information());

        let redirected = RedirectedHeaderOptionSlice::from_slice(&[
            4, 2, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8,
        ])
        .unwrap();
        assert_eq!(NdpOptionType::REDIRECTED_HEADER, redirected.option_type());
        assert_eq!(
            &[4, 2, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8],
            redirected.as_bytes()
        );
        assert_eq!(&[1, 2, 3, 4, 5, 6, 7, 8], redirected.redirected_packet());

        let mtu = MtuOptionSlice::from_slice(&[5, 1, 0, 0, 0, 0, 5, 220]).unwrap();
        assert_eq!(NdpOptionType::MTU, mtu.option_type());
        assert_eq!(&[5, 1, 0, 0, 0, 0, 5, 220], mtu.as_bytes());
        assert_eq!(1500, mtu.mtu());

        let unknown = UnknownNdpOptionSlice::from_slice(&[250, 1, 1, 2, 3, 4, 5, 6]).unwrap();
        assert_eq!(NdpOptionType(250), unknown.option_type());
        assert_eq!(&[250, 1, 1, 2, 3, 4, 5, 6], unknown.as_bytes());
        assert_eq!(&[1, 2, 3, 4, 5, 6], unknown.data());
    }

    #[test]
    fn from_slice_errors() {
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::SOURCE_LINK_LAYER_ADDRESS,
                expected_size: NDP_OPTION_HEADER_LEN,
                actual_size: 1
            }),
            SourceLinkLayerAddressOptionSlice::from_slice(&[1])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::TARGET_LINK_LAYER_ADDRESS,
                expected_size: NDP_OPTION_HEADER_LEN,
                actual_size: 1
            }),
            TargetLinkLayerAddressOptionSlice::from_slice(&[2])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::SOURCE_LINK_LAYER_ADDRESS,
                actual_option_id: NdpOptionType::TARGET_LINK_LAYER_ADDRESS,
                expected_length_units: 1,
                actual_length_units: 1,
            }),
            SourceLinkLayerAddressOptionSlice::from_slice(&[2, 1, 1, 2, 3, 4, 5, 6])
        );
        assert_eq!(
            Err(NdpOptionReadError::ZeroLength {
                option_id: NdpOptionType::SOURCE_LINK_LAYER_ADDRESS
            }),
            SourceLinkLayerAddressOptionSlice::from_slice(&[1, 0])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::SOURCE_LINK_LAYER_ADDRESS,
                expected_size: 16,
                actual_size: 8
            }),
            SourceLinkLayerAddressOptionSlice::from_slice(&[1, 2, 1, 2, 3, 4, 5, 6])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::TARGET_LINK_LAYER_ADDRESS,
                actual_option_id: NdpOptionType::SOURCE_LINK_LAYER_ADDRESS,
                expected_length_units: 1,
                actual_length_units: 1,
            }),
            TargetLinkLayerAddressOptionSlice::from_slice(&[1, 1, 1, 2, 3, 4, 5, 6])
        );
        assert_eq!(
            Err(NdpOptionReadError::ZeroLength {
                option_id: NdpOptionType::TARGET_LINK_LAYER_ADDRESS
            }),
            TargetLinkLayerAddressOptionSlice::from_slice(&[2, 0])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::TARGET_LINK_LAYER_ADDRESS,
                expected_size: 16,
                actual_size: 8
            }),
            TargetLinkLayerAddressOptionSlice::from_slice(&[2, 2, 1, 2, 3, 4, 5, 6])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::PREFIX_INFORMATION,
                expected_size: PrefixInformation::LEN,
                actual_size: PrefixInformation::LEN - 1
            }),
            PrefixInformationOptionSlice::from_slice(&[0u8; PrefixInformation::LEN - 1])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::REDIRECTED_HEADER,
                expected_size: 8,
                actual_size: 7
            }),
            RedirectedHeaderOptionSlice::from_slice(&[0u8; 7])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::REDIRECTED_HEADER,
                actual_option_id: NdpOptionType::MTU,
                expected_length_units: 1,
                actual_length_units: 1,
            }),
            RedirectedHeaderOptionSlice::from_slice(&[5, 1, 0, 0, 0, 0, 0, 0])
        );
        assert_eq!(
            Err(NdpOptionReadError::ZeroLength {
                option_id: NdpOptionType::REDIRECTED_HEADER
            }),
            RedirectedHeaderOptionSlice::from_slice(&[4, 0, 0, 0, 0, 0, 0, 0])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::REDIRECTED_HEADER,
                expected_size: 16,
                actual_size: 8
            }),
            RedirectedHeaderOptionSlice::from_slice(&[4, 2, 0, 0, 0, 0, 0, 0])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::MTU,
                expected_size: 8,
                actual_size: 7
            }),
            MtuOptionSlice::from_slice(&[0u8; 7])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::MTU,
                actual_option_id: NdpOptionType::REDIRECTED_HEADER,
                expected_length_units: 1,
                actual_length_units: 1,
            }),
            MtuOptionSlice::from_slice(&[4, 1, 0, 0, 0, 0, 5, 220])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::MTU,
                actual_option_id: NdpOptionType::MTU,
                expected_length_units: 1,
                actual_length_units: 2,
            }),
            MtuOptionSlice::from_slice(&[5, 2, 0, 0, 0, 0, 5, 220])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType(0),
                expected_size: NDP_OPTION_HEADER_LEN,
                actual_size: 0
            }),
            UnknownNdpOptionSlice::from_slice(&[])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType(250),
                expected_size: NDP_OPTION_HEADER_LEN,
                actual_size: 1
            }),
            UnknownNdpOptionSlice::from_slice(&[250])
        );
        assert_eq!(
            Err(NdpOptionReadError::ZeroLength {
                option_id: NdpOptionType(250)
            }),
            UnknownNdpOptionSlice::from_slice(&[250, 0])
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType(250),
                expected_size: 16,
                actual_size: 8
            }),
            UnknownNdpOptionSlice::from_slice(&[250, 2, 1, 2, 3, 4, 5, 6])
        );
    }
}
