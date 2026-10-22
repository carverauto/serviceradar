//! Readers for the package databases netprobe consults inside a process root: dpkg, apk
//! and the rpm sqlite backend. Each reader reports every installed package once, with the
//! identity fields the endpoint inventory derives for it and the paths it installs.
//!
//! The identity fields mirror what the ScaLibr endpoint inventory records for the same
//! package (its package-URL namespace and `distro` qualifier conventions), so core can
//! match a reference to the inventory package.

use std::collections::HashMap;
use std::fs;
use std::io::{self, BufRead, BufReader};
use std::path::Path;

use super::root_path::RootFs;
use super::sqlite::{SqliteDatabase, Value};
use super::{OwningPackage, PackageResolver, rpm_header};

/// Parsed `os-release` of a process root.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OsRelease {
    pub id: String,
    pub version_id: String,
    pub version_codename: String,
    pub build_id: String,
}

impl OsRelease {
    pub fn read(root: &RootFs) -> Self {
        let contents = ["/etc/os-release", "/usr/lib/os-release"]
            .iter()
            .find_map(|path| root.read_to_string(path).ok())
            .unwrap_or_default();
        let fields = parse_os_release(&contents);
        let get = |key: &str| fields.get(key).cloned().unwrap_or_default();
        Self {
            id: get("ID"),
            version_id: get("VERSION_ID"),
            version_codename: get("VERSION_CODENAME"),
            build_id: get("BUILD_ID"),
        }
    }
}

fn parse_os_release(contents: &str) -> HashMap<String, String> {
    contents
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.starts_with('#') {
                return None;
            }
            let (key, value) = line.split_once('=')?;
            let value = value.trim().trim_matches(|c| c == '"' || c == '\'');
            Some((key.trim().to_string(), value.to_string()))
        })
        .collect()
}

/// What reading one kind of package database found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DatabaseOutcome {
    /// The database is not present in this root.
    Absent,
    /// The database was read completely.
    Read,
    /// The database is present but could not be parsed.
    Unreadable,
    /// The rpm sqlite backend has a pending write-ahead log.
    WalPending,
    /// Only the rpm BerkeleyDB backend is present.
    RpmBerkeleyDb,
    /// Only the rpm NDB backend is present.
    RpmNdb,
}

/// Receives each installed package and the paths it installs.
pub trait PackageSink {
    /// Registers a package and returns its index for `add_path`, or `None` to stop reading.
    fn add_package(&mut self, package: OwningPackage, resolver: PackageResolver) -> Option<u32>;
    /// Records that `package` installs `path`. Returns `false` to stop reading.
    fn add_path(&mut self, package: u32, path: &str) -> bool;
}

pub fn read_dpkg(root: &RootFs, os: &OsRelease, sink: &mut dyn PackageSink) -> DatabaseOutcome {
    let status = match root.open("/var/lib/dpkg/status") {
        Ok(file) => file,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return DatabaseOutcome::Absent,
        Err(_) => return DatabaseOutcome::Unreadable,
    };
    let namespace = non_empty_or(&os.id, "linux");
    let release = non_empty_or(&os.version_codename, &os.version_id);

    let mut stanza: HashMap<String, String> = HashMap::new();
    for line in BufReader::new(status).lines() {
        let Ok(line) = line else {
            return DatabaseOutcome::Unreadable;
        };
        if line.trim().is_empty() {
            if !stanza.is_empty()
                && let Some(outcome) = add_dpkg_package(root, &stanza, &namespace, &release, sink)
            {
                return outcome;
            }
            stanza.clear();
            continue;
        }
        // Continuation lines of multi-line fields (Description, Conffiles) are not needed.
        if line.starts_with([' ', '\t']) {
            continue;
        }
        if let Some((key, value)) = line.split_once(':') {
            stanza.insert(key.trim().to_string(), value.trim().to_string());
        }
    }
    if !stanza.is_empty()
        && let Some(outcome) = add_dpkg_package(root, &stanza, &namespace, &release, sink)
    {
        return outcome;
    }
    DatabaseOutcome::Read
}

