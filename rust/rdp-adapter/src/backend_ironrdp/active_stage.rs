#[cfg(serviceradar_rdp_connector_link_probe)]
fn encode_active_stage_keyboard_input_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<ActiveStageInputProbe, BackendError> {
    let frame = DesktopFrame {
        session_id: "session-1".to_owned(),
        protocol: "rdp".to_owned(),
        frame_type: "desktop.input".to_owned(),
        width: 0,
        height: 0,
        input: Some(crate::protocol::DesktopInputEvent {
            kind: "key".to_owned(),
            key: "Enter".to_owned(),
            down: true,
            button: String::new(),
            x: 0,
            y: 0,
            focused: false,
        }),
        quality: None,
        reason: String::new(),
        timestamp: 0,
        metadata: Default::default(),
    };

    encode_active_stage_desktop_input_for_probe(plan, credential, &frame)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn encode_active_stage_desktop_input_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    frame: &DesktopFrame,
) -> Result<ActiveStageInputProbe, BackendError> {
    let (mut active_stage, desktop_size) = build_active_stage_for_probe(plan, credential);
    let mut image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        desktop_size.width,
        desktop_size.height,
    );
    let events = map_desktop_input_events_for_probe(frame)?;
    let outputs = active_stage
        .process_fastpath_input(&mut image, &events)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    Ok(summarize_active_stage_outputs_for_probe(outputs))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn read_active_stage_server_frame_for_probe<S: Read, W: Write>(
    framed: &mut ironrdp_blocking::Framed<S>,
    session: &mut ActiveStageSessionProbe<W>,
    timestamp_unix_nano: i64,
) -> Result<ActiveStageOutputProbe, BackendError> {
    let (action, frame) = framed
        .read_pdu()
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    session.server_frame(action, &frame, timestamp_unix_nano)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn copy_screen_policy_for_probe(policy: &DesktopScreenPolicy) -> DesktopScreenPolicy {
    DesktopScreenPolicy {
        max_width: policy.max_width,
        max_height: policy.max_height,
        color_depth: policy.color_depth,
        frame_rate: policy.frame_rate,
        bitrate_bps: policy.bitrate_bps,
        idle_seconds: policy.idle_seconds,
        ttl_seconds: policy.ttl_seconds,
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn map_desktop_input_events_for_probe(
    frame: &DesktopFrame,
) -> Result<Vec<ironrdp_pdu::input::fast_path::FastPathInputEvent>, BackendError> {
    let Some(input) = frame.input.as_ref() else {
        return Err(BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT));
    };

    match input.kind.as_str() {
        "key" => {
            let scancode = browser_key_to_set1_scancode_for_probe(&input.key)
                .ok_or(BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT))?;
            let mut flags = ironrdp_pdu::input::fast_path::KeyboardFlags::empty();
            if !input.down {
                flags |= ironrdp_pdu::input::fast_path::KeyboardFlags::RELEASE;
            }

            Ok(vec![
                ironrdp_pdu::input::fast_path::FastPathInputEvent::KeyboardEvent(flags, scancode),
            ])
        }
        "pointer" => {
            let mut flags = ironrdp_pdu::input::mouse::PointerFlags::MOVE;
            match input.button.as_str() {
                "" => {}
                "left" => flags |= ironrdp_pdu::input::mouse::PointerFlags::LEFT_BUTTON,
                "middle" => {
                    flags |= ironrdp_pdu::input::mouse::PointerFlags::MIDDLE_BUTTON_OR_WHEEL;
                }
                "right" => flags |= ironrdp_pdu::input::mouse::PointerFlags::RIGHT_BUTTON,
                _ => return Err(BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT)),
            }
            if input.down && !input.button.is_empty() {
                flags |= ironrdp_pdu::input::mouse::PointerFlags::DOWN;
            }

            let x = u16::try_from(input.x)
                .map_err(|_| BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT))?;
            let y = u16::try_from(input.y)
                .map_err(|_| BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT))?;

            Ok(vec![
                ironrdp_pdu::input::fast_path::FastPathInputEvent::MouseEvent(
                    ironrdp_pdu::input::MousePdu {
                        flags,
                        number_of_wheel_rotation_units: 0,
                        x_position: x,
                        y_position: y,
                    },
                ),
            ])
        }
        "focus" => Ok(Vec::new()),
        _ => Err(BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT)),
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn browser_key_to_set1_scancode_for_probe(key: &str) -> Option<u8> {
    Some(match key {
        "Escape" => 0x01,
        "1" => 0x02,
        "2" => 0x03,
        "3" => 0x04,
        "4" => 0x05,
        "5" => 0x06,
        "6" => 0x07,
        "7" => 0x08,
        "8" => 0x09,
        "9" => 0x0a,
        "0" => 0x0b,
        "-" => 0x0c,
        "=" => 0x0d,
        "Backspace" => 0x0e,
        "Tab" => 0x0f,
        "q" | "Q" => 0x10,
        "w" | "W" => 0x11,
        "e" | "E" => 0x12,
        "r" | "R" => 0x13,
        "t" | "T" => 0x14,
        "y" | "Y" => 0x15,
        "u" | "U" => 0x16,
        "i" | "I" => 0x17,
        "o" | "O" => 0x18,
        "p" | "P" => 0x19,
        "[" => 0x1a,
        "]" => 0x1b,
        "Enter" => 0x1c,
        "a" | "A" => 0x1e,
        "s" | "S" => 0x1f,
        "d" | "D" => 0x20,
        "f" | "F" => 0x21,
        "g" | "G" => 0x22,
        "h" | "H" => 0x23,
        "j" | "J" => 0x24,
        "k" | "K" => 0x25,
        "l" | "L" => 0x26,
        ";" => 0x27,
        "'" => 0x28,
        "`" => 0x29,
        "\\" => 0x2b,
        "z" | "Z" => 0x2c,
        "x" | "X" => 0x2d,
        "c" | "C" => 0x2e,
        "v" | "V" => 0x2f,
        "b" | "B" => 0x30,
        "n" | "N" => 0x31,
        "m" | "M" => 0x32,
        "," => 0x33,
        "." => 0x34,
        "/" => 0x35,
        " " | "Space" => 0x39,
        _ => return None,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_active_stage_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> (ironrdp_session::ActiveStage, ironrdp_connector::DesktopSize) {
    let (connection_result, desktop_size) = build_connection_result_for_probe(plan, credential);

    (
        active_stage_from_connection_result_for_probe(connection_result),
        desktop_size,
    )
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn active_stage_from_connection_result_for_probe(
    connection_result: ironrdp_connector::ConnectionResult,
) -> ironrdp_session::ActiveStage {
    let ironrdp_connector::ConnectionResult {
        io_channel_id,
        user_channel_id,
        message_channel_id,
        share_id,
        static_channels,
        desktop_size: _,
        enable_server_pointer,
        pointer_software_rendering,
        activation_factory: _,
        compression_type,
    } = connection_result;

    ironrdp_session::ActiveStageBuilder {
        static_channels,
        user_channel_id,
        io_channel_id,
        message_channel_id,
        share_id,
        compression_type,
        enable_server_pointer,
        pointer_software_rendering,
    }
    .build()
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connection_result_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> (
    ironrdp_connector::ConnectionResult,
    ironrdp_connector::DesktopSize,
) {
    let config = build_connector_config_for_probe(plan, credential);
    let desktop_size = config.desktop_size;
    let connector = ironrdp_connector::ClientConnector::new(
        config.clone(),
        default_connector_client_addr_for_probe(),
    );
    let activation_factory =
        ironrdp_connector::connection_activation::ConnectionActivationFactory::new(
            config, 1003, 1004,
        );
    let connection_result = ironrdp_connector::ConnectionResult {
        io_channel_id: 1003,
        user_channel_id: 1004,
        message_channel_id: None,
        share_id: 0,
        static_channels: connector.static_channels,
        desktop_size,
        enable_server_pointer: false,
        pointer_software_rendering: false,
        activation_factory,
        compression_type: None,
    };

    (connection_result, desktop_size)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn summarize_active_stage_outputs_for_probe(
    outputs: Vec<ironrdp_session::ActiveStageOutput>,
) -> ActiveStageInputProbe {
    let mut response_frames = 0;
    let mut response_bytes = 0;
    let mut graphics_updates = 0;

    for output in outputs {
        match output {
            ironrdp_session::ActiveStageOutput::ResponseFrame(frame) => {
                response_frames += 1;
                response_bytes += frame.len();
            }
            ironrdp_session::ActiveStageOutput::GraphicsUpdate(_) => {
                graphics_updates += 1;
            }
            ironrdp_session::ActiveStageOutput::PointerDefault
            | ironrdp_session::ActiveStageOutput::PointerHidden
            | ironrdp_session::ActiveStageOutput::PointerPosition { .. }
            | ironrdp_session::ActiveStageOutput::PointerBitmap(_)
            | ironrdp_session::ActiveStageOutput::Terminate(_)
            | ironrdp_session::ActiveStageOutput::DeactivateAll
            | ironrdp_session::ActiveStageOutput::MultitransportRequest(_)
            | ironrdp_session::ActiveStageOutput::AutoDetect(_) => {}
        }
    }

    ActiveStageInputProbe {
        response_frames,
        response_bytes,
        graphics_updates,
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[allow(clippy::too_many_arguments)]
fn handle_active_stage_outputs_for_probe<W: Write>(
    outputs: Vec<ironrdp_session::ActiveStageOutput>,
    upstream: &mut W,
    media_queue: &mut VecDeque<Vec<u8>>,
    image: &ironrdp_session::image::DecodedImage,
    policy: &DesktopScreenPolicy,
    session_binding_id: &str,
    media_session_id: &str,
    next_sequence: &mut u64,
    timestamp_unix_nano: i64,
) -> Result<ActiveStageOutputProbe, BackendError> {
    handle_active_stage_outputs_with_writer_for_probe(
        outputs,
        |frame| {
            upstream
                .write_all(frame)
                .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
        },
        media_queue,
        image,
        policy,
        session_binding_id,
        media_session_id,
        next_sequence,
        timestamp_unix_nano,
    )
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[allow(clippy::too_many_arguments)]
fn handle_active_stage_outputs_with_writer_for_probe<F>(
    outputs: Vec<ironrdp_session::ActiveStageOutput>,
    mut write_response_frame: F,
    media_queue: &mut VecDeque<Vec<u8>>,
    image: &ironrdp_session::image::DecodedImage,
    policy: &DesktopScreenPolicy,
    session_binding_id: &str,
    media_session_id: &str,
    next_sequence: &mut u64,
    timestamp_unix_nano: i64,
) -> Result<ActiveStageOutputProbe, BackendError>
where
    F: FnMut(&[u8]) -> Result<(), BackendError>,
{
    let mut probe = ActiveStageOutputProbe {
        rdp_response_frames: 0,
        rdp_response_bytes: 0,
        queued_media_frames: 0,
        queued_media_bytes: 0,
        terminal_outputs: 0,
    };

    for output in outputs {
        match output {
            ironrdp_session::ActiveStageOutput::ResponseFrame(frame) => {
                write_response_frame(&frame)?;
                probe.rdp_response_frames += 1;
                probe.rdp_response_bytes += frame.len();
            }
            ironrdp_session::ActiveStageOutput::GraphicsUpdate(rect) => {
                let media_frame = encode_graphics_update_for_probe(
                    session_binding_id,
                    media_session_id,
                    *next_sequence,
                    timestamp_unix_nano,
                    image,
                    &rect,
                    policy,
                )?;
                *next_sequence = next_sequence
                    .checked_add(1)
                    .ok_or(BackendError::Unsupported(INVALID_GRAPHICS_UPDATE))?;
                probe.queued_media_frames += 1;
                probe.queued_media_bytes += media_frame.len();
                media_queue.push_back(media_frame);
            }
            ironrdp_session::ActiveStageOutput::Terminate(_)
            | ironrdp_session::ActiveStageOutput::DeactivateAll
            | ironrdp_session::ActiveStageOutput::MultitransportRequest(_)
            | ironrdp_session::ActiveStageOutput::AutoDetect(_) => {
                probe.terminal_outputs += 1;
            }
            ironrdp_session::ActiveStageOutput::PointerDefault
            | ironrdp_session::ActiveStageOutput::PointerHidden
            | ironrdp_session::ActiveStageOutput::PointerPosition { .. }
            | ironrdp_session::ActiveStageOutput::PointerBitmap(_) => {}
        }
    }

    Ok(probe)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn encode_graphics_update_for_probe(
    session_binding_id: &str,
    media_session_id: &str,
    sequence: u64,
    timestamp_unix_nano: i64,
    image: &ironrdp_session::image::DecodedImage,
    rect: &ironrdp_pdu::geometry::InclusiveRectangle,
    policy: &DesktopScreenPolicy,
) -> Result<Vec<u8>, BackendError> {
    if image.pixel_format() != ironrdp_graphics::image_processing::PixelFormat::RgbA32
        || rect.left > rect.right
        || rect.top > rect.bottom
        || rect.right >= image.width()
        || rect.bottom >= image.height()
    {
        return Err(BackendError::Unsupported(INVALID_GRAPHICS_UPDATE));
    }

    let payload = image.data_for_rect(rect);
    let rect_width = u32::from(rect.right - rect.left + 1);
    let rect_height = u32::from(rect.bottom - rect.top + 1);
    let metadata = format!(
        r#"{{"dirtyRects":[{{"x":{},"y":{},"width":{},"height":{},"payloadOffset":0,"payloadLength":{},"bytesPerRow":{}}}],"pixelFormat":"rgba"}}"#,
        rect.left,
        rect.top,
        rect_width,
        rect_height,
        payload.len(),
        image.stride()
    );
    let frame = DesktopMediaFrame {
        session_binding_id,
        media_session_id,
        sequence,
        timestamp_unix_nano,
        width: u32::from(image.width()),
        height: u32::from(image.height()),
        payload_family: DesktopMediaPayloadFamily::DirtyRect,
        encoding: "rgba",
        metadata: metadata.as_bytes(),
        payload,
        flags: 0,
    };

    encode_desktop_media_frame(&frame, policy)
        .map_err(|_| BackendError::Unsupported(INVALID_GRAPHICS_UPDATE))
}
