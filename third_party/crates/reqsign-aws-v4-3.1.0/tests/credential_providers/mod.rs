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

mod assume_role;
mod assume_role_with_web_identity;
mod cognito;
mod ecs;
mod env;
mod imds;
#[cfg(not(target_arch = "wasm32"))]
mod process;
mod profile;
mod s3_express;
#[cfg(not(target_arch = "wasm32"))]
mod sso;

#[cfg(not(target_arch = "wasm32"))]
use reqsign_command_execute_tokio::TokioCommandExecute;
use reqsign_core::{Context, OsEnv, StaticEnv};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;
use std::collections::HashMap;

pub fn create_test_context() -> Context {
    let _ = env_logger::builder().is_test(true).try_init();
    let _ = dotenvy::dotenv();

    let mut ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    #[cfg(not(target_arch = "wasm32"))]
    {
        ctx = ctx.with_command_execute(TokioCommandExecute);
    }

    ctx
}

pub fn create_test_context_with_env(envs: HashMap<String, String>) -> Context {
    let _ = env_logger::builder().is_test(true).try_init();
    let _ = dotenvy::dotenv();

    // Get home directory from HOME environment variable if set
    let home_dir = std::env::var("HOME").ok().map(std::path::PathBuf::from);

    let mut ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    #[cfg(not(target_arch = "wasm32"))]
    {
        ctx = ctx.with_command_execute(TokioCommandExecute);
    }

    // StaticEnv overrides specific environment variables on top of OsEnv
    ctx.with_env(StaticEnv { home_dir, envs })
}
