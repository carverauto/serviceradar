//! Path resolution confined to a process's root filesystem.
//!
//! A package database lists paths as the process sees them. Inside a container, an
//! absolute symlink such as `/sbin -> /usr/sbin` points into the container, but the
//! kernel would resolve it against netprobe's own root when reached through
//! `/proc/<pid>/root`. `RootFs` follows symlinks itself and restarts absolute targets at
//! the process root, so resolution never leaves it.

use std::collections::VecDeque;
use std::ffi::OsString;
use std::fs::{self, File};
use std::io;
use std::path::{Component, Path, PathBuf};

/// Symlinks followed per resolution before giving up, as the kernel's own limit.
const MAX_SYMLINKS: usize = 40;

#[derive(Clone, Debug)]
pub struct RootFs {
    root: PathBuf,
}

impl RootFs {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Resolves `inner`, a path as the process sees it, to a path inside the root with
    /// every symlink, including the last component, followed within the root.
    pub fn resolve(&self, inner: &str) -> io::Result<PathBuf> {
        let mut pending: VecDeque<OsString> = VecDeque::new();
        push_components(&mut pending, Path::new(inner));
        let mut resolved: Vec<OsString> = Vec::new();
        let mut links = 0;

        while let Some(component) = pending.pop_front() {
            if component == ".." {
                resolved.pop();
                continue;
            }
            let mut candidate = self.root.clone();
            candidate.extend(&resolved);
            candidate.push(&component);
            let metadata = fs::symlink_metadata(&candidate)?;
            if !metadata.file_type().is_symlink() {
                resolved.push(component);
                continue;
            }
            links += 1;
            if links > MAX_SYMLINKS {
                return Err(io::Error::other("too many levels of symbolic links"));
            }
            let target = fs::read_link(&candidate)?;
            if target.is_absolute() {
                resolved.clear();
            }
            let mut expanded = VecDeque::new();
            push_components(&mut expanded, &target);
            expanded.append(&mut pending);
            pending = expanded;
        }

        let mut path = self.root.clone();
        path.extend(&resolved);
        Ok(path)
    }

    pub fn open(&self, inner: &str) -> io::Result<File> {
        File::open(self.resolve(inner)?)
    }

    pub fn read_to_string(&self, inner: &str) -> io::Result<String> {
        fs::read_to_string(self.resolve(inner)?)
    }
}

/// Appends the normal and `..` components of `path`; the root and `.` add nothing.
fn push_components(out: &mut VecDeque<OsString>, path: &Path) {
    for component in path.components() {
        match component {
            Component::Normal(part) => out.push_back(part.to_owned()),
            Component::ParentDir => out.push_back(OsString::from("..")),
            Component::RootDir | Component::CurDir | Component::Prefix(_) => {}
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::os::unix::fs::symlink;

    use super::*;

    #[test]
    fn absolute_symlinks_restart_at_the_process_root_not_the_host_root() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("rootfs");
        fs::create_dir_all(root.join("usr/sbin")).unwrap();
        fs::write(root.join("usr/sbin/exampled"), b"").unwrap();
        symlink("/usr/sbin", root.join("sbin")).unwrap();
        // `..` cannot climb out of the root either.
        symlink("../../../usr/sbin/exampled", root.join("usr/sbin/alias")).unwrap();

        let rootfs = RootFs::new(&root);

        assert_eq!(
            rootfs.resolve("/sbin/exampled").unwrap(),
            root.join("usr/sbin/exampled")
        );
        assert_eq!(
            rootfs.resolve("/usr/sbin/alias").unwrap(),
            root.join("usr/sbin/exampled")
        );
    }

    #[test]
    fn symlink_loops_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        symlink("/loop", dir.path().join("loop")).unwrap();

        assert!(RootFs::new(dir.path()).resolve("/loop").is_err());
    }
}
