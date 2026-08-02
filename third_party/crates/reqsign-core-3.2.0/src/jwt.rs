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

//! JWT encoding helpers.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rsa::RsaPrivateKey;
use rsa::pkcs1v15::SigningKey;
use rsa::pkcs8::DecodePrivateKey;
use rsa::rand_core::OsRng;
use rsa::sha2::Sha256;
use rsa::signature::{RandomizedSigner, SignatureEncoding};
use serde::Serialize;

use crate::{Error, Result};

/// Encode a JWS compact JWT using the RS256 algorithm.
///
/// RS256 is RSA PKCS#1 v1.5 with SHA-256. The caller owns the JWT header and
/// claims shape so service-specific fields such as `x5t` stay service-local.
pub fn encode_rs256<H, C>(header: &H, claims: &C, private_key: &RsaPrivateKey) -> Result<String>
where
    H: Serialize,
    C: Serialize,
{
    let encoded_header = encode_json(header)?;
    let encoded_claims = encode_json(claims)?;
    let signing_input = format!("{encoded_header}.{encoded_claims}");

    let mut rng = OsRng;
    let signing_key = SigningKey::<Sha256>::new(private_key.clone());
    let signature = signing_key.sign_with_rng(&mut rng, signing_input.as_bytes());
    let encoded_signature = URL_SAFE_NO_PAD.encode(signature.to_bytes());

    Ok(format!("{signing_input}.{encoded_signature}"))
}

/// Encode a JWS compact JWT using an RSA private key in PKCS#8 PEM format.
pub fn encode_rs256_pem<H, C>(header: &H, claims: &C, private_key_pem: &[u8]) -> Result<String>
where
    H: Serialize,
    C: Serialize,
{
    let private_key_pem = std::str::from_utf8(private_key_pem).map_err(|e| {
        Error::credential_invalid("RSA private key PEM is not valid UTF-8").with_source(e)
    })?;
    let private_key = RsaPrivateKey::from_pkcs8_pem(private_key_pem).map_err(|e| {
        Error::credential_invalid("failed to parse PKCS#8 RSA private key PEM").with_source(e)
    })?;

    encode_rs256(header, claims, &private_key)
}

fn encode_json<T>(value: &T) -> Result<String>
where
    T: Serialize,
{
    let json = serde_json::to_vec(value)
        .map_err(|e| Error::unexpected("failed to serialize JWT JSON").with_source(e))?;
    Ok(URL_SAFE_NO_PAD.encode(json))
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use rsa::pkcs1v15::{Signature, VerifyingKey};
    use rsa::rand_core::OsRng;
    use rsa::signature::Verifier;
    use serde_json::json;

    #[derive(Serialize)]
    struct Header<'a> {
        alg: &'a str,
        typ: &'a str,
        x5t: &'a str,
    }

    #[derive(Serialize)]
    struct Claims<'a> {
        iss: &'a str,
        sub: &'a str,
        aud: &'a str,
        exp: u64,
    }

    #[test]
    fn encode_rs256_keeps_jws_shape_and_verifiable_signature() -> Result<()> {
        let mut rng = OsRng;
        let private_key = RsaPrivateKey::new(&mut rng, 2048)
            .map_err(|e| Error::unexpected("failed to generate test RSA key").with_source(e))?;

        let jwt = encode_rs256(
            &Header {
                alg: "RS256",
                typ: "JWT",
                x5t: "thumbprint",
            },
            &Claims {
                iss: "client",
                sub: "client",
                aud: "https://example.com/token",
                exp: 1,
            },
            &private_key,
        )?;

        let parts = jwt.split('.').collect::<Vec<_>>();
        assert_eq!(parts.len(), 3);

        let header: serde_json::Value = serde_json::from_slice(
            &URL_SAFE_NO_PAD
                .decode(parts[0])
                .map_err(|e| Error::unexpected("failed to decode JWT header").with_source(e))?,
        )
        .map_err(|e| Error::unexpected("failed to parse JWT header").with_source(e))?;
        assert_eq!(
            header,
            json!({
                "alg": "RS256",
                "typ": "JWT",
                "x5t": "thumbprint"
            })
        );

        let signature = URL_SAFE_NO_PAD
            .decode(parts[2])
            .map_err(|e| Error::unexpected("failed to decode JWT signature").with_source(e))?;
        let signature = Signature::try_from(signature.as_slice())
            .map_err(|e| Error::unexpected("failed to parse JWT signature").with_source(e))?;
        let verifying_key = VerifyingKey::<Sha256>::new(private_key.to_public_key());
        verifying_key
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)
            .map_err(|e| Error::unexpected("failed to verify JWT signature").with_source(e))?;

        Ok(())
    }
}
