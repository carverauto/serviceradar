use serde::{de, ser};
use std::error::Error;
use std::fmt;
use std::marker::PhantomData;
use std::ops::Deref;
use std::str::FromStr;

// === CharSetError === //

#[derive(Debug)]
pub struct CharSetError;

impl Error for CharSetError {}

impl fmt::Display for CharSetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        writeln!(f, "invalid charset")
    }
}

// === CharSet === //

pub trait CharSet {
    const NAME: &'static str;

    /// Checks whether a sequence is a valid string or not.
    fn check(data: &[u8]) -> bool;
}

// === RestrictedString === //

/// A generic restricted character string.
#[derive(Clone, Hash, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct RestrictedString<C> {
    data: Vec<u8>,
    marker: PhantomData<C>,
}

impl<C: CharSet> RestrictedString<C> {
    /// Create a new RestrictedString without CharSet validation.
    ///
    /// # Safety
    ///
    /// You have to make sure the right CharSet is used.
    pub unsafe fn new_unchecked<V>(data: V) -> Self
    where
        V: Into<Vec<u8>>,
    {
        RestrictedString {
            data: data.into(),
            marker: PhantomData,
        }
    }

    pub fn new<V>(data: V) -> Result<Self, CharSetError>
    where
        V: Into<Vec<u8>>,
    {
        let data = data.into();
        if !C::check(&data) {
            return Err(CharSetError);
        };
        Ok(RestrictedString {
            data,
            marker: PhantomData,
        })
    }

    /// Converts into underlying bytes.
    pub fn into_bytes(self) -> Vec<u8> {
        self.data
    }

    /// Returns underlying bytes.
    pub fn as_bytes(&self) -> &[u8] {
        &self.data
    }
}

impl<C: CharSet> Deref for RestrictedString<C> {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        &self.data
    }
}

impl<C: CharSet> AsRef<[u8]> for RestrictedString<C> {
    fn as_ref(&self) -> &[u8] {
        &self.data
    }
}

impl<C: CharSet> fmt::Debug for RestrictedString<C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}(", C::NAME)?;
        if let Ok(utf8) = std::str::from_utf8(&self.data) {
            fmt::Debug::fmt(utf8, f)?;
        } else {
            write!(f, "0x")?;
            self.data.iter().try_for_each(|byte| write!(f, "{byte:02X}"))?;
        }
        write!(f, ")")?;

        Ok(())
    }
}

impl<C: CharSet> fmt::Display for RestrictedString<C> {
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        fmt::Display::fmt(&String::from_utf8_lossy(&self.data), fmt)
    }
}

impl<C: CharSet> From<RestrictedString<C>> for Vec<u8> {
    fn from(rs: RestrictedString<C>) -> Self {
        rs.into_bytes()
    }
}

impl<'de, C> de::Deserialize<'de> for RestrictedString<C>
where
    C: CharSet,
{
    fn deserialize<D>(deserializer: D) -> Result<RestrictedString<C>, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Visitor<C>(std::marker::PhantomData<C>);

        impl<'de, C> de::Visitor<'de> for Visitor<C>
        where
            C: CharSet,
        {
            type Value = RestrictedString<C>;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a valid buffer representing a restricted string")
            }

            fn visit_bytes<E>(self, v: &[u8]) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                self.visit_byte_buf(v.to_vec())
            }

            fn visit_byte_buf<E>(self, v: Vec<u8>) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                RestrictedString::new(v).map_err(|_| {
                    E::invalid_value(
                        de::Unexpected::Other("invalid charset"),
                        &"a buffer representing a string using the right charset",
                    )
                })
            }
        }

        deserializer.deserialize_byte_buf(Visitor(std::marker::PhantomData))
    }
}

impl<C> ser::Serialize for RestrictedString<C> {
    fn serialize<S>(&self, serializer: S) -> Result<<S as ser::Serializer>::Ok, <S as ser::Serializer>::Error>
    where
        S: ser::Serializer,
    {
        serializer.serialize_bytes(&self.data)
    }
}

// === NumericString === //

/// 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, and SPACE
#[derive(Clone, Debug, Hash, PartialEq, Eq, PartialOrd, Ord)]
pub struct NumericCharSet;

