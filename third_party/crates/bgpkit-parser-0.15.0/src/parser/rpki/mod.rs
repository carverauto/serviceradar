//! RPKI (Resource Public Key Infrastructure) protocol parsers.
//!
//! This module provides parsing and encoding functions for RPKI-related protocols:
//!
//! - [`rtr`]: RPKI-to-Router (RTR) Protocol parsing and encoding (RFC 6810, RFC 8210)
//!
//! # Example
//!
//! ```rust
//! use bgpkit_parser::parser::rpki::rtr::{parse_rtr_pdu, RtrEncode};
//! use bgpkit_parser::models::rpki::rtr::*;
//!
//! // Create and encode a Reset Query
//! let query = RtrResetQuery::new_v1();
//! let bytes = query.encode();
//!
//! // Parse the bytes back
//! let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
//! assert!(matches!(pdu, RtrPdu::ResetQuery(_)));
//! ```

pub mod rtr;

pub use rtr::*;
