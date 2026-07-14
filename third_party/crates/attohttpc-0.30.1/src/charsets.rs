//! This module is a clean re-export of the `encoding_rs` crate.
//! You can probably find the charset you need in here.

use encoding_rs::Encoding;

/// This type is an alias to the `encoding_rs::Encoding` type, used
/// to normalize the name across the crate.
pub type Charset = &'static Encoding;

pub use encoding_rs::{
    BIG5, EUC_JP, EUC_KR, GB18030, GBK, IBM866, ISO_2022_JP, ISO_8859_10, ISO_8859_13, ISO_8859_14, ISO_8859_15,
    ISO_8859_16, ISO_8859_2, ISO_8859_3, ISO_8859_4, ISO_8859_5, ISO_8859_6, ISO_8859_7, ISO_8859_8, ISO_8859_8_I,
    KOI8_R, KOI8_U, MACINTOSH, SHIFT_JIS, UTF_16BE, UTF_16LE, UTF_8, WINDOWS_1250, WINDOWS_1251, WINDOWS_1252,
    WINDOWS_1253, WINDOWS_1254, WINDOWS_1255, WINDOWS_1256, WINDOWS_1257, WINDOWS_1258, WINDOWS_874, X_MAC_CYRILLIC,
};
