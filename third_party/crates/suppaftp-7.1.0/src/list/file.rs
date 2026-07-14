use std::convert::TryFrom;
use std::path::Path;
use std::str::FromStr;
use std::time::SystemTime;

use super::{FileType, ListParser, ParseError, ParseResult, PosixPex, PosixPexQuery};

/// Describes a file entry on the remote system.
/// This data type is returned in a collection after parsing a LIST output
///
/// Each file comes with metadata such as name, type (file, directory, symlink),
/// size, modification time, POSIX permissions and owner/group ids (if available).
///
/// # Parsing
///
/// You can parse a LIST line by using the [`ListParser`] by calling either
///
/// - [`ListParser::from_posix_line`]
/// - [`ListParser::from_dos_line`]
///
/// or by using the generic implementation of [`FromStr`] or [`TryFrom<&str>`].
/// In case you opt for the generic implementations, the parser will first try to parse the line
/// as POSIX format and if it fails, it will try to parse it as DOS format.
///
/// So, if you know which format you are dealing with, it is better to use the specific functions.
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub struct File {
    /// File name
    pub(crate) name: String,
    /// File type describes whether it is a directory, a file or a symlink
    pub(crate) file_type: FileType,
    /// File size in bytes
    pub(crate) size: usize,
    /// Last time the file was modified
    pub(crate) modified: SystemTime,
    /// User id (POSIX only)
    pub(crate) uid: Option<u32>,
    /// Group id (POSIX only)
    pub(crate) gid: Option<u32>,
    /// POSIX permissions
    pub(crate) posix_pex: (PosixPex, PosixPex, PosixPex),
}

impl File {
    /// Get file name
    pub fn name(&self) -> &str {
        self.name.as_str()
    }

    /// Get whether file is a directory
    pub fn is_directory(&self) -> bool {
        self.file_type.is_directory()
    }

    /// Get whether file is a file
    pub fn is_file(&self) -> bool {
        self.file_type.is_file()
    }

    /// Get whether file is a symlink
    pub fn is_symlink(&self) -> bool {
        self.file_type.is_symlink()
    }

    /// Returns, if available, the file the symlink is pointing to
    pub fn symlink(&self) -> Option<&Path> {
        self.file_type.symlink()
    }

    /// Returns a reference to the file type
    pub fn file_type(&self) -> &FileType {
        &self.file_type
    }

    /// Returned file size in bytes
    pub fn size(&self) -> usize {
        self.size
    }

    /// Returns the last time the file was modified
    pub fn modified(&self) -> SystemTime {
        self.modified
    }

    /// Returns when available the owner user of the file. (POSIX only)
    pub fn uid(&self) -> Option<u32> {
        self.uid.to_owned()
    }

    /// Returns when available the owner group of the file. (POSIX only)
    pub fn gid(&self) -> Option<u32> {
        self.gid.to_owned()
    }

    /// Returns whether `who` can read file
    pub fn can_read(&self, who: PosixPexQuery) -> bool {
        self.query_pex(who).can_read()
    }

    /// Returns whether `who` can write file
    pub fn can_write(&self, who: PosixPexQuery) -> bool {
        self.query_pex(who).can_write()
    }

    /// Returns whether `who` can execute file
    pub fn can_execute(&self, who: PosixPexQuery) -> bool {
        self.query_pex(who).can_execute()
    }

    /// Returns the pex structure for selected query
    fn query_pex(&self, who: PosixPexQuery) -> &PosixPex {
        match who {
            PosixPexQuery::Group => &self.posix_pex.1,
            PosixPexQuery::Others => &self.posix_pex.2,
            PosixPexQuery::Owner => &self.posix_pex.0,
        }
    }

