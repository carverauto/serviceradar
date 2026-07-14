use crate::workload_api::error::WorkloadApiError;
use crate::workload_api::WorkloadApiClient;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

pub(super) type ClientFuture =
    Pin<Box<dyn Future<Output = Result<WorkloadApiClient, WorkloadApiError>> + Send + 'static>>;
pub(super) type ClientFactory = Arc<dyn Fn() -> ClientFuture + Send + Sync + 'static>;
