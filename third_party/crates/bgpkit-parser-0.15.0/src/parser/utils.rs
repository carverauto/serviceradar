/*!
Provides IO utility functions for read bytes of different length and converting to corresponding structs.
*/
use ipnet::{IpNet, Ipv4Net, Ipv6Net};
use std::convert::TryFrom;
use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr},
};

use crate::error::ParserError;
use crate::models::*;
use crate::ParserError::TruncatedMsg;
use bytes::{Buf, BufMut, Bytes, BytesMut};
use log::debug;
use regex::Regex;
use std::net::IpAddr;

impl ReadUtils for Bytes {}

// Allow reading IPs from Reads
pub trait ReadUtils: Buf {
    #[inline]
    fn has_n_remaining(&self, n: usize) -> Result<(), ParserError> {
        let remaining = self.remaining();
        if remaining < n {
            Err(TruncatedMsg(format!(
                "not enough bytes to read. remaining: {remaining}, required: {n}"
            )))
        } else {
            Ok(())
        }
    }

    #[inline]
    fn read_u8(&mut self) -> Result<u8, ParserError> {
        self.has_n_remaining(1)?;
        Ok(self.get_u8())
    }

    #[inline]
    fn read_u16(&mut self) -> Result<u16, ParserError> {
        self.has_n_remaining(2)?;
        Ok(self.get_u16())
    }

    #[inline]
    fn read_u32(&mut self) -> Result<u32, ParserError> {
        self.has_n_remaining(4)?;
        Ok(self.get_u32())
    }

    #[inline]
    fn read_u64(&mut self) -> Result<u64, ParserError> {
        self.has_n_remaining(8)?;
        Ok(self.get_u64())
    }

    fn read_exact(&mut self, buf: &mut [u8]) -> Result<(), ParserError> {
        self.has_n_remaining(buf.len())?;
        self.copy_to_slice(buf);
        Ok(())
    }

