//! De/serialization via the JSON format
//! Requires feature `serde_json`

use std::io::{BufRead, Write};

use crate::cookie_store::{StoreResult, CookieStore};

/// Load JSON-formatted cookies from `reader`, skipping any __expired__ cookies.
/// __NB__: This function is not compatible with data produced by [CookieStore::save_json] or
/// [CookieStore::save_incl_expired_and_nonpersistent_json].
pub fn load<R: BufRead>(reader: R) -> StoreResult<CookieStore> {
    super::load(reader, |cookies| serde_json::from_str(cookies))
}

/// Load JSON-formatted cookies from `reader`, loading both __expired__ and __unexpired__ cookies.
/// __NB__: This function is not compatible with data produced by [CookieStore::save_json] or
/// [CookieStore::save_incl_expired_and_nonpersistent_json].
pub fn load_all<R: BufRead>(reader: R) -> StoreResult<CookieStore> {
    super::load_all(reader, |cookies| serde_json::from_str(cookies))
}

/// Serialize any __unexpired__ and __persistent__ cookies in the store to JSON format and
/// write them to `writer`.
/// __NB__: This function does not produce data compatible with [CookieStore::load_json] or
/// [CookieStore::load_json_all].
pub fn save<W: Write>(cookie_store: &CookieStore, writer: &mut W) -> StoreResult<()> {
    super::save(cookie_store, writer, ::serde_json::to_string_pretty)
}

/// Serialize all (including __expired__ and __non-persistent__) cookies in the store to JSON format and write them to `writer`.
/// __NB__: This function does not produce data compatible with [CookieStore::load_json] or
/// [CookieStore::load_json_all].
pub fn save_incl_expired_and_nonpersistent<W: Write>(
    cookie_store: &CookieStore,
    writer: &mut W,
) -> StoreResult<()> {
    super::save_incl_expired_and_nonpersistent(cookie_store, writer, ::serde_json::to_string_pretty)
}

#[cfg(test)]
mod tests {
    use std::io::BufWriter;

    use super::{ save_incl_expired_and_nonpersistent, save };

    use super::{ load, load_all };

    fn cookie() -> String {
        r#"[
  {
    "raw_cookie": "2=two; SameSite=None; Secure; Path=/; Expires=Tue, 03 Aug 2100 00:38:37 GMT",
    "path": [
      "/",
      true
    ],
    "domain": {
      "HostOnly": "test.com"
    },
    "expires": {
      "AtUtc": "2100-08-03T00:38:37Z"
    }
  }
]
"#
            .to_string()
    }

    fn cookie_expired() -> String {
        r#"[
  {
    "raw_cookie": "1=one; SameSite=None; Secure; Path=/; Expires=Thu, 03 Aug 2000 00:38:37 GMT",
    "path": [
      "/",
      true
    ],
    "domain": {
      "HostOnly": "test.com"
    },
    "expires": {
      "AtUtc": "2000-08-03T00:38:37Z"
    }
  }
]
"#
            .to_string()
    }

    #[test]
    fn check_count() {
        let cookie = cookie();

        let cookie_store = load(Into::<&[u8]>::into(cookie.as_bytes())).unwrap();
        assert_eq!(cookie_store.iter_any().map(|_| 1).sum::<i32>(), 1);
        assert_eq!(cookie_store.iter_unexpired().map(|_| 1).sum::<i32>(), 1);

        let cookie_store_all = load_all(Into::<&[u8]>::into(cookie.as_bytes())).unwrap();
        assert_eq!(cookie_store_all.iter_any().map(|_| 1).sum::<i32>(), 1);
        assert_eq!(cookie_store_all.iter_unexpired().map(|_| 1).sum::<i32>(), 1);

        let mut writer = BufWriter::new(Vec::new());
        save(&cookie_store, &mut writer).unwrap();
        let string = String::from_utf8(writer.into_inner().unwrap()).unwrap();
        assert_eq!(cookie, string);

        let mut writer = BufWriter::new(Vec::new());
        save_incl_expired_and_nonpersistent(&cookie_store, &mut writer).unwrap();
        let string = String::from_utf8(writer.into_inner().unwrap()).unwrap();
        assert_eq!(cookie, string);

        let mut writer = BufWriter::new(Vec::new());
        save(&cookie_store_all, &mut writer).unwrap();
        let string = String::from_utf8(writer.into_inner().unwrap()).unwrap();
        assert_eq!(cookie, string);

        let mut writer = BufWriter::new(Vec::new());
        save_incl_expired_and_nonpersistent(&cookie_store_all, &mut writer).unwrap();
        let string = String::from_utf8(writer.into_inner().unwrap()).unwrap();
        assert_eq!(cookie, string);
    }

    #[test]
    fn check_count_expired() {
        let cookie = cookie_expired();

        let cookie_store = load(Into::<&[u8]>::into(cookie.as_bytes())).unwrap();
        assert_eq!(cookie_store.iter_any().map(|_| 1).sum::<i32>(), 0);
        assert_eq!(cookie_store.iter_unexpired().map(|_| 1).sum::<i32>(), 0);

        let cookie_store_all = load_all(Into::<&[u8]>::into(cookie.as_bytes())).unwrap();
        assert_eq!(cookie_store_all.iter_any().map(|_| 1).sum::<i32>(), 1);
        assert_eq!(cookie_store_all.iter_unexpired().map(|_| 1).sum::<i32>(), 0);

        let mut writer = BufWriter::new(Vec::new());
        save(&cookie_store, &mut writer).unwrap();
        let string = String::from_utf8(writer.into_inner().unwrap()).unwrap();
        assert_eq!("[]\n", string);

        let mut writer = BufWriter::new(Vec::new());
        save_incl_expired_and_nonpersistent(&cookie_store, &mut writer).unwrap();
        let string = String::from_utf8(writer.into_inner().unwrap()).unwrap();
        assert_eq!("[]\n", string);

        let mut writer = BufWriter::new(Vec::new());
        save(&cookie_store_all, &mut writer).unwrap();
        let string = String::from_utf8(writer.into_inner().unwrap()).unwrap();
        assert_eq!("[]\n", string);

        let mut writer = BufWriter::new(Vec::new());
        save_incl_expired_and_nonpersistent(&cookie_store_all, &mut writer).unwrap();
        let string = String::from_utf8(writer.into_inner().unwrap()).unwrap();
        assert_eq!(cookie, string);
    }
}
