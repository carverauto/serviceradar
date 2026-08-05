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

use percent_encoding::AsciiSet;
use percent_encoding::NON_ALPHANUMERIC;

// Headers used in aws services.
pub const X_AMZ_CONTENT_SHA_256: &str = "x-amz-content-sha256";
pub const X_AMZ_DATE: &str = "x-amz-date";
pub const X_AMZ_SECURITY_TOKEN: &str = "x-amz-security-token";
pub const X_AMZ_S3_SESSION_TOKEN: &str = "x-amz-s3session-token";

// Env values used in aws services.
pub const AWS_ACCESS_KEY_ID: &str = "AWS_ACCESS_KEY_ID";
pub const AWS_SECRET_ACCESS_KEY: &str = "AWS_SECRET_ACCESS_KEY";
pub const AWS_SESSION_TOKEN: &str = "AWS_SESSION_TOKEN";
#[cfg(not(target_arch = "wasm32"))]
pub const AWS_PROFILE: &str = "AWS_PROFILE";
#[cfg(not(target_arch = "wasm32"))]
pub const AWS_CONFIG_FILE: &str = "AWS_CONFIG_FILE";
#[cfg(not(target_arch = "wasm32"))]
pub const AWS_SHARED_CREDENTIALS_FILE: &str = "AWS_SHARED_CREDENTIALS_FILE";

/// AsciiSet for [AWS UriEncode](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html)
///
/// - URI encode every byte except the unreserved characters: 'A'-'Z', 'a'-'z', '0'-'9', '-', '.', '_', and '~'.
pub static AWS_URI_ENCODE_SET: AsciiSet = NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

/// AsciiSet for [AWS UriEncode](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html)
///
/// But used in query.
pub static AWS_QUERY_ENCODE_SET: AsciiSet = NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');
