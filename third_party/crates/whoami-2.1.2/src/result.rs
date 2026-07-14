use crate::Error;

/// This crate's convenience type alias for [`Result`](std::result::Result)s
pub type Result<T = (), E = Error> = core::result::Result<T, E>;
