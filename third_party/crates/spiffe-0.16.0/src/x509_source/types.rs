use crate::workload_api::error::WorkloadApiError;
use crate::workload_api::WorkloadApiClient;
use crate::X509Svid;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

/// Strategy for selecting an X.509 SVID when multiple SVIDs are available.
///
/// Implement this trait to customize SVID selection logic. The picker is called whenever
/// a new X.509 context is received from the Workload API.
/// Implementations must not panic.
/// Implementations must be deterministic for a given slice of SVIDs, because the selected
/// SVID expiry is cached per snapshot for health checks.
///
/// # Example
///
/// ```no_run
/// use spiffe::X509Svid;
/// use std::sync::Arc;
/// use spiffe::x509_source::SvidPicker;
///
/// #[derive(Debug)]
/// struct HintPicker {
///     hint: String,
/// }
///
/// impl SvidPicker for HintPicker {
///     fn pick_svid(&self, svids: &[Arc<X509Svid>]) -> Option<usize> {
///         svids.iter()
///             .position(|svid| svid.hint() == Some(&self.hint))
///     }
/// }
/// ```
pub trait SvidPicker: Send + Sync + 'static {
    /// Selects an SVID from the provided slice by returning its index.
    ///
    /// Returning `None` indicates that no suitable SVID could be selected.
    /// Returning `Some(index)` selects the SVID at the given index in the slice.
    fn pick_svid(&self, svids: &[Arc<X509Svid>]) -> Option<usize>;
}

pub(super) type ClientFuture =
    Pin<Box<dyn Future<Output = Result<WorkloadApiClient, WorkloadApiError>> + Send + 'static>>;
pub(super) type ClientFactory = Arc<dyn Fn() -> ClientFuture + Send + Sync + 'static>;
