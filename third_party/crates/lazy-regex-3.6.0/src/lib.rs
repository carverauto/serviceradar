/*!

With lazy-regex macros, regular expressions

* are checked at compile time, with clear error messages
* are wrapped in `once_cell` lazy static initializers so that they're compiled only once
* can hold flags as suffix: `let case_insensitive_regex = regex!("ab*"i);`
* are defined in a less verbose way

The [`regex!`] macro returns references to normal instances of [`regex::Regex`] or [`regex::bytes::Regex`] so all the usual features are available.

But most often, you won't even use the `regex!` macro but the other macros which are specialized for testing a match, replacing, or capturing groups in some common situations:

* [Test a match](#test-a-match) with [`regex_is_match!`]
* [Extract a value](#extract-a-value) with [`regex_find!`]
* [Capture](#capture) with [`regex_captures!`]
* [Iter on captures](#iter-on-captures) with [`regex_captures_iter!`]
* [Replace with captured groups](#replace-with-captured-groups) with [`regex_replace!`] and [`regex_replace_all!`]
* [Remove part(s) of a string](#remove-part-of-a-string) with [`regex_remove!`] and [`regex_remove_all!`]
* [Switch over patterns](#switch-over-patterns) with [`regex_switch!`]

They support the `B` flag for the `regex::bytes::Regex` variant.

All macros exist with a `bytes_` prefix for building `bytes::Regex`, so you also have [`bytes_regex!`], [`bytes_regex_is_match!`], [`bytes_regex_find!`], [`bytes_regex_captures!`], [`bytes_regex_replace!`], [`bytes_regex_replace_all!`], and [`bytes_regex_switch!`].

Some structs of the regex crate are reexported to ease dependency managment.

# Build Regexes

Build a simple regex:

```rust
# use lazy_regex::regex;
let r = regex!("sa+$");
assert_eq!(r.is_match("Saa"), false);
```

Build a regex with flag(s):

```rust
# use lazy_regex::regex;
let r = regex!("sa+$"i);
assert_eq!(r.is_match("Saa"), true);
```
You can use a raw literal:

```rust
# use lazy_regex::regex;
let r = regex!(r#"^"+$"#);
assert_eq!(r.is_match("\"\""), true);
```

Or a raw literal with flag(s):
```rust
# use lazy_regex::regex;
let r = regex!(r#"^\s*("[a-t]*"\s*)+$"#i);
assert_eq!(r.is_match(r#" "Aristote" "Platon" "#), true);
```

Build a regex that operates on `&[u8]`:
```rust
# use lazy_regex::regex;
let r = regex!("(byte)?string$"B);
assert_eq!(r.is_match(b"bytestring"), true);
```

There's no problem using the multiline definition syntax:
```rust
# use lazy_regex::regex;
let r = regex!(r"(?x)
    (?P<name>\w+)
    -
    (?P<version>[0-9.]+)
");
assert_eq!(r.find("This is lazy_regex-2.2!").unwrap().as_str(), "lazy_regex-2.2");
```

(look at the `regex_captures!` macro to easily extract the groups)

This line doesn't compile because the regex is invalid:
```compile_fail
let r = regex!("(unclosed");

```
Supported regex flags: [`i`, `m`, `s`, `x`, `U`][regex::RegexBuilder], and you may also use `B` to build a bytes regex.

The following regexes are equivalent:
* `bytes_regex!("^ab+$"i)`
* `bytes_regex!("(?i)^ab+$")`
* `regex!("^ab+$"iB)`
* `regex!("(?i)^ab+$"B)`

They're all case insensitive instances of `regex::bytes::Regex`.


# Test a match

```rust
# use lazy_regex::*;
let b = regex_is_match!("[ab]+", "car");
assert_eq!(b, true);
let b = bytes_regex_is_match!("[ab]+", b"car");
assert_eq!(b, true);
```

See [`regex_is_match!`]


# Extract a value

```rust
# use lazy_regex::regex_find;
let f_word = regex_find!(r"\bf\w+\b", "The fox jumps.");
assert_eq!(f_word, Some("fox"));
let f_word = regex_find!(r"\bf\w+\b"B, b"The forest is silent.");
assert_eq!(f_word, Some(b"forest" as &[u8]));
```

See [`regex_find!`]

# Capture

```rust
# use lazy_regex::regex_captures;
let (_, letter) = regex_captures!("([a-z])[0-9]+"i, "form A42").unwrap();
assert_eq!(letter, "A");

let (whole, name, version) = regex_captures!(
    r"(\w+)-([0-9.]+)", // a literal regex
    "This is lazy_regex-2.0!", // any expression
).unwrap();
assert_eq!(whole, "lazy_regex-2.0");
assert_eq!(name, "lazy_regex");
assert_eq!(version, "2.0");
```

There's no limit to the size of the tuple.
It's checked at compile time to ensure you have the right number of capturing groups.

You receive `""` for optional groups with no value.

See [`regex_captures!`]

# Iter on captures

```rust
# use lazy_regex::regex_captures_iter;
let hay = "'Citizen Kane' (1941), 'The Wizard of Oz' (1939), 'M' (1931).";
let mut movies = vec![];
let iter = regex_captures_iter!(r"'([^']+)'\s+\(([0-9]{4})\)", hay);
for (_, [title, year]) in iter.map(|c| c.extract()) {
    movies.push((title, year.parse::<i64>().unwrap()));
}
assert_eq!(movies, vec![
    ("Citizen Kane", 1941),
    ("The Wizard of Oz", 1939),
    ("M", 1931),
]);
```

See [`regex_captures_iter!`]

# Replace with captured groups

The [`regex_replace!`] and [`regex_replace_all!`] macros bring once compilation and compilation time checks to the `replace` and `replace_all` functions.

## Replace with a closure

```rust
# use lazy_regex::regex_replace_all;
let text = "Foo8 fuu3";
let text = regex_replace_all!(
    r"\bf(\w+)(\d)"i,
    text,
    |_, name, digit| format!("F<{}>{}", name, digit),
);
assert_eq!(text, "F<oo>8 F<uu>3");
```
The number of arguments given to the closure is checked at compilation time to match the number of groups in the regular expression.

If it doesn't match you get a clear error message at compilation time.

## Replace with another kind of Replacer

```rust
# use lazy_regex::regex_replace_all;
let text = "UwU";
let output = regex_replace_all!("U", text, "O");
assert_eq!(&output, "OwO");
```

# Remove part of a string

[`regex_remove!`] is cleaner than using `regex_replace!` with an empty string.

Contrary to `replace`, lazy-regex removing macros don't allocate a new string if the match is at an end of the input, which makes it especially useful for trimming suffixes or prefixes.

```rust
# use lazy_regex::regex_remove;
let text = "lazy-regex-3.5.0";
let name = regex_remove!(
    r"-[0-9]+(\.[0-9]+)*$",
    text,
);
assert_eq!(name, "lazy-regex");
assert!(matches!(name, std::borrow::Cow::Borrowed(_)));
```

You can also remove all matches of a regex with [`regex_remove_all!`].

```rust
# use lazy_regex::regex_remove_all;
assert_eq!(
    regex_remove_all!(r"\s+", "    ab  c    d  e    "),
    "abcde"
);
```

Whenever possible, no new string is allocated and a borrowed slice is returned, even when several matches are removed
(if they're all either at the start or end of the text).

```rust
# use lazy_regex::regex_remove_all;
let input = "154681string63731";
let output = regex_remove_all!(r"\d", input);
assert_eq!(output, "string");
assert!(matches!(output, std::borrow::Cow::Borrowed("string")));
```

# Switch over patterns

Execute the expression bound to the first matching regex, with named captured groups declared as variables:

```rust
use lazy_regex::regex_switch;
#[derive(Debug, PartialEq)]
pub enum ScrollCommand {
    Top,
    Bottom,
    Lines(i32),
    Pages(i32),
    JumpTo(String),
}
impl std::str::FromStr for ScrollCommand {
    type Err = &'static str;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        regex_switch!(s,
            "^scroll-to-top$" => Self::Top,
            "^scroll-to-bottom$" => Self::Bottom,
            r"^scroll-lines?\((?<n>[+-]?\d{1,4})\)$" => Self::Lines(n.parse().unwrap()),
            r"^scroll-pages?\((?<n>[+-]?\d{1,4})\)$" => Self::Pages(n.parse().unwrap()),
            r"^jump-to\((?<name>\w+)\)$" => Self::JumpTo(name.to_string()),
        ).ok_or("unknown command")
    }
}
assert_eq!("scroll-lines(42)".parse(), Ok(ScrollCommand::Lines(42)));
assert_eq!("scroll-lines(XLII)".parse::<ScrollCommand>(), Err("unknown command"));
```

See [`regex_switch!`]

# Shared lazy static

When a regular expression is used in several functions, you sometimes don't want
to repeat it but have a shared static instance.

The [`regex!`] macro, while being backed by a lazy static regex, returns a reference.

If you want to have a shared lazy static regex, use the [`lazy_regex!`] macro:

```rust
# use lazy_regex::*;

pub static GLOBAL_REX: Lazy<Regex> = lazy_regex!("^ab+$"i);
```

Like for the other macros, the regex is static, checked at compile time, and lazily built at first use.

See [`lazy_regex!`]

*/