/// Returns the database outcome when reading must stop: the sink asked to stop, or a file
/// list could not be read to the end.
fn add_dpkg_package(
    root: &RootFs,
    stanza: &HashMap<String, String>,
    namespace: &str,
    release: &str,
    sink: &mut dyn PackageSink,
) -> Option<DatabaseOutcome> {
    let field = |key: &str| stanza.get(key).map(String::as_str).unwrap_or_default();
    let name = field("Package");
    let version = field("Version");
    // "want flag status": only "installed" packages own files on disk.
    let installed = field("Status").split_whitespace().nth(2) == Some("installed");
    if name.is_empty() || version.is_empty() || !installed {
        return None;
    }
    let architecture = field("Architecture");
    let source = field("Source")
        .split_whitespace()
        .next()
        .filter(|source| !source.is_empty())
        .unwrap_or(name);

    let Some(index) = sink.add_package(
        OwningPackage {
            package_type: "deb".to_string(),
            package_manager: "dpkg".to_string(),
            // The endpoint inventory stores no ecosystem for OS packages; core maps this blank
            // value to an absent (nil) component before deriving the package identity key, as
            // it does for every blank identity field.
            ecosystem: String::new(),
            namespace: namespace.to_string(),
            release: release.to_string(),
            binary_package: name.to_string(),
            source_package: source.to_string(),
            architecture: architecture.to_string(),
            installed_version: version.to_string(),
        },
        PackageResolver::Dpkg,
    ) else {
        return Some(DatabaseOutcome::Read);
    };

    // Multi-Arch: same packages keep their list under "<name>:<arch>.list".
    let qualified = format!("/var/lib/dpkg/info/{name}:{architecture}.list");
    let plain = format!("/var/lib/dpkg/info/{name}.list");
    let Some(list) = [qualified, plain]
        .iter()
        .find_map(|path| root.open(path).ok())
    else {
        return None;
    };
    for line in BufReader::new(list).lines() {
        let Ok(path) = line else {
            return Some(DatabaseOutcome::Unreadable);
        };
        if path.starts_with('/') && path != "/." && !sink.add_path(index, &path) {
            return Some(DatabaseOutcome::Read);
        }
    }
    None
}

