//! Abstraction over Wasite - Terminal interface conventions for WASI

#![no_std]
#![forbid(unsafe_code)]
#![doc(
    html_logo_url = "https://ardaku.github.io/mm/logo.svg",
    html_favicon_url = "https://ardaku.github.io/mm/icon.svg",
    html_root_url = "https://docs.rs/wasite"
)]
#![warn(
    anonymous_parameters,
    missing_copy_implementations,
    missing_debug_implementations,
    missing_docs,
    nonstandard_style,
    rust_2018_idioms,
    single_use_lifetimes,
    trivial_casts,
    trivial_numeric_casts,
    unreachable_pub,
    unused_extern_crates,
    unused_qualifications,
    variant_size_differences
)]

extern crate alloc;

use alloc::string::String;
use core::num::NonZeroU16;

/// Type alias for [`Result`](core::result::Result)
pub type Result<T = (), E = Error> = core::result::Result<T, E>;

/// A Wasite Error
#[derive(Debug)]
pub struct Error(#[allow(dead_code)] wasi::io::streams::StreamError);

/// The language preferences of the [`User`]
#[derive(Debug)]
#[non_exhaustive]
pub struct Languages(String);

impl Languages {
    fn parse_all(&self) -> impl Iterator<Item = &str> {
        self.0.split(':')
    }

    /// Get language list for collation.
    pub fn collation(&self) -> impl Iterator<Item = &str> {
        self.parse_all()
            .filter_map(|l| l.strip_prefix("Collation="))
    }

    /// Get language list for character classes.
    pub fn char_class(&self) -> impl Iterator<Item = &str> {
        self.parse_all()
            .filter_map(|l| l.strip_prefix("CharClass="))
    }

    /// Get language list for monetary values.
    pub fn monetary(&self) -> impl Iterator<Item = &str> {
        self.parse_all().filter_map(|l| l.strip_prefix("Monetary="))
    }

    /// Get language list for messages.
    pub fn message(&self) -> impl Iterator<Item = &str> {
        self.parse_all().filter_map(|l| l.strip_prefix("Message="))
    }

    /// Get language list for numeric values.
    pub fn numeric(&self) -> impl Iterator<Item = &str> {
        self.parse_all().filter_map(|l| l.strip_prefix("Numeric="))
    }

    /// Get language list for time.
    pub fn time(&self) -> impl Iterator<Item = &str> {
        self.parse_all().filter_map(|l| l.strip_prefix("Time="))
    }

    /// Get language list for other.
    pub fn other(&self) -> impl Iterator<Item = &str> {
        self.parse_all().filter(|l| !l.contains('='))
    }
}

/// The `User` part of the [`Environment`]
#[derive(Debug)]
#[non_exhaustive]
pub struct User {
    /// The username of the current user
    pub username: String,
    /// The user's preferred languages
    pub langs: Languages,
}

/// The `Host` part of the [`Environment`]
#[derive(Debug)]
#[non_exhaustive]
pub struct Host {
    /// The pretty name of the host device
    pub name: String,
    /// The hostname of the host device
    pub hostname: String,
    /// The IANA TZDB identifier for the timezone (ex: `America/New_York`)
    pub timezone: String,
}

/// Information from environment variables
#[derive(Debug)]
#[non_exhaustive]
pub struct Environment {
    /// Information about the user
    pub user: User,
    /// Information about the host device
    pub host: Host,
}

/// Dimensions of the terminal of [`State`]
#[derive(Copy, Clone, Debug)]
#[non_exhaustive]
pub struct Dimensions {
    /// Width of the terminal
    pub width: NonZeroU16,
    /// Height of the terminal
    pub height: NonZeroU16,
}

/// Position of cursor of [`State`]
#[derive(Copy, Clone, Debug)]
#[non_exhaustive]
pub struct Cursor {
    /// Column of the cursor
    pub column: NonZeroU16,
    /// Line of the cursor
    pub line: NonZeroU16,
}

/// Terminal state
#[derive(Copy, Clone, Debug)]
#[non_exhaustive]
pub struct State {
    /// Dimensions of the terminal
    pub dimensions: Dimensions,
    /// Position of cursor
    pub cursor: Cursor,
}

/// Get environment variable information
pub fn environment() -> Environment {
    let mut env = Environment {
        user: User {
            username: String::new(),
            langs: Languages(String::new()),
        },
        host: Host {
            name: String::new(),
            hostname: String::new(),
            timezone: String::new(),
        },
    };

    for (key, value) in wasi::cli::environment::get_environment() {
        match key.as_str() {
            "USER" => env.user.username = value,
            "HOSTNAME" => env.host.hostname = value,
            "NAME" => env.host.name = value,
            "TZ" => env.host.timezone = value,
            "LANGS" => env.user.langs = Languages(value),
            _ => {}
        }
    }

    env
}

/// Get terminal state
pub fn state() -> Result<State> {
    let err = Err(Error(wasi::io::streams::StreamError::Closed));
    let stdout = wasi::cli::stdout::get_stdout();

    stdout.blocking_flush().map_err(Error)?;
    stdout.write(b"\x05").map_err(Error)?;

    // enquiry mode
    let stdin = wasi::cli::stdin::get_stdin();
    let bytes = stdin.read(24).map_err(Error)?;
    let string = String::from_utf8_lossy(&bytes);
    let mut parts = string.split(';');
    let Some(part_one) = parts.next() else {
        return err;
    };
    let Some(part_two) = parts.next() else {
        return err;
    };
    let mut cols = part_one.split('/');
    let Some(column) = cols.next() else {
        return err;
    };
    let Some(width) = cols.next() else {
        return err;
    };
    let mut row = part_two.split('/');
    let Some(line) = row.next() else {
        return err;
    };
    let Some(height) = row.next() else {
        return err;
    };

    // exit enquire mode
    stdout.write(b"\x06").map_err(Error)?;
    stdout.blocking_flush().map_err(Error)?;

    // Parse
    let Ok(column) = column.parse() else {
        return err;
    };
    let Ok(width) = width.parse() else {
        return err;
    };
    let Ok(line) = line.parse() else {
        return err;
    };
    let Ok(height) = height.parse() else {
        return err;
    };

    Ok(State {
        dimensions: Dimensions { width, height },
        cursor: Cursor { column, line },
    })
}

/// Terminal commands
#[non_exhaustive]
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
#[allow(variant_size_differences)]
pub enum Command<'a> {
    /// Clear the screen
    Clear,
    /// Flash the screen
    Alert,
    /// Turn raw mode on or off
    Raw(bool),
    /// Set the terminal title
    Title(&'a str),
    /// Turn alternate screen on or off (doesn't scroll)
    Screen(bool),
}

/// Execute terminal commands
pub fn execute(commands: &[Command<'_>]) -> Result {
    let stdout = wasi::cli::stdout::get_stdout();

    stdout.blocking_flush().map_err(Error)?;

    for command in commands {
        match command {
            Command::Clear => stdout.write(b"\x00").map_err(Error)?,
            Command::Alert => stdout.write(b"\x07").map_err(Error)?,
            Command::Raw(enabled) => {
                if *enabled {
                    stdout.write(b"\x03").map_err(Error)?;
                } else {
                    stdout.write(b"\x02").map_err(Error)?;
                }
            }
            Command::Title(title) => {
                stdout.write(b"\x01").map_err(Error)?;
                stdout.write(title.as_bytes()).map_err(Error)?;
                stdout.write(b"\x04").map_err(Error)?;
            }
            Command::Screen(enabled) => {
                if *enabled {
                    stdout.write(b"\x0F").map_err(Error)?;
                } else {
                    stdout.write(b"\x0E").map_err(Error)?;
                }
            }
        }
    }

    stdout.blocking_flush().map_err(Error)
}
