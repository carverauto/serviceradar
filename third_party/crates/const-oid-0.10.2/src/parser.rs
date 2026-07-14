//! OID string parser with `const` support.

use crate::{Arc, Error, ObjectIdentifier, Result, encoder::Encoder};

/// Const-friendly OID string parser.
///
/// Parses an OID from the dotted string representation.
#[derive(Debug)]
pub(crate) struct Parser {
    /// Current arc in progress
    current_arc: Option<Arc>,

    /// BER/DER encoder
    encoder: Encoder<{ ObjectIdentifier::MAX_SIZE }>,
}

impl Parser {
    /// Parse an OID from a dot-delimited string e.g. `1.2.840.113549.1.1.1`
    pub(crate) const fn parse(s: &str) -> Result<Self> {
        let bytes = s.as_bytes();

        if bytes.is_empty() {
            return Err(Error::Empty);
        }

        match bytes[0] {
            b'0'..=b'9' => Self {
                current_arc: None,
                encoder: Encoder::new(),
            }
            .parse_bytes(bytes),
            actual => Err(Error::DigitExpected { actual }),
        }
    }

    /// Finish parsing, returning the result
    pub(crate) const fn finish(self) -> Result<ObjectIdentifier> {
        self.encoder.finish()
    }

    /// Parse the remaining bytes
    const fn parse_bytes(mut self, bytes: &[u8]) -> Result<Self> {
        match bytes {
            // TODO(tarcieri): use `?` when stable in `const fn`
            [] => match self.current_arc {
                Some(arc) => match self.encoder.arc(arc) {
                    Ok(encoder) => {
                        self.encoder = encoder;
                        Ok(self)
                    }
                    Err(err) => Err(err),
                },
                None => Err(Error::TrailingDot),
            },
            [byte @ b'0'..=b'9', remaining @ ..] => {
                let digit = byte.saturating_sub(b'0');
                let arc = match self.current_arc {
                    Some(arc) => arc,
                    None => 0,
                };

                // TODO(tarcieri): use `and_then` when const traits are stable
                self.current_arc = match arc.checked_mul(10) {
                    Some(arc) => match arc.checked_add(digit as Arc) {
                        None => return Err(Error::ArcTooBig),
                        Some(arc) => Some(arc),
                    },
                    None => return Err(Error::ArcTooBig),
                };
                self.parse_bytes(remaining)
            }
            [b'.', remaining @ ..] => {
                match self.current_arc {
                    Some(arc) => {
                        if remaining.is_empty() {
                            return Err(Error::TrailingDot);
                        }

                        // TODO(tarcieri): use `?` when stable in `const fn`
                        match self.encoder.arc(arc) {
                            Ok(encoder) => {
                                self.encoder = encoder;
                                self.current_arc = None;
                                self.parse_bytes(remaining)
                            }
                            Err(err) => Err(err),
                        }
                    }
                    None => Err(Error::RepeatedDot),
                }
            }
            [byte, ..] => Err(Error::DigitExpected { actual: *byte }),
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::Parser;
    use crate::Error;

    #[test]
    fn parse() {
        let oid = Parser::parse("1.23.456").unwrap().finish().unwrap();
        assert_eq!(oid, "1.23.456".parse().unwrap());
    }

    #[test]
    fn reject_empty_string() {
        assert_eq!(Parser::parse("").err().unwrap(), Error::Empty);
    }

    #[test]
    fn reject_non_digits() {
        assert_eq!(
            Parser::parse("X").err().unwrap(),
            Error::DigitExpected { actual: b'X' }
        );

        assert_eq!(
            Parser::parse("1.2.X").err().unwrap(),
            Error::DigitExpected { actual: b'X' }
        );
    }

    #[test]
    fn reject_trailing_dot() {
        assert_eq!(Parser::parse("1.23.").err().unwrap(), Error::TrailingDot);
    }
}
