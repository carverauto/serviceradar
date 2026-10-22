//! Resolves the executable a process runs to the installed package that owns it
//! (add-srql-exposure-intelligence, design Decision 18).
//!
//! The answer is decided by inode, never by name: a package owns the executable only when
//! one of its listed paths, resolved inside the process's own root, has the executable's
//! `(dev, inode)`. That makes merged-`/usr` layouts and other directory symlinks resolve,
//! and keeps a binary that was upgraded or removed while its process kept running from
//! being attributed to whatever package now owns the path.
//!
//! Cost is bounded twice. Each process root's package databases are indexed once per
//! database change, keeping only executable regular files, and at most
//! [`MAX_ROOT_INDEXES`] roots are kept. Each executable is then resolved once per
//! `(root, dev, inode)` and cached ([`MAX_CACHED_EXECUTABLES`] entries).

mod package_db;
mod root_path;
mod rpm_header;
mod sqlite;

use std::collections::HashMap;
use std::fs::{self, Metadata};
use std::io;
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::proto::netprobe::{
    ExecutableOwnership, ExecutableOwnershipResolver as WireResolver,
    ExecutableOwnershipState as WireState,
};
use package_db::{DatabaseOutcome, OsRelease, PackageSink};
use root_path::RootFs;

/// Resolved executables kept in the cache.
const MAX_CACHED_EXECUTABLES: usize = 4096;
/// Process roots (the host plus distinct containers) whose package index is kept.
const MAX_ROOT_INDEXES: usize = 32;
/// Package-database paths read per index build; a larger database truncates the index,
/// and every executable in that root is then `Unknown` (`package_index_truncated`) until
/// the next re-index, per Decision 18's state order.
const MAX_INDEXED_PATHS: usize = 2_000_000;
/// Executables indexed per root.
const MAX_INDEXED_EXECUTABLES: usize = 262_144;
/// A root whose package database keeps changing is re-indexed at most this often.
const MIN_REINDEX_INTERVAL: Duration = Duration::from_secs(30);

const EXECUTE_BITS: u32 = 0o111;
const DELETED_SUFFIX: &str = " (deleted)";

pub const DETAIL_PROCESS_EXITED: &str = "process_exited";
pub const DETAIL_PROCFS_DENIED: &str = "procfs_denied";
pub const DETAIL_PROCFS_UNREADABLE: &str = "procfs_unreadable";
pub const DETAIL_RESOLVER_UNAVAILABLE: &str = "resolver_unavailable";
pub const DETAIL_EXECUTABLE_DELETED: &str = "executable_deleted";
pub const DETAIL_NOT_OWNED: &str = "not_owned";
pub const DETAIL_NO_PACKAGE_DATABASE: &str = "no_package_database";
pub const DETAIL_PACKAGE_DATABASE_UNREADABLE: &str = "package_database_unreadable";
pub const DETAIL_PACKAGE_DATABASE_CHANGING: &str = "package_database_changing";
pub const DETAIL_PACKAGE_INDEX_TRUNCATED: &str = "package_index_truncated";
pub const DETAIL_RPMDB_WAL_PENDING: &str = "rpmdb_wal_pending";
pub const DETAIL_RPM_BERKELEYDB: &str = "rpm_berkeleydb";
pub const DETAIL_RPM_NDB: &str = "rpm_ndb";

pub const SCOPE_HOST: &str = "host";
pub const SCOPE_CONTAINER: &str = "container";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum OwnershipState {
    Resolved,
    Unknown,
    NotPermitted,
    NotFound,
    UnsupportedDb,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PackageResolver {
    Dpkg,
    Rpm,
    Apk,
}

/// The package identity fields core's assessment identity derivation reads, plus the
/// installed version.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct OwningPackage {
    pub package_type: String,
    pub package_manager: String,
    pub namespace: String,
    pub release: String,
    pub ecosystem: String,
    pub binary_package: String,
    pub source_package: String,
    pub architecture: String,
    pub installed_version: String,
}

/// The ownership of one process's executable. Only `Resolved` carries a package.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ExecutableOwnershipRecord {
    pub state: OwnershipState,
    pub detail: &'static str,
    pub source_scope: &'static str,
    pub package: Option<Arc<OwningPackage>>,
    pub resolver: Option<PackageResolver>,
    pub executable_path: String,
    pub dev: u64,
    pub inode: u64,
}