    /// Parse an output line from a MLSD or MLST command
    #[deprecated(
        since = "7.1.0",
        note = "Use `FileParser::parse_mlsd` or `FileParser::parse_mlst` instead"
    )]
    pub fn from_mlsx_line(line: &str) -> ParseResult<Self> {
        super::ListParser::parse_mlsx(line)
    }

    /// Parse a POSIX LIST output line and if it is valid, return a [`File`] instance.
    /// In case of error a [`ParseError`] is returned
    #[deprecated(since = "7.1.0", note = "Use `FileParser::parse_posix` instead")]
    pub fn from_posix_line(line: &str) -> ParseResult<Self> {
        super::ListParser::parse_posix(line)
    }

    /// Try to parse a "LIST" output command line in DOS format.
    /// Returns error if syntax is not DOS compliant.
    /// DOS syntax has the following syntax:
    ///
    /// ```text
    /// {DATE} {TIME} {<DIR> | SIZE} {FILENAME}
    /// 10-19-20  03:19PM <DIR> pub
    /// 04-08-14  03:09PM 403   readme.txt
    /// ```
    #[deprecated(since = "7.1.0", note = "Use `FileParser::parse_dos` instead")]
    pub fn from_dos_line(line: &str) -> ParseResult<Self> {
        super::ListParser::parse_dos(line)
    }
}

impl FromStr for File {
    type Err = ParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::try_from(s)
    }
}

impl TryFrom<&str> for File {
    type Error = ParseError;

    fn try_from(line: &str) -> Result<Self, Self::Error> {
        ListParser::parse_posix(line)
            .or_else(|_| ListParser::parse_dos(line))
            .or_else(|_| ListParser::parse_mlsd(line))
            .or_else(|_| ListParser::parse_mlst(line))
    }
}

impl TryFrom<&String> for File {
    type Error = ParseError;

    fn try_from(line: &String) -> Result<Self, Self::Error> {
        Self::try_from(line.as_str())
    }
}

impl TryFrom<String> for File {
    type Error = ParseError;

    fn try_from(line: String) -> Result<Self, Self::Error> {
        File::try_from(line.as_str())
    }
}

#[cfg(test)]
mod test {

    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn file_getters() {
        let file: File = File {
            name: String::from("provola.txt"),
            file_type: FileType::File,
            size: 2048,
            modified: SystemTime::UNIX_EPOCH,
            gid: Some(0),
            uid: Some(0),
            posix_pex: (PosixPex::from(7), PosixPex::from(5), PosixPex::from(4)),
        };
        assert_eq!(file.name(), "provola.txt");
        assert_eq!(file.is_directory(), false);
        assert_eq!(file.is_file(), true);
        assert_eq!(file.is_symlink(), false);
        assert_eq!(file.symlink(), None);
        assert_eq!(file.size(), 2048);
        assert_eq!(file.gid(), Some(0));
        assert_eq!(file.uid(), Some(0));
        assert_eq!(file.modified(), SystemTime::UNIX_EPOCH);
        // -- posix pex
        assert_eq!(file.can_read(PosixPexQuery::Owner), true);
        assert_eq!(file.can_write(PosixPexQuery::Owner), true);
        assert_eq!(file.can_execute(PosixPexQuery::Owner), true);
        assert_eq!(file.can_read(PosixPexQuery::Group), true);
        assert_eq!(file.can_write(PosixPexQuery::Group), false);
        assert_eq!(file.can_execute(PosixPexQuery::Group), true);
        assert_eq!(file.can_read(PosixPexQuery::Others), true);
        assert_eq!(file.can_write(PosixPexQuery::Others), false);
        assert_eq!(file.can_execute(PosixPexQuery::Others), false);
    }

    #[test]
    fn file_type() {
        use std::path::PathBuf;

        assert_eq!(FileType::Directory.is_directory(), true);
        assert_eq!(FileType::Directory.is_file(), false);
        assert_eq!(FileType::Directory.is_symlink(), false);
        assert_eq!(FileType::Directory.symlink(), None);
        assert_eq!(FileType::File.is_directory(), false);
        assert_eq!(FileType::File.is_file(), true);
        assert_eq!(FileType::File.is_symlink(), false);
        assert_eq!(FileType::File.symlink(), None);
        assert_eq!(FileType::Symlink(PathBuf::default()).is_directory(), false);
        assert_eq!(FileType::Symlink(PathBuf::default()).is_file(), false);
        assert_eq!(FileType::Symlink(PathBuf::default()).is_symlink(), true);
        assert_eq!(
            FileType::Symlink(PathBuf::default()).symlink(),
            Some(PathBuf::default().as_path())
        );
    }
}
