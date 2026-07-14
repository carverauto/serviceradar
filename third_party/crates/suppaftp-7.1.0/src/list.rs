//! # List
//!
//! This module exposes the parser for the LIST command.
//! Please note that there's no guarantee this parser works and the reason is quite simple.
//! There's no specification regarding the LIST command output, so it basically depends on the implementation of the
//! remote FTP server. Despite this though, this parser, has worked on all the ftp server I've used.
//! If you find a variant which doesn't work with this parser,
//! please feel free to report an issue to <https://github.com/veeso/suppaftp>.
//!
//! This module also exposes the [`File`] type which represents a file entry on the remote system.
//! You can distinguish whether the entry is a file, a directory or a symlink by checking the appropriate methods on the [`File`] type or
//! by getting the [`FileType`] enum.
//!
//! ## Get started
//!
//! Whenever you receive the output for your LIST command, all you have to do is to iterate over lines and
//! call [`File::from_str`] function as shown in the example.
//!
//! ```rust
//! use suppaftp::list::{File, ListParser};
//!
//! // imagine this line received from a LIST command
//! let line = "-rw-r--r-- 1 user group 1234 Nov 5 13:46 example.txt";
//!
//! let file = ListParser::parse_posix(line).expect("failed to parse LIST line");
//!
//! assert_eq!(file.name(), "example.txt");
//! ```

mod file;
mod file_type;
mod pex;

use std::ops::Range;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use chrono::prelude::Utc;
use chrono::{Datelike, NaiveDate, NaiveDateTime};
use lazy_regex::{Lazy, Regex};
use thiserror::Error;

pub use self::file::File;
pub use self::file_type::FileType;
pub use self::pex::{PosixPex, PosixPexQuery};

