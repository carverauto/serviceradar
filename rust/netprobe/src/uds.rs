//! Unix-domain-socket controls shared by netprobe's two IPC surfaces.
//!
//! Both the legacy `NetprobeFrame` socket ([`crate::server`]) and the generic
//! `AddonService` socket ([`crate::addon_service`]) need the same two things,
//! and having each grow its own copy is how one of them drifts. They are
//! deliberately different in kind:
//!
//! * [`restrict_to_owner`] is an **access control**. It is the only thing
//!   standing between these sockets and every other local account.
//! * [`PeerCredentials`] is **evidence**. It cannot authorize anything (see
//!   below) but it records which local process opened the connection, which is
//!   what a host-local audit trail needs.

use std::path::Path;

use anyhow::{Context, Result};

/// Make `path` reachable only by its owner, and prove it took effect.
///
/// `surface` names what is being protected and appears in the failure, because
/// "refusing to serve" is only actionable if the operator knows which socket.
///
/// The read-back is not defensive padding: `set_permissions` reports success on
/// mounts that ignore `chmod` entirely. Refusing to serve is the right failure
/// mode here — a socket nobody can reach is a loud, fixable problem, while one
/// reachable by every local account is a silent one.
pub fn restrict_to_owner(path: &Path, surface: &str) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to restrict {}", path.display()))?;

        let mode = std::fs::metadata(path)
            .with_context(|| format!("failed to stat {}", path.display()))?
            .permissions()
            .mode()
            & 0o777;

        if mode != 0o600 {
            anyhow::bail!(
                "refusing to serve {surface} on {}: mode is {mode:o}, not 0600 -- \
                 it would be reachable by other local processes",
                path.display(),
            );
        }
    }

    #[cfg(not(unix))]
    {
        let _ = (path, surface);
    }

    Ok(())
}

/// The connecting process, as the kernel reported it at `connect` time.
///
/// # This is not an authorization control, and must not become one
///
/// The socket is mode 0600 owned by netprobe's runtime user, so the only uids
/// that can reach it are that user and root — and root defeats a uid allowlist
/// with a single `setuid` before `connect`. A uid check would therefore reject
/// nothing that 0600 does not already reject, while breaking clients that work
/// today (a `sudo` dev loop, `sudo grpcurl -unix` for triage) and breaking them
/// invisibly.
///
/// `pid` is worth recording anyway, and worth being honest about: it is a
/// snapshot from `connect` time. The process may have `exec`ed since, and after
/// it exits the number is reusable. So it identifies a connection in the log
/// well enough to correlate with the journal, and identifies nothing at all
/// well enough to grant a permission.
///
/// What actually keeps a capture from being started by something that bypassed
/// the control plane is that netprobe refuses a request carrying no
/// core-issued session id and actor — an unforgeable-by-locality control rather
/// than a guessable one. See `design.md` D8.7.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PeerCredentials {
    pub pid: i32,
    pub uid: u32,
    pub gid: u32,
}

impl std::fmt::Display for PeerCredentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "pid={} uid={} gid={}", self.pid, self.uid, self.gid)
    }
}

/// Read `SO_PEERCRED` from a connected Unix stream.
///
/// Returns `None` rather than failing the connection: this is evidence, and
/// losing the evidence is not a reason to refuse a client that the mode already
/// authorized. The caller logs the absence.
#[cfg(target_os = "linux")]
pub fn peer_credentials(stream: &tokio::net::UnixStream) -> Option<PeerCredentials> {
    use std::os::fd::AsRawFd;

    let mut ucred = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;

    // SAFETY: `ucred` and `len` are correctly sized for SO_PEERCRED on a
    // SOCK_STREAM AF_UNIX socket, and `fd` is owned by the live `stream`.
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            std::ptr::from_mut(&mut ucred).cast::<libc::c_void>(),
            &mut len,
        )
    };

    if rc != 0 || len as usize != std::mem::size_of::<libc::ucred>() {
        return None;
    }

    Some(PeerCredentials {
        pid: ucred.pid,
        uid: ucred.uid,
        gid: ucred.gid,
    })
}

/// `SO_PEERCRED` is Linux-specific. Other platforms spell it differently
/// (`LOCAL_PEERCRED`, `getpeereid`) and netprobe does not run there, so the
/// evidence is simply absent rather than wrong.
#[cfg(not(target_os = "linux"))]
pub fn peer_credentials(_stream: &tokio::net::UnixStream) -> Option<PeerCredentials> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn restricting_a_socket_makes_it_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("s.sock");
        let _listener = tokio::net::UnixListener::bind(&path).unwrap();

        restrict_to_owner(&path, "test surface").unwrap();

        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[tokio::test]
    async fn a_loosened_socket_is_re_restricted() {
        // Guards the read-back: if `set_permissions` were skipped or ignored,
        // this would still be 0666 and the assertion would say so.
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("s.sock");
        let _listener = tokio::net::UnixListener::bind(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();

        restrict_to_owner(&path, "test surface").unwrap();

        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn restricting_a_missing_path_fails_rather_than_reporting_success() {
        // A bind that silently did not create the socket must not leave a
        // caller believing the mode was applied.
        let dir = tempfile::TempDir::new().unwrap();
        let err = restrict_to_owner(&dir.path().join("absent.sock"), "test surface")
            .expect_err("a missing socket cannot have been restricted");
        assert!(
            format!("{err:#}").contains("failed to restrict"),
            "the failure must name what it could not do: {err:#}"
        );
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn peer_credentials_report_this_process() {
        // The only self-checkable assertion: a connection from this test IS
        // this process, so the pid must be ours.
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("s.sock");
        let listener = tokio::net::UnixListener::bind(&path).unwrap();

        let accept = tokio::spawn(async move { listener.accept().await.unwrap().0 });
        let _client = tokio::net::UnixStream::connect(&path).await.unwrap();
        let server_side = accept.await.unwrap();

        let creds = peer_credentials(&server_side).expect("SO_PEERCRED on a connected stream");
        assert_eq!(creds.pid, std::process::id() as i32);
        assert_eq!(creds.uid, unsafe { libc::getuid() });
    }
}
