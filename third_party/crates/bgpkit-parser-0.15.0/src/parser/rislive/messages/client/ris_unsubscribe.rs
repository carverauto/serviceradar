use crate::rislive::messages::{RisLiveClientMessage, RisSubscribe};
use serde::Serialize;

#[derive(Default, Debug, Serialize)]
pub struct RisUnsubscribe {
    #[serde(flatten)]
    data: RisSubscribe,
}

impl RisUnsubscribe {
    pub fn new(subscribe: RisSubscribe) -> Self {
        Self { data: subscribe }
    }
}

impl RisLiveClientMessage for RisUnsubscribe {
    fn msg_type(&self) -> &'static str {
        "ris_unsubscribe"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rislive::messages::client::ris_subscribe::RisSubscribeType;

    #[test]
    fn test_subscribe() {
        let subscribe = RisSubscribe::new()
            .host("rrc00")
            .data_type(RisSubscribeType::UPDATE)
            .acknowledge(true);
        let unsubscribe = RisUnsubscribe::new(subscribe);

        assert_eq!(unsubscribe.msg_type(), "ris_unsubscribe");

        println!("{}", unsubscribe.to_json_string());
    }
}
