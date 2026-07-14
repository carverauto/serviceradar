use crate::{asn1_string, TestValidCharset};
use crate::{Error, Result};
#[cfg(not(feature = "std"))]
use alloc::string::String;

asn1_string!(NumericString);

impl TestValidCharset for NumericString<'_> {
    fn test_valid_charset(i: &[u8]) -> Result<()> {
        #[allow(clippy::trivially_copy_pass_by_ref)]
        fn is_numeric(b: &u8) -> bool {
            matches!(*b, b'0'..=b'9' | b' ')
        }
        if !i.iter().all(is_numeric) {
            return Err(Error::StringInvalidCharset);
        }
        Ok(())
    }
}