mod remove;

pub use {
    lazy_regex_proc_macros::{
        lazy_regex,
        regex,
        regex_captures,
        regex_captures_iter,
        regex_find,
        regex_if,
        regex_is_match,
        regex_replace,
        regex_replace_all,
        regex_switch,
        bytes_lazy_regex,
        bytes_regex,
        bytes_regex_captures,
        bytes_regex_find,
        bytes_regex_if,
        bytes_regex_is_match,
        bytes_regex_replace,
        bytes_regex_replace_all,
        bytes_regex_switch,
    },
    once_cell::sync::Lazy,
    remove::{
        remove_match,
        remove_all_matches,
    },
};

#[cfg(not(feature = "lite"))]
pub use {
    regex::{
        self,
        Captures, Regex, RegexBuilder,
        bytes::{
            Regex as BytesRegex,
            RegexBuilder as BytesRegexBuilder
        },
    },
    remove::{
        bytes_remove_match,
        bytes_remove_all_matches,
    },
};

#[cfg(feature = "lite")]
pub use {
    regex_lite::{
        self as regex,
        Captures, Regex, RegexBuilder,
    },
};

/// Remove the first match of a regex from the text, returning a borrowed slice when possible
///
/// ```rust
/// # use lazy_regex::regex_remove;
/// let name = regex_remove!(
///     r"-[0-9]+(\.[0-9]+)*$",
///      "lazy-regex-3.5.2",
/// );
/// assert_eq!(name, "lazy-regex");
/// assert!(matches!(name, std::borrow::Cow::Borrowed(_)));
/// ```
#[macro_export]
macro_rules! regex_remove {
    ($rex:tt, $text:expr $(,)?) => {{
        let rex = $crate::regex!($rex);
        $crate::remove_match(
            &rex,
            $text,
        )
    }};
}

