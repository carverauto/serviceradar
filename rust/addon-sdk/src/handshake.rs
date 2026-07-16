/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! The HashiCorp `go-plugin` handshake, implemented for the plugin (server)
//! side in Rust.
//!
//! Pinned against `github.com/hashicorp/go-plugin@v1.8.0` (`server.go`,
//! `constants.go`). The contract is:
//!
//! 1. The host sets the magic-cookie env var before launching the plugin; the
//!    plugin refuses to run as a plugin unless it matches.
//! 2. The plugin binds a Unix-domain socket (the host restricts the directory
//!    via `PLUGIN_UNIX_SOCKET_DIR`).
//! 3. The plugin prints exactly one handshake line to stdout, then flushes:
//!    `CORE|APP|net|addr|proto|cert` (six pipe-separated fields; a seventh gRPC
//!    broker-multiplexing flag is appended only when `PLUGIN_MULTIPLEX_GRPC` is
//!    set, matching go-plugin's behavior for old-client compatibility).
//!
//! The values must match `go/pkg/addon/addon.go` (`ProtocolVersion`,
//! `PluginName`, magic cookie) so the agent's *unmodified* go-plugin client
//! accepts the Rust add-on.

use std::io::Write as _;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use tokio::net::UnixListener;

/// The go-plugin core protocol version (`plugin.CoreProtocolVersion`). Distinct
/// from the application protocol version negotiated per add-on.
pub const CORE_PROTOCOL_VERSION: u32 = 1;

/// Application protocol version negotiated between the agent and add-ons. Must
/// equal `addon.ProtocolVersion` in `go/pkg/addon/addon.go`.
pub const APP_PROTOCOL_VERSION: u32 = 1;

/// The dispense key under which the Addon service is served. Must equal
/// `addon.PluginName` in `go/pkg/addon/addon.go`.
pub const PLUGIN_NAME: &str = "addon";

/// Magic cookie key/value guarding deliberate plugin launches. Must equal
/// `addon.magicCookieKey`/`magicCookieValue`. This is a UX guard, not a security
/// boundary (AutoMTLS provides that).
pub const MAGIC_COOKIE_KEY: &str = "SERVICERADAR_ADDON_PLUGIN";
pub const MAGIC_COOKIE_VALUE: &str = "serviceradar-addon-v1";

/// go-plugin environment variables the host passes to the plugin.
pub const ENV_CLIENT_CERT: &str = "PLUGIN_CLIENT_CERT";
pub const ENV_UNIX_SOCKET_DIR: &str = "PLUGIN_UNIX_SOCKET_DIR";
pub const ENV_UNIX_SOCKET_GROUP: &str = "PLUGIN_UNIX_SOCKET_GROUP";
pub const ENV_MULTIPLEX_GRPC: &str = "PLUGIN_MULTIPLEX_GRPC";
pub const ENV_PROTOCOL_VERSIONS: &str = "PLUGIN_PROTOCOL_VERSIONS";

/// The gRPC protocol identifier used in the handshake line (`plugin.ProtocolGRPC`).
pub const PROTOCOL_GRPC: &str = "grpc";

/// Errors raised while completing the handshake.
#[derive(Debug, thiserror::Error)]
pub enum HandshakeError {
    #[error(
        "magic cookie {key} not set or mismatched; this binary is a plugin and is not meant to be executed directly"
    )]
    MagicCookie { key: String },
    #[error("failed to create plugin unix socket: {0}")]
    Socket(#[from] std::io::Error),
}

/// Verifies the magic cookie the host must set before launching the plugin.
///
/// Mirrors go-plugin's `Serve` check: on mismatch the real server prints a
/// human-friendly message and exits 1. Here we surface the friendly message and
/// return an error so the caller controls process exit.
pub fn check_magic_cookie() -> Result<(), HandshakeError> {
    match std::env::var(MAGIC_COOKIE_KEY) {
        Ok(v) if v == MAGIC_COOKIE_VALUE => Ok(()),
        _ => Err(HandshakeError::MagicCookie {
            key: MAGIC_COOKIE_KEY.to_string(),
        }),
    }
}

/// The human-friendly message go-plugin prints when a plugin binary is run
/// directly (magic cookie missing). Emitted by the reference binary so operators
/// running the add-on by hand get the same UX as a Go add-on.
pub const DIRECT_EXECUTION_MESSAGE: &str = "This binary is a plugin. These are not meant to be executed directly.\n\
Please execute the program that consumes these plugins, which will\n\
load any plugins automatically\n";

/// A bound Unix-domain socket plus the path the handshake line advertises.
pub struct PluginListener {
    pub listener: UnixListener,
    pub path: PathBuf,
}

