use crate::{
    err::{packet::TransportChecksumError, ValueTooBigError},
    *,
};

/// The possible headers on the transport layer
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TransportHeader {
    Udp(UdpHeader),
    Tcp(TcpHeader),
    Icmpv4(Icmpv4Header),
    Icmpv6(Icmpv6Header),
}

impl TransportHeader {
    /// Returns Result::Some containing the udp header if self has the value Udp.
    /// Otherwise None is returned.
    pub fn udp(self) -> Option<UdpHeader> {
        use crate::TransportHeader::*;
        if let Udp(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns Result::Some containing the udp header if self has the value Udp.
    /// Otherwise None is returned.
    pub fn mut_udp(&mut self) -> Option<&mut UdpHeader> {
        use crate::TransportHeader::*;
        if let Udp(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns Result::Some containing the tcp header if self has the value Tcp.
    /// Otherwise None is returned.
    pub fn tcp(self) -> Option<TcpHeader> {
        use crate::TransportHeader::*;
        if let Tcp(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns Result::Some containing a mutable reference to the tcp header if self has the value Tcp.
    /// Otherwise None is returned.
    pub fn mut_tcp(&mut self) -> Option<&mut TcpHeader> {
        use crate::TransportHeader::*;
        if let Tcp(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns Result::Some containing the ICMPv4 header if self has the value Icmpv4.
    /// Otherwise None is returned.
    pub fn icmpv4(self) -> Option<Icmpv4Header> {
        use crate::TransportHeader::*;
        if let Icmpv4(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns Result::Some containing the ICMPv4 header if self has the value Icmpv4.
    /// Otherwise None is returned.
    pub fn mut_icmpv4(&mut self) -> Option<&mut Icmpv4Header> {
        use crate::TransportHeader::*;
        if let Icmpv4(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns Result::Some containing the ICMPv6 header if self has the value Icmpv6.
    /// Otherwise None is returned.
    pub fn icmpv6(self) -> Option<Icmpv6Header> {
        use crate::TransportHeader::*;
        if let Icmpv6(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns Result::Some containing the ICMPv6 header if self has the value Icmpv6.
    /// Otherwise None is returned.
    pub fn mut_icmpv6(&mut self) -> Option<&mut Icmpv6Header> {
        use crate::TransportHeader::*;
        if let Icmpv6(value) = self {
            Some(value)
        } else {
            None
        }
    }

    /// Returns the size of the transport header (in case of UDP fixed,
    /// in case of TCP cotanining the options).
    pub fn header_len(&self) -> usize {
        use crate::TransportHeader::*;
        match self {
            Udp(_) => UdpHeader::LEN,
            Tcp(value) => value.header_len(),
            Icmpv4(value) => value.header_len(),
            Icmpv6(value) => value.header_len(),
        }
    }

    /// Calculates the checksum for the transport header & sets it in the header for
    /// an ipv4 header.
    pub fn update_checksum_ipv4(
        &mut self,
        ip_header: &Ipv4Header,
        payload: &[u8],
    ) -> Result<(), TransportChecksumError> {
        use crate::{err::packet::TransportChecksumError::*, TransportHeader::*};
        match self {
            Udp(header) => {
                header.checksum = header
                    .calc_checksum_ipv4(ip_header, payload)
                    .map_err(PayloadLen)?;
            }
            Tcp(header) => {
                header.checksum = header
                    .calc_checksum_ipv4(ip_header, payload)
                    .map_err(PayloadLen)?;
            }
            Icmpv4(header) => {
                header.update_checksum(payload);
            }
            Icmpv6(_) => return Err(Icmpv6InIpv4),
        }
        Ok(())
    }

    /// Calculates the checksum for the transport header & sets it in the header for
    /// an ipv6 header.
    pub fn update_checksum_ipv6(
        &mut self,
        ip_header: &Ipv6Header,
        payload: &[u8],
    ) -> Result<(), ValueTooBigError<usize>> {
        use crate::TransportHeader::*;
        match self {
            Icmpv4(header) => header.update_checksum(payload),
            Icmpv6(header) => {
                header.update_checksum(ip_header.source, ip_header.destination, payload)?
            }
            Udp(header) => {
                header.checksum = header.calc_checksum_ipv6(ip_header, payload)?;
            }
            Tcp(header) => {
                header.checksum = header.calc_checksum_ipv6(ip_header, payload)?;
            }
        }
        Ok(())
    }

    /// Write the transport header to the given writer.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        use crate::TransportHeader::*;
        match self {
            Icmpv4(value) => value.write(writer),
            Icmpv6(value) => value.write(writer),
            Udp(value) => value.write(writer),
            Tcp(value) => value.write(writer),
        }
    }
}

#[cfg(test)]
mod test {
    use crate::{test_gens::*, *};
    use alloc::{format, vec::Vec};
    use core::slice;
    use proptest::prelude::*;
    use std::io::Cursor;

    proptest! {
        #[test]
        fn debug(
            tcp in tcp_any(),
            udp in udp_any(),
            icmpv4 in icmpv4_header_any(),
            icmpv6 in icmpv6_header_any(),
        ) {
            use TransportHeader::*;
            assert_eq!(
                format!("Udp({:?})", udp),
                format!("{:?}", Udp(udp.clone())),
            );
            assert_eq!(
                format!("Tcp({:?})", tcp),
                format!("{:?}", Tcp(tcp.clone())),
            );
            assert_eq!(
                format!("Icmpv4({:?})", icmpv4),
                format!("{:?}", Icmpv4(icmpv4.clone())),
            );
            assert_eq!(
                format!("Icmpv6({:?})", icmpv6),
                format!("{:?}", Icmpv6(icmpv6.clone())),
            );
        }
    }

    proptest! {
        #[test]
        fn clone_eq(
            tcp in tcp_any(),
            udp in udp_any(),
            icmpv4 in icmpv4_header_any(),
            icmpv6 in icmpv6_header_any(),
        ) {
            use TransportHeader::*;
            let values = [
                Udp(udp),
                Tcp(tcp),
                Icmpv4(icmpv4),
                Icmpv6(icmpv6),
            ];
            for value in values {
                assert_eq!(value.clone(), value);
            }
        }
    }

    #[test]
    fn udp() {
        let udp: UdpHeader = Default::default();
        assert_eq!(Some(udp.clone()), TransportHeader::Udp(udp).udp());
        assert_eq!(None, TransportHeader::Tcp(Default::default()).udp());
    }
    #[test]
    fn mut_udp() {
        let udp: UdpHeader = Default::default();
        assert_eq!(Some(&mut udp.clone()), TransportHeader::Udp(udp).mut_udp());
        assert_eq!(None, TransportHeader::Tcp(Default::default()).mut_udp());
    }
    #[test]
    fn tcp() {
        let tcp: TcpHeader = Default::default();
        assert_eq!(Some(tcp.clone()), TransportHeader::Tcp(tcp).tcp());
        assert_eq!(None, TransportHeader::Udp(Default::default()).tcp());
    }
    #[test]
    fn mut_tcp() {
        let tcp: TcpHeader = Default::default();
        assert_eq!(Some(&mut tcp.clone()), TransportHeader::Tcp(tcp).mut_tcp());
        assert_eq!(None, TransportHeader::Udp(Default::default()).mut_tcp());
    }
    proptest! {
        #[test]
        fn icmpv4(icmpv4 in icmpv4_header_any()) {
            assert_eq!(Some(icmpv4.clone()), TransportHeader::Icmpv4(icmpv4).icmpv4());
            assert_eq!(None, TransportHeader::Udp(Default::default()).icmpv4());
        }
    }
    proptest! {
        #[test]
        fn mut_icmpv4(icmpv4 in icmpv4_header_any()) {
            assert_eq!(Some(&mut icmpv4.clone()), TransportHeader::Icmpv4(icmpv4).mut_icmpv4());
            assert_eq!(None, TransportHeader::Udp(Default::default()).mut_icmpv4());
        }
    }
    proptest! {
        #[test]
        fn icmpv6(icmpv6 in icmpv6_header_any()) {
            assert_eq!(Some(icmpv6.clone()), TransportHeader::Icmpv6(icmpv6).icmpv6());
            assert_eq!(None, TransportHeader::Udp(Default::default()).icmpv6());
        }
    }
    proptest! {
        #[test]
        fn mut_icmpv6(icmpv6 in icmpv6_header_any()) {
            assert_eq!(Some(&mut icmpv6.clone()), TransportHeader::Icmpv6(icmpv6).mut_icmpv6());
            assert_eq!(None, TransportHeader::Udp(Default::default()).mut_icmpv6());
        }
    }
    proptest! {
        #[test]
        fn header_size(
            udp in udp_any(),
            tcp in tcp_any(),
            icmpv4 in icmpv4_header_any(),
            icmpv6 in icmpv6_header_any(),
        ) {
            assert_eq!(
                TransportHeader::Udp(udp).header_len(),
                UdpHeader::LEN
            );
            assert_eq!(
                TransportHeader::Tcp(tcp.clone()).header_len(),
                tcp.header_len() as usize
            );
            assert_eq!(
                TransportHeader::Icmpv4(icmpv4.clone()).header_len(),
                icmpv4.header_len()
            );
            assert_eq!(
                TransportHeader::Icmpv6(icmpv6.clone()).header_len(),
                icmpv6.header_len()
            );
        }
    }
    proptest! {
        #[test]
        fn update_checksum_ipv4(
            ipv4 in ipv4_any(),
            udp in udp_any(),
            tcp in tcp_any(),
            icmpv4 in icmpv4_header_any(),
            icmpv6 in icmpv6_header_any()
        ) {
            use TransportHeader::*;
            use crate::err::{ValueTooBigError, ValueType, packet::TransportChecksumError::*};

            // udp
            {
                // ok case
                {
                    let mut transport = Udp(udp.clone());
                    let payload = Vec::new();
                    transport.update_checksum_ipv4(&ipv4, &payload).unwrap();
                    assert_eq!(transport.udp().unwrap().checksum,
                               udp.calc_checksum_ipv4(&ipv4, &payload).unwrap());
                }
                // error case
                {
                    let mut transport = Udp(udp.clone());
                    let len = (core::u16::MAX as usize) - UdpHeader::LEN + 1;
                    let tcp_payload = unsafe {
                        //NOTE: The pointer must be initialized with a non null value
                        //      otherwise a key constraint of slices is not fulfilled
                        //      which can lead to crashes in release mode.
                        use core::ptr::NonNull;
                        slice::from_raw_parts(
                            NonNull::<u8>::dangling().as_ptr(),
                            len
                        )
                    };
                    assert_eq!(
                        transport.update_checksum_ipv4(&ipv4, &tcp_payload),
                        Err(PayloadLen(ValueTooBigError{
                            actual: len,
                            max_allowed: (core::u16::MAX as usize) - UdpHeader::LEN,
                            value_type: ValueType::UdpPayloadLengthIpv4
                        }))
                    );
                }
            }
            // tcp
            {
                //ok case
                {
                    let mut transport = Tcp(tcp.clone());
                    let payload = Vec::new();
                    transport.update_checksum_ipv4(&ipv4, &payload).unwrap();
                    assert_eq!(transport.tcp().unwrap().checksum,
                               tcp.calc_checksum_ipv4(&ipv4, &payload).unwrap());
                }
                //error case
                {
                    let mut transport = Tcp(tcp.clone());
                    let len = (core::u16::MAX - tcp.header_len_u16()) as usize + 1;
                    let tcp_payload = unsafe {
                        //NOTE: The pointer must be initialized with a non null value
                        //      otherwise a key constraint of slices is not fulfilled
                        //      which can lead to crashes in release mode.
                        use core::ptr::NonNull;
                        slice::from_raw_parts(
                            NonNull::<u8>::dangling().as_ptr(),
                            len
                        )
                    };
                    assert_eq!(
                        transport.update_checksum_ipv4(&ipv4, &tcp_payload),
                        Err(PayloadLen(ValueTooBigError{
                            actual: len,
                            max_allowed: (core::u16::MAX as usize) - usize::from(tcp.header_len()),
                            value_type: ValueType::TcpPayloadLengthIpv4
                        }))
                    );
                }
            }

            // icmpv4
            {
                let mut transport = Icmpv4(icmpv4.clone());
                let payload = Vec::new();
                transport.update_checksum_ipv4(&ipv4, &payload).unwrap();
                assert_eq!(
                    transport.icmpv4().unwrap().checksum,
                    icmpv4.icmp_type.calc_checksum(&payload)
                );
            }

            // icmpv6 (error)
            assert_eq!(
                Icmpv6(icmpv6).update_checksum_ipv4(&ipv4, &[]),
                Err(Icmpv6InIpv4)
            );
        }
    }

    proptest! {
        #[test]
        #[cfg(target_pointer_width = "64")]
        fn update_checksum_ipv6(
            ipv6 in ipv6_any(),
            udp in udp_any(),
            tcp in tcp_any(),
            icmpv4 in icmpv4_header_any(),
            icmpv6 in icmpv6_header_any(),
        ) {
            use TransportHeader::*;
            use crate::err::{ValueTooBigError, ValueType};

            // udp
            {
                //ok case
                {
                    let mut transport = Udp(udp.clone());
                    let payload = Vec::new();
                    transport.update_checksum_ipv6(&ipv6, &payload).unwrap();
                    assert_eq!(transport.udp().unwrap().checksum,
                               udp.calc_checksum_ipv6(&ipv6, &payload).unwrap());
                }
                //error case
                {
                    let mut transport = Udp(udp.clone());
                    let len = (core::u32::MAX as usize) - UdpHeader::LEN + 1;
                    let payload = unsafe {
                        //NOTE: The pointer must be initialized with a non null value
                        //      otherwise a key constraint of slices is not fulfilled
                        //      which can lead to crashes in release mode.
                        use core::ptr::NonNull;
                        slice::from_raw_parts(
                            NonNull::<u8>::dangling().as_ptr(),
                            len
                        )
                    };
                    assert_eq!(
                        transport.update_checksum_ipv6(&ipv6, &payload),
                        Err(ValueTooBigError{
                            actual: len,
                            max_allowed: (core::u32::MAX as usize) - UdpHeader::LEN,
                            value_type: ValueType::UdpPayloadLengthIpv6
                        })
                    );
                }
            }

            // tcp
            {
                //ok case
                {
                    let mut transport = Tcp(tcp.clone());
                    let payload = Vec::new();
                    transport.update_checksum_ipv6(&ipv6, &payload).unwrap();
                    assert_eq!(transport.tcp().unwrap().checksum,
                               tcp.calc_checksum_ipv6(&ipv6, &payload).unwrap());
                }
                //error case
                {
                    let mut transport = Tcp(tcp.clone());
                    let len = (core::u32::MAX - tcp.header_len() as u32) as usize + 1;
                    let tcp_payload = unsafe {
                        //NOTE: The pointer must be initialized with a non null value
                        //      otherwise a key constraint of slices is not fulfilled
                        //      which can lead to crashes in release mode.
                        use core::ptr::NonNull;
                        slice::from_raw_parts(
                            NonNull::<u8>::dangling().as_ptr(),
                            len
                        )
                    };
                    assert_eq!(
                        transport.update_checksum_ipv6(&ipv6, &tcp_payload),
                        Err(ValueTooBigError{
                            actual: len,
                            max_allowed: (core::u32::MAX - tcp.header_len() as u32) as usize,
                            value_type: ValueType::TcpPayloadLengthIpv6
                        })
                    );
                }
            }

            // icmpv4
            {
                let mut transport = Icmpv4(icmpv4.clone());
                let payload = Vec::new();
                transport.update_checksum_ipv6(&ipv6, &payload).unwrap();
                assert_eq!(
                    transport.icmpv4().unwrap().checksum,
                    icmpv4.icmp_type.calc_checksum(&payload)
                );
            }

            // icmpv6
            {
                // normal case
                {
                    let mut transport = Icmpv6(icmpv6.clone());
                    let payload = Vec::new();
                    transport.update_checksum_ipv6(&ipv6, &payload).unwrap();
                    assert_eq!(
                        transport.icmpv6().unwrap().checksum,
                        icmpv6.icmp_type.calc_checksum(ipv6.source, ipv6.destination, &payload).unwrap()
                    );
                }

                // error case
                {
                    let mut transport = Icmpv6(icmpv6.clone());
                    // SAFETY: In case the error is not triggered
                    //         a segmentation fault will be triggered.
                    let too_big_slice = unsafe {
                        //NOTE: The pointer must be initialized with a non null value
                        //      otherwise a key constraint of slices is not fulfilled
                        //      which can lead to crashes in release mode.
                        use core::ptr::NonNull;
                        core::slice::from_raw_parts(
                            NonNull::<u8>::dangling().as_ptr(),
                            (core::u32::MAX - 7) as usize
                        )
                    };
                    assert_eq!(
                        transport.update_checksum_ipv6(&ipv6, too_big_slice),
                        Err(ValueTooBigError{
                            actual: too_big_slice.len(),
                            max_allowed: (core::u32::MAX - 8) as usize,
                            value_type: ValueType::Icmpv6PayloadLength,
                        })
                    );
                }
            }
        }
    }

    proptest! {
        #[test]
        fn write(
            udp in udp_any(),
            tcp in tcp_any(),
            icmpv4 in icmpv4_header_any(),
            icmpv6 in icmpv6_header_any(),
        ) {
            // udp
            {
                //write
                {
                    let result_input = {
                        let mut buffer = Vec::new();
                        udp.write(&mut buffer).unwrap();
                        buffer
                    };
                    let result_transport = {
                        let mut buffer = Vec::new();
                        TransportHeader::Udp(udp.clone()).write(&mut buffer).unwrap();
                        buffer
                    };
                    assert_eq!(result_input, result_transport);
                }
                //trigger an error
                {
                    let mut a: [u8;0] = [];
                    assert!(
                        TransportHeader::Udp(udp.clone())
                        .write(&mut Cursor::new(&mut a[..]))
                        .is_err()
                    );
                }
            }
            // tcp
            {
                //write
                {
                    let result_input = {
                        let mut buffer = Vec::new();
                        tcp.write(&mut buffer).unwrap();
                        buffer
                    };
                    let result_transport = {
                        let mut buffer = Vec::new();
                        TransportHeader::Tcp(tcp.clone()).write(&mut buffer).unwrap();
                        buffer
                    };
                    assert_eq!(result_input, result_transport);
                }
                //trigger an error
                {
                    let mut a: [u8;0] = [];
                    assert!(
                        TransportHeader::Tcp(tcp.clone())
                        .write(&mut Cursor::new(&mut a[..]))
                        .is_err()
                    );
                }
            }

            // icmpv4
            {
                // normal write
                {
                    let result_input = {
                        let mut buffer = Vec::new();
                        icmpv4.write(&mut buffer).unwrap();
                        buffer
                    };
                    let result_transport = {
                        let mut buffer = Vec::new();
                        TransportHeader::Icmpv4(icmpv4.clone()).write(&mut buffer).unwrap();
                        buffer
                    };
                    assert_eq!(result_input, result_transport);
                }

                // error during write
                {
                    let mut a: [u8;0] = [];
                    assert!(
                        TransportHeader::Icmpv4(icmpv4.clone())
                        .write(&mut Cursor::new(&mut a[..]))
                        .is_err()
                    );
                }
            }

            // icmpv6
            {
                // normal write
                {
                    let result_input = {
                        let mut buffer = Vec::new();
                        icmpv6.write(&mut buffer).unwrap();
                        buffer
                    };
                    let result_transport = {
                        let mut buffer = Vec::new();
                        TransportHeader::Icmpv6(icmpv6.clone()).write(&mut buffer).unwrap();
                        buffer
                    };
                    assert_eq!(result_input, result_transport);
                }

                // error during write
                {
                    let mut a: [u8;0] = [];
                    assert!(
                        TransportHeader::Icmpv6(icmpv6.clone())
                        .write(&mut Cursor::new(&mut a[..]))
                        .is_err()
                    );
                }
            }
        }
    }
}
