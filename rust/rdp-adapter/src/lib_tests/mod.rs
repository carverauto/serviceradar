use super::*;
use std::cell::RefCell;
use std::rc::Rc;

struct RecordingBackend {
    state: Rc<RefCell<RecordingState>>,
}

#[derive(Default)]
struct RecordingState {
    opened_session: Option<String>,
    input_frames: Vec<DesktopFrame>,
    acks: Vec<DesktopMediaAck>,
    close_payloads: Vec<DesktopClosePayload>,
    pending_media_frames: Vec<Vec<u8>>,
    pump_count: usize,
    pump_media_frames: Vec<Vec<u8>>,
    media_drain_error: Option<&'static str>,
}

impl RdpBackend for RecordingBackend {
    fn open(&mut self, request: OpenPayload) -> Result<Box<dyn RdpBackendSession>, BackendError> {
        self.state.borrow_mut().opened_session = Some(request.session_id);

        Ok(Box::new(RecordingSession {
            state: Rc::clone(&self.state),
        }))
    }
}

struct RecordingSession {
    state: Rc<RefCell<RecordingState>>,
}

impl RdpBackendSession for RecordingSession {
    fn input(&mut self, frame: &DesktopFrame) -> Result<(), BackendError> {
        self.state.borrow_mut().input_frames.push(frame.clone());

        Ok(())
    }

    fn ack(&mut self, ack: &DesktopMediaAck) -> Result<(), BackendError> {
        self.state.borrow_mut().acks.push(DesktopMediaAck {
            session_binding_id: ack.session_binding_id.clone(),
            media_session_id: ack.media_session_id.clone(),
            last_accepted_seq: ack.last_accepted_seq,
            credit_bytes: ack.credit_bytes,
            quality_level: ack.quality_level.clone(),
            pause: ack.pause,
            resume: ack.resume,
            close_reason: ack.close_reason.clone(),
        });

        Ok(())
    }

    fn close(&mut self, payload: &DesktopClosePayload) -> Result<(), BackendError> {
        self.state.borrow_mut().close_payloads.push(payload.clone());

        Ok(())
    }

    fn pump(&mut self) -> Result<(), BackendError> {
        let mut state = self.state.borrow_mut();
        state.pump_count += 1;
        let pump_media_frames = std::mem::take(&mut state.pump_media_frames);
        state.pending_media_frames.extend(pump_media_frames);

        Ok(())
    }

    fn drain_media_frames(&mut self) -> Result<Vec<Vec<u8>>, BackendError> {
        let mut state = self.state.borrow_mut();

        if let Some(message) = state.media_drain_error.take() {
            return Err(BackendError::Unsupported(message));
        }

        Ok(std::mem::take(&mut state.pending_media_frames))
    }
}

mod capabilities;
mod framing;
mod payload_zeroize;
mod session_lifecycle;
mod session_rejections;

fn valid_ack_payload() -> String {
    r#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"quality_level":"low","pause":true,"close_reason":"browser close"}"#.to_owned()
}

fn valid_input_payload() -> String {
    r#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"key","key":"Enter","down":true}}"#.to_owned()
}

fn input_test_policy() -> protocol::DesktopScreenPolicy {
    protocol::DesktopScreenPolicy {
        max_width: 1920,
        max_height: 1080,
        color_depth: 0,
        frame_rate: 30,
        bitrate_bps: 8_000_000,
        idle_seconds: 900,
        ttl_seconds: 3600,
    }
}
