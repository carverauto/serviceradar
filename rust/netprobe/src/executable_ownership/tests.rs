//! Resolution tests against a synthetic procfs: `<tmp>/proc/<pid>/{exe,root}` are
//! symlinks into invented root filesystems, as the kernel's magic links are. Every
//! package, path and version is invented.

use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::*;

const RPMDB_FIXTURE: &[u8] = include_bytes!("../../testdata/executable_ownership/rpmdb.sqlite");

/// One precedence case: name, root setup, expected state and detail.
type PrecedenceCase = (&'static str, fn(&Path), OwnershipState, &'static str);

struct Fixture {
    dir: tempfile::TempDir,
}

impl Fixture {
    /// A procfs whose pid 1 runs in the `host` root.
    fn new() -> Self {
        let fixture = Self {
            dir: tempfile::tempdir().unwrap(),
        };
        let host = fixture.root("host");
        fs::create_dir_all(fixture.proc().join("1")).unwrap();
        symlink(&host, fixture.proc().join("1/root")).unwrap();
        fixture
    }

    fn proc(&self) -> PathBuf {
        self.dir.path().join("proc")
    }

    fn root(&self, name: &str) -> PathBuf {
        let root = self.dir.path().join(name);
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn process(&self, pid: u32, root: &Path, executable: &Path) {
        let dir = self.proc().join(pid.to_string());
        fs::create_dir_all(&dir).unwrap();
        symlink(executable, dir.join("exe")).unwrap();
        symlink(root, dir.join("root")).unwrap();
    }

    fn resolver(&self) -> ExecutableOwnershipResolver {
        ExecutableOwnershipResolver::new(self.proc())
    }
}

fn write(path: &Path, contents: &[u8]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, contents).unwrap();
}

