use alloc::string::String;

use crate::Result;

#[cfg(feature = "std")]
pub(super) type OsString = std::ffi::OsString;
#[cfg(not(feature = "std"))]
pub(super) type OsString = String;

#[cfg(not(feature = "std"))]
pub(crate) fn string_from_os(string: String) -> Result<String> {
    Ok(string)
}

#[cfg(feature = "std")]
pub(crate) fn string_from_os(string: OsString) -> Result<String> {
    use crate::Error;

    #[cfg(any(
        all(not(target_os = "windows"), not(target_arch = "wasm32")),
        all(
            target_arch = "wasm32",
            target_os = "wasi",
            not(target_env = "p2")
        ),
    ))]
    {
        #[cfg(not(target_os = "wasi"))]
        use std::os::unix::ffi::OsStringExt;
        #[cfg(target_os = "wasi")]
        use std::os::wasi::ffi::OsStringExt;
        use std::string::ToString;

        String::from_utf8(string.into_vec())
            .map_err(|e| Error::with_invalid_data(e.to_string()))
    }

    #[cfg(any(
        target_os = "windows",
        all(target_arch = "wasm32", not(target_os = "wasi")),
        all(target_arch = "wasm32", target_os = "wasi", target_env = "p2"),
    ))]
    {
        string
            .into_string()
            .map_err(|_| Error::with_invalid_data("Not valid unicode"))
    }
}
