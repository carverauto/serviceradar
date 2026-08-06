# 0.0.5

- Use `NonZero<char/u8>` in `unescape_c_str` and `check_raw_c_str` to statically exclude nuls
- Add `#[inline]` to small functions for improved performance

# 0.0.4

- Add `check_raw_str`, `check_raw_byte_str`, `check_raw_c_str`,
- Add `unescape_str`, `unescape_byte_str`, `unescape_c_str`,
- Add `check_for_errors`,
- Remove: `unescape_unicode` and `unescape_mixed`

# 0.0.3

- Extend `rustc-dep-of-std` feature to include `libcore`

# 0.0.2

- Add new `rustc-dep-of-std` feature to allow building `libproc-macro`

# 0.0.1

- Add `EscapeError`, `MixedUnit` and `Mode` enums
- Add `byte_from_char`, `unescape_byte`, `unescape_char`, `unescape_mixed` and `unescape_unicode` functions
