//! RPKI (Resource Public Key Infrastructure) related data structures.
//!
//! This module provides data structures for RPKI-related protocols:
//!
//! - [`rtr`]: RPKI-to-Router (RTR) Protocol PDU definitions (RFC 6810, RFC 8210)

pub mod rtr;

pub use rtr::*;
