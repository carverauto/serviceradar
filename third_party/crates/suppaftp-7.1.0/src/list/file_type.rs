use std::path::{Path, PathBuf};

/// Describes the kind of file. Can be `Directory`, `File` or `Symlink`.
/// If `Symlink` the path to the pointed file is provided.
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub enum FileType {
    /// Directory type
    Directory,
    /// Regular file type
    File,
    /// Symlink type with the path to the pointed file
    Symlink(PathBuf),
}

impl FileType {
    /// Returns whether the file is a directory
    pub fn is_directory(&self) -> bool {
        matches!(self, &FileType::Directory)
    }

    /// Returns whether the file is a file
    pub fn is_file(&self) -> bool {
        matches!(self, &FileType::File)
    }

    /// Returns whether the file is a symlink
    pub fn is_symlink(&self) -> bool {
        matches!(self, &FileType::Symlink(_))
    }

    /// get symlink if any
    pub fn symlink(&self) -> Option<&Path> {
        match self {
            FileType::Symlink(p) => Some(p.as_path()),
            _ => None,
        }
    }
}
