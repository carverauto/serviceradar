use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Serialize, Deserialize)]
pub struct RisSubscribeOk {
    pub subscription: Value,
    pub socketOptions: Value,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_ris_subscribe_ok_serialization() {
        let ris_subscribe_ok = RisSubscribeOk {
            subscription: json!({"messageType": "Subscription"}),
            socketOptions: json!({"timeOut": 5000}),
        };
        let serialized = serde_json::to_string(&ris_subscribe_ok).unwrap();
        assert_eq!(serialized, "{\"subscription\":{\"messageType\":\"Subscription\"},\"socketOptions\":{\"timeOut\":5000}}");
    }

    #[test]
    fn test_ris_subscribe_ok_deserialization() {
        let data = r#"{
            "subscription": {"messageType": "Subscription"},
            "socketOptions": {"timeOut": 5000}
        }"#;
        let ris_subscribe_ok: RisSubscribeOk = serde_json::from_str(data).unwrap();
        assert_eq!(
            ris_subscribe_ok.subscription,
            json!({"messageType": "Subscription"})
        );
        assert_eq!(ris_subscribe_ok.socketOptions, json!({"timeOut": 5000}));
    }
}