#[macro_export]
#[cfg(not(feature = "lite"))]
macro_rules! bytes_regex_remove {
    ($rex:tt, $text:expr $(,)?) => {{
        let rex = $crate::bytes_regex!($rex);
        $crate::bytes_remove_match(
            &rex,
            $text,
        )
    }};
}

/// Remove all matches of a regex from the text
///
/// ```rust
/// # use lazy_regex::regex_remove_all;
/// assert_eq!(
///     regex_remove_all!(r"\s+", "    ab  c    d  e    "),
///     "abcde"
/// );
/// ```
///
/// Whenever possible, no new string is allocated and a borrowed slice is returned, even when several matches are removed
/// (if they're all either at the start or end of the text).
///
/// ```rust
/// # use lazy_regex::regex_remove_all;
/// let input = "154681string63731";
/// let output = regex_remove_all!(r"\d", input);
/// assert_eq!(output, "string");
/// assert!(matches!(output, std::borrow::Cow::Borrowed("string")));
/// ```
#[macro_export]
macro_rules! regex_remove_all {
    ($rex:tt, $text:expr $(,)?) => {{
        let rex = $crate::regex!($rex);
        $crate::remove_all_matches(
            &rex,
            $text,
        )
    }};
}

#[macro_export]
macro_rules! bytes_regex_remove_all {
    ($rex:tt, $text:expr $(,)?) => {{
        let rex = $crate::bytes_regex!($rex);
        $crate::bytes_remove_all_matches(
            &rex,
            $text,
        )
    }};
}

