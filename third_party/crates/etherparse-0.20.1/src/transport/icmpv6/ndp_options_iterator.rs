use crate::icmpv6::{
    MtuOptionSlice, NdpOptionHeader, NdpOptionReadError, NdpOptionSlice, NdpOptionType,
    PrefixInformationOptionSlice, RedirectedHeaderOptionSlice, SourceLinkLayerAddressOptionSlice,
    TargetLinkLayerAddressOptionSlice, UnknownNdpOptionSlice,
};

/// Allows iterating over Neighbor Discovery options in an ICMPv6 payload.
#[derive(Clone, Eq, PartialEq)]
pub struct NdpOptionsIterator<'a> {
    pub(crate) options: &'a [u8],
}

impl<'a> NdpOptionsIterator<'a> {
    /// Creates an iterator over Neighbor Discovery options in serialized form.
    pub fn from_slice(options: &'a [u8]) -> NdpOptionsIterator<'a> {
        NdpOptionsIterator { options }
    }

    /// Returns the bytes not yet processed by the iterator.
    pub fn rest(&self) -> &'a [u8] {
        self.options
    }

    fn parse_next_option(&mut self) -> Result<NdpOptionSlice<'a>, NdpOptionReadError> {
        use NdpOptionReadError::*;

        let (header, _) = NdpOptionHeader::from_slice(self.options)?;
        let option_id = header.option_type;
        let length_units = header.length_units;
        if 0 == length_units {
            return Err(ZeroLength { option_id });
        }

        let option_len = header.byte_len();
        let (option, rest) =
            self.options
                .split_at_checked(option_len)
                .ok_or(UnexpectedEndOfSlice {
                    option_id,
                    expected_size: option_len,
                    actual_size: self.options.len(),
                })?;

        let parsed = match option_id {
            NdpOptionType::SOURCE_LINK_LAYER_ADDRESS => {
                SourceLinkLayerAddressOptionSlice::from_slice(option)
                    .map(NdpOptionSlice::SourceLinkLayerAddress)
            }
            NdpOptionType::TARGET_LINK_LAYER_ADDRESS => {
                TargetLinkLayerAddressOptionSlice::from_slice(option)
                    .map(NdpOptionSlice::TargetLinkLayerAddress)
            }
            NdpOptionType::PREFIX_INFORMATION => PrefixInformationOptionSlice::from_slice(option)
                .map(NdpOptionSlice::PrefixInformation),
            NdpOptionType::REDIRECTED_HEADER => RedirectedHeaderOptionSlice::from_slice(option)
                .map(NdpOptionSlice::RedirectedHeader),
            NdpOptionType::MTU => MtuOptionSlice::from_slice(option).map(NdpOptionSlice::Mtu),
            _ => UnknownNdpOptionSlice::from_slice(option).map(NdpOptionSlice::Unknown),
        }?;

        self.options = rest;

        Ok(parsed)
    }
}

impl<'a> Iterator for NdpOptionsIterator<'a> {
    type Item = Result<NdpOptionSlice<'a>, NdpOptionReadError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.options.is_empty() {
            return None;
        }

        let parse_result = self.parse_next_option();

        if parse_result.is_err() {
            // We don't try to parse any more options after encountering an invalid option.
            self.options = &[];
        }
        Some(parse_result)
    }
}