    fn read_address(&mut self, afi: &Afi) -> io::Result<IpAddr> {
        match afi {
            Afi::Ipv4 => match self.read_ipv4_address() {
                Ok(ip) => Ok(IpAddr::V4(ip)),
                _ => Err(io::Error::other("Cannot parse IPv4 address")),
            },
            Afi::Ipv6 => match self.read_ipv6_address() {
                Ok(ip) => Ok(IpAddr::V6(ip)),
                _ => Err(io::Error::other("Cannot parse IPv6 address")),
            },
            Afi::LinkState => {
                // Link-State doesn't use traditional IP addresses
                // Use IPv4 zero address as placeholder
                Ok(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)))
            }
        }
    }

    fn read_ipv4_address(&mut self) -> Result<Ipv4Addr, ParserError> {
        let addr = self.read_u32()?;
        Ok(Ipv4Addr::from(addr))
    }

    fn read_ipv6_address(&mut self) -> Result<Ipv6Addr, ParserError> {
        self.has_n_remaining(16)?;
        let buf = self.get_u128();
        Ok(Ipv6Addr::from(buf))
    }

    fn read_ipv4_prefix(&mut self) -> Result<Ipv4Net, ParserError> {
        let addr = self.read_ipv4_address()?;
        let mask = self.read_u8()?;
        match Ipv4Net::new(addr, mask) {
            Ok(n) => Ok(n),
            Err(_) => Err(io::Error::other("Invalid prefix mask").into()),
        }
    }

    fn read_ipv6_prefix(&mut self) -> Result<Ipv6Net, ParserError> {
        let addr = self.read_ipv6_address()?;
        let mask = self.read_u8()?;
        match Ipv6Net::new(addr, mask) {
            Ok(n) => Ok(n),
            Err(_) => Err(io::Error::other("Invalid prefix mask").into()),
        }
    }

    #[inline]
    fn read_asn(&mut self, as_length: AsnLength) -> Result<Asn, ParserError> {
        match as_length {
            AsnLength::Bits16 => self.read_u16().map(Asn::new_16bit),
            AsnLength::Bits32 => self.read_u32().map(Asn::new_32bit),
        }
    }

    fn read_asns(&mut self, as_length: &AsnLength, count: usize) -> Result<Vec<Asn>, ParserError> {
        let mut path = Vec::with_capacity(count);

        match as_length {
            AsnLength::Bits16 => {
                self.has_n_remaining(count * 2)?; // 2 bytes for 16-bit ASN
                for _ in 0..count {
                    path.push(Asn::new_16bit(self.read_u16()?));
                }
            }
            AsnLength::Bits32 => {
                self.has_n_remaining(count * 4)?; // 4 bytes for 32-bit ASN
                for _ in 0..count {
                    path.push(Asn::new_32bit(self.read_u32()?));
                }
            }
        }

        Ok(path)
    }

    fn read_afi(&mut self) -> Result<Afi, ParserError> {
        Afi::try_from(self.read_u16()?).map_err(ParserError::from)
    }

    fn read_safi(&mut self) -> Result<Safi, ParserError> {
        Safi::try_from(self.read_u8()?).map_err(ParserError::from)
    }

    /// Read announced/withdrawn prefix.
    ///
    /// The length in bits is 1 byte, and then based on the IP version it reads different number of bytes.
    /// If the `add_path` is true, it will also first read a 4-byte path id first; otherwise, a path-id of 0
    /// is automatically set.
    fn read_nlri_prefix(
        &mut self,
        afi: &Afi,
        add_path: bool,
    ) -> Result<NetworkPrefix, ParserError> {
        let path_id = if add_path {
            Some(self.read_u32()?)
        } else {
            None
        };

        // Length in bits
        let bit_len = self.read_u8()?;

        // Convert to bytes
        let byte_len: usize = (bit_len as usize).div_ceil(8);
        let addr: IpAddr = match afi {
            Afi::Ipv4 => {
                // 4 bytes -- u32
                if byte_len > 4 {
                    return Err(ParserError::ParseError(format!(
                        "Invalid byte length for IPv4 prefix. byte_len: {byte_len}, bit_len: {bit_len}"
                    )));
                }
                self.has_n_remaining(byte_len)?;
                let mut buff = [0; 4];
                self.copy_to_slice(&mut buff[..byte_len]);
                IpAddr::V4(Ipv4Addr::from(buff))
            }
            Afi::Ipv6 => {
                // 16 bytes
                if byte_len > 16 {
                    return Err(ParserError::ParseError(format!(
                        "Invalid byte length for IPv6 prefix. byte_len: {byte_len}, bit_len: {bit_len}"
                    )));
                }
                self.has_n_remaining(byte_len)?;
                let mut buff = [0; 16];
                self.copy_to_slice(&mut buff[..byte_len]);
                IpAddr::V6(Ipv6Addr::from(buff))
            }
            Afi::LinkState => {
                // Link-State doesn't use traditional IP prefixes
                // Use IPv4 zero address as placeholder
                IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0))
            }
        };
        let prefix = match IpNet::new(addr, bit_len) {
            Ok(p) => p,
            Err(_) => {
                return Err(ParserError::ParseError(format!(
                    "Invalid network prefix length: {bit_len}"
                )))
            }
        };

        Ok(NetworkPrefix::new(prefix, path_id))
    }

    fn read_n_bytes(&mut self, n_bytes: usize) -> Result<Vec<u8>, ParserError> {
        self.has_n_remaining(n_bytes)?;
        Ok(self.copy_to_bytes(n_bytes).into())
    }

    fn read_n_bytes_to_string(&mut self, n_bytes: usize) -> Result<String, ParserError> {
        let buffer = self.read_n_bytes(n_bytes)?;
        Ok(buffer
            .into_iter()
            .map(|x: u8| x as char)
            .collect::<String>())
    }
}

pub fn parse_nlri_list(
    mut input: Bytes,
    add_path: bool,
    afi: &Afi,
) -> Result<Vec<NetworkPrefix>, ParserError> {
    let mut is_add_path = add_path;
    let mut prefixes = vec![];

    let mut retry = false;
    let mut guessed = false;

    let mut input_copy = None;

    while input.remaining() > 0 {
        if !is_add_path && input[0] == 0 {
            // it's likely that this is a add-path wrongfully wrapped in non-add-path msg
            debug!("not add-path but with NLRI size to be 0, likely add-path msg in wrong msg type, treat as add-path now");
            // cloning the data bytes
            is_add_path = true;
            guessed = true;
            input_copy = Some(input.clone());
        }
        let prefix = match input.read_nlri_prefix(afi, is_add_path) {
            Ok(p) => p,
            Err(e) => {
                if guessed {
                    retry = true;
                    break;
                } else {
                    return Err(e);
                }
            }
        };
        prefixes.push(prefix);
    }

    if retry {
        prefixes.clear();
        // try again without attempt to guess add-path
        // if we reach here (retry==true), input_copy must be Some
        let mut input_2 = input_copy.unwrap();
        while input_2.remaining() > 0 {
            let prefix = input_2.read_nlri_prefix(afi, add_path)?;
            prefixes.push(prefix);
        }
    }

    Ok(prefixes)
}

