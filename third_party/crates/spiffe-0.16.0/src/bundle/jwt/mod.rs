//! JWT bundle types.

use crate::bundle::BundleSource;
use crate::spiffe_id::TrustDomain;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::convert::Infallible;
use std::sync::Arc;
use thiserror::Error;

/// A single JWT authority (public key material) stored as a JWK JSON object.
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct JwtAuthority {
    kid: Arc<str>,
    jwk_json: Arc<[u8]>,
}

impl JwtAuthority {
    /// Returns the key ID (`kid`)
    pub fn key_id(&self) -> &str {
        &self.kid
    }

    /// Returns the JWK JSON bytes representing this authority.
    pub fn jwk_json(&self) -> &[u8] {
        &self.jwk_json
    }

    /// Constructs a new [`JwtAuthority`] from a JSON Web Key (JWK) in JSON format.
    ///
    /// The provided JSON must represent a **single JWK object** (not a JWKS). The
    /// `kid` (Key ID) field is required and is used to identify the authority when
    /// validating JWT signatures.
    ///
    /// The JWK JSON is stored verbatim (after round-trip normalization) and is not
    /// interpreted or validated beyond extracting the `kid`.
    ///
    /// # Errors
    ///
    /// Returns [`JwtBundleError`] if:
    /// - the JSON is invalid or cannot be deserialized,
    /// - the JWK does not contain a `kid` field, or the field is not a string.
    ///
    /// Note: Cryptographic validity of the key material is **not** checked here.
    pub fn from_jwk_json(jwk_json: &[u8]) -> Result<Self, JwtBundleError> {
        let value: Value = serde_json::from_slice(jwk_json)?;

        let kid = value
            .get("kid")
            .and_then(|v| v.as_str())
            .ok_or(JwtBundleError::MissingKeyId)?;

        let jwk_json = serde_json::to_vec(&value)?;

        Ok(Self {
            kid: Arc::<str>::from(kid),
            jwk_json: Arc::<[u8]>::from(jwk_json),
        })
    }
}

/// Contains a collection of trusted JWT authorities (Public keys) for a `TrustDomain`.
///
/// JWT bundles are used to verify the signatures of [`JwtSvid`] tokens.
/// Obtain bundles from the [Workload API](crate::WorkloadApiClient).
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct JwtBundle {
    trust_domain: TrustDomain,
    jwt_authorities: HashMap<String, Arc<JwtAuthority>>,
}

/// Contains a set of [`JwtBundle`], keyed by [`TrustDomain`].
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct JwtBundleSet {
    bundles: BTreeMap<TrustDomain, Arc<JwtBundle>>,
}

