#[cfg(all(feature = "ironrdp-backend", serviceradar_rdp_connector_link_probe))]
#[test]
fn live_connector_probe_helper_open_returns_network_pump_session_when_configured() {
    serviceradar_rdp_adapter::run_live_helper_open_probe_from_env()
        .expect("live RDP adapter open probe");
}

#[cfg(not(all(feature = "ironrdp-backend", serviceradar_rdp_connector_link_probe)))]
#[test]
fn live_connector_probe_helper_open_skips_without_connector_build() {}
