// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use crate::{BoxedFuture, Error, MaybeSend, Result};
use bytes::Bytes;
use std::collections::HashMap;
use std::fmt::Debug;
use std::future::Future;
use std::ops::Deref;
use std::path::PathBuf;
use std::sync::Arc;

/// Context provides the context for the request signing.
///
/// ## Important
///
/// reqsign provides NO default implementations. Users MAY configure components they need.
/// Any unconfigured component will use a no-op implementation that returns errors or empty values when called.
///
/// ## Example
///
/// ```
/// use reqsign_core::{Context, OsEnv};
///
/// // Create a context with explicit implementations
/// let ctx = Context::new()
///     .with_env(OsEnv);  // Optionally configure environment implementation
/// ```
#[derive(Clone)]
pub struct Context {
    fs: Arc<dyn FileReadDyn>,
    http: Arc<dyn HttpSendDyn>,
    env: Arc<dyn Env>,
    cmd: Arc<dyn CommandExecuteDyn>,
}

impl Debug for Context {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Context")
            .field("fs", &self.fs)
            .field("http", &self.http)
            .field("env", &self.env)
            .field("cmd", &self.cmd)
            .finish()
    }
}

impl Default for Context {
    fn default() -> Self {
        Self::new()
    }
}

impl Context {
    /// Create a new Context with no-op implementations.
    ///
    /// All components use no-op implementations by default.
    /// Use the `with_*` methods to configure the components you need.
    ///
    /// ```
    /// use reqsign_core::Context;
    ///
    /// let ctx = Context::new();
    /// // All components use no-op implementations by default
    /// // You can configure specific components as needed:
    /// // ctx.with_file_read(my_file_reader)
    /// //    .with_http_send(my_http_client)
    /// //    .with_env(my_env_provider);
    /// ```
    pub fn new() -> Self {
        Self {
            fs: Arc::new(NoopFileRead),
            http: Arc::new(NoopHttpSend),
            env: Arc::new(NoopEnv),
            cmd: Arc::new(NoopCommandExecute),
        }
    }

    /// Replace the file reader implementation.
    pub fn with_file_read(mut self, fs: impl FileRead) -> Self {
        self.fs = Arc::new(fs);
        self
    }

    /// Replace the HTTP client implementation.
    pub fn with_http_send(mut self, http: impl HttpSend) -> Self {
        self.http = Arc::new(http);
        self
    }

    /// Replace the environment implementation.
    pub fn with_env(mut self, env: impl Env) -> Self {
        self.env = Arc::new(env);
        self
    }

    /// Replace the command executor implementation.
    pub fn with_command_execute(mut self, cmd: impl CommandExecute) -> Self {
        self.cmd = Arc::new(cmd);
        self
    }

    /// Read the file content entirely in `Vec<u8>`.
    #[inline]
    pub async fn file_read(&self, path: &str) -> Result<Vec<u8>> {
        self.fs.file_read_dyn(path).await
    }

    /// Read the file content entirely in `String`.
    pub async fn file_read_as_string(&self, path: &str) -> Result<String> {
        let bytes = self.file_read(path).await?;
        Ok(String::from_utf8_lossy(&bytes).to_string())
    }

    /// Send http request and return the response.
    #[inline]
    pub async fn http_send(&self, req: http::Request<Bytes>) -> Result<http::Response<Bytes>> {
        self.http.http_send_dyn(req).await
    }

    /// Send http request and return the response as string.
    pub async fn http_send_as_string(
        &self,
        req: http::Request<Bytes>,
    ) -> Result<http::Response<String>> {
        let (parts, body) = self.http.http_send_dyn(req).await?.into_parts();
        let body = String::from_utf8_lossy(&body).to_string();
        Ok(http::Response::from_parts(parts, body))
    }

    /// Get the home directory of the current user.
    #[inline]
    pub fn home_dir(&self) -> Option<PathBuf> {
        self.env.home_dir()
    }