/// An error that can arise creating a new [`JwtBundle`].
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum JwtBundleError {
    /// The JWT authority misses the key ID that identifies it.
    #[error("missing key ID")]
    MissingKeyId,
    /// There was a problem deserializing bytes into a Json JWT keys set.
    #[error("cannot deserialize json jwk set")]
    Deserialize(#[from] serde_json::Error),
}

impl JwtBundle {
    /// Creates an empty `JwtBundle` for the given `TrustDomain`.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, JwtBundle};
    ///
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = JwtBundle::new(trust_domain);
    /// assert!(bundle.find_jwt_authority("some-kid").is_none());
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn new(trust_domain: TrustDomain) -> Self {
        Self {
            trust_domain,
            jwt_authorities: HashMap::new(),
        }
    }

    /// Returns the [`TrustDomain`] associated to the bundle.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, JwtBundle};
    ///
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = JwtBundle::new(trust_domain.clone());
    /// assert_eq!(bundle.trust_domain(), &trust_domain);
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub const fn trust_domain(&self) -> &TrustDomain {
        &self.trust_domain
    }

    /// Parses a `JwtBundle` from bytes representing a set of  JWT authorities. The data must be
    /// a standard RFC 7517 JWTK document.
    ///
    /// # Arguments
    ///
    /// * `trust_domain` -  A [`TrustDomain`] to associate to the bundle.
    /// * `jwt_authorities` -  A slice of bytes representing a set of JWT authorities in a standard RFC 7517 JWKS document.
    ///
    /// # Errors
    ///
    /// If the function cannot parse the bytes into a JSON `WebKey` Set, a [`JwtBundleError`] variant will be returned.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{JwtBundle, TrustDomain};
    ///
    /// let jwt_authorities = r#"{
    ///     "keys": [
    ///         {
    ///             "kty": "EC",
    ///             "kid": "C6vs25welZOx6WksNYfbMfiw9l96pMnD",
    ///             "crv": "P-256",
    ///             "x": "ngLYQnlfF6GsojUwqtcEE3WgTNG2RUlsGhK73RNEl5k",
    ///             "y": "tKbiDSUSsQ3F1P7wteeHNXIcU-cx6CgSbroeQrQHTLM"
    ///         }
    ///     ]
    ///  }"#
    /// .as_bytes();
    /// let trust_domain = TrustDomain::new("example.org").unwrap();
    /// let jwt_bundle = JwtBundle::from_jwt_authorities(trust_domain, jwt_authorities).unwrap();
    ///
    /// assert!(
    ///     jwt_bundle
    ///         .find_jwt_authority("C6vs25welZOx6WksNYfbMfiw9l96pMnD")
    ///         .is_some()
    /// );
    /// ```
    pub fn from_jwt_authorities(
        trust_domain: TrustDomain,
        jwks: &[u8],
    ) -> Result<Self, JwtBundleError> {
        use serde::de::Error as _;

        let value: Value = serde_json::from_slice(jwks)?;

        let keys = value
            .get("keys")
            .and_then(Value::as_array)
            .ok_or_else(|| serde_json::Error::custom("jwks must contain a 'keys' array"))?;

        let mut authorities: HashMap<String, Arc<JwtAuthority>> = HashMap::new();

        for key in keys {
            let jwk_json = serde_json::to_vec(key)?;
            let authority = JwtAuthority::from_jwk_json(&jwk_json)?;
            authorities.insert(authority.key_id().to_owned(), Arc::new(authority));
        }

        Ok(Self {
            trust_domain,
            jwt_authorities: authorities,
        })
    }

    /// Returns the [`JwtAuthority`] with the given key ID.
    ///
    /// The key ID (`kid`) corresponds to the `kid` header in JWT-SVIDs. Use this
    /// method to find the authority needed to verify a token's signature.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, JwtBundle};
    /// # // In practice, you would parse from JWKS:
    /// # // let bundle = JwtBundle::from_jwt_authorities(trust_domain, jwks_bytes)?;
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = JwtBundle::new(trust_domain);
    /// # let kid = "test-kid";
    /// if let Some(authority) = bundle.find_jwt_authority(kid) {
    ///     // Use authority to verify JWT signature
    ///     let _jwk_json = authority.jwk_json();
    /// }
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn find_jwt_authority(&self, key_id: &str) -> Option<&Arc<JwtAuthority>> {
        self.jwt_authorities.get(key_id)
    }

    /// Adds a JWK authority to the bundle from a single JWK JSON object.
    ///
    /// # Errors
    ///
    /// Returns [`JwtBundleError::MissingKeyId`] if the JWK JSON object does not contain `kid`.
    /// Returns [`JwtBundleError::Deserialize`] if the provided bytes are not valid JSON.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, JwtBundle};
    /// use spiffe::bundle::jwt::JwtAuthority;
    ///
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let mut bundle = JwtBundle::new(trust_domain);
    ///
    /// let jwk_json = br#"{"kty":"EC","kid":"test","crv":"P-256","x":"","y":""}"#;
    /// let authority = JwtAuthority::from_jwk_json(jwk_json)?;
    ///
    /// bundle.add_jwt_authority(authority);
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn add_jwt_authority(&mut self, authority: JwtAuthority) {
        self.jwt_authorities
            .insert(authority.key_id().to_owned(), Arc::new(authority));
    }

    /// Adds a JWT authority to the bundle from a single JWK JSON object.
    ///
    /// The input must be a **single JWK** (not a JWKS). The `kid` (Key ID) field is
    /// required and is used to identify the authority within the bundle.
    ///
    /// # Errors
    ///
    /// Returns [`JwtBundleError`] if:
    /// - the provided bytes are not valid JSON,
    /// - the JSON does not represent a valid JWK object,
    /// - the JWK does not contain a `kid` field.
    pub fn add_jwk_authority_json(&mut self, jwk_json: &[u8]) -> Result<(), JwtBundleError> {
        let authority = JwtAuthority::from_jwk_json(jwk_json)?;
        self.add_jwt_authority(authority);
        Ok(())
    }

    /// Returns an iterator over all JWT authorities in this bundle.
    ///
    /// The iterator yields `&Arc<JwtAuthority>` values, allowing access to each
    /// authority's key ID and JWK JSON without consuming the bundle.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, JwtBundle};
    ///
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = JwtBundle::new(trust_domain);
    ///
    /// for authority in bundle.jwt_authorities() {
    ///     println!("Key ID: {}", authority.key_id());
    /// }
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn jwt_authorities(&self) -> impl Iterator<Item = &Arc<JwtAuthority>> {
        self.jwt_authorities.values()
    }
}

impl JwtBundleSet {
    /// Creates an empty JWT bundle set.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, JwtBundle, JwtBundleSet};
    ///
    /// let mut set = JwtBundleSet::new();
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = JwtBundle::new(trust_domain.clone());
    /// set.add_bundle(bundle);
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub const fn new() -> Self {
        Self {
            bundles: BTreeMap::new(),
        }
    }

    /// Adds a new [`JwtBundle`] into the set. If a bundle already exists for the
    /// trust domain, the existing bundle is replaced.
    pub fn add_bundle(&mut self, bundle: JwtBundle) {
        let trust_domain = bundle.trust_domain().clone();
        self.bundles.insert(trust_domain, Arc::new(bundle));
    }

    /// Returns the bundle for a trust domain.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, JwtBundle, JwtBundleSet};
    ///
    /// let mut set = JwtBundleSet::new();
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = JwtBundle::new(trust_domain.clone());
    /// set.add_bundle(bundle);
    ///
    /// let retrieved = set.get(&trust_domain);
    /// assert!(retrieved.is_some());
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn get(&self, trust_domain: &TrustDomain) -> Option<Arc<JwtBundle>> {
        self.bundles.get(trust_domain).cloned()
    }

    /// Returns a reference to the bundle for a trust domain.
    pub fn get_ref(&self, trust_domain: &TrustDomain) -> Option<&Arc<JwtBundle>> {
        self.bundles.get(trust_domain)
    }

    /// Returns an iterator over `(TrustDomain, JwtBundle)` entries.
    pub fn iter(&self) -> impl Iterator<Item = (&TrustDomain, &Arc<JwtBundle>)> {
        self.bundles.iter()
    }

    /// Returns the number of bundles in the set.
    pub fn len(&self) -> usize {
        self.bundles.len()
    }

    /// Returns `true` if the set contains no bundles.
    pub fn is_empty(&self) -> bool {
        self.bundles.is_empty()
    }

    /// Returns the [`JwtBundle`] associated with the given [`TrustDomain`].
    #[deprecated(since = "0.9.0", note = "Use `JwtBundleSet::get` instead.")]
    pub fn bundle_for(&self, trust_domain: &TrustDomain) -> Option<&Arc<JwtBundle>> {
        self.bundles.get(trust_domain)
    }
}

impl Default for JwtBundleSet {
    fn default() -> Self {
        Self::new()
    }
}

impl BundleSource for JwtBundleSet {
    type Item = JwtBundle;
    type Error = Infallible;

    fn bundle_for_trust_domain(
        &self,
        trust_domain: &TrustDomain,
    ) -> Result<Option<Arc<Self::Item>>, Self::Error> {
        Ok(self.get(trust_domain))
    }
}

impl Extend<JwtBundle> for JwtBundleSet {
    fn extend<T: IntoIterator<Item = JwtBundle>>(&mut self, iter: T) {
        for b in iter {
            self.add_bundle(b);
        }
    }
}

impl FromIterator<JwtBundle> for JwtBundleSet {
    fn from_iter<T: IntoIterator<Item = JwtBundle>>(iter: T) -> Self {
        let mut set = Self::new();
        set.extend(iter);
        set
    }
}

#[cfg(test)]
mod jwt_bundle_test {
    use super::*;

    fn td(s: &str) -> TrustDomain {
        TrustDomain::new(s).unwrap()
    }

    fn jwk_with_kid(kid: &str) -> JwtAuthority {
        let json = format!(
            r#"{{
                "kty": "oct",
                "kid": "{kid}",
                "k": "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow"
            }}"#
        );
        JwtAuthority::from_jwk_json(json.as_bytes()).expect("valid JWK JSON")
    }

    #[test]
    fn test_new_bundle_is_empty_and_has_trust_domain() {
        let trust_domain = td("example.org");
        let bundle = JwtBundle::new(trust_domain.clone());

        assert_eq!(bundle.trust_domain(), &trust_domain);
        assert!(bundle.jwt_authorities.is_empty());
    }

    #[test]
    fn test_parse_bundle_from_json_single_authority() {
        let bundle_bytes = r#"{
            "keys": [
                {
                    "kty": "EC",
                    "kid": "C6vs25welZOx6WksNYfbMfiw9l96pMnD",
                    "crv": "P-256",
                    "x": "ngLYQnlfF6GsojUwqtcEE3WgTNG2RUlsGhK73RNEl5k",
                    "y": "tKbiDSUSsQ3F1P7wteeHNXIcU-cx6CgSbroeQrQHTLM"
                }
            ]
        }"#
        .as_bytes();

        let trust_domain = td("example.org");
        let jwt_bundle = JwtBundle::from_jwt_authorities(trust_domain, bundle_bytes).unwrap();

        assert!(jwt_bundle
            .find_jwt_authority("C6vs25welZOx6WksNYfbMfiw9l96pMnD")
            .is_some());
    }

    #[test]
    fn test_parse_bundle_from_json_multiple_authorities() {
        let bundle_bytes = r#"{
            "keys": [
                {
                    "kty": "EC",
                    "kid": "C6vs25welZOx6WksNYfbMfiw9l96pMnD",
                    "crv": "P-256",
                    "x": "ngLYQnlfF6GsojUwqtcEE3WgTNG2RUlsGhK73RNEl5k",
                    "y": "tKbiDSUSsQ3F1P7wteeHNXIcU-cx6CgSbroeQrQHTLM"
                },
                {
                    "kty": "EC",
                    "kid": "gHTCunJbefYtnZnTctd84xeRWyMrEsWD",
                    "crv": "P-256",
                    "x": "7MGOl06DP9df2u8oHY6lqYFIoQWzCj9UYlp-MFeEYeY",
                    "y": "PSLLy5Pg0_kNGFFXq_eeq9kYcGDM3MPHJ6ncteNOr6w"
                }
            ]
        }"#
        .as_bytes();

        let trust_domain = td("example.org");
        let jwt_bundle = JwtBundle::from_jwt_authorities(trust_domain, bundle_bytes).unwrap();

        assert!(jwt_bundle
            .find_jwt_authority("C6vs25welZOx6WksNYfbMfiw9l96pMnD")
            .is_some());
        assert!(jwt_bundle
            .find_jwt_authority("gHTCunJbefYtnZnTctd84xeRWyMrEsWD")
            .is_some());
    }

    #[test]
    fn test_parse_jwks_with_empty_keys_array() {
        let bundle_bytes = br#"{"keys": []}"#;
        let trust_domain = td("domain.test");

        let jwt_bundle = JwtBundle::from_jwt_authorities(trust_domain, bundle_bytes)
            .expect("failed to parse JWKS with empty keys array");

        assert!(jwt_bundle.jwt_authorities.is_empty());
    }

    #[test]
    fn test_parse_bundle_missing_kid_returns_missing_key_id() {
        let bundle_bytes = r#"{
            "keys": [
                {
                    "kty": "EC",
                    "crv": "P-256",
                    "x": "ngLYQnlfF6GsojUwqtcEE3WgTNG2RUlsGhK73RNEl5k",
                    "y": "tKbiDSUSsQ3F1P7wteeHNXIcU-cx6CgSbroeQrQHTLM"
                }
            ]
        }"#
        .as_bytes();

        let trust_domain = td("example.org");
        let err = JwtBundle::from_jwt_authorities(trust_domain, bundle_bytes).unwrap_err();

        assert!(matches!(err, JwtBundleError::MissingKeyId));
    }

    #[test]
    fn test_parse_bundle_invalid_json_returns_deserialize() {
        // Deliberately malformed JSON (extra '{')
        let bundle_bytes = br#"{{ "keys": [] }"#;

        let trust_domain = td("example.org");
        let err = JwtBundle::from_jwt_authorities(trust_domain, bundle_bytes).unwrap_err();

        assert!(matches!(err, JwtBundleError::Deserialize(_)));
    }

    #[test]
    fn test_add_jwt_authority_success_and_find() {
        let trust_domain = td("example.org");
        let mut bundle = JwtBundle::new(trust_domain);

        bundle.add_jwt_authority(jwk_with_kid("kid-1"));

        assert!(bundle.find_jwt_authority("kid-1").is_some());
        assert!(bundle.find_jwt_authority("missing").is_none());
    }

    #[test]
    fn test_authority_from_jwk_json_missing_kid() {
        // Build a JWK without kid via JSON parsing.
        let jwk_json = br#"{
        "kty": "oct",
        "k": "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow"
    }"#;

        let err = JwtAuthority::from_jwk_json(jwk_json).unwrap_err();
        assert!(matches!(err, JwtBundleError::MissingKeyId));
    }

    #[test]
    fn test_set_new_default_len_is_empty() {
        let set = JwtBundleSet::new();
        assert!(set.is_empty());
        assert_eq!(set.len(), 0);

        let set2 = JwtBundleSet::default();
        assert!(set2.is_empty());
        assert_eq!(set2.len(), 0);
    }

    #[test]
    fn test_set_add_and_get() {
        let td1 = td("a.test");
        let td2 = td("b.test");

        let mut set = JwtBundleSet::new();
        set.add_bundle(JwtBundle::new(td1.clone()));
        set.add_bundle(JwtBundle::new(td2.clone()));

        assert_eq!(set.len(), 2);
        assert!(set.get(&td1).is_some());
        assert!(set.get(&td2).is_some());
        assert!(set.get(&td("missing.test")).is_none());

        // get_ref returns same bundle Arc contents
        let a1 = set.get(&td1).unwrap();
        let a2 = set.get_ref(&td1).unwrap();
        assert_eq!(a1, *a2);
    }

    #[test]
    fn test_set_add_replaces_existing_bundle_for_same_trust_domain() {
        let trust_domain = td("replace.test");

        let mut b1 = JwtBundle::new(trust_domain.clone());
        b1.add_jwt_authority(jwk_with_kid("kid-old"));

        let mut b2 = JwtBundle::new(trust_domain.clone());
        b2.add_jwt_authority(jwk_with_kid("kid-new"));

        let mut set = JwtBundleSet::new();
        set.add_bundle(b1);
        assert!(set
            .get(&trust_domain)
            .unwrap()
            .find_jwt_authority("kid-old")
            .is_some());

        set.add_bundle(b2); // replace
        let bundle = set.get(&trust_domain).unwrap();
        assert!(bundle.find_jwt_authority("kid-old").is_none());
        assert!(bundle.find_jwt_authority("kid-new").is_some());
        assert_eq!(set.len(), 1);
    }

    #[test]
    fn test_set_iter_returns_all_entries() {
        let td1 = td("a.test");
        let td2 = td("b.test");

        let mut set = JwtBundleSet::new();
        set.add_bundle(JwtBundle::new(td1.clone()));
        set.add_bundle(JwtBundle::new(td2.clone()));

        let trust_domains: Vec<TrustDomain> = set.iter().map(|(td, _)| (*td).clone()).collect();
        assert_eq!(trust_domains.len(), 2);
        assert!(trust_domains.contains(&td1));
        assert!(trust_domains.contains(&td2));
    }

    #[test]
    fn test_bundle_source_impl_matches_get() {
        let td1 = td("a.test");
        let mut set = JwtBundleSet::new();
        set.add_bundle(JwtBundle::new(td1.clone()));

        let via_get = set.get(&td1);
        let via_trait = set.bundle_for_trust_domain(&td1).expect("infallible");

        assert_eq!(via_get, via_trait);
    }

    #[test]
    fn test_extend_and_from_iterator() {
        let td1 = td("a.test");
        let td2 = td("b.test");

        let b1 = JwtBundle::new(td1.clone());
        let b2 = JwtBundle::new(td2.clone());

        let mut set = JwtBundleSet::new();
        set.extend([b1.clone(), b2.clone()]);
        assert_eq!(set.len(), 2);
        assert!(set.get(&td1).is_some());
        assert!(set.get(&td2).is_some());

        let set2: JwtBundleSet = vec![b1, b2].into_iter().collect();
        assert_eq!(set2.len(), 2);
        assert!(set2.get(&td1).is_some());
        assert!(set2.get(&td2).is_some());
    }

    #[test]
    fn test_bundle_for() {
        let trust_domain = td("example.org");
        let mut set = JwtBundleSet::new();
        set.add_bundle(JwtBundle::new(trust_domain.clone()));

        #[expect(deprecated, reason = "testing deprecated API")]
        {
            assert!(set.bundle_for(&trust_domain).is_some());
        }
    }
}
