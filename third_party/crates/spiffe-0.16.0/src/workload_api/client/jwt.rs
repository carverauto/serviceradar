use crate::constants::DEFAULT_SVID;
use crate::workload_api::pb::workload::{
    JwtBundlesRequest, JwtBundlesResponse, JwtsvidRequest, JwtsvidResponse, ValidateJwtsvidRequest,
    ValidateJwtsvidResponse,
};
use crate::{
    JwtBundle, JwtBundleSet, JwtSvid, SpiffeId, TrustDomain, WorkloadApiClient, WorkloadApiError,
};
use futures::{Stream, StreamExt as _};
use std::str::FromStr as _;
use std::sync::Arc;

impl WorkloadApiClient {
    /// Fetches the current set of JWT bundles from the SPIFFE Workload API.
    ///
    /// This method establishes a streaming gRPC request to the Workload API
    /// and returns the latest JWT bundle set received from the server.
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if the gRPC request fails, the stream
    /// terminates unexpectedly, or an invalid response is received.
    pub async fn fetch_jwt_bundles(&self) -> Result<JwtBundleSet, WorkloadApiError> {
        let request = JwtBundlesRequest::default();

        let mut client = self.client.clone();

        let grpc_stream_response: tonic::Response<tonic::Streaming<JwtBundlesResponse>> =
            client.fetch_jwt_bundles(request).await?;

        let response = Self::first_message(grpc_stream_response.into_inner()).await?;
        Self::parse_jwt_bundle_set_from_grpc_response(response)
    }

    /// Fetches a `JwtSvid` for the given audience and optional SPIFFE ID.
    ///
    /// If `spiffe_id` is `None`, the Workload API returns the default identity.
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if the JWT-SVID request fails or the Workload API
    /// returns an invalid or empty response.
    pub async fn fetch_jwt_svid<I>(
        &self,
        audience: I,
        spiffe_id: Option<&SpiffeId>,
    ) -> Result<JwtSvid, WorkloadApiError>
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        #[cfg(test)]
        if let Some(fetch) = &self.jwt_fetch_hook {
            let audience = audience
                .into_iter()
                .map(|a| a.as_ref().to_string())
                .collect();
            return fetch(audience, spiffe_id.cloned()).await;
        }

        let response = self.fetch_jwt(audience, spiffe_id).await?;
        let r = response
            .svids
            .get(DEFAULT_SVID)
            .ok_or(WorkloadApiError::EmptyResponse)?;

        let mut svid = JwtSvid::from_str(&r.svid).map_err(WorkloadApiError::JwtSvid)?;

        if !r.hint.is_empty() {
            svid = svid.with_hint(Arc::<str>::from(r.hint.as_str()));
        }

