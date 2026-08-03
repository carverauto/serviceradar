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

use crate::Context;
use crate::Error;
use crate::ProvideCredential;
use crate::ProvideCredentialDyn;
use crate::Result;
use crate::SignRequest;
use crate::SignRequestDyn;
use crate::SigningCredential;
use std::any::type_name;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Loads credentials and atomically signs request heads.
///
/// The service-specific [`SignRequest`] runs against a private candidate. Only the
/// candidate URI and headers are committed after successful signing.
#[derive(Clone, Debug)]
pub struct Signer<K: SigningCredential> {
    ctx: Context,
    loader: Arc<dyn ProvideCredentialDyn<Credential = K>>,
    builder: Arc<dyn SignRequestDyn<Credential = K>>,
    credential: Arc<Mutex<Option<K>>>,
}

impl<K: SigningCredential> Signer<K> {
    /// Create a new signer.
    pub fn new(
        ctx: Context,
        loader: impl ProvideCredential<Credential = K>,
        builder: impl SignRequest<Credential = K>,
    ) -> Self {
        Self {
            ctx,

            loader: Arc::new(loader),
            builder: Arc::new(builder),
            credential: Arc::new(Mutex::new(None)),
        }
    }

    /// Replace the context while keeping credential provider and request signer.
    pub fn with_context(mut self, ctx: Context) -> Self {
        self.ctx = ctx;
        self
    }

    /// Replace the credential provider while keeping context and request signer.
    pub fn with_credential_provider(
        mut self,
        provider: impl ProvideCredential<Credential = K>,
    ) -> Self {
        self.loader = Arc::new(provider);
        self.credential = Arc::new(Mutex::new(None)); // Clear cached credential
        self
    }

    /// Replace the request signer while keeping context and credential provider.
    pub fn with_request_signer(mut self, signer: impl SignRequest<Credential = K>) -> Self {
        self.builder = Arc::new(signer);
        self
    }

