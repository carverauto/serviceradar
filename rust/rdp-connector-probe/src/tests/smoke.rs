use super::*;

#[test]
fn links_connector_without_root_workspace_lockfile() {
    assert!(crate::connector_dependency_is_linked());
}

#[test]
fn links_active_stage_without_root_workspace_lockfile() {
    assert!(crate::active_stage_dependency_is_linked());
}

#[test]
fn builds_active_stage_from_service_radar_connector_plan() {
    let probe = crate::build_active_stage_smoke(open_request("EXAMPLE\\alice", "required"))
        .expect("active stage smoke");

    assert_eq!(probe.desktop_width, 1920);
    assert_eq!(probe.desktop_height, 1080);
    assert!(probe.accepts_mouse_position_update);
}

#[test]
fn active_stage_encodes_keyboard_input_response_frame() {
    let probe =
        crate::encode_active_stage_keyboard_input_smoke(open_request("EXAMPLE\\alice", "required"))
            .expect("active stage input");

    assert_eq!(probe.response_frames, 1);
    assert!(probe.response_bytes > 0);
    assert_eq!(probe.graphics_updates, 0);
}