    /// Expand `~` in input path.
    ///
    /// - If path not starts with `~/` or `~\\`, returns `Some(path)` directly.
    /// - Otherwise, replace `~` with home dir instead.
    /// - If home_dir is not found, returns `None`.
    pub fn expand_home_dir(&self, path: &str) -> Option<String> {
        if !path.starts_with("~/") && !path.starts_with("~\\") {
            Some(path.to_string())
        } else {
            self.home_dir()
                .map(|home| path.replace('~', &home.to_string_lossy()))
        }
    }

    /// Get the environment variable.
    ///
    /// - Returns `Some(v)` if the environment variable is found and is valid utf-8.
    /// - Returns `None` if the environment variable is not found or value is invalid.
    #[inline]
    pub fn env_var(&self, key: &str) -> Option<String> {
        self.env.var(key)
    }

    /// Returns a hashmap of (variable, value) pairs of strings, for all the
    /// environment variables of the current process.
    #[inline]
    pub fn env_vars(&self) -> HashMap<String, String> {
        self.env.vars()
    }

    /// Execute an external command with the given program and arguments.
    ///
    /// Returns the command output including exit status, stdout, and stderr.
    pub async fn command_execute(&self, program: &str, args: &[&str]) -> Result<CommandOutput> {
        self.cmd.command_execute_dyn(program, args).await
    }
}

/// FileRead is used to read the file content entirely in `Vec<u8>`.
///
/// This could be used by `Load` to load the credential from the file.
pub trait FileRead: Debug + Send + Sync + 'static {
    /// Read the file content entirely in `Vec<u8>`.
    fn file_read(&self, path: &str) -> impl Future<Output = Result<Vec<u8>>> + MaybeSend;
}

/// FileReadDyn is the dyn version of [`FileRead`].
pub trait FileReadDyn: Debug + Send + Sync + 'static {
    /// Dyn version of [`FileRead::file_read`].
    fn file_read_dyn<'a>(&'a self, path: &'a str) -> BoxedFuture<'a, Result<Vec<u8>>>;
}

impl<T: FileRead + ?Sized> FileReadDyn for T {
    fn file_read_dyn<'a>(&'a self, path: &'a str) -> BoxedFuture<'a, Result<Vec<u8>>> {
        Box::pin(self.file_read(path))
    }
}

impl<T: FileReadDyn + ?Sized> FileRead for Arc<T> {
    async fn file_read(&self, path: &str) -> Result<Vec<u8>> {
        self.deref().file_read_dyn(path).await
    }
}

/// HttpSend is used to send http request during the signing process.
///
/// For example, fetch IMDS token from AWS or OAuth2 refresh token. This trait is designed
/// especially for the signer, please don't use it as a general http client.
pub trait HttpSend: Debug + Send + Sync + 'static {
    /// Send http request and return the response.
    fn http_send(
        &self,
        req: http::Request<Bytes>,
    ) -> impl Future<Output = Result<http::Response<Bytes>>> + MaybeSend;
}

/// HttpSendDyn is the dyn version of [`HttpSend`].
pub trait HttpSendDyn: Debug + Send + Sync + 'static {
    /// Dyn version of [`HttpSend::http_send`].
    fn http_send_dyn(
        &self,
        req: http::Request<Bytes>,
    ) -> BoxedFuture<'_, Result<http::Response<Bytes>>>;
}

impl<T: HttpSend + ?Sized> HttpSendDyn for T {
    fn http_send_dyn(
        &self,
        req: http::Request<Bytes>,
    ) -> BoxedFuture<'_, Result<http::Response<Bytes>>> {
        Box::pin(self.http_send(req))
    }
}

impl<T: HttpSendDyn + ?Sized> HttpSend for Arc<T> {
    async fn http_send(&self, req: http::Request<Bytes>) -> Result<http::Response<Bytes>> {
        self.deref().http_send_dyn(req).await
    }
}

