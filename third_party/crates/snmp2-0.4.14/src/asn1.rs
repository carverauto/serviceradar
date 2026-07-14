use core::fmt;
use std::{mem, ptr};

use crate::{snmp, Error, Oid, Result, USIZE_LEN};

pub const PRIMITIVE: u8 = 0b0000_0000;
pub const CONSTRUCTED: u8 = 0b0010_0000;

pub const CLASS_UNIVERSAL: u8 = 0b0000_0000;
pub const CLASS_APPLICATION: u8 = 0b0100_0000;
pub const CLASS_CONTEXTSPECIFIC: u8 = 0b1000_0000;
#[allow(dead_code)]
pub const CLASS_PRIVATE: u8 = 0b1100_0000;

pub const TYPE_BOOLEAN: u8 = CLASS_UNIVERSAL | PRIMITIVE | 1;
pub const TYPE_INTEGER: u8 = CLASS_UNIVERSAL | PRIMITIVE | 2;
pub const TYPE_OCTETSTRING: u8 = CLASS_UNIVERSAL | PRIMITIVE | 4;
pub const TYPE_NULL: u8 = CLASS_UNIVERSAL | PRIMITIVE | 5;
pub const TYPE_OBJECTIDENTIFIER: u8 = CLASS_UNIVERSAL | PRIMITIVE | 6;
pub const TYPE_SEQUENCE: u8 = CLASS_UNIVERSAL | CONSTRUCTED | 16;
pub const TYPE_SET: u8 = CLASS_UNIVERSAL | CONSTRUCTED | 17;

/// ASN.1/DER decoder iterator.
///
/// Supports:
///
/// - types required by SNMP.
///
/// Does not support:
///
/// - extended tag IDs.
/// - indefinite lengths (disallowed by DER).
/// - INTEGER values not representable by i64.
pub struct AsnReader<'a> {
    inner: &'a [u8],
}

impl<'a> Clone for AsnReader<'a> {
    fn clone(&self) -> AsnReader<'a> {
        AsnReader { inner: self.inner }
    }
}

impl fmt::Debug for AsnReader<'_> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_list().entries(self.clone()).finish()
    }
}

impl<'a> AsnReader<'a> {
    pub fn from_bytes(bytes: &[u8]) -> AsnReader {
        AsnReader { inner: bytes }
    }

    pub fn peek_byte(&mut self) -> Result<u8> {
        if self.inner.is_empty() {
            Err(Error::AsnEof)
        } else {
            Ok(self.inner[0])
        }
    }

    pub fn read_byte(&mut self) -> Result<u8> {
        match self.inner.split_first() {
            Some((head, tail)) => {
                self.inner = tail;
                Ok(*head)
            }
            _ => Err(Error::AsnEof),
        }
    }

    pub fn read_length(&mut self) -> Result<usize> {
        if let Some((head, tail)) = self.inner.split_first() {
            let o: usize;
            if *head < 128 {
                // short form
                o = *head as usize;
                self.inner = tail;
                Ok(o)
            } else if head == &0xff {
                Err(Error::AsnInvalidLen) // reserved for future use
            } else {
                // long form
                let length_len = (*head & 0b0111_1111) as usize;
                if length_len == 0 {
                    // Indefinite length. Not allowed in DER.
                    return Err(Error::AsnInvalidLen);
                }

                let mut bytes = [0u8; USIZE_LEN];
                if length_len > USIZE_LEN {
                    return Err(Error::AsnInvalidLen);
                }
                if tail.len() < length_len {
                    return Err(Error::AsnEof);
                }
                bytes[(USIZE_LEN - length_len)..].copy_from_slice(&tail[..length_len]);

                o = unsafe { mem::transmute::<[u8; USIZE_LEN], usize>(bytes).to_be() };
                self.inner = &tail[length_len..];
                Ok(o)
            }
        } else {
            Err(Error::AsnEof)
        }
    }

    pub fn read_i64_type(&mut self, expected_ident: u8) -> Result<i64> {
        let ident = self.read_byte()?;
        if ident != expected_ident {
            return Err(Error::AsnWrongType);
        }
        let val_len = self.read_length()?;
        if val_len > self.inner.len() {
            return Err(Error::AsnInvalidLen);
        }
        let (val, remaining) = self.inner.split_at(val_len);
        self.inner = remaining;
        decode_i64(val)
    }