    /// Sign a wire-ready request head.
    ///
    /// The request URI must satisfy the input contract of the configured
    /// [`SignRequest`]. Built-in signers require an authority and expect path and query
    /// data to be percent-encoded exactly once before this call. Signing does not
    /// perform general-purpose URI encoding for the caller.
    ///
    /// If credential loading or request signing returns an error, `req` is unchanged.
    /// On success, only `req.uri` and `req.headers` may change; the method, version, and
    /// extensions retain their input values.
    ///
    /// `expires_in` is a service-specific validity input and does not universally
    /// select query authentication. The configured service signer and credential type
    /// determine how it is interpreted.
    ///
    /// Cached credentials must be fresh according to [`SigningCredential::is_valid`]
    /// and usable through [`SignRequest::required_valid_until`]. A refreshed credential
    /// only needs to satisfy the exact operation deadline. Provider errors are returned
    /// without internal retry or fallback to the previous cached credential.
    pub async fn sign(
        &self,
        req: &mut http::request::Parts,
        expires_in: Option<Duration>,
    ) -> Result<()> {
        let credential = self.credential.lock().expect("lock poisoned").clone();
        let credential = match credential {
            Some(credential)
                if credential.is_valid()
                    && credential.is_valid_at(
                        self.builder
                            .required_valid_until_dyn(&credential, expires_in),
                    ) =>
            {
                credential
            }
            _ => {
                let credential = self
                    .loader
                    .provide_credential_dyn(&self.ctx)
                    .await?
                    .ok_or_else(|| {
                        Error::credential_invalid("failed to load signing credential")
                            .with_context(format!("credential_type: {}", type_name::<K>()))
                    })?;

                *self.credential.lock().expect("lock poisoned") = Some(credential.clone());

                let required_until = self
                    .builder
                    .required_valid_until_dyn(&credential, expires_in);
                if !credential.is_valid_at(required_until) {
                    return Err(Error::credential_invalid(
                        "refreshed signing credential expires before the requested operation deadline",
                    )
                    .with_context(format!("credential_type: {}", type_name::<K>()))
                    .with_context(format!("required_valid_until: {required_until}")));
                }

                credential
            }
        };

        let mut candidate = req.clone();
        self.builder
            .sign_request_dyn(&self.ctx, &mut candidate, Some(&credential), expires_in)
            .await?;

        req.uri = candidate.uri;
        req.headers = candidate.headers;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::Timestamp;
    use crate::{ErrorKind, ProvideCredential, SignRequest};
    use http::{HeaderValue, Method, Request, Version};
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[derive(Clone, Debug)]
    struct TestCredential;

    impl SigningCredential for TestCredential {
        fn is_valid(&self) -> bool {
            true
        }
    }

    #[derive(Debug)]
    struct StaticProvider;

    impl ProvideCredential for StaticProvider {
        type Credential = TestCredential;

        async fn provide_credential(&self, _ctx: &Context) -> Result<Option<Self::Credential>> {
            Ok(Some(TestCredential))
        }
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    struct Extension(&'static str);

    #[derive(Debug)]
    struct MutatingSigner {
        fail: bool,
    }

    impl SignRequest for MutatingSigner {
        type Credential = TestCredential;

        async fn sign_request(
            &self,
            _ctx: &Context,
            req: &mut http::request::Parts,
            _credential: Option<&Self::Credential>,
            _expires_in: Option<Duration>,
        ) -> Result<()> {
            req.method = Method::POST;
            req.uri = "https://signed.example.com/result?auth=1"
                .parse()
                .expect("URI must parse");
            req.version = Version::HTTP_2;
            req.headers.clear();
            req.headers
                .insert("authorization", HeaderValue::from_static("signed"));
            req.extensions.insert(Extension("candidate"));

            if self.fail {
                Err(Error::unexpected("injected signing failure"))
            } else {
                Ok(())
            }
        }
    }

    #[derive(Clone, Debug)]
    struct ExpiringCredential {
        generation: u8,
        fresh: bool,
        expires_at: Timestamp,
        required_until: Timestamp,
    }

    impl SigningCredential for ExpiringCredential {
        fn is_valid(&self) -> bool {
            self.fresh
        }

        fn is_valid_at(&self, timestamp: Timestamp) -> bool {
            self.expires_at > timestamp
        }
    }

    #[derive(Debug)]
    struct SequenceProvider {
        responses: Mutex<VecDeque<Result<Option<ExpiringCredential>>>>,
        calls: Arc<AtomicUsize>,
    }

    impl SequenceProvider {
        fn new(
            responses: impl IntoIterator<Item = Result<Option<ExpiringCredential>>>,
        ) -> (Self, Arc<AtomicUsize>) {
            let calls = Arc::new(AtomicUsize::new(0));
            (
                Self {
                    responses: Mutex::new(responses.into_iter().collect()),
                    calls: calls.clone(),
                },
                calls,
            )
        }
    }

    impl ProvideCredential for SequenceProvider {
        type Credential = ExpiringCredential;

        async fn provide_credential(&self, _ctx: &Context) -> Result<Option<Self::Credential>> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.responses
                .lock()
                .expect("lock poisoned")
                .pop_front()
                .unwrap_or(Ok(None))
        }
    }

    #[derive(Debug)]
    struct OperationSigner;

    impl SignRequest for OperationSigner {
        type Credential = ExpiringCredential;

        fn required_valid_until(
            &self,
            credential: &Self::Credential,
            _expires_in: Option<Duration>,
        ) -> Timestamp {
            credential.required_until
        }

        async fn sign_request(
            &self,
            _ctx: &Context,
            req: &mut http::request::Parts,
            credential: Option<&Self::Credential>,
            expires_in: Option<Duration>,
        ) -> Result<()> {
            let credential = credential.expect("credential must be present");
            if !credential.is_valid_at(self.required_valid_until(credential, expires_in)) {
                return Err(Error::credential_invalid(
                    "credential is not valid for operation",
                ));
            }
            req.headers.insert(
                "x-credential-generation",
                credential.generation.to_string().parse()?,
            );
            Ok(())
        }
    }

    fn request_parts() -> http::request::Parts {
        let mut parts = Request::get("https://example.com/original?x=%2F")
            .version(Version::HTTP_11)
            .header("x-original", "value")
            .body(())
            .expect("request must build")
            .into_parts()
            .0;
        parts.extensions.insert(Extension("caller"));
        parts
    }

    #[test]
    fn failure_leaves_entire_request_head_unchanged() {
        let signer = Signer::new(
            Context::new(),
            StaticProvider,
            MutatingSigner { fail: true },
        );
        let mut parts = request_parts();
        let original = parts.clone();

        let result = futures::executor::block_on(signer.sign(&mut parts, None));

        assert!(result.is_err());
        assert_eq!(parts.method, original.method);
        assert_eq!(parts.uri, original.uri);
        assert_eq!(parts.version, original.version);
        assert_eq!(parts.headers, original.headers);
        assert_eq!(
            parts.extensions.get::<Extension>(),
            original.extensions.get::<Extension>()
        );
    }

    #[test]
    fn success_commits_only_uri_and_headers() {
        let signer = Signer::new(
            Context::new(),
            StaticProvider,
            MutatingSigner { fail: false },
        );
        let mut parts = request_parts();
        let original = parts.clone();

        futures::executor::block_on(signer.sign(&mut parts, None)).expect("signing must succeed");

        assert_eq!(parts.method, original.method);
        assert_eq!(parts.version, original.version);
        assert_eq!(
            parts.extensions.get::<Extension>(),
            original.extensions.get::<Extension>()
        );
        assert_eq!(
            parts.uri,
            "https://signed.example.com/result?auth=1"
                .parse::<http::Uri>()
                .expect("URI must parse")
        );
        assert_eq!(
            parts.headers.get("authorization"),
            Some(&HeaderValue::from_static("signed"))
        );
        assert!(!parts.headers.contains_key("x-original"));
    }

    #[test]
    fn refreshes_cached_credential_for_operation_requirement() {
        let base = Timestamp::from_second(1_000).expect("timestamp must be valid");
        let cached = ExpiringCredential {
            generation: 1,
            fresh: true,
            expires_at: base + Duration::from_secs(20),
            required_until: base + Duration::from_secs(30),
        };
        let refreshed = ExpiringCredential {
            generation: 2,
            fresh: true,
            expires_at: base + Duration::from_secs(20),
            required_until: base + Duration::from_secs(10),
        };
        let (provider, calls) = SequenceProvider::new([Ok(Some(refreshed))]);
        let signer = Signer::new(Context::new(), provider, OperationSigner);
        *signer.credential.lock().expect("lock poisoned") = Some(cached);

        let mut parts = request_parts();
        futures::executor::block_on(signer.sign(&mut parts, None))
            .expect("refreshed credential must satisfy the recomputed requirement");

        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(
            parts.headers.get("x-credential-generation"),
            Some(&HeaderValue::from_static("2"))
        );
    }

    #[test]
    fn uses_refreshed_credential_that_is_usable_but_not_fresh() {
        let base = Timestamp::from_second(2_000).expect("timestamp must be valid");
        let credential = ExpiringCredential {
            generation: 1,
            fresh: false,
            expires_at: base + Duration::from_secs(30),
            required_until: base + Duration::from_secs(10),
        };
        let (provider, calls) =
            SequenceProvider::new([Ok(Some(credential.clone())), Ok(Some(credential))]);
        let signer = Signer::new(Context::new(), provider, OperationSigner);

        for _ in 0..2 {
            let mut parts = request_parts();
            futures::executor::block_on(signer.sign(&mut parts, None))
                .expect("usable refreshed credential must be accepted");
        }

        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn refresh_error_does_not_fall_back_and_caller_can_retry() {
        let base = Timestamp::from_second(3_000).expect("timestamp must be valid");
        let cached = ExpiringCredential {
            generation: 1,
            fresh: false,
            expires_at: base + Duration::from_secs(30),
            required_until: base + Duration::from_secs(10),
        };
        let refreshed = ExpiringCredential {
            generation: 2,
            fresh: true,
            expires_at: base + Duration::from_secs(30),
            required_until: base + Duration::from_secs(10),
        };
        let (provider, calls) = SequenceProvider::new([
            Err(Error::unexpected("injected refresh failure")),
            Ok(Some(refreshed)),
        ]);
        let signer = Signer::new(Context::new(), provider, OperationSigner);
        *signer.credential.lock().expect("lock poisoned") = Some(cached);

        let mut parts = request_parts();
        let original = parts.clone();
        let err = futures::executor::block_on(signer.sign(&mut parts, None))
            .expect_err("refresh error must be returned");
        assert_eq!(err.kind(), ErrorKind::Unexpected);
        assert_eq!(parts.uri, original.uri);
        assert_eq!(parts.headers, original.headers);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        futures::executor::block_on(signer.sign(&mut parts, None))
            .expect("caller retry must attempt refresh again");
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(
            parts.headers.get("x-credential-generation"),
            Some(&HeaderValue::from_static("2"))
        );
    }

    #[test]
    fn missing_refresh_does_not_fall_back_and_caller_can_retry() {
        let base = Timestamp::from_second(4_000).expect("timestamp must be valid");
        let cached = ExpiringCredential {
            generation: 1,
            fresh: false,
            expires_at: base + Duration::from_secs(30),
            required_until: base + Duration::from_secs(10),
        };
        let refreshed = ExpiringCredential {
            generation: 2,
            fresh: true,
            expires_at: base + Duration::from_secs(30),
            required_until: base + Duration::from_secs(10),
        };
        let (provider, calls) = SequenceProvider::new([Ok(None), Ok(Some(refreshed))]);
        let signer = Signer::new(Context::new(), provider, OperationSigner);
        *signer.credential.lock().expect("lock poisoned") = Some(cached);
        let mut parts = request_parts();
        let original = parts.clone();

        let err = futures::executor::block_on(signer.sign(&mut parts, None))
            .expect_err("missing credential must fail");

        assert_eq!(err.kind(), ErrorKind::CredentialInvalid);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(parts.uri, original.uri);
        assert_eq!(parts.headers, original.headers);

        futures::executor::block_on(signer.sign(&mut parts, None))
            .expect("caller retry must attempt refresh again");
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(
            parts.headers.get("x-credential-generation"),
            Some(&HeaderValue::from_static("2"))
        );
    }
}