impl ExecutableOwnershipRecord {
    fn unresolved(state: OwnershipState, detail: &'static str) -> Self {
        Self {
            state,
            detail,
            source_scope: "",
            package: None,
            resolver: None,
            executable_path: String::new(),
            dev: 0,
            inode: 0,
        }
    }

    /// The record for a resolution that could not run at all.
    pub fn resolver_unavailable() -> Self {
        Self::unresolved(OwnershipState::Unknown, DETAIL_RESOLVER_UNAVAILABLE)
    }

    pub fn to_proto(&self) -> ExecutableOwnership {
        let state = match self.state {
            OwnershipState::Resolved => WireState::Resolved,
            OwnershipState::Unknown => WireState::Unknown,
            OwnershipState::NotPermitted => WireState::NotPermitted,
            OwnershipState::NotFound => WireState::NotFound,
            OwnershipState::UnsupportedDb => WireState::UnsupportedDb,
        };
        let resolver = match self.resolver {
            Some(PackageResolver::Dpkg) => WireResolver::Dpkg,
            Some(PackageResolver::Rpm) => WireResolver::Rpm,
            Some(PackageResolver::Apk) => WireResolver::Apk,
            None => WireResolver::Unspecified,
        };
        let package = self.package.as_deref().cloned().unwrap_or_default();
        ExecutableOwnership {
            resolution_state: state as i32,
            detail: self.detail.to_string(),
            source_scope: self.source_scope.to_string(),
            package_type: package.package_type,
            package_manager: package.package_manager,
            namespace: package.namespace,
            release: package.release,
            ecosystem: package.ecosystem,
            binary_package: package.binary_package,
            source_package: package.source_package,
            architecture: package.architecture,
            installed_version: package.installed_version,
            resolver: resolver as i32,
            executable_path: self.executable_path.clone(),
            executable_dev: self.dev,
            executable_inode: self.inode,
        }
    }
}

/// Counters for the metrics endpoint.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ResolverCounters {
    /// Executables resolved against an index (cache misses).
    pub resolutions: u64,
    /// Answers served from the per-executable cache.
    pub cache_hits: u64,
    /// Package-database indexes built.
    pub index_builds: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct FileId {
    dev: u64,
    ino: u64,
}

impl FileId {
    #[cfg(unix)]
    fn of(metadata: &Metadata) -> Self {
        Self {
            dev: metadata.dev(),
            ino: metadata.ino(),
        }
    }

