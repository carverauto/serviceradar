use percent_encoding::{AsciiSet, NON_ALPHANUMERIC};

// Headers used in azure services.
pub const X_MS_DATE: &str = "x-ms-date";
#[allow(dead_code)]
pub const CONTENT_MD5: &str = "content-md5";

pub static AZURE_QUERY_ENCODE_SET: AsciiSet = NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'/')
    .remove(b'~');
