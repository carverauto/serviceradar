use crate::rislive::messages::RisLiveClientMessage;
use serde::Serialize;

#[derive(Debug)]
pub struct Ping {}

impl Serialize for Ping {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_none()
    }
}

impl RisLiveClientMessage for Ping {
    fn msg_type(&self) -> &'static str {
        "ping"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    #[test]
    fn test_to_json_string() {
        let ping_msg = Ping {};
        let json_str = ping_msg.to_json_string();
        let value: Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(value, json!({"type": "ping", "data": null}));
    }
}
