/*!
Parse MRT header and content, provides [BgpElem][BgpElem] struct for per-prefix information.

[BgpElem]: crate::BgpElem
*/
pub mod messages;
pub mod mrt_elem;
pub mod mrt_header;
pub mod mrt_record;

pub use messages::bgp4mp::parse_bgp4mp;
pub use messages::table_dump::parse_table_dump_message;
pub use messages::table_dump_v2::parse_table_dump_v2_message;
pub use mrt_record::{chunk_mrt_record, parse_mrt_record, RawMrtRecord};