/// Permits parameterizing the home functions via the _from variants
pub trait Env: Debug + Send + Sync + 'static {
    /// Get an environment variable.
    ///
    /// - Returns `Some(v)` if the environment variable is found and is valid utf-8.
    /// - Returns `None` if the environment variable is not found or value is invalid.
    fn var(&self, key: &str) -> Option<String>;

    /// Returns a hashmap of (variable, value) pairs of strings, for all the
    /// environment variables of the current process.
    fn vars(&self) -> HashMap<String, String>;

    /// Return the path to the users home dir, returns `None` if any error occurs.
    fn home_dir(&self) -> Option<PathBuf>;
}

/// Implements Env for the OS context, both Unix style and Windows.
#[derive(Debug, Copy, Clone)]
pub struct OsEnv;

impl Env for OsEnv {
    fn var(&self, key: &str) -> Option<String> {
        std::env::var_os(key)?.into_string().ok()
    }

    fn vars(&self) -> HashMap<String, String> {
        std::env::vars().collect()
    }

    #[cfg(any(unix, target_os = "redox"))]
    fn home_dir(&self) -> Option<PathBuf> {
        #[allow(deprecated)]
        std::env::home_dir()
    }

    #[cfg(windows)]
    fn home_dir(&self) -> Option<PathBuf> {
        windows::home_dir_inner()
    }

    #[cfg(target_arch = "wasm32")]
    fn home_dir(&self) -> Option<PathBuf> {
        None
    }
}

/// StaticEnv provides a static env environment.
///
/// This is useful for testing or for providing a fixed environment.
#[derive(Debug, Clone, Default)]
pub struct StaticEnv {
    /// The home directory to use.
    pub home_dir: Option<PathBuf>,
    /// The environment variables to use.
    pub envs: HashMap<String, String>,
}

impl Env for StaticEnv {
    fn var(&self, key: &str) -> Option<String> {
        self.envs.get(key).cloned()
    }

    fn vars(&self) -> HashMap<String, String> {
        self.envs.clone()
    }

    fn home_dir(&self) -> Option<PathBuf> {
        self.home_dir.clone()
    }
}

/// CommandOutput represents the output of a command execution.
#[derive(Debug, Clone)]
pub struct CommandOutput {
    /// Exit status code (0 for success)
    pub status: i32,
    /// Standard output as bytes
    pub stdout: Vec<u8>,
    /// Standard error as bytes
    pub stderr: Vec<u8>,
}

impl CommandOutput {
    /// Check if the command exited successfully.
    pub fn success(&self) -> bool {
        self.status == 0
    }
}

/// CommandExecute is used to execute external commands for credential retrieval.
///
/// This trait abstracts command execution to support different runtime environments:
/// - Tokio-based async execution
/// - Blocking execution for non-async contexts
/// - WebAssembly environments (returning errors)
/// - Mock implementations for testing
pub trait CommandExecute: Debug + Send + Sync + 'static {
    /// Execute a command with the given program and arguments.
    fn command_execute<'a>(
        &'a self,
        program: &'a str,
        args: &'a [&'a str],
    ) -> impl Future<Output = Result<CommandOutput>> + MaybeSend + 'a;
}

/// CommandExecuteDyn is the dyn version of [`CommandExecute`].
pub trait CommandExecuteDyn: Debug + Send + Sync + 'static {
    /// Dyn version of [`CommandExecute::command_execute`].
    fn command_execute_dyn<'a>(
        &'a self,
        program: &'a str,
        args: &'a [&'a str],
    ) -> BoxedFuture<'a, Result<CommandOutput>>;
}

impl<T: CommandExecute + ?Sized> CommandExecuteDyn for T {
    fn command_execute_dyn<'a>(
        &'a self,
        program: &'a str,
        args: &'a [&'a str],
    ) -> BoxedFuture<'a, Result<CommandOutput>> {
        Box::pin(self.command_execute(program, args))
    }
}

impl<T: CommandExecuteDyn + ?Sized> CommandExecute for Arc<T> {
    async fn command_execute(&self, program: &str, args: &[&str]) -> Result<CommandOutput> {
        self.deref().command_execute_dyn(program, args).await
    }
}

/// NoopFileRead is a no-op implementation that always returns an error.
///
/// This is used when no file reader is configured.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoopFileRead;

