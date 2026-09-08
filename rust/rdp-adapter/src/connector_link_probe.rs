pub fn connector_link_probe_capabilities() -> bool {
    let desktop_size = ironrdp_connector::DesktopSize {
        width: 1024,
        height: 768,
    };
    let _connector = ironrdp_connector::ClientConnector::new(
        connector_config(desktop_size),
        "127.0.0.1:0".parse().expect("loopback socket"),
    );
    let _framed = ironrdp_blocking::Framed::new(std::io::Cursor::new(Vec::<u8>::new()));

    desktop_size.width == 1024 && desktop_size.height == 768
}

fn connector_config(desktop_size: ironrdp_connector::DesktopSize) -> ironrdp_connector::Config {
    ironrdp_connector::Config {
        desktop_size,
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: true,
        credentials: ironrdp_connector::Credentials::UsernamePassword {
            username: "alice".to_owned(),
            password: "probe-password".to_owned(),
        },
        domain: None,
        client_build: 1,
        client_name: "serviceradar".to_owned(),
        keyboard_type: ironrdp_pdu::gcc::KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0,
        ime_file_name: String::new(),
        bitmap: None,
        dig_product_id: String::new(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        platform: ironrdp_pdu::rdp::capability_sets::MajorPlatformType::UNIX,
        hardware_id: None,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        performance_flags: ironrdp_pdu::rdp::client_info::PerformanceFlags::default(),
        license_cache: None,
        timezone_info: ironrdp_pdu::rdp::client_info::TimezoneInfo::default(),
        compression_type: None,
        enable_server_pointer: false,
        pointer_software_rendering: false,
        multitransport_flags: None,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn links_connector_dependencies_from_isolated_crate_universe() {
        assert!(crate::connector_link_probe_capabilities());
    }
}