pub fn encode_asn(asn: &Asn, asn_len: &AsnLength) -> Bytes {
    let mut bytes = BytesMut::new();
    match asn_len {
        AsnLength::Bits16 => bytes.put_u16(asn.into()),
        AsnLength::Bits32 => {
            bytes.put_u32(asn.into());
        }
    }
    bytes.freeze()
}

pub fn encode_ipaddr(addr: &IpAddr) -> Vec<u8> {
    match addr {
        IpAddr::V4(addr) => addr.octets().to_vec(),
        IpAddr::V6(addr) => addr.octets().to_vec(),
    }
}

pub fn encode_nlri_prefixes(prefixes: &[NetworkPrefix]) -> Bytes {
    let mut bytes = BytesMut::new();
    for prefix in prefixes {
        bytes.extend(prefix.encode());
    }
    bytes.freeze()
}

/// A CRC32 implementation that converts a string to a hex string.
///
/// CRC32 is a checksum algorithm that is used to verify the integrity of data. It is short in
/// length and sufficient for generating unique file names based on remote URLs.
pub fn crc32(input: &str) -> String {
    let input_bytes = input.as_bytes();
    let mut table = [0u32; 256];
    let polynomial = 0xedb88320u32;

    for i in 0..256 {
        let mut crc = i as u32;
        for _ in 0..8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ polynomial;
            } else {
                crc >>= 1;
            }
        }
        table[i as usize] = crc;
    }

    let mut crc = !0u32;
    for byte in input_bytes.iter() {
        let index = ((crc ^ (*byte as u32)) & 0xff) as usize;
        crc = (crc >> 8) ^ table[index];
    }

    format!("{:08x}", !crc)
}

/// Convert a f64 timestamp into u32 seconds and u32 microseconds.
///
/// # Arguments
///
/// * `timestamp` - The timestamp to convert.
///
/// # Returns
///
/// A tuple containing the converted seconds and microseconds.
///
/// # Example
///
/// ```rust
/// use bgpkit_parser::utils::convert_timestamp;
///
/// let timestamp = 1609459200.123456;
/// let (seconds, microseconds) = convert_timestamp(timestamp);
/// assert_eq!(seconds, 1609459200);
/// assert_eq!(microseconds, 123456);
/// ```
// convert f64 timestamp into u32 seconds and u32 microseconds
pub fn convert_timestamp(timestamp: f64) -> (u32, u32) {
    let seconds = timestamp as u32;
    let microseconds = ((timestamp - seconds as f64) * 1_000_000.0) as u32;
    (seconds, microseconds)
}

#[derive(Debug, Clone)]
pub struct ComparableRegex {
    pattern: String,
    regex: Regex,
}

impl PartialEq for ComparableRegex {
    fn eq(&self, other: &Self) -> bool {
        self.pattern == other.pattern
    }
}

impl ComparableRegex {
    pub fn new(pattern: &str) -> Result<Self, ParserError> {
        let regex = match Regex::new(pattern) {
            Ok(r) => r,
            Err(_) => {
                return Err(ParserError::FilterError(format!(
                    "Invalid regex pattern: {pattern}"
                )))
            }
        };
        Ok(ComparableRegex {
            pattern: pattern.to_string(),
            regex,
        })
    }