impl FileRead for NoopFileRead {
    async fn file_read(&self, _path: &str) -> Result<Vec<u8>> {
        Err(Error::unexpected(
            "file reading not supported: no file reader configured",
        ))
    }
}

/// NoopHttpSend is a no-op implementation that always returns an error.
///
/// This is used when no HTTP client is configured.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoopHttpSend;

impl HttpSend for NoopHttpSend {
    async fn http_send(&self, _req: http::Request<Bytes>) -> Result<http::Response<Bytes>> {
        Err(Error::unexpected(
            "HTTP sending not supported: no HTTP client configured",
        ))
    }
}

/// NoopEnv is a no-op implementation that always returns None/empty.
///
/// This is used when no environment is configured.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoopEnv;

impl Env for NoopEnv {
    fn var(&self, _key: &str) -> Option<String> {
        None
    }

    fn vars(&self) -> HashMap<String, String> {
        HashMap::new()
    }

    fn home_dir(&self) -> Option<PathBuf> {
        None
    }
}

/// NoopCommandExecute is a no-op implementation that always returns an error.
///
/// This is used when no command executor is configured.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoopCommandExecute;

impl CommandExecute for NoopCommandExecute {
    async fn command_execute(&self, _program: &str, _args: &[&str]) -> Result<CommandOutput> {
        Err(Error::unexpected(
            "command execution not supported: no command executor configured",
        ))
    }
}

#[cfg(target_os = "windows")]
mod windows {
    use std::env;
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    use std::path::PathBuf;
    use std::ptr;
    use std::slice;

    use windows_sys::Win32::Foundation::S_OK;
    use windows_sys::Win32::System::Com::CoTaskMemFree;
    use windows_sys::Win32::UI::Shell::{
        FOLDERID_Profile, KF_FLAG_DONT_VERIFY, SHGetKnownFolderPath,
    };

    pub fn home_dir_inner() -> Option<PathBuf> {
        env::var_os("USERPROFILE")
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .or_else(home_dir_crt)
    }

    #[cfg(not(target_vendor = "uwp"))]
    fn home_dir_crt() -> Option<PathBuf> {
        unsafe {
            let mut path = ptr::null_mut();
            match SHGetKnownFolderPath(
                &FOLDERID_Profile,
                KF_FLAG_DONT_VERIFY as u32,
                std::ptr::null_mut(),
                &mut path,
            ) {
                S_OK => {
                    let path_slice = slice::from_raw_parts(path, wcslen(path));
                    let s = OsString::from_wide(&path_slice);
                    CoTaskMemFree(path.cast());
                    Some(PathBuf::from(s))
                }
                _ => {
                    // Free any allocated memory even on failure. A null ptr is a no-op for `CoTaskMemFree`.
                    CoTaskMemFree(path.cast());
                    None
                }
            }
        }
    }

    #[cfg(target_vendor = "uwp")]
    fn home_dir_crt() -> Option<PathBuf> {
        None
    }

    unsafe extern "C" {
        unsafe fn wcslen(buf: *const u16) -> usize;
    }

    #[cfg(not(target_vendor = "uwp"))]
    #[cfg(test)]
    mod tests {
        use super::home_dir_inner;
        use std::env;
        use std::ops::Deref;
        use std::path::{Path, PathBuf};

        #[test]
        fn test_with_without() {
            let olduserprofile = env::var_os("USERPROFILE").unwrap();
            unsafe {
                env::remove_var("HOME");
                env::remove_var("USERPROFILE");
            }
            assert_eq!(home_dir_inner(), Some(PathBuf::from(olduserprofile)));

            let home = Path::new(r"C:\Users\foo tar baz");
            unsafe {
                env::set_var("HOME", home.as_os_str());
                env::set_var("USERPROFILE", home.as_os_str());
            }
            assert_ne!(home_dir_inner().as_ref().map(Deref::deref), Some(home));
            assert_eq!(home_dir_inner().as_ref().map(Deref::deref), Some(home));
        }
    }
}
