use crate::*;

/// In case a route header is present it is also possible
/// to attach a "final destination" header.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Ipv6RoutingExtensions {
    pub routing: Ipv6RawExtHeader,
    pub final_destination_options: Option<Ipv6RawExtHeader>,
}

impl Ipv6RoutingExtensions {
    /// Minimum length required for routing extension headers in bytes/octets.
    pub const MIN_LEN: usize = Ipv6RawExtHeader::MAX_LEN;

    /// Maximum summed up length of all extension headers in bytes/octets.
    pub const MAX_LEN: usize = Ipv6RawExtHeader::MAX_LEN * 2;

    /// Return the length of the headers in bytes.
    pub fn header_len(&self) -> usize {
        self.routing.header_len()
            + self
                .final_destination_options
                .as_ref()
                .map(|h| h.header_len())
                .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_gens::ipv6_raw_ext_any;
    use proptest::prelude::*;

    #[test]
    fn debug() {
        use alloc::format;

        let a: Ipv6RoutingExtensions = Ipv6RoutingExtensions {
            routing: Ipv6RawExtHeader::new_raw(0.into(), &[0; 6]).unwrap(),
            final_destination_options: None,
        };
        assert_eq!(
            &format!(
                "Ipv6RoutingExtensions {{ routing: {:?}, final_destination_options: {:?} }}",
                a.routing, a.final_destination_options,
            ),
            &format!("{:?}", a)
        );
    }

    #[test]
    fn clone_eq() {
        let a: Ipv6RoutingExtensions = Ipv6RoutingExtensions {
            routing: Ipv6RawExtHeader::new_raw(0.into(), &[0; 6]).unwrap(),
            final_destination_options: None,
        };
        assert_eq!(a, a.clone());
    }

    proptest! {
        #[test]
        fn header_len(
            routing in ipv6_raw_ext_any(),
            final_destination_options in ipv6_raw_ext_any()
        ) {
            // without final dest options
            assert_eq!(
                Ipv6RoutingExtensions{
                    routing: routing.clone(),
                    final_destination_options: None,
                }.header_len(),
                routing.header_len()
            );

            // with final dest options
            assert_eq!(
                Ipv6RoutingExtensions{
                    routing: routing.clone(),
                    final_destination_options: Some(final_destination_options.clone()),
                }.header_len(),
                routing.header_len() + final_destination_options.header_len()
            );
        }
    }
}
