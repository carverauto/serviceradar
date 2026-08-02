use ahash::AHashMap;
use once_cell::sync::Lazy;
use serde_json::{from_str, Value};

pub(crate) type ContentMediaTypeCheckType = fn(&str) -> bool;

pub(crate) fn is_json(instance_string: &str) -> bool {
    from_str::<Value>(instance_string).is_ok()
}

pub(crate) static DEFAULT_CONTENT_MEDIA_TYPE_CHECKS: Lazy<
    AHashMap<&'static str, ContentMediaTypeCheckType>,
> = Lazy::new(|| {
    let mut map: AHashMap<&'static str, ContentMediaTypeCheckType> = AHashMap::with_capacity(1);
    map.insert("application/json", is_json);
    map
});
