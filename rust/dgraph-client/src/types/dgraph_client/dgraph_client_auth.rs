/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! ACL login and token refresh.

use prost::Message;
use proto_dgraph::api;
use tonic::{Code, Request, Status};

use super::DgraphClient;
use crate::errors::auth_error::AuthError;
use crate::errors::dgraph_error::DgraphError;
use crate::types::secret::Secret;
use crate::types::token_cache::Tokens;

/// gRPC metadata key carrying the access token. Matches the Go client.
const ACCESS_JWT_METADATA_KEY: &str = "accessjwt";

/// Server message fragment indicating an expired access token.
///
/// The server does not use a distinct status code for this, so the message is the only
/// signal available. It is used only as a fallback after the status code check below, and
/// only ever to decide whether to attempt one refresh.
const TOKEN_EXPIRED_FRAGMENT: &str = "Token is expired";

impl DgraphClient {
    /// Log in with the configured ACL credentials.
    pub(crate) async fn login(&self) -> Result<(), DgraphError> {
        let config = self.config();
        let (Some(userid), Some(password)) = (config.username(), config.password()) else {
            return Ok(());
        };

        let request = api::LoginRequest {
            userid: userid.to_string(),
            password: password.expose().to_string(),
            namespace: config.namespace().unwrap_or(0),
            ..Default::default()
        };

        let tokens = self.issue_login(request).await?;
        self.tokens().store(tokens).await;

        Ok(())
    }

    /// Exchange a login request for tokens.
    async fn issue_login(&self, request: api::LoginRequest) -> Result<Tokens, AuthError> {
        let mut stub = self.stub();
        let response = stub
            .login(Request::new(request))
            .await
            .map_err(|status| AuthError::LoginFailed(status.code(), status.message().to_string()))?
            .into_inner();

        Self::decode_tokens(&response.json)
    }

    /// Decode the login payload.
    ///
    /// The wire field is named `json`, but it carries a protobuf-encoded `api.Jwt`. The Go
    /// client calls `proto.Unmarshal` on it too; the name is simply wrong upstream.
    fn decode_tokens(payload: &[u8]) -> Result<Tokens, AuthError> {
        let jwt = api::Jwt::decode(payload).map_err(|err| {
            AuthError::MalformedJwtPayload(format!(
                "login payload is not a protobuf-encoded Jwt: {err}"
            ))
        })?;

        Ok(Tokens::new(
            Secret::new(jwt.access_jwt),
            Secret::new(jwt.refresh_jwt),
        ))
    }

    /// Attach the cached access token to an outgoing request.
    pub(crate) async fn authenticated<T>(&self, message: T) -> Request<T> {
        let mut request = Request::new(message);

        if let Some(token) = self.tokens().access_token().await {
            // A malformed token cannot be represented in gRPC metadata; skip it rather
            // than panicking on caller-adjacent data.
            if let Ok(value) = token.expose().parse() {
                request
                    .metadata_mut()
                    .insert(ACCESS_JWT_METADATA_KEY, value);
            }
        }

        request
    }

    /// Whether a failed RPC should trigger exactly one token refresh.
    ///
    /// Checks the status code first. The message fallback exists because Dgraph reports an
    /// expired token as `Unauthenticated`/`Unknown` with a distinguishing message rather
    /// than a dedicated code.
    ///
    /// Requests are only retried when tokens are actually cached: without them there is
    /// nothing to refresh, and retrying would just repeat the same failure.
    pub(crate) fn is_token_expired(status: &Status) -> bool {
        let plausible_code = matches!(
            status.code(),
            Code::Unauthenticated | Code::PermissionDenied | Code::Unknown
        );

        plausible_code && status.message().contains(TOKEN_EXPIRED_FRAGMENT)
    }

    /// Refresh the access token once, collapsing concurrent refreshes into one login.
    pub(crate) async fn refresh_token(&self, original: &Status) -> Result<(), DgraphError> {
        let previous = self.tokens().access_token().await;
        let original_code = original.code();
        let original_message = original.message().to_string();

        self.tokens()
            .refresh_once(previous, |refresh_token| async move {
                let Some(refresh_token) = refresh_token else {
                    return Err(AuthError::MissingRefreshToken(
                        original_code,
                        original_message.clone(),
                    ));
                };

                let request = api::LoginRequest {
                    refresh_token: refresh_token.expose().to_string(),
                    ..Default::default()
                };

                self.issue_login(request)
                    .await
                    .map_err(|err| match err.kind() {
                        // Re-tag a login failure that happened during a refresh so the
                        // triggering failure is not lost, which is the Go client's worst
                        // error-reporting behaviour.
                        crate::errors::auth_error::AuthErrorEnum::LoginFailed { code, message } => {
                            AuthError::RefreshFailed(
                                *code,
                                message.clone(),
                                original_code,
                                original_message.clone(),
                            )
                        }
                        _ => err,
                    })
            })
            .await?;

        Ok(())
    }

    /// Whether this client has credentials that make a refresh possible at all.
    pub(crate) async fn can_refresh(&self) -> bool {
        self.tokens().is_populated().await
    }
}
