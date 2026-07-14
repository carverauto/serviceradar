/*!
Provides parsing of BGP messages.
*/
pub mod attributes;
pub mod messages;
pub use messages::parse_bgp_message;