    pub fn is_match<S: AsRef<str>>(&self, text: S) -> bool {
        self.regex.is_match(text.as_ref())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;

    #[test]
    fn test_read_u8() {
        let mut buf = Bytes::from_static(&[0x12]);
        assert_eq!(buf.read_u8().unwrap(), 0x12);
    }

    #[test]
    fn test_read_u16() {
        let mut buf = Bytes::from_static(&[0x12, 0x34]);
        assert_eq!(buf.read_u16().unwrap(), 0x1234);
    }

    #[test]
    fn test_read_u32() {
        let mut buf = Bytes::from_static(&[0x12, 0x34, 0x56, 0x78]);
        assert_eq!(buf.read_u32().unwrap(), 0x12345678);
    }

    #[test]
    fn test_read_u64() {
        let mut buf = Bytes::from_static(&[0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]);
        assert_eq!(buf.read_u64().unwrap(), 0x123456789ABCDEF0);
    }

    #[test]
    fn test_read_ipv4_address() {
        let mut buf = Bytes::from_static(&[0xC0, 0xA8, 0x01, 0x01]);
        assert_eq!(
            buf.read_ipv4_address().unwrap(),
            Ipv4Addr::new(192, 168, 1, 1)
        );
    }

    #[test]
    fn test_read_ipv6_address() {
        let mut buf = Bytes::from_static(&[
            0x20, 0x01, 0x0D, 0xB8, 0x85, 0xA3, 0x00, 0x00, 0x00, 0x00, 0x8A, 0x2E, 0x03, 0x70,
            0x73, 0x34,
        ]);
        assert_eq!(
            buf.read_ipv6_address().unwrap(),
            Ipv6Addr::new(0x2001, 0x0DB8, 0x85A3, 0x0000, 0x0000, 0x8A2E, 0x0370, 0x7334)
        );
    }

    #[test]
    fn test_read_address() {
        let mut buf = Bytes::from_static(&[0xC0, 0xA8, 0x01, 0x01]);
        assert_eq!(
            buf.read_address(&Afi::Ipv4).unwrap(),
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))
        );

        let mut buf = Bytes::from_static(&[
            0x20, 0x01, 0x0D, 0xB8, 0x85, 0xA3, 0x00, 0x00, 0x00, 0x00, 0x8A, 0x2E, 0x03, 0x70,
            0x73, 0x34,
        ]);
        assert_eq!(
            buf.read_address(&Afi::Ipv6).unwrap(),
            IpAddr::V6(Ipv6Addr::new(
                0x2001, 0x0DB8, 0x85A3, 0x0000, 0x0000, 0x8A2E, 0x0370, 0x7334
            ))
        );

        let mut buf = Bytes::from_static(&[0xC0, 0xA8, 0x01]);
        assert!(buf.read_address(&Afi::Ipv4).is_err());

