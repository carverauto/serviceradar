//! Reading the CA bundle named by a `ca_bundle_url` field.
//!
//! HERE, RATHER THAN IN A CONSUMER, because this crate owns the field. It previously lived in
//! `rust/srql`, which meant every other consumer had to depend on the whole SQL stack -- Diesel,
//! libpq and a Postgres connection pool -- to perform an HTTP GET. `rust/integration-db` already
//! did exactly that.
//!
//! Not a secret, and not authenticated by us. A CA bundle is what a client needs BEFORE it can
//! authenticate anything, so it is published unauthenticated over plain HTTP and its integrity
//! comes from whatever protects the endpoint -- the same bootstrap shape as fetching a JWKS.
//! `//k8s/srql-fixtures/ca-bundle.yaml` is the in-cluster publisher: it serves one path, holds
//! no private key, and is HTTP-only on purpose, because TLS here would need the very bundle
//! being fetched.

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
