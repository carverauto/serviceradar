#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ActiveStageInputProbe {
    response_frames: usize,
    response_bytes: usize,
    graphics_updates: usize,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ActiveStageOutputProbe {
    rdp_response_frames: usize,
    rdp_response_bytes: usize,
    queued_media_frames: usize,
    queued_media_bytes: usize,
    terminal_outputs: usize,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ActiveStageSessionProbe<W: Write> {
    active_stage: ironrdp_session::ActiveStage,
    image: ironrdp_session::image::DecodedImage,
    upstream: W,
    media_queue: VecDeque<Vec<u8>>,
    policy: DesktopScreenPolicy,
    session_binding_id: String,
    media_session_id: String,
    next_sequence: u64,
    terminal: bool,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<W: Write> ActiveStageSessionProbe<W> {
    fn new(
        plan: &NonSecretConnectionPlan,
        credential: &MemoryUserCredential,
        upstream: W,
        policy: &DesktopScreenPolicy,
        session_binding_id: String,
        media_session_id: String,
    ) -> Self {
        let (connection_result, desktop_size) = build_connection_result_for_probe(plan, credential);

        Self::from_connection_result(
            connection_result,
            desktop_size,
            upstream,
            policy,
            session_binding_id,
            media_session_id,
        )
    }

    fn from_connection_result(
        connection_result: ironrdp_connector::ConnectionResult,
        desktop_size: ironrdp_connector::DesktopSize,
        upstream: W,
        policy: &DesktopScreenPolicy,
        session_binding_id: String,
        media_session_id: String,
    ) -> Self {
        let active_stage = active_stage_from_connection_result_for_probe(connection_result);
        let image = ironrdp_session::image::DecodedImage::new(
            ironrdp_graphics::image_processing::PixelFormat::RgbA32,
            desktop_size.width,
            desktop_size.height,
        );

        Self {
            active_stage,
            image,
            upstream,
            media_queue: VecDeque::new(),
            policy: copy_screen_policy_for_probe(policy),
            session_binding_id,
            media_session_id,
            next_sequence: 0,
            terminal: false,
        }
    }

    fn input(&mut self, frame: &DesktopFrame) -> Result<ActiveStageOutputProbe, BackendError> {
        self.require_active()?;
        let events = map_desktop_input_events_for_probe(frame)?;
        let outputs = self
            .active_stage
            .process_fastpath_input(&mut self.image, &events)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        let probe = handle_active_stage_outputs_for_probe(
            outputs,
            &mut self.upstream,
            &mut self.media_queue,
            &self.image,
            &self.policy,
            &self.session_binding_id,
            &self.media_session_id,
            &mut self.next_sequence,
            frame.timestamp,
        )?;

        self.observe_outputs(probe)
    }

    fn graceful_shutdown(&mut self) -> Result<ActiveStageOutputProbe, BackendError> {
        let outputs = self
            .active_stage
            .graceful_shutdown()
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        handle_active_stage_outputs_for_probe(
            outputs,
            &mut self.upstream,
            &mut self.media_queue,
            &self.image,
            &self.policy,
            &self.session_binding_id,
            &self.media_session_id,
            &mut self.next_sequence,
            0,
        )
    }

    fn server_frame(
        &mut self,
        action: ironrdp_pdu::Action,
        frame: &[u8],
        timestamp_unix_nano: i64,
    ) -> Result<ActiveStageOutputProbe, BackendError> {
        self.require_active()?;
        let outputs = self
            .active_stage
            .process(&mut self.image, action, frame)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        let probe = handle_active_stage_outputs_for_probe(
            outputs,
            &mut self.upstream,
            &mut self.media_queue,
            &self.image,
            &self.policy,
            &self.session_binding_id,
            &self.media_session_id,
            &mut self.next_sequence,
            timestamp_unix_nano,
        )?;

        self.observe_outputs(probe)
    }

    fn drain_media_frames(&mut self) -> Vec<Vec<u8>> {
        self.media_queue.drain(..).collect()
    }

    fn upstream_ref(&self) -> &W {
        &self.upstream
    }

    fn require_active(&self) -> Result<(), BackendError> {
        if self.terminal {
            Err(BackendError::Unsupported(ACTIVE_SESSION_TERMINATED))
        } else {
            Ok(())
        }
    }

    fn observe_outputs(
        &mut self,
        probe: ActiveStageOutputProbe,
    ) -> Result<ActiveStageOutputProbe, BackendError> {
        if probe.terminal_outputs == 0 {
            Ok(probe)
        } else {
            // IronRDP 0.11 exposes server deactivation and optional control
            // transports separately from its active stage. Until this helper
            // owns reactivation, multitransport, and auto-detect sequences,
            // make the unsupported server transition sticky and fail closed.
            self.terminal = true;
            Err(BackendError::Unsupported(ACTIVE_SESSION_TERMINATED))
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<W: Write> RdpBackendSession for ActiveStageSessionProbe<W> {
    fn input(&mut self, frame: &DesktopFrame) -> Result<(), BackendError> {
        ActiveStageSessionProbe::input(self, frame).map(|_| ())
    }

    fn ack(&mut self, _ack: &crate::protocol::DesktopMediaAck) -> Result<(), BackendError> {
        self.require_active()
    }

    fn close(&mut self, _payload: &DesktopClosePayload) -> Result<(), BackendError> {
        ActiveStageSessionProbe::graceful_shutdown(self).map(|_| ())
    }

    fn drain_media_frames(&mut self) -> Result<Vec<Vec<u8>>, BackendError> {
        Ok(ActiveStageSessionProbe::drain_media_frames(self))
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ActiveStageNetworkPumpSessionProbe<S: Read, W: Write> {
    framed: ironrdp_blocking::Framed<S>,
    inner: ActiveStageSessionProbe<W>,
    timestamp_unix_nano: i64,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read, W: Write> ActiveStageNetworkPumpSessionProbe<S, W> {
    fn new(
        framed: ironrdp_blocking::Framed<S>,
        inner: ActiveStageSessionProbe<W>,
        timestamp_unix_nano: i64,
    ) -> Self {
        Self {
            framed,
            inner,
            timestamp_unix_nano,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn from_connection_result(
        framed: ironrdp_blocking::Framed<S>,
        connection_result: ironrdp_connector::ConnectionResult,
        desktop_size: ironrdp_connector::DesktopSize,
        upstream: W,
        policy: &DesktopScreenPolicy,
        session_binding_id: String,
        media_session_id: String,
        timestamp_unix_nano: i64,
    ) -> Self {
        let inner = ActiveStageSessionProbe::from_connection_result(
            connection_result,
            desktop_size,
            upstream,
            policy,
            session_binding_id,
            media_session_id,
        );

        Self::new(framed, inner, timestamp_unix_nano)
    }

    fn drain_media_frames(&mut self) -> Vec<Vec<u8>> {
        self.inner.drain_media_frames()
    }

    fn upstream_ref(&self) -> &W {
        self.inner.upstream_ref()
    }

    fn network_writes_len(&self) -> usize
    where
        S: NetworkWriteProbe,
    {
        self.framed.get_inner().0.writes_len()
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write, W: Write> RdpBackendSession for ActiveStageNetworkPumpSessionProbe<S, W> {
    fn input(&mut self, frame: &DesktopFrame) -> Result<(), BackendError> {
        self.inner.require_active()?;
        let events = map_desktop_input_events_for_probe(frame)?;
        let outputs = self
            .inner
            .active_stage
            .process_fastpath_input(&mut self.inner.image, &events)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        let probe = self.handle_outputs_to_network(outputs, frame.timestamp)?;
        self.inner.observe_outputs(probe).map(|_| ())
    }

    fn ack(&mut self, _ack: &crate::protocol::DesktopMediaAck) -> Result<(), BackendError> {
        self.inner.require_active()
    }

    fn close(&mut self, payload: &DesktopClosePayload) -> Result<(), BackendError> {
        let _reason = &payload.reason;
        let outputs = self
            .inner
            .active_stage
            .graceful_shutdown()
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        self.handle_outputs_to_network(outputs, 0).map(|_| ())
    }

    fn pump(&mut self) -> Result<(), BackendError> {
        self.inner.require_active()?;
        let (action, frame) = self
            .framed
            .read_pdu()
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
        let outputs = self
            .inner
            .active_stage
            .process(&mut self.inner.image, action, &frame)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        let probe = self.handle_outputs_to_network(outputs, self.timestamp_unix_nano)?;
        self.inner.observe_outputs(probe).map(|_| ())
    }

    fn drain_media_frames(&mut self) -> Result<Vec<Vec<u8>>, BackendError> {
        Ok(ActiveStageNetworkPumpSessionProbe::drain_media_frames(self))
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write, W: Write> ActiveStageNetworkPumpSessionProbe<S, W> {
    fn handle_outputs_to_network(
        &mut self,
        outputs: Vec<ironrdp_session::ActiveStageOutput>,
        timestamp_unix_nano: i64,
    ) -> Result<ActiveStageOutputProbe, BackendError> {
        handle_active_stage_outputs_with_writer_for_probe(
            outputs,
            |frame| {
                self.framed
                    .write_all(frame)
                    .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
            },
            &mut self.inner.media_queue,
            &self.inner.image,
            &self.inner.policy,
            &self.inner.session_binding_id,
            &self.inner.media_session_id,
            &mut self.inner.next_sequence,
            timestamp_unix_nano,
        )
    }
}