        let mut buf = Bytes::from_static(&[
            0x20, 0x01, 0x0D, 0xB8, 0x85, 0xA3, 0x00, 0x00, 0x00, 0x00, 0x8A, 0x2E, 0x03, 0x70,
            0x73,
        ]);
        assert!(buf.read_address(&Afi::Ipv6).is_err());
    }

    #[test]
    fn test_read_asn() {
        let mut buf = Bytes::from_static(&[0x00, 0x01]);
        assert_eq!(buf.read_asn(AsnLength::Bits16).unwrap(), Asn::new_16bit(1));

        let mut buf = Bytes::from_static(&[0x00, 0x00, 0x01, 0x00]);
        assert_eq!(
            buf.read_asn(AsnLength::Bits32).unwrap(),
            Asn::new_32bit(256)
        );
    }

    #[test]
    fn read_asns() {
        let mut buf = Bytes::from_static(&[0x00, 0x01, 0x00, 0x00]);
        assert_eq!(
            buf.read_asns(&AsnLength::Bits16, 2).unwrap(),
            vec![Asn::new_16bit(1), Asn::new_16bit(0)]
        );
    }

    #[test]
    fn test_read_afi() {
        let mut buf = Bytes::from_static(&[0x00, 0x01]);
        assert_eq!(buf.read_afi().unwrap(), Afi::Ipv4);

        let mut buf = Bytes::from_static(&[0x00, 0x02]);
        assert_eq!(buf.read_afi().unwrap(), Afi::Ipv6);
    }

    #[test]
    fn test_read_safi() {
        let mut buf = Bytes::from_static(&[0x01]);
        assert_eq!(buf.read_safi().unwrap(), Safi::Unicast);

        let mut buf = Bytes::from_static(&[0x02]);
        assert_eq!(buf.read_safi().unwrap(), Safi::Multicast);

        // RFC 8950 VPN SAFI values
        let mut buf = Bytes::from_static(&[0x80]); // 128 in hex
        assert_eq!(buf.read_safi().unwrap(), Safi::MplsVpn);

        let mut buf = Bytes::from_static(&[0x81]); // 129 in hex
        assert_eq!(buf.read_safi().unwrap(), Safi::MulticastVpn);
    }

    #[test]
    fn test_has_n_remaining() {
        let mut buf = Bytes::from_static(&[0x12, 0x34, 0x56, 0x78]);
        assert!(buf.has_n_remaining(4).is_ok());
        assert!(buf.has_n_remaining(5).is_err());

        let _ = buf.read_u8().unwrap();
        assert!(buf.has_n_remaining(3).is_ok());
        assert!(buf.has_n_remaining(4).is_err());
    }

    #[test]
    fn test_read_ipv4_prefix() {
        let mut buf = Bytes::from_static(&[0xC0, 0xA8, 0x01, 0x01, 0x18]);
        assert_eq!(
            buf.read_ipv4_prefix().unwrap(),
            Ipv4Net::new(Ipv4Addr::new(192, 168, 1, 1), 24).unwrap()
        );

        // Test with invalid IPv4 prefix mask, /33
        let mut buf = Bytes::from_static(&[0xC0, 0xA8, 0x01, 0x01, 0x21]);
        assert!(buf.read_ipv4_prefix().is_err());
    }

    #[test]
    fn test_read_ipv6_prefix() {
        let mut buf = Bytes::from_static(&[
            0x20, 0x01, 0x0D, 0xB8, 0x85, 0xA3, 0x00, 0x00, 0x00, 0x00, 0x8A, 0x2E, 0x03, 0x70,
            0x73, 0x34, 0x40,
        ]);
        assert_eq!(
            buf.read_ipv6_prefix().unwrap(),
            Ipv6Net::new(
                Ipv6Addr::new(0x2001, 0x0DB8, 0x85A3, 0x0000, 0x0000, 0x8A2E, 0x0370, 0x7334),
                64
            )
            .unwrap()
        );

        // Test with invalid IPv6 prefix mask, /129
        let mut buf = Bytes::from_static(&[
            0x20, 0x01, 0x0D, 0xB8, 0x85, 0xA3, 0x00, 0x00, 0x00, 0x00, 0x8A, 0x2E, 0x03, 0x70,
            0x73, 0x34, 0x81,
        ]);
        assert!(buf.read_ipv6_prefix().is_err());
    }

    #[test]
    fn test_read_n_bytes() {
        let mut buf = Bytes::from_static(&[0x12, 0x34, 0x56, 0x78]);
        assert_eq!(buf.read_n_bytes(4).unwrap(), vec![0x12, 0x34, 0x56, 0x78]);
    }

    #[test]
    fn test_read_n_bytes_to_string() {
        let mut buf = Bytes::from_static(&[0x48, 0x65, 0x6C, 0x6C, 0x6F]); // "Hello" in ASCII
        assert_eq!(buf.read_n_bytes_to_string(5).unwrap(), "Hello");
    }

    #[test]
    fn test_crc32() {
        assert_eq!(crc32("Hello, World!"), "ec4ac3d0");
    }

    #[test]
    fn test_read_nlri_prefix() {
        let mut buf = Bytes::from_static(&[0x18, 0xC0, 0xA8, 0x01]);
        let expected = NetworkPrefix::new(
            IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 1, 0), 24).unwrap()),
            None,
        );
        assert_eq!(buf.read_nlri_prefix(&Afi::Ipv4, false).unwrap(), expected);

        let mut buf = Bytes::from_static(&[0x00, 0x00, 0x00, 0x01, 0x18, 0xC0, 0xA8, 0x01]);
        let expected = NetworkPrefix::new(
            IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 1, 0), 24).unwrap()),
            Some(1),
        );
        assert_eq!(buf.read_nlri_prefix(&Afi::Ipv4, true).unwrap(), expected);
    }

    #[test]
    fn test_encode_asn() {
        let asn = Asn::new_32bit(1);
        let asn_len = AsnLength::Bits32;
        let expected = Bytes::from_static(&[0x00, 0x00, 0x00, 0x01]);
        assert_eq!(encode_asn(&asn, &asn_len), expected);

        let asn = Asn::new_16bit(1);
        let asn_len = AsnLength::Bits16;
        let expected = Bytes::from_static(&[0x00, 0x01]);
        assert_eq!(encode_asn(&asn, &asn_len), expected);
    }

    #[test]
    fn test_encode_ipaddr() {
        let addr = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1));
        let expected = vec![192, 168, 1, 1];
        assert_eq!(encode_ipaddr(&addr), expected);

        let addr = IpAddr::V6(Ipv6Addr::new(
            0x2001, 0x0DB8, 0x85A3, 0x0000, 0x0000, 0x8A2E, 0x0370, 0x7334,
        ));
        let expected = vec![
            0x20, 0x01, 0x0D, 0xB8, 0x85, 0xA3, 0x00, 0x00, 0x00, 0x00, 0x8A, 0x2E, 0x03, 0x70,
            0x73, 0x34,
        ];
        assert_eq!(encode_ipaddr(&addr), expected);
    }

    #[test]
    fn test_encode_nlri_prefixes() {
        let prefixes = vec![
            NetworkPrefix::new(
                IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 1, 0), 24).unwrap()),
                None,
            ),
            NetworkPrefix::new(
                IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 2, 0), 24).unwrap()),
                None,
            ),
        ];
        let expected = Bytes::from_static(&[0x18, 0xC0, 0xA8, 0x01, 0x18, 0xC0, 0xA8, 0x02]);
        assert_eq!(encode_nlri_prefixes(&prefixes), expected);

        let prefixes = vec![
            NetworkPrefix::new(
                IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 1, 0), 24).unwrap()),
                Some(1),
            ),
            NetworkPrefix::new(
                IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 2, 0), 24).unwrap()),
                Some(1),
            ),
        ];
        let expected = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x01, 0x18, 0xC0, 0xA8, 0x01, 0x00, 0x00, 0x00, 0x01, 0x18, 0xC0,
            0xA8, 0x02,
        ]);
        assert_eq!(encode_nlri_prefixes(&prefixes), expected);
    }

    #[test]
    fn test_comparable_regex_functionality() {
        // Test valid pattern creation
        let regex1 = ComparableRegex::new(r"\d+").unwrap();
        let regex2 = ComparableRegex::new(r"\d+").unwrap();
        let regex3 = ComparableRegex::new(r"\w+").unwrap();

        // Verify pattern storage
        assert_eq!(regex1.pattern, r"\d+");
        assert_eq!(regex3.pattern, r"\w+");

        // Verify equality with same pattern
        assert_eq!(regex1, regex2);

        // Verify inequality with different patterns
        assert_ne!(regex1, regex3);

        // Verify regex matching functionality
        assert!(regex1.regex.is_match("123"));
        assert!(!regex1.regex.is_match("abc"));
    }

    #[test]
    #[should_panic(expected = "Invalid regex pattern")]
    fn test_comparable_regex_invalid_pattern_panic() {
        // Test invalid pattern creation
        ComparableRegex::new(r"(\d+").unwrap(); // Unclosed parenthesis should panic
    }

    #[test]
    fn test_parse_nlri_list() {
        // Test normal case with add_path=false
        let input = Bytes::from_static(&[0x18, 0xC0, 0xA8, 0x01, 0x18, 0xC0, 0xA8, 0x02]);
        let expected = vec![
            NetworkPrefix::new(
                IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 1, 0), 24).unwrap()),
                None,
            ),
            NetworkPrefix::new(
                IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 2, 0), 24).unwrap()),
                None,
            ),
        ];
        assert_eq!(parse_nlri_list(input, false, &Afi::Ipv4).unwrap(), expected);

        // Test normal case with add_path=true
        let input = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x01, 0x18, 0xC0, 0xA8, 0x01, 0x00, 0x00, 0x00, 0x02, 0x18, 0xC0,
            0xA8, 0x02,
        ]);
        let expected = vec![
            NetworkPrefix::new(
                IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 1, 0), 24).unwrap()),
                Some(1),
            ),
            NetworkPrefix::new(
                IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 2, 0), 24).unwrap()),
                Some(2),
            ),
        ];
        assert_eq!(parse_nlri_list(input, true, &Afi::Ipv4).unwrap(), expected);

        // Test the auto-detection of add_path when first byte is 0
        let input = Bytes::from_static(&[0x00, 0x00, 0x00, 0x01, 0x18, 0xC0, 0xA8, 0x01]);
        let expected = vec![NetworkPrefix::new(
            IpNet::V4(Ipv4Net::new(Ipv4Addr::new(192, 168, 1, 0), 24).unwrap()),
            Some(1),
        )];
        assert_eq!(parse_nlri_list(input, false, &Afi::Ipv4).unwrap(), expected);
    }

    #[test]
    fn test_convert_timestamp() {
        // Test integer timestamp
        let (seconds, microseconds) = convert_timestamp(1609459200.0);
        assert_eq!(seconds, 1609459200);
        assert_eq!(microseconds, 0);

        // Test fractional timestamp
        let (seconds, microseconds) = convert_timestamp(1609459200.123456);
        assert_eq!(seconds, 1609459200);
        assert_eq!(microseconds, 123456);

        // Test rounding
        let (seconds, microseconds) = convert_timestamp(1609459200.1234567);
        assert_eq!(seconds, 1609459200);
        assert_eq!(microseconds, 123456); // Should round to microseconds
    }
}
