// Internal logging facade.
// Provides `debug!`, `info!`, `warn!`, `error!` macros backed by
// either `tracing`, `log`, or no-op depending on enabled features.

#[allow(unused_imports, reason = "might not be used at any given time")]
#[expect(clippy::allow_attributes, reason = "might be used at any given time")]
pub(crate) use crate::observability::{
    log_debug as debug, log_error as error, log_info as info, log_warn as warn,
};
