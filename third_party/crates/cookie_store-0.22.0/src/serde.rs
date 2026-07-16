//! De/serialization functionality
//! Requires feature `serde`

use std::io::{BufRead, Write};

use crate::{Cookie, cookie_store::StoreResult, CookieStore};

#[cfg(feature = "serde_json")]
pub mod json;
#[cfg(feature = "serde_ron")]
pub mod ron;

/// Load cookies from `reader`, deserializing with `cookie_from_str`, skipping any __expired__
/// cookies
pub fn load<R, E, F>(reader: R, cookies_from_str: F) -> StoreResult<CookieStore>
    where
    R: BufRead,
    F: Fn(&str) -> Result<Vec<Cookie<'static>>, E>,
    crate::Error: From<E>,
{
    load_from(reader, cookies_from_str, false)
}

/// Load cookies from `reader`, deserializing with `cookie_from_str`, loading both __unexpired__
/// and __expired__ cookies
pub fn load_all<R, E, F>(reader: R, cookies_from_str: F) -> StoreResult<CookieStore>
    where
    R: BufRead,
    F: Fn(&str) -> Result<Vec<Cookie<'static>>, E>,
    crate::Error: From<E>,
{
    load_from(reader, cookies_from_str, true)
}

fn load_from<R, E, F>(
    mut reader: R,
    cookies_from_str: F,
    include_expired: bool,
) -> StoreResult<CookieStore>
    where
    R: BufRead,
    F: Fn(&str) -> Result<Vec<Cookie<'static>>, E>,
    crate::Error: From<E>,
{
    let mut cookie_store = String::new();
    reader.read_to_string(&mut cookie_store)?;
    let cookies = cookies_from_str(&cookie_store)?;
    CookieStore::from_cookies(
        cookies.into_iter().map(|cookies| Ok(cookies)),
        include_expired,
    )
}

/// Serialize any __unexpired__ and __persistent__ cookies in the store with `cookie_to_string`
/// and write them to `writer`
pub fn save<W, E, F>(
    cookie_store: &CookieStore,
    writer: &mut W,
    cookies_to_string: F,
) -> StoreResult<()>
    where
    W: Write,
    F: Fn(&Vec<Cookie<'static>>) -> Result<String, E>,
    crate::Error: From<E>,
{
    let mut cookies = Vec::new();
    for cookie in cookie_store.iter_unexpired() {
        if cookie.is_persistent() {
            cookies.push(cookie.clone());
        }
    }
    let cookies = cookies_to_string(&cookies);
    writeln!(writer, "{}", cookies?)?;
    Ok(())
}

/// Serialize all (including __expired__ and __non-persistent__) cookies in the store with `cookie_to_string` and write them to `writer`
pub fn save_incl_expired_and_nonpersistent<W, E, F>(
    cookie_store: &CookieStore,
    writer: &mut W,
    cookies_to_string: F,
) -> StoreResult<()>
    where
    W: Write,
    F: Fn(&Vec<Cookie<'static>>) -> Result<String, E>,
    crate::Error: From<E>,
{
    let mut cookies = Vec::new();
    for cookie in cookie_store.iter_any() {
        cookies.push(cookie.clone());
    }
    let cookies = cookies_to_string(&cookies);
    writeln!(writer, "{}", cookies?)?;
    Ok(())
}
