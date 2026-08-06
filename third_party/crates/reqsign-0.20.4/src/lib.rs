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

#![doc = include_str!("../README.md")]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]

// Re-export core types
pub use reqsign_core::*;

// Context utilities
#[cfg(feature = "default-context")]
mod context;
#[cfg(feature = "default-context")]
pub use context::default_context;

// Service modules with convenience APIs
#[cfg(feature = "aliyun")]
pub mod aliyun;

#[cfg(any(feature = "aws-v4", feature = "aws-v4a"))]
pub mod aws;

#[cfg(feature = "azure")]
pub mod azure;

#[cfg(feature = "google")]
pub mod google;

#[cfg(feature = "huaweicloud")]
pub mod huaweicloud;

#[cfg(feature = "oracle")]
pub mod oracle;

#[cfg(feature = "tencent")]
pub mod tencent;

#[cfg(feature = "volcengine")]
pub mod volcengine;