        Ok(svid)
    }

    /// Fetches all JWT-SVIDs for the given audience and optional SPIFFE ID.
    ///
    /// The Workload API can return more than one JWT-SVID. Each returned [`JwtSvid`] may include an
    /// optional **hint** (via [`JwtSvid::hint`]) that can be used to disambiguate which SVID to use.
    ///
    /// If `spiffe_id` is `None`, the Workload API returns JWT-SVIDs for the default identity.
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if the JWT-SVID request fails, the Workload API response is
    /// invalid or empty, or any returned token cannot be parsed.
    pub async fn fetch_all_jwt_svids<I>(
        &self,
        audience: I,
        spiffe_id: Option<&SpiffeId>,
    ) -> Result<Vec<JwtSvid>, WorkloadApiError>
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        let response = self.fetch_jwt(audience, spiffe_id).await?;

        response
            .svids
            .into_iter()
            .map(|r| {
                let mut svid = JwtSvid::from_str(&r.svid).map_err(WorkloadApiError::JwtSvid)?;
                if !r.hint.is_empty() {
                    svid = svid.with_hint(Arc::<str>::from(r.hint.as_str()));
                }
                Ok(svid)
            })
            .collect()
    }

    /// Fetches the JWT-SVID whose Workload API hint matches `hint`.
    ///
    /// Wrapper around [`WorkloadApiClient::fetch_all_jwt_svids`] that selects
    /// a single [`JwtSvid`] by its hint.
    ///
    /// The hint is **not** part of the JWT token; it is transport metadata provided by the SPIFFE
    /// Workload API to help identify a specific SVID when multiple are available.
    ///
    /// If `spiffe_id` is `None`, the Workload API returns JWT-SVIDs for the default identity.
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if the JWT-SVID request fails, the Workload API response is
    /// invalid, or no JWT-SVID with the requested hint is found.
    pub async fn fetch_jwt_svid_by_hint<I>(
        &self,
        audience: I,
        spiffe_id: Option<&SpiffeId>,
        hint: impl AsRef<str>,
    ) -> Result<JwtSvid, WorkloadApiError>
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        let hint = hint.as_ref();
        let all = self.fetch_all_jwt_svids(audience, spiffe_id).await?;
        all.into_iter()
            .find(|s| s.hint() == Some(hint))
            .ok_or_else(|| WorkloadApiError::HintNotFound(hint.to_owned()))
    }

    /// Fetches a JWT-SVID token string for the given audience and optional SPIFFE ID.
    ///
    /// If `spiffe_id` is `None`, the Workload API returns the default identity.
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if the token request fails or the Workload API
    /// returns an invalid or empty response.
    #[cfg(feature = "jwt")]
    pub async fn fetch_jwt_token<I>(
        &self,
        audience: I,
        spiffe_id: Option<&SpiffeId>,
    ) -> Result<String, WorkloadApiError>
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        let response = self.fetch_jwt(audience, spiffe_id).await?;
        response
            .svids
            .get(DEFAULT_SVID)
            .map(|r| r.svid.clone())
            .ok_or(WorkloadApiError::EmptyResponse)
    }

    /// Validates a JWT-SVID token for the given audience and returns the parsed [`JwtSvid`].
    ///
    /// Validation is performed by the SPIRE agent via the Workload API. After successful
    /// validation, the token is parsed locally for structured access. The use of
    /// `parse_insecure` is safe here because the security property comes from the agent's
    /// validation, not from local signature verification.
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if validation fails or the token cannot be parsed.
    pub async fn validate_jwt_token(
        &self,
        audience: &str,
        jwt_token: &str,
    ) -> Result<JwtSvid, WorkloadApiError> {
        // Validate via the SPIRE agent (security property comes from agent validation)
        let _unused: ValidateJwtsvidResponse = self.validate_jwt(audience, jwt_token).await?;
        // Parse locally for structured access (safe because agent already validated)
        let jwt_svid = JwtSvid::parse_insecure(jwt_token)?;
        Ok(jwt_svid)
    }

    /// Streams JWT bundle set updates from the Workload API.
    ///
    /// The stream ends when the server closes the connection. This stream does not
    /// automatically reconnect; if you need resilience and automatic reconnection,
    /// use [`X509Source`] for X.509 material or handle reconnection manually.
    ///
    /// # Errors
    ///
    /// Returns a [`WorkloadApiError`] if the Workload API stream cannot be
    /// established or the initial request fails.
    pub async fn stream_jwt_bundles(
        &self,
    ) -> Result<
        impl Stream<Item = Result<JwtBundleSet, WorkloadApiError>> + Send + 'static + use<>,
        WorkloadApiError,
    > {
        let request = JwtBundlesRequest::default();

        let mut client = self.client.clone();

        let response = client.fetch_jwt_bundles(request).await?;
        let stream = response.into_inner().map(|message| {
            message
                .map_err(WorkloadApiError::from)
                .and_then(Self::parse_jwt_bundle_set_from_grpc_response)
        });
        Ok(Box::pin(stream))
    }
}

impl WorkloadApiClient {
    async fn fetch_jwt<I>(
        &self,
        audience: I,
        spiffe_id: Option<&SpiffeId>,
    ) -> Result<JwtsvidResponse, WorkloadApiError>
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        let request = JwtsvidRequest {
            spiffe_id: spiffe_id.map(ToString::to_string).unwrap_or_default(),
            audience: audience
                .into_iter()
                .map(|a| a.as_ref().to_string())
                .collect(),
        };

        let mut client = self.client.clone();

        Ok(client.fetch_jwtsvid(request).await?.into_inner())
    }

    async fn validate_jwt(
        &self,
        audience: &str,
        jwt_svid: &str,
    ) -> Result<ValidateJwtsvidResponse, WorkloadApiError> {
        let request = ValidateJwtsvidRequest {
            audience: audience.to_string(),
            svid: jwt_svid.into(),
        };
        let mut client = self.client.clone();
        Ok(client.validate_jwtsvid(request).await?.into_inner())
    }

    fn parse_jwt_bundle_set_from_grpc_response(
        response: JwtBundlesResponse,
    ) -> Result<JwtBundleSet, WorkloadApiError> {
        let mut bundle_set = JwtBundleSet::new();

        for (td, bundle_data) in response.bundles {
            let trust_domain = TrustDomain::try_from(td)?;
            let bundle = JwtBundle::from_jwt_authorities(trust_domain, &bundle_data)
                .map_err(WorkloadApiError::from)?;

            bundle_set.add_bundle(bundle);
        }

        Ok(bundle_set)
    }
}
