# parse-zoneinfo

[![parse-zoneinfo GitHub Actions][gh-image]][gh-checks]
[![parse-zoneinfo on crates.io][cratesio-image]][cratesio]
[![parse-zoneinfo on docs.rs][docsrs-image]][docsrs]
[![Chat][discord-image]][discord]

[gh-image]: https://github.com/chronotope/chrono-tz/actions/workflows/rust.yml/badge.svg
[gh-checks]: https://github.com/chronotope/chrono-tz/actions/workflows/rust.yml
[cratesio-image]: https://img.shields.io/crates/v/parse-zoneinfo.svg
[cratesio]: https://crates.io/crates/parse-zoneinfo
[docsrs-image]: https://docs.rs/parse-zoneinfo/badge.svg
[docsrs]: https://docs.rs/parse-zoneinfo
[discord-image]: https://img.shields.io/discord/976380008299917365?logo=discord
[discord]: https://discord.gg/sXpav4PS7M

Rust library for reading the text files comprising the [zoneinfo database], which records time zone changes and offsets across the world from multiple sources.

The zoneinfo database is distributed in one of two formats: a raw text format with one file per continent, and a compiled binary format with one file per time zone. This crate deals with the text format.

The database itself is maintained by IANA. For more information, see [IANA’s page on the time zone database][iana]. You can also find the text files in [the tz repository][tz].

Parse-zoneinfo is a fork of [`zoneinfo_parse`] by Benjamin Sago (now unmaintained). It is used by [`chrono-tz`].

[iana]: https://www.iana.org/time-zones
[tz]: https://github.com/eggert/tz
[zoneinfo database]: https://en.wikipedia.org/wiki/Tz_database
[`zoneinfo_parse`]: https://crates.io/crates/zoneinfo_parse
[`chrono-tz`]: https://crates.io/crates/chrono-tz

## Rust version requirements

The Minimum Supported Rust Version (MSRV) is currently **Rust 1.57.0**.

# Usage

The zoneinfo files contains `Zone`, `Rule`, and `Link` information. Each type of line forms a variant in the `line::Line` enum.

To get started, here are a few lines representing what time is like in the `Europe/Madrid` time zone:
```
# Zone	NAME		GMTOFF	RULES	FORMAT	[UNTIL]
Zone	Europe/Madrid	-0:14:44 -	LMT	1901 Jan  1  0:00u
			 0:00	Spain	WE%sT	1940 Mar 16 23:00
			 1:00	Spain	CE%sT	1979
			 1:00	EU	CE%sT
```

The first line is a comment. The second starts with `Zone`, so we know

So parsing these five lines would return the five following results:

- A `line::Line::Space` for the comment, because the line doesn’t contain any information (but isn’t strictly *invalid* either).
- A `line::Line::Zone` for the first `Zone` entry. This contains a `Zone` struct that holds the name of the zone. All the other fields are stored in the `ZoneInfo` struct.
- A `line::Line::Continuation` for the next entry. This is different from the line above as it doesn’t contain a name field; it only has the information in a `ZoneInfo` struct.
- The fourth line contains the same types of data as the third.
- As does the fifth.

Lines with rule definitions look like this:
```
# Rule	NAME	FROM	TO	TYPE	IN	ON	AT	SAVE	LETTER/S
Rule	Spain	1918	only	-	Apr	15	23:00	1:00	S
Rule	Spain	1918	1919	-	Oct	 6	24:00s	0	-
Rule	Spain	1919	only	-	Apr	 6	23:00	1:00	S
Rule	Spain	1924	only	-	Apr	16	23:00	1:00	S
Rule	Spain	1924	only	-	Oct	 4	24:00s	0	-
```

All these lines follow the same pattern: A `line::Line::Rule` that contains a `Rule` struct, which has a field for each column of data.

Finally, there are lines that link one zone to another’s name:
```
# Link	TARGET			LINK-NAME	#= TARGET1
link	Australia/Sydney	Australia/ACT	#= Australia/Canberra
```

The `Link` struct simply contains the names of both the existing and new time zones.

## Interpretation

Once the input lines have been parsed, they must be *interpreted* to form a table of time zone data.

The easiest way to do this is with a `TableBuilder`. You can add various lines to the builder, and it will throw an error as soon as it detects that something’s wrong, such as a duplicate or a missing entry. When all the lines have been fed to the builder, you can use the `build` method to produce a `Table` containing fields for the rule, zone, and link lines.

## Example program

The `example` folder of this crate contains a basic parser example.

`parse-zoneinfo` is used to produce the data for [`chrono-tz`]. For a full example of its use see [`chrono-tz-build`].

[`chrono-tz-build`]: https://github.com/chronotope/chrono-tz/tree/main/chrono-tz-build

