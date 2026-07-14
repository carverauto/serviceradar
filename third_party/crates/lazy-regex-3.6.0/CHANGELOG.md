
<a name="v3.6.0"></a>
### v3.6.0 - 2026-02-11
- `regex_remove_all!` and `bytes_regex_remove_all!`
- MSRV updated to 1.71

<a name="v3.5.1"></a>
### v3.5.1 - 2026-01-04
- `regex_remove!` and `bytes_regex_remove!`

<a name="v3.4.1"></a>
### v3.4.1 - 2024-12-27
- regex_captures_iter! macro - Fix #37

<a name="v3.3.0"></a>
### v3.3.0 - 2024-08-23
- revert a change regarding dependencies & features, brought with 3.2.0, which proved to be unconvenient for configuration with no default features - Fix #36

<a name="v3.2.0"></a>
### v3.2.0 - 2024-07-25
- `regex_if!` and `bytes_regex_if!`
- `regex_switch!` and `bytes_regex_switch!`

<a name="v3.1.0"></a>
### v3.1.0 - 2023-11-09
- bytes_ prefixed macros create instances of `bytes::Regex` - Fix #30

<a name="v3.0.2"></a>
### v3.0.2 - 2023-09-12
- replace macros now accept a mut closure as replacer - Fix #27

<a name="v3.0.1"></a>
### v3.0.1 - 2023-07-28
- syn dependency updated to 2.0

<a name="v3.0.0"></a>
### v3.0.0 - 2023-07-07
- the `lite` feature switches the engine to `regex-lite` instead of `regex`. The whole regex|regex-lite crate is reexported under `lazy_regex::regex`
- regex crate upgraded to 1.9

<a name="v2.5.0"></a>
### v2.5.0 - 2023-03-09
- `replace!` and `replace_all!` now supports non closure replacers - Fix #19

<a name="v2.4.1"></a>
### v2.4.1 - 2023-01-05
- rustc minimal version downgraded from 1.65 to to 1.56 by popular demand

<a name="v2.4.0"></a>
### v2.4.0 - 2023-01-04
- allow building with `--no-default-features`
- regex crate upgraded from 1.5 to 1.7 (minor Unicode changes)
- rustc minimal version now 1.65

<a name="v2.3.1"></a>
### v2.3.1 - 2022-11-03
- better error messages on bad regexes - thanks @necauqua

<a name="v2.3.0"></a>
### v2.3.0 - 2022-03-05
- support for [bytes](https://docs.rs/regex/latest/regex/bytes/index.html) regexes with the `B` suffix notation - thanks @bnoctis - Fix #11

<a name="v2.2.2"></a>
### v2.2.2 - 2021-10-20
Reexpose features of the regex crate

<a name="v2.2.1"></a>
### v2.2.1 - 2021-06-07
Add the `regex_replace!` macro for when you only want to replace one match
Reexports more types of the regex crates

<a name="v2.2.0"></a>
### v2.2.0 - 2021-06-04
Add the `regex_replace_all!` macro to do replacements with a closure taking the right number of `&str` arguments according to the number of groups in the regular expression

<a name="v2.1.0"></a>
### v2.1.0 - 2021-06-02
Add the `lazy_regex!` macro returning a `Lazy<Regex>` for easy use in a `pub static` shared declaration.

<a name="v2.0.2"></a>
### v2.0.2 - 2021-05-31
Fix a cross compilation problem, thanks @AlephAlpha - Fix #5

<a name="v2.0.1"></a>
### v2.0.1 - 2021-05-20
Improved documentation

<a name="v2.0.0"></a>
### v2.0.0 - 2021-05-17
- regular expressions are now checked at compile time
- regex_is_match!
- regex_find!
- regex_captures!

<a name="v1.1.0"></a>
### v1.1.0 - 2021-05-08
- no more complementary import needed
- now based on once_cell instead of lazy_static

<a name="v1.0.0"></a>
### v1.0.0 - 2021-05-04
- first public release
