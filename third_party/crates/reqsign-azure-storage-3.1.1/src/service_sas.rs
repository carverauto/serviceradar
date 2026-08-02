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

use reqsign_core::Result;
use reqsign_core::hash;
use reqsign_core::time::Timestamp;

const SERVICE_SAS_VERSION: &str = "2020-12-06";
const BLOB_SERVICE: &str = "blob";

/// Resource level for Azure Storage Service SAS.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServiceSasResource {
    /// A container resource.
    Container { container: String },
    /// A blob resource.
    Blob { container: String, blob: String },
}

impl ServiceSasResource {
    /// Build a resource from a request path.
    ///
    /// The input path must be percent-decoded.
    pub fn from_path_percent_decoded(path: &str) -> Result<Self> {
        let path = path.strip_prefix('/').unwrap_or(path);
        let mut segments = path.split('/').filter(|v| !v.is_empty());

        let container = segments
            .next()
            .ok_or_else(|| reqsign_core::Error::request_invalid("missing container in path"))?
            .to_string();

        let rest = segments.collect::<Vec<_>>();
        if rest.is_empty() {
            Ok(ServiceSasResource::Container { container })
        } else {
            Ok(ServiceSasResource::Blob {
                container,
                blob: rest.join("/"),
            })
        }
    }

    pub(crate) fn signed_resource(&self) -> &'static str {
        match self {
            ServiceSasResource::Container { .. } => "c",
            ServiceSasResource::Blob { .. } => "b",
        }
    }

    pub(crate) fn canonicalized_resource(&self, account: &str) -> String {
        match self {
            ServiceSasResource::Container { container } => {
                format!("/{BLOB_SERVICE}/{account}/{container}")
            }
            ServiceSasResource::Blob { container, blob } => {
                format!("/{BLOB_SERVICE}/{account}/{container}/{blob}")
            }
        }
    }
}

/// Service SAS generator using Shared Key.
///
/// Reference: <https://learn.microsoft.com/en-us/rest/api/storageservices/create-service-sas>
pub struct ServiceSharedAccessSignature {
    account: String,
    key: String,

    resource: ServiceSasResource,
    permissions: String,
    expiry: Timestamp,
    start: Option<Timestamp>,
    ip: Option<String>,
    protocol: Option<String>,
    version: String,
}

impl ServiceSharedAccessSignature {
    /// Create a Service SAS signer.
    pub fn new(
        account: String,
        key: String,
        resource: ServiceSasResource,
        permissions: String,
        expiry: Timestamp,
    ) -> Self {
        Self {
            account,
            key,
            resource,
            permissions,
            expiry,
            start: None,
            ip: None,
            protocol: None,
            version: SERVICE_SAS_VERSION.to_string(),
        }
    }

    /// Set the start time.
    pub fn with_start(mut self, start: Timestamp) -> Self {
        self.start = Some(start);
        self
    }

    /// Set the IP restriction.
    pub fn with_ip(mut self, ip: impl Into<String>) -> Self {
        self.ip = Some(ip.into());
        self
    }

    /// Set the allowed protocol.
    pub fn with_protocol(mut self, protocol: impl Into<String>) -> Self {
        self.protocol = Some(protocol.into());
        self
    }

    /// Set the service version.
    pub fn with_version(mut self, version: impl Into<String>) -> Self {
        self.version = version.into();
        self
    }

    fn signature(&self) -> Result<String> {
        let canonicalized_resource = self.resource.canonicalized_resource(&self.account);

        // Signed identifier (si), snapshot time, encryption scope, response headers are not
        // supported for now. Keep them empty.
        let string_to_sign = format!(
            "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            self.permissions,
            self.start
                .as_ref()
                .map_or("".to_string(), |v| v.format_rfc3339_zulu()),
            self.expiry.format_rfc3339_zulu(),
            canonicalized_resource,
            "",                                        // si
            self.ip.clone().unwrap_or_default(),       // sip
            self.protocol.clone().unwrap_or_default(), // spr
            self.version,                              // sv
            self.resource.signed_resource(),           // sr
            "",                                        // snapshot time
            "",                                        // encryption scope
            "",                                        // rscc
            "",                                        // rscd
            "",                                        // rsce
            "",                                        // rscl
            "",                                        // rsct
        );

        let decoded_key = hash::base64_decode(&self.key)?;
        Ok(hash::base64_hmac_sha256(
            &decoded_key,
            string_to_sign.as_bytes(),
        ))
    }

    /// Generate SAS query parameters.
    pub fn token(&self) -> Result<Vec<(String, String)>> {
        let mut elements: Vec<(String, String)> = vec![
            ("sv".to_string(), self.version.to_string()),
            ("se".to_string(), self.expiry.format_rfc3339_zulu()),
            ("sp".to_string(), self.permissions.to_string()),
            (
                "sr".to_string(),
                self.resource.signed_resource().to_string(),
            ),
        ];

        if let Some(start) = &self.start {
            elements.push(("st".to_string(), start.format_rfc3339_zulu()))
        }
        if let Some(ip) = &self.ip {
            elements.push(("sip".to_string(), ip.to_string()))
        }
        if let Some(protocol) = &self.protocol {
            elements.push(("spr".to_string(), protocol.to_string()))
        }

        let sig = self.signature()?;
        elements.push(("sig".to_string(), sig));

        Ok(elements)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;
    use std::time::Duration;

    fn test_time() -> Timestamp {
        Timestamp::from_str("2022-03-01T08:12:34Z").unwrap()
    }

    #[test]
    fn test_can_generate_service_sas_token_for_blob() {
        let key = hash::base64_encode("key".as_bytes());
        let expiry = test_time() + Duration::from_secs(300);

        let resource = ServiceSasResource::Blob {
            container: "container".to_string(),
            blob: "path/to/blob.txt".to_string(),
        };

        let sign = ServiceSharedAccessSignature::new(
            "account".to_string(),
            key,
            resource,
            "r".to_string(),
            expiry,
        );

        let token_content = sign.token().expect("token generation failed");
        let token = token_content
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<String>>()
            .join("&");

        assert_eq!(
            token,
            "sv=2020-12-06&se=2022-03-01T08:17:34Z&sp=r&sr=b&sig=CP9a2LIrR9zeG4I4jZjqPetJSXWJ77QeUA7c3GMypyM="
        );
    }

    #[test]
    fn test_service_sas_resource_from_path() {
        assert_eq!(
            ServiceSasResource::from_path_percent_decoded("/container").unwrap(),
            ServiceSasResource::Container {
                container: "container".to_string()
            }
        );

        assert_eq!(
            ServiceSasResource::from_path_percent_decoded("/container/blob").unwrap(),
            ServiceSasResource::Blob {
                container: "container".to_string(),
                blob: "blob".to_string()
            }
        );
    }
}
