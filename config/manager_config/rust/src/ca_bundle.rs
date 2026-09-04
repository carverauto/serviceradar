//! Reading the CA bundle named by a `ca_bundle_url` field.
//!
//! HERE, RATHER THAN IN A CONSUMER, because this crate owns the field. It previously lived in
//! `rust/srql`, which meant every other consumer had to depend on the whole SQL stack -- Diesel,
//! libpq and a Postgres connection pool -- to perform an HTTP GET. `rust/integration-db` already
//! did exactly that.
//!
//! Not a secret. A CA bundle is what a client needs BEFORE it can authenticate the *custom*
//! CA's subjects, so it cannot itself be authenticated by that CA. It is published over HTTPS
//! terminated by a publicly trusted cert (Let's Encrypt on lan-shared-gateway). Scratch images
//! already carry those public roots, so `ureq`'s default TLS transport verifies the hop.
//! Wrapping this fetch in a cert issued by the custom CA is the circular case; wrapping it in
//! a public CA is not. `//k8s/srql-fixtures/ca-bundle.yaml` is the publisher: one path, no
//! private key, HTTP behind Envoy.

use crate::errors::ca_bundle_error::CaBundleError;

/// Reads the published CA bundle at `url`.
pub fn fetch_ca_bundle(url: &str) -> Result<Vec<u8>, CaBundleError> {
    let body = ureq::get(url)
        .call()
        .map_err(|err| CaBundleError::Unreachable {
            url: url.to_string(),
            detail: err.to_string(),
        })?
        .body_mut()
        .read_to_string()
        .map_err(|err| CaBundleError::Unreadable {
            url: url.to_string(),
            detail: err.to_string(),
        })?;

    if !body.contains("BEGIN CERTIFICATE") {
        return Err(CaBundleError::NotPem {
            url: url.to_string(),
            bytes: body.len(),
        });
    }

    Ok(body.into_bytes())
}
