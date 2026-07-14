use std::sync::Arc;

use tonic::metadata::{Ascii, MetadataKey, MetadataValue};

const SPIFFE_HEADER_KEY: &str = "workload.spiffe.io";
const SPIFFE_HEADER_VALUE: &str = "true";

// This is a fixed ASCII string literal, so `from_bytes()` should always succeed.
// If this constant is changed to non-ASCII, initialization will panic early at runtime.
static PARSED_HEADER_KEY: std::sync::LazyLock<MetadataKey<Ascii>> =
    std::sync::LazyLock::new(|| MetadataKey::from_static(SPIFFE_HEADER_KEY));

static PARSED_HEADER_VALUE: std::sync::LazyLock<MetadataValue<Ascii>> =
    std::sync::LazyLock::new(|| MetadataValue::from_static(SPIFFE_HEADER_VALUE));

/// Per-RPC metadata interceptor function type.
///
/// Called on every gRPC request to inject custom metadata (e.g. K8s SA
/// tokens for identity-server authentication).
pub type InterceptorFn =
    Arc<dyn Fn(&mut tonic::Request<()>) -> Result<(), tonic::Status> + Send + Sync>;

/// Tonic interceptor that adds the Workload API metadata header required
/// by SPIRE, plus optional custom per-RPC metadata.
///
/// The `extra` field supports identity-server's transport model where
/// callers must provide authentication tokens on every RPC.
#[derive(Clone)]
pub(super) struct MetadataAdder {
    extra: Option<InterceptorFn>,
}

impl MetadataAdder {
    pub(super) fn new(extra: Option<InterceptorFn>) -> Self {
        Self { extra }
    }
}

impl tonic::service::Interceptor for MetadataAdder {
    fn call(
        &mut self,
        mut request: tonic::Request<()>,
    ) -> Result<tonic::Request<()>, tonic::Status> {
        // Apply custom per-RPC metadata first, so the required SPIFFE header
        // cannot be accidentally removed or overwritten by a custom interceptor.
        if let Some(extra) = &self.extra {
            extra(&mut request)?;
        }

        request
            .metadata_mut()
            .insert(PARSED_HEADER_KEY.clone(), PARSED_HEADER_VALUE.clone());

        Ok(request)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tonic::service::Interceptor as _;

    #[test]
    fn spiffe_header_always_inserted() {
        let mut adder = MetadataAdder::new(None);
        let request = tonic::Request::new(());
        let result = adder.call(request);

        let response = result.expect("interceptor should succeed");
        let value = response
            .metadata()
            .get(SPIFFE_HEADER_KEY)
            .expect("spiffe header should be present");
        assert_eq!(value, SPIFFE_HEADER_VALUE);
    }

    #[test]
    fn custom_interceptor_metadata_added() {
        let interceptor: InterceptorFn = Arc::new(|req| {
            req.metadata_mut().insert(
                MetadataKey::from_static("authorization"),
                MetadataValue::from_static("Bearer test-token"),
            );
            Ok(())
        });
        let mut adder = MetadataAdder::new(Some(interceptor));
        let request = tonic::Request::new(());
        let result = adder.call(request);

        let response = result.expect("interceptor should succeed");
        assert_eq!(
            response.metadata().get(SPIFFE_HEADER_KEY).expect("present"),
            SPIFFE_HEADER_VALUE,
        );
        assert_eq!(
            response.metadata().get("authorization").expect("present"),
            "Bearer test-token",
        );
    }

    #[test]
    fn spiffe_header_preserved_when_custom_interceptor_overwrites_it() {
        let interceptor: InterceptorFn = Arc::new(|req| {
            req.metadata_mut().remove(SPIFFE_HEADER_KEY);
            req.metadata_mut().insert(
                MetadataKey::from_static(SPIFFE_HEADER_KEY),
                MetadataValue::from_static("false"),
            );
            Ok(())
        });

        let mut adder = MetadataAdder::new(Some(interceptor));
        let response = adder
            .call(tonic::Request::new(()))
            .expect("interceptor should succeed");

        assert_eq!(
            response.metadata().get(SPIFFE_HEADER_KEY).expect("present"),
            SPIFFE_HEADER_VALUE,
        );
    }

    #[test]
    fn custom_interceptor_error_propagates() {
        let interceptor: InterceptorFn =
            Arc::new(|_| Err(tonic::Status::internal("token expired")));
        let mut adder = MetadataAdder::new(Some(interceptor));
        let request = tonic::Request::new(());
        let result = adder.call(request);

        let err = result.expect_err("interceptor should fail");
        assert_eq!(err.code(), tonic::Code::Internal);
        assert_eq!(err.message(), "token expired");
    }
}