    pub fn read_raw(&mut self, expected_ident: u8) -> Result<&'a [u8]> {
        let ident = self.read_byte()?;
        if ident != expected_ident {
            return Err(Error::AsnWrongType);
        }
        let val_len = self.read_length()?;
        if val_len > self.inner.len() {
            return Err(Error::AsnInvalidLen);
        }
        //dbg!(self.inner.len());
        let (val, remaining) = self.inner.split_at(val_len);
        self.inner = remaining;
        Ok(val)
    }

    pub fn read_constructed<F>(&mut self, expected_ident: u8, f: F) -> Result<()>
    where
        F: Fn(&mut AsnReader) -> Result<()>,
    {
        let ident = self.read_byte()?;
        if ident != expected_ident {
            return Err(Error::AsnWrongType);
        }
        let seq_len = self.read_length()?;
        if seq_len > self.inner.len() {
            return Err(Error::AsnInvalidLen);
        }
        let (seq_bytes, remaining) = self.inner.split_at(seq_len);
        let mut reader = AsnReader::from_bytes(seq_bytes);
        self.inner = remaining;
        f(&mut reader)
    }

    //
    // ASN
    //

    pub fn read_asn_boolean(&mut self) -> Result<bool> {
        let ident = self.read_byte()?;
        if ident != TYPE_NULL {
            return Err(Error::AsnWrongType);
        }
        let val_len = self.read_length()?;
        if val_len != 1 {
            return Err(Error::AsnInvalidLen);
        }
        match self.read_byte()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(Error::AsnParse), // DER mandates 1/0 for booleans
        }
    }

    pub fn read_asn_integer(&mut self) -> Result<i64> {
        self.read_i64_type(TYPE_INTEGER)
    }

    pub fn read_asn_octetstring(&mut self) -> Result<&'a [u8]> {
        self.read_raw(TYPE_OCTETSTRING)
    }

    pub fn read_asn_null(&mut self) -> Result<()> {
        let ident = self.read_byte()?;
        if ident != TYPE_NULL {
            return Err(Error::AsnWrongType);
        }
        let null_len = self.read_length()?;
        if null_len == 0 {
            Ok(())
        } else {
            Err(Error::AsnInvalidLen)
        }
    }

    pub fn read_asn_objectidentifier(&mut self) -> Result<Oid<'a>> {
        let ident = self.read_byte()?;
        if ident != TYPE_OBJECTIDENTIFIER {
            return Err(Error::AsnWrongType);
        }
        let val_len = self.read_length()?;
        if val_len > self.inner.len() {
            return Err(Error::AsnInvalidLen);
        }
        let (input, remaining) = self.inner.split_at(val_len);
        self.inner = remaining;

        Ok(Oid::new(input.into()))
    }

    pub fn read_asn_sequence<F>(&mut self, f: F) -> Result<()>
    where
        F: Fn(&mut AsnReader) -> Result<()>,
    {
        self.read_constructed(TYPE_SEQUENCE, f)
    }

    #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
    pub fn read_snmp_counter32(&mut self) -> Result<u32> {
        self.read_i64_type(snmp::TYPE_COUNTER32).map(|v| v as u32)
    }

    #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
    pub fn read_snmp_unsigned32(&mut self) -> Result<u32> {
        self.read_i64_type(snmp::TYPE_UNSIGNED32).map(|v| v as u32)
    }

    #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
    pub fn read_snmp_timeticks(&mut self) -> Result<u32> {
        self.read_i64_type(snmp::TYPE_TIMETICKS).map(|v| v as u32)
    }

    #[allow(clippy::cast_sign_loss)]
    pub fn read_snmp_counter64(&mut self) -> Result<u64> {
        self.read_i64_type(snmp::TYPE_COUNTER64).map(|v| v as u64)
    }

    pub fn read_snmp_opaque(&mut self) -> Result<&'a [u8]> {
        self.read_raw(snmp::TYPE_OPAQUE)
    }

    pub fn read_snmp_ipaddress(&mut self) -> Result<[u8; 4]> {
        let val = self.read_raw(snmp::TYPE_IPADDRESS)?;
        if val.len() != 4 {
            return Err(Error::AsnInvalidLen);
        }
        unsafe { Ok(ptr::read(val.as_ptr().cast())) }
    }

    pub fn bytes_left(&self) -> usize {
        self.inner.len()
    }
}

fn decode_i64(i: &[u8]) -> Result<i64> {
    if i.len() > mem::size_of::<i64>() {
        return Err(Error::AsnIntOverflow);
    }
    let mut bytes = [0u8; 8];
    bytes[(mem::size_of::<i64>() - i.len())..].copy_from_slice(i);

    let mut ret = unsafe { mem::transmute::<[u8; 8], i64>(bytes).to_be() };
    {
        //sign extend
        let shift_amount = (mem::size_of::<i64>() - i.len()) * 8;
        ret = (ret << shift_amount) >> shift_amount;
    }
    Ok(ret)
}
