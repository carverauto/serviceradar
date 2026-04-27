use super::models::ObservationStreamRequest;
use crate::capture_control::{CaptureControl, CaptureStreamType};
use crate::live_capture::spawn_capture;
use crate::observation::SidekickObservation;
use crate::radio::spawn_channel_hopper;
use crate::spectrum::{
    SpectrumSummary, SpectrumSweep, SpectrumSweepRequest, spawn_hackrf_sweep, summarize_sweep,
};
use axum::extract::ws::{Message, WebSocket};
use std::sync::Arc;
use std::time::Duration;

pub(super) async fn stream_observations(
    mut socket: WebSocket,
    request: ObservationStreamRequest,
    capture_control: Arc<CaptureControl>,
) {
    let target = request.capture.interface_name.clone();
    let _registration = capture_control.register(CaptureStreamType::RfObservation, target);
    let mut stop_rx = capture_control.subscribe_stop();
    let channel_hopper = request.channel_hop.map(spawn_channel_hopper);
    let mut observations = spawn_capture(request.capture);
    let mut pending = Vec::with_capacity(128);
    let mut flush_interval = tokio::time::interval(Duration::from_millis(200));
    flush_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            result = observations.recv() => {
                let Some(result) = result else {
                    let _ = send_observation_batch(&mut socket, &mut pending).await;
                    break;
                };

                match result {
                    Ok(observation) => {
                        pending.push(observation);
                        if pending.len() >= 128
                            && !send_observation_batch(&mut socket, &mut pending).await {
                                break;
                            }
                    }
                    Err(error) => {
                        let _ = send_observation_batch(&mut socket, &mut pending).await;
                        let _ = socket
                            .send(Message::Text(
                                serde_json::json!({ "error": error }).to_string(),
                            ))
                            .await;
                        break;
                    }
                };
            }
            _ = flush_interval.tick() => {
                if !send_observation_batch(&mut socket, &mut pending).await {
                    break;
                }
            }
            stop_result = stop_rx.changed() => {
                let _ = stop_result;
                let _ = send_observation_batch(&mut socket, &mut pending).await;
                let _ = socket
                    .send(Message::Text(r#"{"event":"capture_stopped"}"#.to_string()))
                    .await;
                break;
            }
            client_message = socket.recv() => {
                if client_message.is_none() {
                    break;
                }
            }
        }
    }

    if let Some(channel_hopper) = channel_hopper {
        channel_hopper.abort();
    }
}

async fn send_observation_batch(
    socket: &mut WebSocket,
    pending: &mut Vec<SidekickObservation>,
) -> bool {
    if pending.is_empty() {
        return true;
    }

    let payload = match crate::arrow_stream::encode_observations_ipc(pending) {
        Ok(payload) => payload,
        Err(error) => {
            pending.clear();
            return socket
                .send(Message::Text(
                    serde_json::json!({ "error": error }).to_string(),
                ))
                .await
                .is_ok();
        }
    };

    pending.clear();
    socket.send(Message::Binary(payload)).await.is_ok()
}

pub(super) async fn stream_spectrum(
    mut socket: WebSocket,
    request: SpectrumSweepRequest,
    capture_control: Arc<CaptureControl>,
) {
    let target = request.sdr_id.clone();
    let _registration = capture_control.register(CaptureStreamType::Spectrum, target);
    let mut stop_rx = capture_control.subscribe_stop();
    let mut sweeps = spawn_hackrf_sweep(request);
    let mut pending = Vec::with_capacity(32);
    let mut flush_interval = tokio::time::interval(Duration::from_millis(200));
    flush_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            result = sweeps.recv() => {
                let Some(result) = result else {
                    let _ = send_spectrum_batch(&mut socket, &mut pending).await;
                    break;
                };

                match result {
                    Ok(sweep) => {
                        pending.push(sweep);
                        if pending.len() >= 32 && !send_spectrum_batch(&mut socket, &mut pending).await {
                            break;
                        }
                    }
                    Err(error) => {
                        let _ = send_spectrum_batch(&mut socket, &mut pending).await;
                        let _ = socket
                            .send(Message::Text(
                                serde_json::json!({ "error": error }).to_string(),
                            ))
                            .await;
                        break;
                    }
                }
            }
            _ = flush_interval.tick() => {
                if !send_spectrum_batch(&mut socket, &mut pending).await {
                    break;
                }
            }
            stop_result = stop_rx.changed() => {
                let _ = stop_result;
                let _ = send_spectrum_batch(&mut socket, &mut pending).await;
                let _ = socket
                    .send(Message::Text(r#"{"event":"capture_stopped"}"#.to_string()))
                    .await;
                break;
            }
            client_message = socket.recv() => {
                if client_message.is_none() {
                    break;
                }
            }
        }
    }
}

async fn send_spectrum_batch(socket: &mut WebSocket, pending: &mut Vec<SpectrumSweep>) -> bool {
    if pending.is_empty() {
        return true;
    }

    let payload = match crate::arrow_stream::encode_spectrum_sweeps_ipc(pending) {
        Ok(payload) => payload,
        Err(error) => {
            pending.clear();
            return socket
                .send(Message::Text(
                    serde_json::json!({ "error": error }).to_string(),
                ))
                .await
                .is_ok();
        }
    };

    pending.clear();
    socket.send(Message::Binary(payload)).await.is_ok()
}

pub(super) async fn stream_spectrum_summaries(
    mut socket: WebSocket,
    request: SpectrumSweepRequest,
    capture_control: Arc<CaptureControl>,
) {
    let target = format!("{}:summary", request.sdr_id);
    let _registration = capture_control.register(CaptureStreamType::Spectrum, target);
    let mut stop_rx = capture_control.subscribe_stop();
    let mut sweeps = spawn_hackrf_sweep(request);
    let mut last_capture_unix_nanos: Option<i64> = None;

    loop {
        tokio::select! {
            result = sweeps.recv() => {
                let Some(result) = result else {
                    break;
                };

                match result {
                    Ok(sweep) => {
                        let sweep_rate_hz = last_capture_unix_nanos
                            .and_then(|last| {
                                let delta = sweep.captured_at_unix_nanos.saturating_sub(last);
                                (delta > 0).then(|| 1_000_000_000.0_f32 / delta as f32)
                            })
                            .filter(|rate| rate.is_finite() && *rate > 0.0);
                        last_capture_unix_nanos = Some(sweep.captured_at_unix_nanos);
                        let summary = summarize_sweep(&sweep, sweep_rate_hz);
                        if !send_spectrum_summary(&mut socket, &summary).await {
                            break;
                        }
                    }
                    Err(error) => {
                        let _ = socket
                            .send(Message::Text(
                                serde_json::json!({ "error": error }).to_string(),
                            ))
                            .await;
                        break;
                    }
                }
            }
            stop_result = stop_rx.changed() => {
                let _ = stop_result;
                let _ = socket
                    .send(Message::Text(r#"{"event":"capture_stopped"}"#.to_string()))
                    .await;
                break;
            }
            client_message = socket.recv() => {
                if client_message.is_none() {
                    break;
                }
            }
        }
    }
}

async fn send_spectrum_summary(socket: &mut WebSocket, summary: &SpectrumSummary) -> bool {
    match serde_json::to_string(summary) {
        Ok(payload) => socket.send(Message::Text(payload)).await.is_ok(),
        Err(error) => {
            let payload = serde_json::json!({
                "error": error.to_string(),
            });
            socket
                .send(Message::Text(payload.to_string()))
                .await
                .is_ok()
        }
    }
}
