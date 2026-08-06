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

use bytes::Bytes;
use http::header;
use reqsign_core::Context;
use reqsign_core::Result;
use reqsign_core::hash;
use reqsign_core::time::Timestamp;

use crate::service_sas::ServiceSasResource;

const DEFAULT_USER_DELEGATION_SAS_VERSION: &str = "2020-12-06";

#[derive(Clone, Debug)]
pub(crate) struct UserDelegationKey {
    pub signed_oid: String,
    pub signed_tid: String,
    pub signed_start: Timestamp,
    pub signed_expiry: Timestamp,
    pub signed_service: String,
    pub signed_version: String,
    pub value: String,
}

pub(crate) struct UserDelegationKeyRequest<'a> {
    pub scheme: &'a str,
    pub authority: &'a str,
    pub bearer_token: &'a str,
    pub start: Timestamp,
    pub expiry: Timestamp,
    pub service_version: &'a str,
    pub now: Timestamp,
}

pub(crate) async fn get_user_delegation_key(
    ctx: &Context,
    request: UserDelegationKeyRequest<'_>,
) -> Result<UserDelegationKey> {
    let uri: http::Uri = format!(
        "{}://{}/?restype=service&comp=userdelegationkey",
        request.scheme, request.authority
    )
    .parse()
    .map_err(|e| {
        reqsign_core::Error::request_invalid("invalid user delegation key URI").with_source(e)
    })?;

    // Azure Blob Storage expects a KeyInfo payload.
    //
    // Reference: https://learn.microsoft.com/en-us/rest/api/storageservices/get-user-delegation-key
    let body = format!(
        "<KeyInfo><Start>{}</Start><Expiry>{}</Expiry></KeyInfo>",
        request.start.format_rfc3339_zulu(),
        request.expiry.format_rfc3339_zulu(),
    );

    let req = http::Request::post(uri)
        .header("x-ms-version", request.service_version)
        .header("x-ms-date", request.now.format_http_date())
        .header(header::CONTENT_TYPE, "application/xml")
        .header(
            header::AUTHORIZATION,
            format!("Bearer {}", request.bearer_token),
        )
        .body(Bytes::from(body))
        .map_err(|e| {
            reqsign_core::Error::unexpected("failed to build user delegation key request")
                .with_source(e)
        })?;

    let resp = ctx.http_send(req).await?;
    let (parts, body) = resp.into_parts();
    if !parts.status.is_success() {
        return Err(
            reqsign_core::Error::unexpected("user delegation key request failed")
                .with_context(format!("status: {}", parts.status)),
        );
    }

    let xml = String::from_utf8_lossy(&body).to_string();

    let signed_oid = extract_tag(&xml, "SignedOid")?;
    let signed_tid = extract_tag(&xml, "SignedTid")?;
    let signed_start = parse_timestamp(&extract_tag(&xml, "SignedStart")?)?;
    let signed_expiry = parse_timestamp(&extract_tag(&xml, "SignedExpiry")?)?;
    let signed_service = extract_tag(&xml, "SignedService")?;
    let signed_version = extract_tag(&xml, "SignedVersion")?;
    let value = extract_tag(&xml, "Value")?;

    Ok(UserDelegationKey {
        signed_oid,
        signed_tid,
        signed_start,
        signed_expiry,
        signed_service,
        signed_version,
        value,
    })
}

fn parse_timestamp(s: &str) -> Result<Timestamp> {
    s.parse::<Timestamp>()
        .map_err(|e| reqsign_core::Error::request_invalid("invalid timestamp").with_source(e))
}

fn extract_tag(xml: &str, tag: &str) -> Result<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");

    let start = xml
        .find(&open)
        .ok_or_else(|| reqsign_core::Error::unexpected("missing xml tag").with_context(tag))?
        + open.len();
    let end = xml[start..]
        .find(&close)
        .ok_or_else(|| reqsign_core::Error::unexpected("missing xml end tag").with_context(tag))?
        + start;

    Ok(xml[start..end].trim().to_string())
}

pub(crate) struct UserDelegationSharedAccessSignature {
    account: String,
    key: UserDelegationKey,

    resource: ServiceSasResource,
    permissions: String,
    expiry: Timestamp,
    start: Option<Timestamp>,
    ip: Option<String>,
    protocol: Option<String>,
    version: String,
}

impl UserDelegationSharedAccessSignature {
    pub(crate) fn new(
        account: String,
        key: UserDelegationKey,
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
            version: DEFAULT_USER_DELEGATION_SAS_VERSION.to_string(),
        }
    }

    pub(crate) fn with_start(mut self, start: Timestamp) -> Self {
        self.start = Some(start);
        self
    }

    pub(crate) fn with_ip(mut self, ip: impl Into<String>) -> Self {
        self.ip = Some(ip.into());
        self
    }

    pub(crate) fn with_protocol(mut self, protocol: impl Into<String>) -> Self {
        self.protocol = Some(protocol.into());
        self
    }

    pub(crate) fn with_version(mut self, version: impl Into<String>) -> Self {
        self.version = version.into();
        self
    }

    fn signature(&self) -> Result<String> {
        let canonicalized_resource = self.resource.canonicalized_resource(&self.account);

        let string_to_sign = format!(
            "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            self.permissions,
            self.start
                .as_ref()
                .map_or("".to_string(), |v| v.format_rfc3339_zulu()),
            self.expiry.format_rfc3339_zulu(),
            canonicalized_resource,
            self.key.signed_oid,
            self.key.signed_tid,
            self.key.signed_start.format_rfc3339_zulu(),
            self.key.signed_expiry.format_rfc3339_zulu(),
            self.key.signed_service,
            self.key.signed_version,
            self.ip.clone().unwrap_or_default(),
            self.protocol.clone().unwrap_or_default(),
            self.version,
            self.resource.signed_resource(),
            "", // snapshot time
            "", // encryption scope
            "", // rscc
            "", // rscd
            "", // rsce
            "", // rscl
            "", // rsct
        );

        let decoded_key = hash::base64_decode(&self.key.value)?;
        Ok(hash::base64_hmac_sha256(
            &decoded_key,
            string_to_sign.as_bytes(),
        ))
    }

    pub(crate) fn token(&self) -> Result<Vec<(String, String)>> {
        let mut elements: Vec<(String, String)> = vec![
            ("sv".to_string(), self.version.to_string()),
            ("se".to_string(), self.expiry.format_rfc3339_zulu()),
            ("sp".to_string(), self.permissions.to_string()),
            (
                "sr".to_string(),
                self.resource.signed_resource().to_string(),
            ),
            ("skoid".to_string(), self.key.signed_oid.to_string()),
            ("sktid".to_string(), self.key.signed_tid.to_string()),
            (
                "skt".to_string(),
                self.key.signed_start.format_rfc3339_zulu(),
            ),
            (
                "ske".to_string(),
                self.key.signed_expiry.format_rfc3339_zulu(),
            ),
            ("sks".to_string(), self.key.signed_service.to_string()),
            ("skv".to_string(), self.key.signed_version.to_string()),
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
