use super::*;
use crate::protocol::constants::{
    FRAME_TYPE_INPUT, INPUT_KIND_POINTER, MAX_CLOSE_REASON_BYTES, MAX_TLS_CA_BUNDLE_PEM_BYTES,
};

pub(crate) fn valid_open_payload() -> String {
    r#"{
            "schema":"serviceradar.rdp.helper.open.v1",
            "session_id":"session-1",
            "actor_id":"user-1",
            "local_agent_id":"agent-1",
            "gateway_id":"gateway-1",
            "start_unix":1778636531,
            "target":{
                "target_id":"target-1",
                "display_name":"Windows VM",
                "device_uid":"device-1",
                "protocol":"rdp",
                "route":{"selected_agent_id":"agent-1","selected_gateway_id":"gateway-1"},
                "upstream":{"host":"win.example","port":3389},
                "tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"},
                "credential":{"mode":"memory_user","allowed_principals":["alice"]},
                "screen":{"max_width":1920,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600},
                "redirection":{"clipboard_mode":"disabled"},
                "recording":{"metadata_enabled":true}
            },
            "credential_grant":{"mode":"memory_user","username":"alice","password":"secret","actor_id":"user-1","session_id":"session-1","target_id":"target-1"}
        }"#
        .to_string()
}

mod ack;
mod close;
mod frame;
mod open_accept;
mod open_reject;
mod sensitive;

fn test_screen_policy() -> DesktopScreenPolicy {
    DesktopScreenPolicy {
        max_width: 1920,
        max_height: 1080,
        color_depth: 0,
        frame_rate: 30,
        bitrate_bps: 8_000_000,
        idle_seconds: 900,
        ttl_seconds: 3600,
    }
}