impl CharSet for NumericCharSet {
    const NAME: &'static str = "NUMERIC";

    fn check(data: &[u8]) -> bool {
        for &c in data {
            if c != b' ' && !c.is_ascii_digit() {
                return false;
            }
        }
        true
    }
}

pub type NumericString = RestrictedString<NumericCharSet>;

impl NumericString {
    pub fn from_string(s: String) -> Result<Self, CharSetError> {
        Self::new(s.into_bytes())
    }

    pub fn as_utf8(&self) -> &str {
        core::str::from_utf8(self.as_bytes()).expect("valid UTF-8 subset")
    }

    pub fn into_string(self) -> String {
        String::from_utf8(self.into_bytes()).expect("valid UTF-8 subset")
    }
}

impl FromStr for NumericString {
    type Err = CharSetError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::new(s.as_bytes())
    }
}

// === PrintableString === //

/// a-z, A-Z, ' () +,-.?:/= and SPACE
#[derive(Clone, Debug, Hash, PartialEq, Eq, PartialOrd, Ord)]
pub struct PrintableCharSet;

impl CharSet for PrintableCharSet {
    const NAME: &'static str = "PRINTABLE";

    fn check(data: &[u8]) -> bool {
        for &c in data {
            if !(c.is_ascii_alphanumeric()
                || c == b' '
                || c == b'\''
                || c == b'('
                || c == b')'
                || c == b'+'
                || c == b','
                || c == b'-'
                || c == b'.'
                || c == b'/'
                || c == b':'
                || c == b'='
                || c == b'?')
            {
                return false;
            }
        }
        true
    }
}

pub type PrintableString = RestrictedString<PrintableCharSet>;

impl PrintableString {
    pub fn from_string(s: String) -> Result<Self, CharSetError> {
        Self::new(s.into_bytes())
    }

    pub fn as_utf8(&self) -> &str {
        core::str::from_utf8(self.as_bytes()).expect("valid UTF-8 subset")
    }

    pub fn into_string(self) -> String {
        String::from_utf8(self.into_bytes()).expect("valid UTF-8 subset")
    }
}

impl FromStr for PrintableString {
    type Err = CharSetError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::new(s.as_bytes())
    }
}

// === Utf8String === //

/// any character from a recognized alphabet (including ASCII control characters)
#[derive(Clone, Debug, Hash, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct Utf8CharSet;

impl CharSet for Utf8CharSet {
    const NAME: &'static str = "UTF8";

    fn check(data: &[u8]) -> bool {
        std::str::from_utf8(data).is_ok()
    }
}

pub type Utf8String = RestrictedString<Utf8CharSet>;

impl Utf8String {
    pub fn from_string(s: String) -> Result<Self, CharSetError> {
        Self::new(s.into_bytes())
    }

    pub fn as_utf8(&self) -> &str {
        core::str::from_utf8(self.as_bytes()).expect("valid UTF-8 subset")
    }

    pub fn into_string(self) -> String {
        String::from_utf8(self.into_bytes()).expect("valid UTF-8 subset")
    }
}

impl FromStr for Utf8String {
    type Err = CharSetError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::new(s.as_bytes())
    }
}

// === IA5String === //

/// First 128 ASCII characters (values from `0x00` to `0x7F`)
/// Used to represent ISO 646 (IA5) characters.
#[derive(Clone, Debug, Hash, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct Ia5CharSet;

impl CharSet for Ia5CharSet {
    const NAME: &'static str = "IA5";

    fn check(data: &[u8]) -> bool {
        for &c in data {
            if !c.is_ascii() {
                return false;
            }
        }
        true
    }
}

pub type Ia5String = RestrictedString<Ia5CharSet>;

#[deprecated = "Use IA5String instead"]
pub use Ia5String as IA5String;

impl Ia5String {
    pub fn from_string(s: String) -> Result<Self, CharSetError> {
        Self::new(s.into_bytes())
    }

    pub fn as_utf8(&self) -> &str {
        core::str::from_utf8(self.as_bytes()).expect("valid UTF-8 subset")
    }

    pub fn into_string(self) -> String {
        String::from_utf8(self.into_bytes()).expect("valid UTF-8 subset")
    }
}

