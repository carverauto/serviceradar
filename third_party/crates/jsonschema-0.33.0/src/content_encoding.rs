use crate::error::ValidationError;
use ahash::AHashMap;
use base64::{engine::general_purpose, Engine as _};
use once_cell::sync::Lazy;

pub(crate) type ContentEncodingCheckType = fn(&str) -> bool;
pub(crate) type ContentEncodingConverterType =
    fn(&str) -> Result<Option<String>, ValidationError<'static>>;

pub(crate) fn is_base64(instance_string: &str) -> bool {
    general_purpose::STANDARD.decode(instance_string).is_ok()
}

pub(crate) fn from_base64(
    instance_string: &str,
) -> Result<Option<String>, ValidationError<'static>> {
    match general_purpose::STANDARD.decode(instance_string) {
        Ok(value) => Ok(Some(String::from_utf8(value)?)),
        Err(_) => Ok(None),
    }
}

pub(crate) static DEFAULT_CONTENT_ENCODING_CHECKS_AND_CONVERTERS: Lazy<
    AHashMap<&'static str, (ContentEncodingCheckType, ContentEncodingConverterType)>,
> = Lazy::new(|| {
    let mut map: AHashMap<&'static str, (ContentEncodingCheckType, ContentEncodingConverterType)> =
        AHashMap::with_capacity(1);
    map.insert("base64", (is_base64, from_base64));
    map
});
