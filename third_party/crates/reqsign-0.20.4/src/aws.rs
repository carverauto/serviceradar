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

//! AWS signing support.
//!
//! SigV4 remains available directly under `reqsign::aws` for compatibility.
//! The explicit algorithm modules are `v4` and `v4a`.

/// AWS Signature Version 4 support.
#[cfg(feature = "aws-v4")]
pub mod v4 {
    pub use reqsign_aws_v4::*;

    #[cfg(feature = "default-context")]
    use crate::{Signer, default_context};

    /// Default SigV4 signer type.
    #[cfg(feature = "default-context")]
    pub type DefaultSigner = Signer<Credential>;

    /// Create a default SigV4 signer for an AWS service and region.
    ///
    /// The signer uses the default context and AWS credential provider chain.
    #[cfg(feature = "default-context")]
    pub fn default_signer(service: &str, region: &str) -> DefaultSigner {
        Signer::new(
            default_context(),
            DefaultCredentialProvider::new(),
            RequestSigner::new(service, region),
        )
    }
}

// Preserve the existing reqsign::aws::* API and make reqsign::aws::v4 explicit.
#[cfg(feature = "aws-v4")]
pub use v4::*;

/// AWS Signature Version 4A support.
#[cfg(feature = "aws-v4a")]
pub mod v4a {
    pub use reqsign_aws_v4a::*;

    #[cfg(feature = "default-context")]
    use crate::{Signer, default_context};

    /// Default SigV4a signer type.
    #[cfg(feature = "default-context")]
    pub type DefaultSigner = Signer<Credential>;

    /// Create a default SigV4a signer for an AWS service and signing region set.
    ///
    /// The signer uses the default context and AWS credential provider chain.
    #[cfg(feature = "default-context")]
    pub fn default_signer(service: &str, region_set: SigningRegionSet) -> DefaultSigner {
        Signer::new(
            default_context(),
            DefaultCredentialProvider::new(),
            RequestSigner::new(service, region_set),
        )
    }
}