impl FromStr for Ia5String {
    type Err = CharSetError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::new(s.as_bytes())
    }
}

// === BmpString === //

#[derive(Clone, Debug, Hash, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct BmpCharSet;

impl CharSet for BmpCharSet {
    const NAME: &'static str = "BMP";

    fn check(data: &[u8]) -> bool {
        // BMP strings are two-byte characters
        if data.len() % 2 != 0 {
            return false;
        }

        let chunk_it = data.chunks_exact(2);
        debug_assert!(chunk_it.remainder().is_empty());

        // Characters are encoded in big-endian
        let u16_it = chunk_it.map(|code_unit| u16::from_be_bytes([code_unit[0], code_unit[1]]));

        let mut count = 0;

        for res in char::decode_utf16(u16_it) {
            if res.is_err() {
                return false;
            }

            count += 1;
        }

        // Unlike UTF-16, BMP encoding is not a variable-length encoding.
        // (i.e.: BMP is only the first plane, "plane 0", of the Unicode standard.)
        count == data.len() / 2
    }
}

pub type BmpString = RestrictedString<BmpCharSet>;

#[deprecated = "Use BmpString instead"]
pub use BmpString as BMPString;

impl BmpString {
    pub fn to_utf8(&self) -> String {
        let chunk_it = self.as_bytes().chunks_exact(2);
        debug_assert!(chunk_it.remainder().is_empty());
        let u16_it = chunk_it.map(|code_unit| u16::from_be_bytes([code_unit[0], code_unit[1]]));
        char::decode_utf16(u16_it)
            .map(|res| res.expect("valid code point"))
            .collect()
    }
}

impl FromStr for BmpString {
    type Err = CharSetError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let data: Vec<u8> = s.encode_utf16().flat_map(|code_unit| code_unit.to_be_bytes()).collect();
        Self::new(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_printable_string() {
        PrintableString::from_str("29INRUSAET3snre?:=tanui83  9283019").expect("valid string");
    }

    #[test]
    fn invalid_printable_string() {
        assert!(PrintableString::from_str("1224na÷日本語はむずかちー−×—«BUeisuteurnt").is_err());
    }

    #[test]
    fn valid_numeric_string() {
        NumericString::from_str("2983  9283019").expect("valid string");
    }

    #[test]
    fn invalid_numeric_string() {
        assert!(NumericString::from_str("1224na÷日本語はむずかちー−×—«BUeisuteurnt").is_err());
    }

    #[test]
    fn valid_ia5_string() {
        Ia5String::from_str("BUeisuteurnt").expect("valid string");
    }

    #[test]
    fn invalid_ia5_string() {
        assert!(Ia5String::from_str("BUéisuteurnt").is_err());
    }

    #[test]
    fn valid_utf8_string() {
        Utf8String::from_str("1224na÷日本語はむずかちー−×—«BUeisuteurnt").expect("valid string");
    }

    #[test]
    fn valid_bmp_string() {
        assert_eq!(
            BmpString::from_str("语言处理").expect("valid BMP string").to_utf8(),
            "语言处理"
        );

        assert_eq!(
            BmpString::new(vec![
                0x00, 0x43, 0x00, 0x65, 0x00, 0x72, 0x00, 0x74, 0x00, 0x69, 0x00, 0x66, 0x00, 0x69, 0x00, 0x63, 0x00,
                0x61, 0x00, 0x74, 0x00, 0x65, 0x00, 0x54, 0x00, 0x65, 0x00, 0x6d, 0x00, 0x70, 0x00, 0x6c, 0x00, 0x61,
                0x00, 0x74, 0x00, 0x65,
            ])
            .expect("valid BMP string")
            .to_utf8(),
            "CertificateTemplate"
        );

        assert_eq!(
            BmpString::new(vec![0x00, 0x55, 0x00, 0x73, 0x00, 0x65, 0x00, 0x72])
                .expect("valid BMP string")
                .to_utf8(),
            "User"
        );
    }

    #[test]
    fn invalid_bmp_string() {
        assert!(BmpString::new("1224na÷日本語はむずかちー−×—«BUeisuteurnt".as_bytes()).is_err())
    }
}