    #[cfg(not(unix))]
    fn of(_metadata: &Metadata) -> Self {
        Self { dev: 0, ino: 0 }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct ExecutableKey {
    root: FileId,
    executable: FileId,
}

/// Identifies the state of a root's package databases: each database file's identity,
/// size and modification time, keyed by its path inside the root. The host path is not
/// part of it, because every process reaches the same root through its own
/// `/proc/<pid>/root`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct DatabaseFingerprint(Vec<(&'static str, FileId, u64, i128)>);

const FINGERPRINT_PATHS: [&str; 7] = [
    "/var/lib/dpkg/status",
    "/var/lib/dpkg/info",
    "/lib/apk/db/installed",
    "/usr/lib/sysimage/rpm/rpmdb.sqlite",
    "/usr/lib/sysimage/rpm/rpmdb.sqlite-wal",
    "/var/lib/rpm/rpmdb.sqlite",
    "/var/lib/rpm/rpmdb.sqlite-wal",
];

impl DatabaseFingerprint {
    fn of(root: &RootFs) -> Self {
        Self(
            FINGERPRINT_PATHS
                .iter()
                .filter_map(|inner| {
                    let metadata = fs::metadata(root.resolve(inner).ok()?).ok()?;
                    Some((
                        *inner,
                        FileId::of(&metadata),
                        metadata.len(),
                        modified_nanos(&metadata),
                    ))
                })
                .collect(),
        )
    }
}

struct RootIndex {
    fingerprint: DatabaseFingerprint,
    generation: u64,
    built_at: Instant,
    last_used: Instant,
    /// The databases changed after this index was built and it is waiting out
    /// [`MIN_REINDEX_INTERVAL`]; its answers are not trusted meanwhile.
    stale: bool,
    owners: HashMap<FileId, u32>,
    packages: Vec<(Arc<OwningPackage>, PackageResolver)>,
    read_any: bool,
    unreadable: bool,
    truncated: bool,
    wal_pending: bool,
    unsupported: Option<&'static str>,
}

impl RootIndex {
    fn build(
        root: &RootFs,
        fingerprint: DatabaseFingerprint,
        generation: u64,
        now: Instant,
    ) -> Self {
        let os = OsRelease::read(root);
        let mut builder = IndexBuilder::new(root);
        let outcomes = [
            package_db::read_dpkg(root, &os, &mut builder),
            package_db::read_apk(root, &os, &mut builder),
            package_db::read_rpm(root, &os, &mut builder),
        ];
        let unsupported = outcomes.iter().find_map(|outcome| match outcome {
            DatabaseOutcome::RpmBerkeleyDb => Some(DETAIL_RPM_BERKELEYDB),
            DatabaseOutcome::RpmNdb => Some(DETAIL_RPM_NDB),
            _ => None,
        });
        Self {
            fingerprint,
            generation,
            built_at: now,
            last_used: now,
            stale: false,
            truncated: builder.truncated,
            owners: builder.owners,
            packages: builder.packages,
            read_any: outcomes.contains(&DatabaseOutcome::Read),
            unreadable: outcomes.contains(&DatabaseOutcome::Unreadable),
            wal_pending: outcomes.contains(&DatabaseOutcome::WalPending),
            unsupported,
        }
    }

    /// Classifies an executable against this index, in the precedence of design
    /// Decision 18: anything that leaves the answer undetermined is `Unknown`; an
    /// unsupported database is `UnsupportedDb` only when no supported one was read;
    /// otherwise an inode no read database lists is `NotFound`.
    fn classify(
        &self,
        executable: FileId,
        deleted: bool,
    ) -> (OwnershipState, &'static str, Option<u32>) {
        if deleted {
            return (OwnershipState::Unknown, DETAIL_EXECUTABLE_DELETED, None);
        }
        if let Some(detail) = self.incomplete() {
            return (OwnershipState::Unknown, detail, None);
        }
        match (self.owners.get(&executable), self.unsupported) {
            (Some(package), _) => (OwnershipState::Resolved, "", Some(*package)),
            (None, Some(detail)) if !self.read_any => (OwnershipState::UnsupportedDb, detail, None),
            (None, _) => (OwnershipState::NotFound, DETAIL_NOT_OWNED, None),
        }
    }

    fn incomplete(&self) -> Option<&'static str> {
        if self.wal_pending {
            Some(DETAIL_RPMDB_WAL_PENDING)
        } else if self.unreadable {
            Some(DETAIL_PACKAGE_DATABASE_UNREADABLE)
        } else if self.truncated {
            Some(DETAIL_PACKAGE_INDEX_TRUNCATED)
        } else if !self.read_any && self.unsupported.is_none() {
            Some(DETAIL_NO_PACKAGE_DATABASE)
        } else {
            None
        }
    }
}

/// Collects `(dev, inode) -> package` for the executable regular files a root's
/// databases list. Directory resolution is cached for the duration of one build.
struct IndexBuilder<'a> {
    root: &'a RootFs,
    directories: HashMap<String, Option<PathBuf>>,
    owners: HashMap<FileId, u32>,
    packages: Vec<(Arc<OwningPackage>, PackageResolver)>,
    paths_read: usize,
    truncated: bool,
}

impl<'a> IndexBuilder<'a> {
    fn new(root: &'a RootFs) -> Self {
        Self {
            root,
            directories: HashMap::new(),
            owners: HashMap::new(),
            packages: Vec::new(),
            paths_read: 0,
            truncated: false,
        }
    }

    fn executable_id(&mut self, path: &str) -> Option<FileId> {
        let (directory, name) = path.rsplit_once('/')?;
        if name.is_empty() {
            return None;
        }
        let resolved = self
            .directories
            .entry(directory.to_string())
            .or_insert_with(|| {
                let directory = if directory.is_empty() { "/" } else { directory };
                self.root.resolve(directory).ok()
            })
            .clone()?;
        // A listed symlink owns nothing; the file it points to is listed by its own owner.
        let metadata = fs::symlink_metadata(resolved.join(name)).ok()?;
        (metadata.is_file() && mode(&metadata) & EXECUTE_BITS != 0).then(|| FileId::of(&metadata))
    }
}