fn write_executable(path: &Path) {
    write(path, b"\x7fELF");
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn os_release(root: &Path, contents: &str) {
    write(&root.join("etc/os-release"), contents.as_bytes());
}

/// Writes a dpkg status file and one list file per package.
fn dpkg(root: &Path, packages: &[(&str, &str, &str, &[&str])]) {
    let mut status = String::new();
    for (name, version, source, files) in packages {
        status.push_str(&format!(
            "Package: {name}\nStatus: install ok installed\nArchitecture: amd64\n\
             Version: {version}\nSource: {source}\nDescription: invented\n \
             continuation line\n\n"
        ));
        let list: String = files.iter().map(|path| format!("{path}\n")).collect();
        write(
            &root.join(format!("var/lib/dpkg/info/{name}.list")),
            format!("/.\n/usr\n{list}").as_bytes(),
        );
    }
    write(&root.join("var/lib/dpkg/status"), status.as_bytes());
}

fn package(record: &ExecutableOwnershipRecord) -> &OwningPackage {
    record
        .package
        .as_deref()
        .expect("resolved record names a package")
}

#[test]
fn dpkg_executable_resolves_to_its_package_on_the_host() {
    let fixture = Fixture::new();
    let host = fixture.root("host");
    os_release(
        &host,
        "ID=debian\nVERSION_ID=\"12\"\nVERSION_CODENAME=bookworm\n",
    );
    dpkg(
        &host,
        &[
            (
                "example-daemon",
                "1:2.4.1-3",
                "example-src",
                &["/usr/sbin/exampled"],
            ),
            (
                "example-docs",
                "2.4.1-3",
                "example-src",
                &["/usr/share/doc/example/README"],
            ),
        ],
    );
    write_executable(&host.join("usr/sbin/exampled"));
    fixture.process(4242, &host, &host.join("usr/sbin/exampled"));

    let record = fixture.resolver().resolve(4242);

    assert_eq!(record.state, OwnershipState::Resolved);
    assert_eq!(record.source_scope, SCOPE_HOST);
    assert_eq!(record.resolver, Some(PackageResolver::Dpkg));
    assert_eq!(record.executable_path, "/usr/sbin/exampled");
    assert_eq!(
        record.inode,
        fs::metadata(host.join("usr/sbin/exampled")).unwrap().ino()
    );
    assert_eq!(
        package(&record),
        &OwningPackage {
            package_type: "deb".to_string(),
            package_manager: "dpkg".to_string(),
            namespace: "debian".to_string(),
            release: "bookworm".to_string(),
            ecosystem: String::new(),
            binary_package: "example-daemon".to_string(),
            source_package: "example-src".to_string(),
            architecture: "amd64".to_string(),
            installed_version: "1:2.4.1-3".to_string(),
        }
    );
}

#[test]
fn listed_path_through_a_directory_symlink_resolves_by_inode() {
    // A merged-/usr host: the package lists /sbin/exampled, the kernel reports the
    // canonical /usr/sbin/exampled.
    let fixture = Fixture::new();
    let host = fixture.root("host");
    dpkg(
        &host,
        &[(
            "example-daemon",
            "2.0-1",
            "example-daemon",
            &["/sbin/exampled"],
        )],
    );
    write_executable(&host.join("usr/sbin/exampled"));
    symlink("usr/sbin", host.join("sbin")).unwrap();
    fixture.process(4242, &host, &host.join("usr/sbin/exampled"));

    let record = fixture.resolver().resolve(4242);

    assert_eq!(record.state, OwnershipState::Resolved);
    assert_eq!(package(&record).binary_package, "example-daemon");
}

#[test]
fn container_process_resolves_against_its_own_root() {
    let fixture = Fixture::new();
    let host = fixture.root("host");
    // The host owns a file at the same path; the container's database must win.
    dpkg(
        &host,
        &[(
            "host-example",
            "9.9-1",
            "host-example",
            &["/usr/bin/examplectl"],
        )],
    );
    write_executable(&host.join("usr/bin/examplectl"));

    let container = fixture.root("container");
    os_release(&container, "ID=alpine\nVERSION_ID=3.20.1\n");
    write(
        &container.join("lib/apk/db/installed"),
        b"C:Q1invented=\nP:Example-CTL\nV:1.2.3-r0\nA:x86_64\no:example-ctl\n\
          F:usr/bin\nR:examplectl\nF:etc/example\nR:examplectl.conf\n\n",
    );
    write_executable(&container.join("usr/bin/examplectl"));
    fixture.process(5151, &container, &container.join("usr/bin/examplectl"));

    let record = fixture.resolver().resolve(5151);

    assert_eq!(record.state, OwnershipState::Resolved);
    assert_eq!(record.source_scope, SCOPE_CONTAINER);
    assert_eq!(record.resolver, Some(PackageResolver::Apk));
    let package = package(&record);
    assert_eq!(package.binary_package, "example-ctl");
    assert_eq!(package.source_package, "example-ctl");
    assert_eq!(package.installed_version, "1.2.3-r0");
    assert_eq!(package.namespace, "alpine");
    assert_eq!(package.release, "3.20.1");
}

#[test]
fn rpm_sqlite_database_resolves_including_headers_that_overflow_a_page() {
    let fixture = Fixture::new();
    let host = fixture.root("host");
    os_release(&host, "ID=\"rhel\"\nVERSION_ID=\"9.4\"\n");
    write(
        &host.join("usr/lib/sysimage/rpm/rpmdb.sqlite"),
        RPMDB_FIXTURE,
    );
    // rpm hosts commonly link the legacy directory to the new one; read it once.
    fs::create_dir_all(host.join("var/lib")).unwrap();
    symlink("../../usr/lib/sysimage/rpm", host.join("var/lib/rpm")).unwrap();
    write_executable(&host.join("usr/sbin/exampled"));
    // example-tools lists 600 executables; its header spans overflow pages.
    write_executable(&host.join("usr/libexec/example-tools/tool-450"));
    fixture.process(10, &host, &host.join("usr/sbin/exampled"));
    fixture.process(11, &host, &host.join("usr/libexec/example-tools/tool-450"));
    let mut resolver = fixture.resolver();

    let daemon = resolver.resolve(10);
    let tool = resolver.resolve(11);

    assert_eq!(daemon.state, OwnershipState::Resolved);
    assert_eq!(daemon.resolver, Some(PackageResolver::Rpm));
    let daemon = package(&daemon);
    assert_eq!(daemon.binary_package, "exampled");
    assert_eq!(daemon.source_package, "exampled");
    assert_eq!(daemon.installed_version, "2.4.1-3.el9");
    assert_eq!(daemon.architecture, "x86_64");
    assert_eq!(daemon.namespace, "rhel");
    assert_eq!(daemon.release, "rhel-9.4");
    assert_eq!(tool.state, OwnershipState::Resolved);
    assert_eq!(package(&tool).binary_package, "example-tools");
}

#[test]
fn replaced_binary_is_not_attributed_to_the_upgraded_package() {
    // The package was upgraded while the process kept running: the installed path holds
    // the new file, and the kernel reports the running executable deleted.
    let fixture = Fixture::new();
    let host = fixture.root("host");
    dpkg(
        &host,
        &[(
            "example-daemon",
            "2.0-1",
            "example-daemon",
            &["/usr/sbin/exampled"],
        )],
    );
    write_executable(&host.join("usr/sbin/exampled"));
    let old_binary = host.join("usr/sbin/exampled (deleted)");
    write_executable(&old_binary);
    fixture.process(4242, &host, &old_binary);

    let record = fixture.resolver().resolve(4242);

    assert_eq!(record.state, OwnershipState::Unknown);
    assert_eq!(record.detail, DETAIL_EXECUTABLE_DELETED);
    assert_eq!(record.package, None);
    assert_eq!(record.executable_path, "/usr/sbin/exampled");
}

#[test]
fn executable_deleted_after_resolution_is_not_served_from_the_cache() {
    let fixture = Fixture::new();
    let host = fixture.root("host");
    dpkg(
        &host,
        &[(
            "example-daemon",
            "2.0-1",
            "example-daemon",
            &["/usr/sbin/exampled"],
        )],
    );
    let installed = host.join("usr/sbin/exampled");
    write_executable(&installed);
    fixture.process(4242, &host, &installed);
    let mut resolver = fixture.resolver();
    assert_eq!(resolver.resolve(4242).state, OwnershipState::Resolved);

    // Unlinking keeps the running inode, size and mtime; the kernel only marks the link.
    let unlinked = host.join("usr/sbin/exampled (deleted)");
    fs::rename(&installed, &unlinked).unwrap();
    let exe = fixture.proc().join("4242/exe");
    fs::remove_file(&exe).unwrap();
    symlink(&unlinked, &exe).unwrap();

    let record = resolver.resolve(4242);

    assert_eq!(record.state, OwnershipState::Unknown);
    assert_eq!(record.detail, DETAIL_EXECUTABLE_DELETED);
    assert_eq!(record.package, None);
}

#[test]
fn unowned_executable_is_not_found_and_names_no_package() {
    let fixture = Fixture::new();
    let host = fixture.root("host");
    dpkg(
        &host,
        &[(
            "example-daemon",
            "2.0-1",
            "example-daemon",
            &["/usr/sbin/exampled"],
        )],
    );
    write_executable(&host.join("opt/example/bin/app"));
    fixture.process(4242, &host, &host.join("opt/example/bin/app"));

    let record = fixture.resolver().resolve(4242);

    assert_eq!(record.state, OwnershipState::NotFound);
    assert_eq!(record.detail, DETAIL_NOT_OWNED);
    assert_eq!(record.package, None);
}

#[test]
fn unsupported_and_incomplete_databases_are_reported_by_precedence() {
    let cases: [PrecedenceCase; 6] = [
        (
            "berkeleydb",
            |root| write(&root.join("var/lib/rpm/Packages"), b"\0\0\0\0"),
            OwnershipState::UnsupportedDb,
            DETAIL_RPM_BERKELEYDB,
        ),
        (
            "ndb",
            |root| write(&root.join("var/lib/rpm/Packages.db"), b"\0\0\0\0"),
            OwnershipState::UnsupportedDb,
            DETAIL_RPM_NDB,
        ),
        (
            "dpkg read with a leftover berkeleydb",
            |root| {
                dpkg(
                    root,
                    &[(
                        "example-docs",
                        "1.0-1",
                        "example-docs",
                        &["/usr/share/doc/example/README"],
                    )],
                );
                write(&root.join("var/lib/rpm/Packages"), b"\0\0\0\0");
            },
            OwnershipState::NotFound,
            DETAIL_NOT_OWNED,
        ),
        (
            "dpkg file list unreadable before the executable",
            |root| {
                dpkg(
                    root,
                    &[(
                        "example-daemon",
                        "2.0-1",
                        "example-daemon",
                        &["/usr/sbin/exampled"],
                    )],
                );
                write(
                    &root.join("var/lib/dpkg/info/example-daemon.list"),
                    b"/.\n/usr/lib/example\xff\n/usr/sbin/exampled\n",
                );
            },
            OwnershipState::Unknown,
            DETAIL_PACKAGE_DATABASE_UNREADABLE,
        ),
        (
            "wal pending",
            |root| {
                // The executable is listed in the main file, but a transaction is open.
                write(&root.join("var/lib/rpm/rpmdb.sqlite"), RPMDB_FIXTURE);
                write(&root.join("var/lib/rpm/rpmdb.sqlite-wal"), b"pending");
            },
            OwnershipState::Unknown,
            DETAIL_RPMDB_WAL_PENDING,
        ),
        (
            "no database",
            |_| {},
            OwnershipState::Unknown,
            DETAIL_NO_PACKAGE_DATABASE,
        ),
    ];
    for (name, setup, state, detail) in cases {
        let fixture = Fixture::new();
        let host = fixture.root("host");
        setup(&host);
        write_executable(&host.join("usr/sbin/exampled"));
        fixture.process(4242, &host, &host.join("usr/sbin/exampled"));

        let record = fixture.resolver().resolve(4242);

        assert_eq!((record.state, record.detail), (state, detail), "{name}");
        assert_eq!(record.package, None, "{name}");
    }
}

#[test]
fn exited_process_is_unknown() {
    let fixture = Fixture::new();

    let record = fixture.resolver().resolve(999_999);

    assert_eq!(record.state, OwnershipState::Unknown);
    assert_eq!(record.detail, DETAIL_PROCESS_EXITED);
}

#[test]
fn resolution_happens_once_per_executable_inode_until_the_database_changes() {
    let fixture = Fixture::new();
    let host = fixture.root("host");
    dpkg(
        &host,
        &[(
            "example-daemon",
            "2.0-1",
            "example-daemon",
            &["/usr/sbin/exampled"],
        )],
    );
    write_executable(&host.join("usr/sbin/exampled"));
    // Many processes, one executable inode.
    for pid in 100..110 {
        fixture.process(pid, &host, &host.join("usr/sbin/exampled"));
    }
    let mut resolver = fixture.resolver();
    let start = Instant::now();

    for pid in 100..110 {
        assert_eq!(
            resolver.resolve_at(pid, start).state,
            OwnershipState::Resolved
        );
    }
    assert_eq!(
        resolver.take_counters(),
        ResolverCounters {
            resolutions: 1,
            cache_hits: 9,
            index_builds: 1,
        }
    );

    // An upgrade rewrites the database. Inside the re-index interval the answer is
    // withheld rather than served from the old index.
    // A longer version changes the status file's size, so the change is seen even where
    // the filesystem's timestamp granularity is coarse.
    dpkg(
        &host,
        &[(
            "example-daemon",
            "2.10-1",
            "example-daemon",
            &["/usr/sbin/exampled"],
        )],
    );
    let changing = resolver.resolve_at(100, start + Duration::from_secs(1));
    assert_eq!(changing.state, OwnershipState::Unknown);
    assert_eq!(changing.detail, DETAIL_PACKAGE_DATABASE_CHANGING);

    let upgraded = resolver.resolve_at(100, start + MIN_REINDEX_INTERVAL);
    assert_eq!(package(&upgraded).installed_version, "2.10-1");
    assert_eq!(
        resolver.take_counters(),
        ResolverCounters {
            resolutions: 1,
            cache_hits: 0,
            index_builds: 1,
        }
    );
}
