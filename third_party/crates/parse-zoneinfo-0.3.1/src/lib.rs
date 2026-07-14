//! Rust library for reading the text files comprising the [zoneinfo
//! database][w], which records time zone changes and offsets across the world
//! from multiple sources.
//!
//! The zoneinfo database is distributed in one of two formats: a raw text
//! format with one file per continent, and a compiled binary format with one
//! file per time zone. This crate deals with the former; for the latter, see
//! the [`zoneinfo_compiled` crate][zc] instead.
//!
//! The database itself is maintained by IANA. For more information, see
//! [IANA’s page on the time zone database][iana]. You can also find the text
//! files themselves in [the tz repository][tz].
//!
//! [iana]: https://www.iana.org/time-zones
//! [tz]: https://github.com/eggert/tz
//! [w]: https://en.wikipedia.org/wiki/Tz_database
//! [zc]: https://github.com/rust-datetime/zoneinfo-compiled
//!
//! ## Outline
//!
//! Reading a zoneinfo text file is split into three stages:
//!
//! - **Parsing** individual lines of text into `Lines` is done by the `line`
//!   module;
//! - **Interpreting** these lines into a complete `Table` is done by the
//!   `table` module;
//! - **Calculating transitions** from this table is done by the `transitions`
//!   module.

#![warn(missing_copy_implementations)]
//#![warn(missing_docs)]
#![warn(nonstandard_style)]
#![warn(trivial_numeric_casts)]
#![warn(unreachable_pub)]
#![warn(unused)]

pub mod line;
pub mod structure;
pub mod table;
pub mod transitions;