/// Binds the plugin's Unix-domain socket exactly like go-plugin's
/// `serverListener_unix`: create a unique temp name inside the host-restricted
/// directory, remove it (the socket path must not pre-exist), then `bind`.
///
/// Honors `PLUGIN_UNIX_SOCKET_DIR` (the host's restricted runtime dir) and
/// `PLUGIN_UNIX_SOCKET_GROUP` (chgrp + 0660) so the socket lands where the agent
/// expects and with the permissions it configured.
pub fn bind_plugin_socket() -> Result<PluginListener, HandshakeError> {
    let dir = std::env::var(ENV_UNIX_SOCKET_DIR).unwrap_or_default();
    let path = unique_socket_path(if dir.is_empty() {
        std::env::temp_dir()
    } else {
        PathBuf::from(dir)
    })?;

    // The path must not exist for bind(2).
    let _ = std::fs::remove_file(&path);

    let listener = UnixListener::bind(&path)?;

    // Match go-plugin: when a group is configured, make the socket group-owned
    // and group-writable (0660). Best-effort: a chown failure should not abort
    // the handshake on systems where the agent did not request a group.
    if let Ok(group) = std::env::var(ENV_UNIX_SOCKET_GROUP)
        && !group.is_empty()
    {
        apply_socket_group(&path, &group)?;
    }

    Ok(PluginListener { listener, path })
}

/// Mirrors go-plugin's `os.CreateTemp(dir, "plugin")`: a `plugin` prefix plus a
/// random suffix, kept short enough for `sockaddr_un`'s path limit.
fn unique_socket_path(dir: PathBuf) -> Result<PathBuf, std::io::Error> {
    // Derive a non-secret unique suffix from pid + a monotonic-ish nonce. We do
    // not need cryptographic randomness here; uniqueness within the runtime dir
    // is sufficient and the agent restricts the directory.
    use std::time::{SystemTime, UNIX_EPOCH};
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let name = format!("plugin{}{}", std::process::id(), nonce);
    Ok(dir.join(name))
}

fn apply_socket_group(path: &Path, group: &str) -> Result<(), std::io::Error> {
    // Resolve the group: accept a numeric gid directly, otherwise leave the
    // owning group unchanged and only relax permissions. We avoid pulling in a
    // libc dependency for name lookup; the agent passes a gid in practice, and
    // the common case (no group) skips this entirely.
    if let Ok(gid) = group.parse::<u32>() {
        chown_group(path, gid)?;
    }
    let mut perms = std::fs::metadata(path)?.permissions();
    perms.set_mode(0o660);
    std::fs::set_permissions(path, perms)?;
    Ok(())
}

#[cfg(unix)]
fn chown_group(path: &Path, gid: u32) -> Result<(), std::io::Error> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt as _;
    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
    // SAFETY: c_path is a valid NUL-terminated C string for the lifetime of the
    // call; -1 leaves the owning uid unchanged.
    let rc = unsafe { libc_chown(c_path.as_ptr(), u32::MAX, gid) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

// Minimal extern binding for chown(2) to avoid taking a libc crate dependency
// solely for the optional socket-group path. `u32::MAX` is passed for the uid to
// mean "unchanged" (it casts to -1 as uid_t).
unsafe extern "C" {
    #[link_name = "chown"]
    fn libc_chown(path: *const std::os::raw::c_char, owner: u32, group: u32)
    -> std::os::raw::c_int;
}

/// Builds the handshake line the host parses (`client.go` `dialer`/`parseConn`).
///
/// Format: `CORE|APP|network|address|protocol|cert`. The seventh field
/// (gRPC broker multiplexing support) is appended only when
/// `PLUGIN_MULTIPLEX_GRPC` is set, matching go-plugin's old-client-safe behavior.
///
/// `server_cert` is the base64 (RawStdEncoding, i.e. no padding) of the server
/// leaf certificate DER, or empty when AutoMTLS is not active.
pub fn build_handshake_line(socket_path: &Path, server_cert: &str) -> String {
    let mut line = format!(
        "{}|{}|unix|{}|{}|{}",
        CORE_PROTOCOL_VERSION,
        APP_PROTOCOL_VERSION,
        socket_path.display(),
        PROTOCOL_GRPC,
        server_cert,
    );
    if std::env::var(ENV_MULTIPLEX_GRPC)
        .map(|v| !v.is_empty())
        .unwrap_or(false)
    {
        // go-plugin appends `|true` to advertise broker multiplexing support.
        line.push_str("|true");
    }
    line
}

/// Writes the handshake line to stdout and flushes, matching go-plugin's
/// `fmt.Printf("%s\n", line); os.Stdout.Sync()`. The host reads exactly one line
/// from the plugin's stdout to learn the socket address and server certificate.
pub fn emit_handshake_line(line: &str) -> std::io::Result<()> {
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{line}")?;
    stdout.flush()
}
