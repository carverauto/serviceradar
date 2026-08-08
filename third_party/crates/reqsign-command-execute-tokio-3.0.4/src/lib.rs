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

//! Tokio-based command execution implementation for reqsign.
//!
//! This crate provides `TokioCommandExecute`, an async command executor that implements
//! the `CommandExecute` trait from `reqsign_core` using Tokio's process operations.
//!
//! ## Overview
//!
//! `TokioCommandExecute` enables reqsign to execute external commands asynchronously using
//! Tokio's process spawning capabilities. This is particularly useful when retrieving
//! credentials from external programs or CLI tools.
//!
//! ## Example
//!
//! ```ignore
//! use reqsign_core::Context;
//! use reqsign_command_execute_tokio::TokioCommandExecute;
//! use reqsign_file_read_tokio::TokioFileRead;
//! use reqsign_http_send_reqwest::ReqwestHttpSend;
//!
//! #[tokio::main]
//! async fn main() {
//!     // Create a context with Tokio command executor
//!     let ctx = Context::new()
//!         .with_file_read(TokioFileRead::default())
//!         .with_http_send(ReqwestHttpSend::default())
//!         .with_command_execute(TokioCommandExecute::default())
//!
//!         .unwrap();
//!
//!     // The context can now execute commands asynchronously
//!     match ctx.command_execute("echo", &["hello", "world"]).await {
//!         Ok(output) => {
//!             if output.success() {
//!                 println!("Output: {}", String::from_utf8_lossy(&output.stdout));
//!             }
//!         }
//!         Err(e) => eprintln!("Failed to execute command: {}", e),
//!     }
//! }
//! ```
//!
//! ## Usage with Service Signers
//!
//! ```ignore
//! use reqsign_core::{Context, Signer};
//! use reqsign_command_execute_tokio::TokioCommandExecute;
//! use reqsign_file_read_tokio::TokioFileRead;
//! use reqsign_http_send_reqwest::ReqwestHttpSend;
//!
//! # async fn example() -> anyhow::Result<()> {
//! // Cloud services that use external credential processes need command execution
//! let ctx = Context::new()
//!     .with_file_read(TokioFileRead::default())
//!     .with_http_send(ReqwestHttpSend::default())
//!     .with_command_execute(TokioCommandExecute::default())
//!     ?;
//!
//! // Create a signer that can execute credential helper processes
//! // let signer = Signer::new(ctx, credential_loader, request_builder);
//! # Ok(())
//! # }
//! ```
use reqsign_core::{CommandExecute, CommandOutput, Error, Result};
#[cfg(not(target_family = "wasm"))]
use std::process::Stdio;
#[cfg(not(target_family = "wasm"))]
use tokio::process::Command;

/// Tokio-based implementation of the `CommandExecute` trait.
///
/// This struct provides async command execution capabilities using Tokio's
/// process spawning operations.
#[derive(Debug, Clone, Copy, Default)]
pub struct TokioCommandExecute;

#[cfg(not(target_family = "wasm"))]
impl CommandExecute for TokioCommandExecute {
    async fn command_execute(&self, program: &str, args: &[&str]) -> Result<CommandOutput> {
        let output = Command::new(program)
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .await
            .map_err(|e| {
                Error::unexpected(format!("failed to execute command '{program}'")).with_source(e)
            })?;

        Ok(CommandOutput {
            status: output.status.code().unwrap_or(-1),
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }
}

#[cfg(target_family = "wasm")]
impl CommandExecute for TokioCommandExecute {
    async fn command_execute(&self, _program: &str, _args: &[&str]) -> Result<CommandOutput> {
        Err(Error::unexpected(
            "TokioCommandExecute is unsupported on wasm targets",
        ))
    }
}

#[cfg(all(test, not(target_family = "wasm")))]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_successful_command() {
        let executor = TokioCommandExecute;
        let output = executor.command_execute("echo", &["hello"]).await.unwrap();

        assert!(output.success());
        assert_eq!(output.status, 0);
        assert!(!output.stdout.is_empty());
    }

    #[tokio::test]
    async fn test_failed_command() {
        let executor = TokioCommandExecute;
        let result = executor
            .command_execute("nonexistent_command_xyz", &[])
            .await;

        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_command_with_non_zero_exit() {
        let executor = TokioCommandExecute;

        // Use 'false' command which always exits with status 1
        #[cfg(unix)]
        let output = executor.command_execute("false", &[]).await.unwrap();

        #[cfg(unix)]
        {
            assert!(!output.success());
            assert_eq!(output.status, 1);
        }
    }
}
