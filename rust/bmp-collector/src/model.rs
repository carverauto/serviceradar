use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BmpRoutingEvent {
    pub event_id: String,
    pub event_type: String,
    pub timestamp: String,
    #[serde(default)]
    pub router_id: Option<String>,
    #[serde(default)]
    pub router_ip: Option<String>,
    #[serde(default)]
    pub peer_ip: Option<String>,
    #[serde(default)]
    pub peer_asn: Option<u32>,
    #[serde(default)]
    pub local_asn: Option<u32>,
    #[serde(default)]
    pub prefix: Option<String>,
    #[serde(default)]
    pub payload: Value,
}

impl BmpRoutingEvent {
    pub fn subject_suffix(&self) -> &'static str {
        match self.event_type.as_str() {
            "peer_up" => "peer_up",
            "peer_down" => "peer_down",
            "route_update" => "route_update",
            "route_withdraw" => "route_withdraw",
            "stats" => "stats",
            _ => "unknown",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::BmpRoutingEvent;
    use serde_json::json;

    #[test]
    fn route_update_maps_subject_suffix() {
        let evt = BmpRoutingEvent {
            event_id: "evt-1".to_string(),
            event_type: "route_update".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            router_id: None,
            router_ip: None,
            peer_ip: None,
            peer_asn: None,
            local_asn: None,
            prefix: None,
            payload: json!({"raw": "value"}),
        };

        assert_eq!(evt.subject_suffix(), "route_update");
    }
}