pub fn read_apk(root: &RootFs, os: &OsRelease, sink: &mut dyn PackageSink) -> DatabaseOutcome {
    let installed = match root.open("/lib/apk/db/installed") {
        Ok(file) => file,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return DatabaseOutcome::Absent,
        Err(_) => return DatabaseOutcome::Unreadable,
    };
    let namespace = non_empty_or(&os.id, "alpine");

    let mut current: Option<u32> = None;
    let mut pending = ApkRecord::default();
    let mut dir = String::new();
    for line in BufReader::new(installed).lines() {
        let Ok(line) = line else {
            return DatabaseOutcome::Unreadable;
        };
        if line.trim().is_empty() {
            current = None;
            pending = ApkRecord::default();
            dir.clear();
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        match key {
            "P" => pending.name = value.to_string(),
            "V" => pending.version = value.to_string(),
            "A" => pending.arch = value.to_string(),
            "F" => dir = value.trim_matches('/').to_string(),
            "R" => {
                let index = match current {
                    Some(index) => index,
                    None => {
                        if pending.name.is_empty() || pending.version.is_empty() {
                            continue;
                        }
                        let Some(index) = sink.add_package(
                            pending.to_package(&namespace, &os.version_id),
                            PackageResolver::Apk,
                        ) else {
                            return DatabaseOutcome::Read;
                        };
                        current = Some(index);
                        index
                    }
                };
                let path = if dir.is_empty() {
                    format!("/{value}")
                } else {
                    format!("/{dir}/{value}")
                };
                if !sink.add_path(index, &path) {
                    return DatabaseOutcome::Read;
                }
            }
            _ => {}
        }
    }
    DatabaseOutcome::Read
}

#[derive(Default)]
struct ApkRecord {
    name: String,
    version: String,
    arch: String,
}

impl ApkRecord {
    fn to_package(&self, namespace: &str, release: &str) -> OwningPackage {
        // The inventory package URL lower-cases apk names and carries the origin, not a
        // source package, so the source identity is the binary name.
        let name = self.name.to_lowercase();
        OwningPackage {
            package_type: "apk".to_string(),
            package_manager: "apk".to_string(),
            // The endpoint inventory stores no ecosystem for OS packages; core maps this blank
            // value to an absent (nil) component before deriving the package identity key, as
            // it does for every blank identity field.
            ecosystem: String::new(),
            namespace: namespace.to_string(),
            release: release.to_string(),
            binary_package: name.clone(),
            source_package: name,
            architecture: self.arch.clone(),
            installed_version: self.version.clone(),
        }
    }
}

/// The rpm database directories, in the order rpm itself prefers them.
const RPM_DIRECTORIES: [&str; 2] = ["/usr/lib/sysimage/rpm", "/var/lib/rpm"];

pub fn read_rpm(root: &RootFs, os: &OsRelease, sink: &mut dyn PackageSink) -> DatabaseOutcome {
    // The first sqlite database found is the one rpm uses; /var/lib/rpm is commonly a
    // symlink to /usr/lib/sysimage/rpm.
    let mut outcome = DatabaseOutcome::Absent;
    for directory in RPM_DIRECTORIES {
        if let Ok(sqlite) = root.resolve(&format!("{directory}/rpmdb.sqlite")) {
            if wal_pending(&sqlite) {
                return DatabaseOutcome::WalPending;
            }
            return match read_rpm_sqlite(&sqlite, os, sink) {
                Ok(()) => DatabaseOutcome::Read,
                Err(_) => DatabaseOutcome::Unreadable,
            };
        }
        if root.resolve(&format!("{directory}/Packages.db")).is_ok() {
            outcome = DatabaseOutcome::RpmNdb;
        } else if root.resolve(&format!("{directory}/Packages")).is_ok() {
            outcome = DatabaseOutcome::RpmBerkeleyDb;
        }
    }
    outcome
}

/// SQLite deletes the write-ahead log when the last connection closes, so a non-empty
/// log means a transaction is open or was interrupted and the main file may be stale.
fn wal_pending(database: &Path) -> bool {
    let mut wal = database.as_os_str().to_owned();
    wal.push("-wal");
    fs::metadata(Path::new(&wal)).is_ok_and(|metadata| metadata.len() > 0)
}

fn read_rpm_sqlite(
    path: &Path,
    os: &OsRelease,
    sink: &mut dyn PackageSink,
) -> Result<(), super::sqlite::SqliteError> {
    let database = SqliteDatabase::open(path)?;
    let Some(root_page) = database.table_root_page("Packages")? else {
        return Err(super::sqlite::SqliteError::Malformed("no Packages table"));
    };
    let namespace = rpm_namespace(&os.id);
    let release = rpm_distro(os);
    let mut malformed = false;
    database.scan_table(root_page, |_, columns| {
        let Some(Value::Blob(blob)) = columns.into_iter().find(|v| matches!(v, Value::Blob(_)))
        else {
            return true;
        };
        let Some(package) = rpm_header::parse(&blob) else {
            malformed = true;
            return false;
        };
        // gpg-pubkey pseudo-packages install no files.
        if package.executable_paths.is_empty() {
            return true;
        }
        let Some(index) = sink.add_package(
            OwningPackage {
                package_type: "rpm".to_string(),
                package_manager: "rpm".to_string(),
                // The endpoint inventory stores no ecosystem for OS packages; core maps this blank
                // value to an absent (nil) component before deriving the package identity key, as
                // it does for every blank identity field.
                ecosystem: String::new(),
                namespace: namespace.clone(),
                release: release.clone(),
                binary_package: package.name.clone(),
                // rpm package URLs carry `sourcerpm`, not a `source` qualifier, so the
                // inventory's source identity is the binary name.
                source_package: package.name,
                architecture: package.arch,
                installed_version: package.version,
            },
            PackageResolver::Rpm,
        ) else {
            return false;
        };
        package
            .executable_paths
            .iter()
            .all(|path| sink.add_path(index, path))
    })?;
    if malformed {
        return Err(super::sqlite::SqliteError::Malformed("rpm header"));
    }
    Ok(())
}

fn rpm_namespace(id: &str) -> String {
    match id {
        "sles" => "suse".to_string(),
        "azurelinux" | "mariner" => "azurelinux".to_string(),
        other => other.to_string(),
    }
}

fn rpm_distro(os: &OsRelease) -> String {
    let version = non_empty_or(&os.version_id, &os.build_id);
    match (os.id.is_empty(), version.is_empty()) {
        (_, true) => String::new(),
        (true, false) => version,
        (false, false) => format!("{}-{version}", os.id),
    }
}

fn non_empty_or(value: &str, fallback: &str) -> String {
    if value.is_empty() {
        fallback.to_string()
    } else {
        value.to_string()
    }
}