impl core::fmt::Debug for NdpOptionsIterator<'_> {
    fn fmt(&self, fmt: &mut core::fmt::Formatter) -> Result<(), core::fmt::Error> {
        let mut list = fmt.debug_list();
        for item in self.clone() {
            match item {
                Ok(value) => {
                    list.entry(&value);
                }
                Err(err) => {
                    list.entry(&Result::<(), NdpOptionReadError>::Err(err.clone()));
                }
            }
        }
        list.finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::icmpv6::PrefixInformation;

    #[test]
    fn from_slice_and_rest() {
        let buffer = [1, 1, 1, 2, 3, 4, 5, 6];
        let iterator = NdpOptionsIterator::from_slice(&buffer);
        assert_eq!(iterator.rest(), &buffer[..]);
    }

    #[test]
    fn next() {
        let source_link_layer_address = [1, 1, 1, 2, 3, 4, 5, 6];
        let target_link_layer_address = [2, 1, 1, 2, 3, 4, 5, 6];
        let redirected_header = [4, 1, 0, 0, 0, 0, 0, 0];
        let mtu = [5, 1, 0, 0, 0, 0, 5, 220];
        let unknown = [250, 1, 1, 2, 3, 4, 5, 6];

        let prefix = PrefixInformation {
            prefix_length: 64,
            on_link: true,
            autonomous_address_configuration: true,
            valid_lifetime: 1,
            preferred_lifetime: 2,
            prefix: [3; 16],
        };
        let prefix_bytes = prefix.to_bytes();

        let mut options = alloc::vec::Vec::new();
        options.extend(source_link_layer_address);
        options.extend(target_link_layer_address);
        options.extend(redirected_header);
        options.extend(mtu);
        options.extend(unknown);
        options.extend(prefix_bytes);

        let mut iter = NdpOptionsIterator::from_slice(&options);
        assert_eq!(
            Some(Ok(NdpOptionSlice::SourceLinkLayerAddress(
                SourceLinkLayerAddressOptionSlice::from_slice(&source_link_layer_address).unwrap()
            ))),
            iter.next()
        );
        assert_eq!(
            Some(Ok(NdpOptionSlice::TargetLinkLayerAddress(
                TargetLinkLayerAddressOptionSlice::from_slice(&target_link_layer_address).unwrap()
            ))),
            iter.next()
        );
        assert_eq!(
            Some(Ok(NdpOptionSlice::RedirectedHeader(
                RedirectedHeaderOptionSlice::from_slice(&redirected_header).unwrap()
            ))),
            iter.next()
        );
        assert_eq!(
            Some(Ok(NdpOptionSlice::Mtu(
                MtuOptionSlice::from_slice(&mtu).unwrap()
            ))),
            iter.next()
        );
        assert_eq!(
            Some(Ok(NdpOptionSlice::Unknown(
                UnknownNdpOptionSlice::from_slice(&unknown).unwrap()
            ))),
            iter.next()
        );
        assert_eq!(
            Some(Ok(NdpOptionSlice::PrefixInformation(
                PrefixInformationOptionSlice::from_slice(&prefix_bytes).unwrap()
            ))),
            iter.next()
        );
        assert_eq!(None, iter.next());
        assert_eq!(0, iter.rest().len());
    }

    #[test]
    fn next_errors() {
        assert_eq!(
            Some(Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::SOURCE_LINK_LAYER_ADDRESS,
                expected_size: NdpOptionHeader::LEN,
                actual_size: 1,
            })),
            NdpOptionsIterator::from_slice(&[1]).next()
        );
        assert_eq!(
            Some(Err(NdpOptionReadError::ZeroLength {
                option_id: NdpOptionType::SOURCE_LINK_LAYER_ADDRESS
            })),
            NdpOptionsIterator::from_slice(&[1, 0]).next()
        );
        assert_eq!(
            Some(Err(NdpOptionReadError::UnexpectedEndOfSlice {
                option_id: NdpOptionType::SOURCE_LINK_LAYER_ADDRESS,
                expected_size: 8,
                actual_size: 6,
            })),
            NdpOptionsIterator::from_slice(&[1, 1, 1, 2, 3, 4]).next()
        );
        assert_eq!(
            Some(Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::PREFIX_INFORMATION,
                expected_size: 32,
                actual_size: 8,
            })),
            NdpOptionsIterator::from_slice(&[3, 1, 0, 0, 0, 0, 0, 0]).next()
        );
        assert_eq!(
            Some(Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::MTU,
                expected_size: 8,
                actual_size: 16,
            })),
            NdpOptionsIterator::from_slice(&[5, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
                .next()
        );
    }

    #[test]
    fn next_stops_after_error() {
        let mut iter = NdpOptionsIterator::from_slice(&[
            3, 1, 0, 0, 0, 0, 0, 0, // Prefix Information with invalid length units
            5, 1, 0, 0, 0, 0, 5, 220, // Valid MTU option that must not be reached
        ]);
        assert_eq!(
            Some(Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::PREFIX_INFORMATION,
                expected_size: 32,
                actual_size: 8,
            })),
            iter.next()
        );
        assert_eq!(None, iter.next());
        assert_eq!(0, iter.rest().len());
    }
}
