//! This module contains the RIS-live client message definitions.
//!
//! Official manual available at <https://ris-live.ripe.net/manual/#client-messages>

pub mod ping;
pub mod request_rrc_list;
pub mod ris_subscribe;
pub mod ris_unsubscribe;

pub trait RisLiveClientMessage: Serialize {
    fn msg_type(&self) -> &'static str;

    fn to_json_string(&self) -> String {
        serde_json::to_string(&json!({
            "type": self.msg_type(),
            "data": self
        }))
        .unwrap()
    }
}

use serde::Serialize;
use serde_json::json;

pub use ping::Ping;
pub use request_rrc_list::RequestRrcList;
pub use ris_subscribe::RisSubscribe;
pub use ris_unsubscribe::RisUnsubscribe;