impl PackageSink for IndexBuilder<'_> {
    fn add_package(&mut self, package: OwningPackage, resolver: PackageResolver) -> u32 {
        self.packages.push((Arc::new(package), resolver));
        u32::try_from(self.packages.len() - 1).unwrap_or(u32::MAX)
    }

    fn add_path(&mut self, package: u32, path: &str) -> bool {
        self.paths_read += 1;
        if self.paths_read > MAX_INDEXED_PATHS || self.owners.len() >= MAX_INDEXED_EXECUTABLES {
            self.truncated = true;
            return false;
        }
        if let Some(id) = self.executable_id(path) {
            // The first listing wins, so the answer does not depend on hash order.
            self.owners.entry(id).or_insert(package);
        }
        true
    }
}

struct CachedResolution {
    generation: u64,
    size: u64,
    modified: i128,
    record: ExecutableOwnershipRecord,
    last_used: Instant,
}

/// Resolves process executables to owning packages, caching per executable inode.
pub struct ExecutableOwnershipResolver {
    proc_root: PathBuf,
    host_root: Option<FileId>,
    roots: HashMap<FileId, RootIndex>,
    cache: HashMap<ExecutableKey, CachedResolution>,
    next_generation: u64,
    counters: ResolverCounters,
}

impl std::fmt::Debug for ExecutableOwnershipResolver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExecutableOwnershipResolver")
            .field("proc_root", &self.proc_root)
            .field("roots", &self.roots.len())
            .field("cached", &self.cache.len())
            .finish()
    }
}

impl ExecutableOwnershipResolver {
    pub fn new(proc_root: impl Into<PathBuf>) -> Self {
        Self {
            proc_root: proc_root.into(),
            host_root: None,
            roots: HashMap::new(),
            cache: HashMap::new(),
            next_generation: 0,
            counters: ResolverCounters::default(),
        }
    }

    /// Returns the counters accumulated since the previous call and resets them.
    pub fn take_counters(&mut self) -> ResolverCounters {
        std::mem::take(&mut self.counters)
    }

    pub fn cache_len(&self) -> usize {
        self.cache.len()
    }

    pub fn resolve(&mut self, pid: u32) -> ExecutableOwnershipRecord {
        self.resolve_at(pid, Instant::now())
    }

    fn resolve_at(&mut self, pid: u32, now: Instant) -> ExecutableOwnershipRecord {
        let process = self.proc_root.join(pid.to_string());
        let exe_link = process.join("exe");
        let executable = match fs::metadata(&exe_link) {
            Ok(metadata) => metadata,
            Err(err) => return procfs_error(&err),
        };
        let link_target = match fs::read_link(&exe_link) {
            Ok(target) => target,
            Err(err) => return procfs_error(&err),
        };
        let root_link = process.join("root");
        let root = match fs::metadata(&root_link) {
            Ok(metadata) => FileId::of(&metadata),
            Err(err) => return procfs_error(&err),
        };
        let (executable_path, deleted) = in_root_executable_path(&link_target, &root_link);
        let source_scope = if Some(root) == self.host_root() {
            SCOPE_HOST
        } else {
            SCOPE_CONTAINER
        };
        let executable_id = FileId::of(&executable);
        let key = ExecutableKey {
            root,
            executable: executable_id,
        };

        let rootfs = RootFs::new(&root_link);
        let (generation, stale) = {
            let index = self.root_index(root, &rootfs, now);
            (index.generation, index.stale)
        };
        let size = executable.len();
        let modified = modified_nanos(&executable);

        if !stale
            && !deleted
            && let Some(cached) = self.cache.get_mut(&key)
            && cached.generation == generation
            && cached.size == size
            && cached.modified == modified
        {
            cached.last_used = now;
            self.counters.cache_hits += 1;
            return cached.record.clone();
        }

        let mut record = ExecutableOwnershipRecord {
            source_scope,
            executable_path,
            dev: executable_id.dev,
            inode: executable_id.ino,
            ..ExecutableOwnershipRecord::unresolved(OwnershipState::Unknown, "")
        };
        if stale {
            record.detail = DETAIL_PACKAGE_DATABASE_CHANGING;
            // Not cached: the next resolution after the re-index answers properly.
            return record;
        }
        let index = self.roots.get(&root).expect("root index was just ensured");
        let (state, detail, package) = index.classify(executable_id, deleted);
        record.state = state;
        record.detail = detail;
        if let Some(package) = package {
            let (package, resolver) = &index.packages[package as usize];
            record.package = Some(Arc::clone(package));
            record.resolver = Some(*resolver);
        }

        self.counters.resolutions += 1;
        if !deleted {
            self.insert_cached(
                key,
                CachedResolution {
                    generation,
                    size,
                    modified,
                    record: record.clone(),
                    last_used: now,
                },
            );
        }
        record
    }

