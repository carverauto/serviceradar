//! Streaming PEM reader.

use super::{Reader, position::Position};
use crate::{EncodingRules, Error, ErrorKind, Length, Result};
use pem_rfc7468::Decoder;

/// `Reader` type which decodes PEM on-the-fly.
#[cfg(feature = "pem")]
#[derive(Clone)]
pub struct PemReader<'i> {
    /// Inner PEM decoder.
    decoder: Decoder<'i>,

    /// Encoding rules to apply when decoding the input.
    encoding_rules: EncodingRules,

    /// Position tracker.
    position: Position,
}

#[cfg(feature = "pem")]
impl<'i> PemReader<'i> {
    /// Create a new PEM reader which decodes data on-the-fly.
    ///
    /// Uses the default 64-character line wrapping.
    pub fn new(pem: &'i [u8]) -> Result<Self> {
        let decoder = Decoder::new(pem)?;
        let input_len = Length::try_from(decoder.remaining_len())?;

        Ok(Self {
            decoder,
            encoding_rules: EncodingRules::default(),
            position: Position::new(input_len),
        })
    }

    /// Get the PEM label which will be used in the encapsulation boundaries
    /// for this document.
    pub fn type_label(&self) -> &'i str {
        self.decoder.type_label()
    }
}

#[cfg(feature = "pem")]
impl<'i> Reader<'i> for PemReader<'i> {
    fn encoding_rules(&self) -> EncodingRules {
        self.encoding_rules
    }

    fn input_len(&self) -> Length {
        self.position.input_len()
    }

    fn position(&self) -> Length {
        self.position.current()
    }

    fn read_nested<T, F, E>(&mut self, len: Length, f: F) -> core::result::Result<T, E>
    where
        F: FnOnce(&mut Self) -> core::result::Result<T, E>,
        E: From<Error>,
    {
        let resumption = self.position.split_nested(len)?;
        let ret = f(self);
        self.position.resume_nested(resumption);
        ret
    }

    fn read_slice(&mut self, _len: Length) -> Result<&'i [u8]> {
        // Can't borrow from PEM because it requires decoding
        Err(self.error(ErrorKind::Reader))
    }

    fn read_into<'o>(&mut self, buf: &'o mut [u8]) -> Result<&'o [u8]> {
        self.position.advance(Length::try_from(buf.len())?)?;
        self.decoder.decode(buf)?;
        Ok(buf)
    }
}