/// POSIX system regex to parse list output
static POSIX_LS_RE: Lazy<Regex> = lazy_regex!(
    r#"^([\-ld])([\-rwxsStT]{9})\s+(\d+)\s+([^ ]+)\s+([^ ]+)\s+(\d+)\s+([^ ]+\s+\d{1,2}\s+(?:\d{1,2}:\d{1,2}|\d{4}))\s+(.+)$"#
);
/// DOS system regex to parse list output
static DOS_LS_RE: Lazy<Regex> =
    lazy_regex!(r#"^(\d{2}\-\d{2}\-\d{2}\s+\d{2}:\d{2}\s*[AP]M)\s+(<DIR>)?([\d,]*)\s+(.+)$"#);

/// Result type for parsing LIST lines
pub type ParseResult<T> = Result<T, ParseError>;

/// Errors that can occur when parsing a LIST line
#[derive(Debug, Error, Eq, PartialEq)]
pub enum ParseError {
    #[error("Syntax error: invalid line")]
    SyntaxError,
    #[error("Invalid date")]
    InvalidDate,
    #[error("Bad file size")]
    BadSize,
}

/// Parser for a line of the `LIST` command output
///
/// You can use this parser to parse a [`File`] from a **line** returned by the `LIST` command.
///
/// You can use either the [`ListParser::parse`] which tries to automatically detect the format (POSIX or DOS)
/// or you can use the more specific methods [`ListParser::parse_posix`] and [`ListParser::parse_dos`].
///
/// # Notes
///
/// The [`ListParser`] has since `7.1.0` replaced the [`File::from_posix_line`] and [`File::from_dos_line`] methods.
pub struct ListParser;

impl ListParser {
    /// Parse an output line from a MLSD command
    /// Returns a [`File`] instance if parsing is successful, otherwise returns a [`ParseError`].
    ///
    /// MLSD syntax has the following syntax:
    ///
    /// ```text
    /// type=dir;modify=20201019151930;UNIX.mode=0755;UNIX.uid=1000;UNIX.gid=1000; pub
    /// ```
    pub fn parse_mlsd(line: &str) -> ParseResult<File> {
        Self::parse_mlsx(line)
    }

    /// Parse an output line from a MLST command
    /// Returns a [`File`] instance if parsing is successful, otherwise returns a [`ParseError`].
    ///
    /// MLST syntax has the following syntax:
    ///
    /// ```text
    /// type=dir;modify=20201019151930;UNIX.mode=0755;UNIX.uid=1000;UNIX.gid=1000; pub
    /// ```
    pub fn parse_mlst(line: &str) -> ParseResult<File> {
        Self::parse_mlsx(line)
    }

    /// Parse an output line from a MLSD or MLST command
    /// Returns a [`File`] instance if parsing is successful, otherwise returns a [`ParseError`].
    ///
    /// MLSD/MLST syntax has the following syntax:
    ///
    /// ```text
    /// type=dir;modify=20201019151930;UNIX.mode=0755;UNIX.uid=1000;UNIX.gid=1000; pub
    /// ```
    fn parse_mlsx(line: &str) -> ParseResult<File> {
        let tokens = line.split(';').collect::<Vec<&str>>();
        if tokens.is_empty() {
            return Err(ParseError::SyntaxError);
        }
        let mut f = File {
            name: String::default(),
            file_type: FileType::File,
            size: 0,
            modified: SystemTime::UNIX_EPOCH,
            uid: None,
            gid: None,
            posix_pex: (
                PosixPex::from(0o7),
                PosixPex::from(0o7),
                PosixPex::from(0o7),
            ),
        };
        for token in tokens.iter() {
            let mut parts = token.split('=');
            let key = match parts.next() {
                Some(k) => k,
                None => continue,
            };
            let value = match parts.next() {
                Some(v) => v,
                None => continue,
            };
            match key.to_lowercase().as_str() {
                "type" => {
                    f.file_type = match value.to_lowercase().as_str() {
                        "dir" => FileType::Directory,
                        "file" => FileType::File,
                        "link" => FileType::Symlink(PathBuf::default()),
                        _ => return Err(ParseError::SyntaxError),
                    };
                }
                "size" => {
                    f.size = value.parse::<usize>().map_err(|_| ParseError::BadSize)?;
                }
                "modify" => {
                    f.modified = Self::parse_mlsx_time(value)?;
                }
                "unix.uid" => {
                    f.uid = value.parse::<u32>().ok();
                }
                "unix.gid" => {
                    f.gid = value.parse::<u32>().ok();
                }
                "unix.mode" => {
                    if value.len() != 3 {
                        return Err(ParseError::SyntaxError);
                    }
                    let chars = value.chars().collect::<Vec<char>>();
                    // convert to nums
                    let modes = chars
                        .iter()
                        .map(|c| c.to_digit(8).unwrap_or(0))
                        .collect::<Vec<u32>>();

                    f.posix_pex = (
                        PosixPex::from(modes[0] as u8),
                        PosixPex::from(modes[1] as u8),
                        PosixPex::from(modes[2] as u8),
                    );
                }
                _ => continue,
            }
        }

        // get name
        f.name = tokens.last().unwrap().trim_start().to_string();

        Ok(f)
    }

    /// Parse a POSIX LIST output line and if it is valid, return a [`File`] instance, otherwise return a [`ParseError`].
    ///
    /// POSIX syntax has the following syntax:
    ///
    /// ```text
    /// {FILE_TYPE}{PERMISSIONS} {LINK_COUNT} {USER} {GROUP} {FILE_SIZE} {MODIFIED_TIME} {FILENAME}
    /// -rw-r--r-- 1 user group 1234 Nov 5 13:46 example.txt
    /// ```
    pub fn parse_posix(line: &str) -> ParseResult<File> {
        // Apply regex to result
        match POSIX_LS_RE.captures(line) {
            // String matches regex
            Some(metadata) => {
                trace!("Parsed POSIX line {}", line);
                // NOTE: metadata fmt: (regex, file_type, permissions, link_count, uid, gid, filesize, mtime, filename)
                // Expected 7 + 1 (8) values: + 1 cause regex is repeated at 0
                if metadata.len() < 8 {
                    trace!("Bad syntax for posix line");
                    return Err(ParseError::SyntaxError);
                }
                // Collect metadata
                // Get if is directory and if is symlink
                let file_type: FileType = match metadata.get(1).unwrap().as_str() {
                    "-" => FileType::File,
                    "d" => FileType::Directory,
                    "l" => FileType::Symlink(PathBuf::default()),
                    _ => return Err(ParseError::SyntaxError), // This case is actually already covered by the regex
                };

                let pex = |range: Range<usize>| {
                    let mut count: u8 = 0;
                    for (i, c) in metadata.get(2).unwrap().as_str()[range].chars().enumerate() {
                        match c {
                            '-' | 'S' | 'T' => {}
                            _ => {
                                count += match i {
                                    0 => 4,
                                    1 => 2,
                                    2 => 1,
                                    _ => 0,
                                }
                            }
                        }
                    }
                    count
                };

                // Get posix pex
                let posix_pex: (PosixPex, PosixPex, PosixPex) = (
                    PosixPex::from(pex(0..3)),
                    PosixPex::from(pex(3..6)),
                    PosixPex::from(pex(6..9)),
                );

                // Parse mtime and convert to SystemTime
                let modified: SystemTime = Self::parse_lstime(
                    metadata.get(7).unwrap().as_str().trim(),
                    "%b %d %Y",
                    "%b %d %H:%M",
                )?;
                // Get gid
                let gid: Option<u32> = metadata.get(5).unwrap().as_str().trim().parse::<u32>().ok();
                // Get uid
                let uid: Option<u32> = metadata.get(4).unwrap().as_str().trim().parse::<u32>().ok();
                // Get filesize
                let size: usize = metadata
                    .get(6)
                    .unwrap()
                    .as_str()
                    .parse::<usize>()
                    .map_err(|_| ParseError::BadSize)?;
                // Split filename if required
                let (name, symlink_path): (String, Option<PathBuf>) = match file_type.is_symlink() {
                    true => Self::get_name_and_link(metadata.get(8).unwrap().as_str()),
                    false => (String::from(metadata.get(8).unwrap().as_str()), None),
                };
                // If symlink path is Some, assign symlink path to file_type
                let file_type: FileType = match symlink_path {
                    Some(p) => FileType::Symlink(p),
                    None => file_type,
                };
                trace!(
                    "Found file with name {}, type: {:?}, size: {}, uid: {:?}, gid: {:?}, pex: {:?}",
                    name, file_type, size, uid, gid, posix_pex
                );
                Ok(File {
                    name,
                    file_type,
                    size,
                    modified,
                    uid,
                    gid,
                    posix_pex,
                })
            }
            None => Err(ParseError::SyntaxError),
        }
    }

    /// Try to parse a "LIST" output command line in DOS format.
    /// Returns [`ParseError`] if syntax is not DOS compliant.
    /// DOS syntax has the following syntax:
    ///
    /// ```text
    /// {DATE} {TIME} {<DIR> | SIZE} {FILENAME}
    /// 10-19-20  03:19PM <DIR> pub
    /// 04-08-14  03:09PM 403   readme.txt
    /// ```
    pub fn parse_dos(line: &str) -> ParseResult<File> {
        // Apply regex to result
        match DOS_LS_RE.captures(line) {
            // String matches regex
            Some(metadata) => {
                trace!("Parsed DOS line {}", line);
                // NOTE: metadata fmt: (regex, date_time, is_dir?, file_size?, file_name)
                // Expected 4 + 1 (5) values: + 1 cause regex is repeated at 0
                if metadata.len() < 5 {
                    return Err(ParseError::SyntaxError);
                }
                // Parse date time
                let modified: SystemTime = Self::parse_dostime(metadata.get(1).unwrap().as_str())?;
                // Get if is a directory
                let file_type: FileType = match metadata.get(2).is_some() {
                    true => FileType::Directory,
                    false => FileType::File,
                };
                // Get file size
                let size: usize = match file_type.is_directory() {
                    true => 0, // If is directory, filesize is 0
                    false => match metadata.get(3) {
                        // If is file, parse arg 3
                        Some(val) => val
                            .as_str()
                            .parse::<usize>()
                            .map_err(|_| ParseError::BadSize)?,
                        None => 0,
                    },
                };
                // Get file name
                let name: String = String::from(metadata.get(4).unwrap().as_str());
                trace!(
                    "Found file with name {}, type: {:?}, size: {}",
                    name, file_type, size,
                );
                // Return entry
                Ok(File {
                    name,
                    file_type,
                    size,
                    modified,
                    uid: None,
                    gid: None,
                    posix_pex: (
                        PosixPex::default(),
                        PosixPex::default(),
                        PosixPex::default(),
                    ),
                })
            }
            None => Err(ParseError::SyntaxError), // Invalid syntax
        }
    }

    /// Returns from a `ls -l` command output file name token, the name of the file and the symbolic link (if there is any)
    fn get_name_and_link(token: &str) -> (String, Option<PathBuf>) {
        let tokens: Vec<&str> = token.split(" -> ").collect();
        let filename: String = String::from(*tokens.first().unwrap());
        let symlink: Option<PathBuf> = tokens.get(1).map(PathBuf::from);
        (filename, symlink)
    }

    /// Convert MLSD time to System Time
    fn parse_mlsx_time(tm: &str) -> Result<SystemTime, ParseError> {
        NaiveDateTime::parse_from_str(tm, "%Y%m%d%H%M%S")
            .map(|dt| {
                SystemTime::UNIX_EPOCH
                    .checked_add(Duration::from_secs(dt.and_utc().timestamp() as u64))
                    .unwrap_or(SystemTime::UNIX_EPOCH)
            })
            .map_err(|_| ParseError::InvalidDate)
    }

    /// Convert ls syntax time to System Time
    /// ls time has two possible syntax:
    /// 1. if year is current: %b %d %H:%M (e.g. Nov 5 13:46)
    /// 2. else: %b %d %Y (e.g. Nov 5 2019)
    fn parse_lstime(tm: &str, fmt_year: &str, fmt_hours: &str) -> Result<SystemTime, ParseError> {
        let datetime: NaiveDateTime = match NaiveDate::parse_from_str(tm, fmt_year) {
            Ok(date) => {
                // Case 2.
                // Return NaiveDateTime from NaiveDate with time 00:00:00
                date.and_hms_opt(0, 0, 0).unwrap()
            }
            Err(_) => {
                // Might be case 1.
                // We need to add Current Year at the end of the string
                let this_year: i32 = Utc::now().year();
                let date_time_str: String = format!("{tm} {this_year}");
                // Now parse
                NaiveDateTime::parse_from_str(
                    date_time_str.as_ref(),
                    format!("{fmt_hours} %Y").as_ref(),
                )
                .map_err(|_| ParseError::InvalidDate)?
            }
        };
        // Convert datetime to system time
        let sys_time: SystemTime = SystemTime::UNIX_EPOCH;
        Ok(sys_time
            .checked_add(Duration::from_secs(datetime.and_utc().timestamp() as u64))
            .unwrap_or(SystemTime::UNIX_EPOCH))
    }

    /// Parse date time string in DOS representation ("%m-%d-%y %I:%M%p")
    fn parse_dostime(tm: &str) -> Result<SystemTime, ParseError> {
        NaiveDateTime::parse_from_str(tm, "%m-%d-%y %I:%M%p")
            .map(|dt| {
                SystemTime::UNIX_EPOCH
                    .checked_add(Duration::from_secs(dt.and_utc().timestamp() as u64))
                    .unwrap_or(SystemTime::UNIX_EPOCH)
            })
            .map_err(|_| ParseError::InvalidDate)
    }
}

#[cfg(test)]
mod tests {
    use chrono::DateTime;

    use super::*;

    #[test]
    fn parse_posix_line() {
        let file = ListParser::parse_posix("-rw-rw-r-- 1 0  1  8192 Nov 5 2018 omar.txt").unwrap();
        pretty_assertions::assert_eq!(file.name(), "omar.txt");
        pretty_assertions::assert_eq!(file.size, 8192);
        pretty_assertions::assert_eq!(file.is_file(), true);
        pretty_assertions::assert_eq!(file.uid, Some(0));
        pretty_assertions::assert_eq!(file.gid, Some(1));
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), false);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(
            file.modified()
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()
                .unwrap(),
            Duration::from_secs(1541376000)
        );
        // Group and user as strings; directory
        let file =
            ListParser::parse_posix("drwxrwxr-x 1 root  dialout  4096 Nov 5 2018 provola").unwrap();
        pretty_assertions::assert_eq!(file.name(), "provola");
        pretty_assertions::assert_eq!(file.size, 4096);
        pretty_assertions::assert_eq!(file.is_directory(), true);
        pretty_assertions::assert_eq!(file.uid, None);
        pretty_assertions::assert_eq!(file.gid, None);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(
            file.modified()
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()
                .unwrap(),
            Duration::from_secs(1541376000)
        );
        // Setuid bit
        let file: File = ListParser::parse_posix(
            "drws------    2 u-redacted g-redacted      3864 Feb 17  2023 sas",
        )
        .unwrap();
        pretty_assertions::assert_eq!(file.is_directory(), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), false);
        let file: File = ListParser::parse_posix(
            "drwS------    2 u-redacted g-redacted      3864 Feb 17  2023 sas",
        )
        .unwrap();
        pretty_assertions::assert_eq!(file.is_directory(), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), false);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), false);
        // Setgid bit
        let file: File = ListParser::parse_posix(
            "drwx--s---    2 u-redacted g-redacted      3864 Feb 17  2023 sas",
        )
        .unwrap();
        pretty_assertions::assert_eq!(file.is_directory(), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), false);
        let file: File = ListParser::parse_posix(
            "drwx--S---    2 u-redacted g-redacted      3864 Feb 17  2023 sas",
        )
        .unwrap();
        pretty_assertions::assert_eq!(file.is_directory(), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), false);
        // Sticky bit
        let file: File = ListParser::parse_posix(
            "drwx-----t    2 u-redacted g-redacted      3864 Feb 17  2023 sas",
        )
        .unwrap();
        pretty_assertions::assert_eq!(file.is_directory(), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), true);
        let file: File = ListParser::parse_posix(
            "drwx--S--T    2 u-redacted g-redacted      3864 Feb 17  2023 sas",
        )
        .unwrap();
        pretty_assertions::assert_eq!(file.is_directory(), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), false);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), false);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), false);

        // Error
        pretty_assertions::assert_eq!(
            ListParser::parse_posix("drwxrwxr-x 1 0  9  Nov 5 2018 docs").unwrap_err(),
            ParseError::SyntaxError
        );
        pretty_assertions::assert_eq!(
            ListParser::parse_posix("drwxrwxr-x 1 root  dialout  4096 Nov 31 2018 provola")
                .unwrap_err(),
            ParseError::InvalidDate
        );
    }

    #[test]
    fn should_parse_utf8_names_in_ls_output() {
        assert!(
            ListParser::parse_posix("-rw-rw-r-- 1 омар  www-data  8192 Nov 5 2018 фообар.txt")
                .is_ok()
        );
    }

    #[test]
    fn parse_dos_line() {
        let file: File = ListParser::parse_dos("04-08-14  03:09PM  8192 omar.txt")
            .ok()
            .unwrap();
        pretty_assertions::assert_eq!(file.name(), "omar.txt");
        pretty_assertions::assert_eq!(file.size, 8192);
        assert!(file.is_file());
        pretty_assertions::assert_eq!(file.gid, None);
        pretty_assertions::assert_eq!(file.uid, None);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(
            file.modified
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()
                .unwrap(),
            Duration::from_secs(1396969740)
        );
        // Parse directory
        let dir: File = ListParser::parse_dos("04-08-14  03:09PM  <DIR> docs").unwrap();
        pretty_assertions::assert_eq!(dir.name(), "docs");
        assert!(dir.is_directory());
        pretty_assertions::assert_eq!(dir.uid, None);
        pretty_assertions::assert_eq!(dir.gid, None);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(
            dir.modified
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()
                .unwrap(),
            Duration::from_secs(1396969740)
        );
        // Error
        pretty_assertions::assert_eq!(
            ListParser::parse_dos("-08-14  03:09PM  <DIR> docs")
                .err()
                .unwrap(),
            ParseError::SyntaxError
        );
        pretty_assertions::assert_eq!(
            ListParser::parse_dos("34-08-14  03:09PM  <DIR> docs")
                .err()
                .unwrap(),
            ParseError::InvalidDate
        );
        pretty_assertions::assert_eq!(
            ListParser::parse_dos("04-08-14  03:09PM  OMAR docs")
                .err()
                .unwrap(),
            ParseError::BadSize
        );
    }

    #[test]
    fn test_should_parse_name_starting_with_tricky_numbers() {
        let file = ListParser::parse_posix(
            "-r--r--r--    1 23        23         1234567 Jan 1  2000 01 1234 foo.mp3",
        )
        .unwrap();
        pretty_assertions::assert_eq!(file.name(), "01 1234 foo.mp3");
        pretty_assertions::assert_eq!(file.size, 1234567);
        pretty_assertions::assert_eq!(
            file.modified
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()
                .unwrap(),
            Duration::from_secs(946684800)
        );
    }

    #[test]
    fn parse_lstime() {
        // Good cases
        pretty_assertions::assert_eq!(
            fmt_time(
                ListParser::parse_lstime("Nov 5 16:32", "%b %d %Y", "%b %d %H:%M")
                    .ok()
                    .unwrap(),
                "%m %d %M"
            )
            .as_str(),
            "11 05 32"
        );
        pretty_assertions::assert_eq!(
            fmt_time(
                ListParser::parse_lstime("Dec 2 21:32", "%b %d %Y", "%b %d %H:%M")
                    .ok()
                    .unwrap(),
                "%m %d %M"
            )
            .as_str(),
            "12 02 32"
        );
        pretty_assertions::assert_eq!(
            ListParser::parse_lstime("Nov 5 2018", "%b %d %Y", "%b %d %H:%M")
                .ok()
                .unwrap()
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()
                .unwrap(),
            Duration::from_secs(1541376000)
        );
        pretty_assertions::assert_eq!(
            ListParser::parse_lstime("Mar 18 2018", "%b %d %Y", "%b %d %H:%M")
                .ok()
                .unwrap()
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()
                .unwrap(),
            Duration::from_secs(1521331200)
        );
        // bad cases
        assert!(ListParser::parse_lstime("Oma 31 2018", "%b %d %Y", "%b %d %H:%M").is_err());
        assert!(ListParser::parse_lstime("Feb 31 2018", "%b %d %Y", "%b %d %H:%M").is_err());
        assert!(ListParser::parse_lstime("Feb 15 25:32", "%b %d %Y", "%b %d %H:%M").is_err());
    }

    #[test]
    fn parse_dostime() {
        pretty_assertions::assert_eq!(
            ListParser::parse_dostime("04-08-14  03:09PM")
                .ok()
                .unwrap()
                .duration_since(SystemTime::UNIX_EPOCH)
                .ok()
                .unwrap(),
            Duration::from_secs(1396969740)
        );
        // Not enough argument for datetime
        assert!(ListParser::parse_dostime("04-08-14").is_err());
    }

    #[test]
    fn test_parse_mlsx_line() {
        let file =
            ListParser::parse_mlsd("type=file;size=8192;modify=20181105163248; omar.txt").unwrap();

        pretty_assertions::assert_eq!(file.name(), "omar.txt");
        pretty_assertions::assert_eq!(file.size, 8192);
        assert!(file.is_file());
        pretty_assertions::assert_eq!(file.gid, None);
        pretty_assertions::assert_eq!(file.uid, None);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Group), true);
        pretty_assertions::assert_eq!(file.can_read(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(file.can_write(PosixPexQuery::Others), true);
        pretty_assertions::assert_eq!(file.can_execute(PosixPexQuery::Others), true);

        let file =
            ListParser::parse_mlsd("type=dir;size=4096;modify=20181105163248; docs").unwrap();

        pretty_assertions::assert_eq!(file.name(), "docs");
        assert!(file.is_directory());

        let file = ListParser::parse_mlsd(
            "type=file;size=4096;modify=20181105163248;unix.mode=644; omar.txt",
        )
        .unwrap();
        pretty_assertions::assert_eq!(
            file.posix_pex,
            (PosixPex::from(6), PosixPex::from(4), PosixPex::from(4))
        );
    }

    #[test]
    fn get_name_and_link() {
        pretty_assertions::assert_eq!(
            ListParser::get_name_and_link("Cargo.toml"),
            (String::from("Cargo.toml"), None)
        );
        pretty_assertions::assert_eq!(
            ListParser::get_name_and_link("Cargo -> Cargo.toml"),
            (String::from("Cargo"), Some(PathBuf::from("Cargo.toml")))
        );
    }

    fn fmt_time(time: SystemTime, fmt: &str) -> String {
        let datetime: DateTime<Utc> = time.into();
        format!("{}", datetime.format(fmt))
    }
}