    fn host_root(&mut self) -> Option<FileId> {
        if self.host_root.is_none() {
            self.host_root = fs::metadata(self.proc_root.join("1").join("root"))
                .or_else(|_| fs::metadata("/"))
                .ok()
                .map(|metadata| FileId::of(&metadata));
        }
        self.host_root
    }

    /// Returns the index for `root`, building or refreshing it when its databases
    /// changed, at most once per [`MIN_REINDEX_INTERVAL`].
    fn root_index(&mut self, root: FileId, rootfs: &RootFs, now: Instant) -> &RootIndex {
        let fingerprint = DatabaseFingerprint::of(rootfs);
        let rebuild = match self.roots.get_mut(&root) {
            Some(index) if index.fingerprint == fingerprint => {
                index.stale = false;
                false
            }
            Some(index) if now.saturating_duration_since(index.built_at) < MIN_REINDEX_INTERVAL => {
                index.stale = true;
                false
            }
            _ => true,
        };
        if rebuild {
            self.evict_root_indexes(root);
            self.next_generation += 1;
            self.counters.index_builds += 1;
            let index = RootIndex::build(rootfs, fingerprint, self.next_generation, now);
            self.roots.insert(root, index);
        }
        let index = self.roots.get_mut(&root).expect("root index present");
        index.last_used = now;
        index
    }

    fn evict_root_indexes(&mut self, incoming: FileId) {
        while self.roots.len() >= MAX_ROOT_INDEXES && !self.roots.contains_key(&incoming) {
            let Some(oldest) = self
                .roots
                .iter()
                .min_by_key(|(_, index)| index.last_used)
                .map(|(id, _)| *id)
            else {
                return;
            };
            self.roots.remove(&oldest);
            self.cache.retain(|key, _| key.root != oldest);
        }
    }

    fn insert_cached(&mut self, key: ExecutableKey, entry: CachedResolution) {
        if self.cache.len() >= MAX_CACHED_EXECUTABLES
            && !self.cache.contains_key(&key)
            && let Some(oldest) = self
                .cache
                .iter()
                .min_by_key(|(_, cached)| cached.last_used)
                .map(|(key, _)| *key)
        {
            self.cache.remove(&oldest);
        }
        self.cache.insert(key, entry);
    }
}

/// The executable path as the process root sees it, and whether the kernel marked the
/// file deleted. When the root is itself visible from netprobe's root (a chroot, or a
/// test fixture), its prefix is removed.
fn in_root_executable_path(link_target: &Path, root_link: &Path) -> (String, bool) {
    let raw = link_target.to_string_lossy();
    let (path, deleted) = match raw.strip_suffix(DELETED_SUFFIX) {
        Some(path) => (path.to_string(), true),
        None => (raw.into_owned(), false),
    };
    let root_target = fs::read_link(root_link).unwrap_or_default();
    let in_root = root_target
        .to_str()
        .filter(|prefix| *prefix != "/" && !prefix.is_empty())
        .and_then(|prefix| path.strip_prefix(prefix))
        .filter(|rest| rest.starts_with('/'))
        .map(str::to_string);
    (in_root.unwrap_or(path), deleted)
}

fn procfs_error(err: &io::Error) -> ExecutableOwnershipRecord {
    match err.kind() {
        io::ErrorKind::NotFound => {
            ExecutableOwnershipRecord::unresolved(OwnershipState::Unknown, DETAIL_PROCESS_EXITED)
        }
        io::ErrorKind::PermissionDenied => ExecutableOwnershipRecord::unresolved(
            OwnershipState::NotPermitted,
            DETAIL_PROCFS_DENIED,
        ),
        _ => {
            ExecutableOwnershipRecord::unresolved(OwnershipState::Unknown, DETAIL_PROCFS_UNREADABLE)
        }
    }
}

fn modified_nanos(metadata: &Metadata) -> i128 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |duration| duration.as_nanos() as i128)
}

#[cfg(unix)]
fn mode(metadata: &Metadata) -> u32 {
    metadata.mode()
}

#[cfg(not(unix))]
fn mode(_metadata: &Metadata) -> u32 {
    0
}

#[cfg(all(test, unix))]
mod tests;
