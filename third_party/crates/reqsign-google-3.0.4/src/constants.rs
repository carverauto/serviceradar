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

// Env values used in google services.
pub const GOOGLE_APPLICATION_CREDENTIALS: &str = "GOOGLE_APPLICATION_CREDENTIALS";
pub const GOOGLE_SCOPE: &str = "GOOGLE_SCOPE";

// Default OAuth2 scope for Google Cloud services
pub const DEFAULT_SCOPE: &str = "https://www.googleapis.com/auth/cloud-platform";

/// AsciiSet for [Google UriEncode](https://cloud.google.com/storage/docs/authentication/canonical-requests)
///
/// - URI encode every byte except the unreserved characters: 'A'-'Z', 'a'-'z', '0'-'9', '-', '.', '_', and '~'.
pub static GOOG_URI_ENCODE_SET: AsciiSet = NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

/// AsciiSet for [Google UriEncode](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html)
///
/// But used in query.
pub static GOOG_QUERY_ENCODE_SET: AsciiSet = NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');
