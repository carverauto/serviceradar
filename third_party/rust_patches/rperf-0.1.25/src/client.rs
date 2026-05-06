/*
 * Copyright (C) 2021 Evtech Solutions, Ltd., dba 3D-P
 * Copyright (C) 2021 Neil Tallim <neiltallim@3d-p.com>
 *
 * This file is part of rperf.
 *
 * rperf is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * rperf is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with rperf.  If not, see <https://www.gnu.org/licenses/>.
 */
pub mod state;

use std::error::Error;
use std::net::{IpAddr, Shutdown, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use clap::ArgMatches;
use mio::net::TcpStream;

use crate::protocol::communication::{send, KEEPALIVE_DURATION};
use crate::protocol::messaging::{
    prepare_begin, prepare_download_configuration, prepare_end, prepare_upload_configuration,
};
use crate::protocol::results::{
    IntervalResult, IntervalResultKind, TcpTestResults, TestResults, UdpTestResults,
};
use crate::protocol::state::RunState;
use crate::stream::tcp;
use crate::stream::udp;
use crate::stream::TestStream;

use anyhow::Result;

use crate::protocol::communication;
use state::ClientRunState;

type BoxResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);

fn connect_to_server(address: &str, port: &u16) -> BoxResult<TcpStream> {
    let destination = format!("{}:{}", address, port);
    log::info!("connecting to server at {}...", destination);

    let server_addr = destination
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| anyhow::anyhow!("unable to resolve {}", address))?;

    let raw_stream = std::net::TcpStream::connect_timeout(&server_addr, CONNECT_TIMEOUT)
        .map_err(|e| anyhow::anyhow!("unable to connect: {}", e))?;

    let stream = TcpStream::from_stream(raw_stream)
        .map_err(|e| anyhow::anyhow!("unable to prepare TCP control-channel: {}", e))?;

    log::info!("connected to server");

    stream
        .set_nodelay(true)
        .expect("cannot disable Nagle's algorithm");
    stream
        .set_keepalive(Some(KEEPALIVE_DURATION))
        .expect("unable to set TCP keepalive");

    Ok(stream)
}

fn prepare_test_results(is_udp: bool, stream_count: u8) -> Mutex<Box<dyn TestResults>> {
    if is_udp {
        let mut udp_test_results = UdpTestResults::new();
        for i in 0..stream_count {
            udp_test_results.prepare_index(&i);
        }
        Mutex::new(Box::new(udp_test_results))
    } else {
        let mut tcp_test_results = TcpTestResults::new();
        for i in 0..stream_count {
            tcp_test_results.prepare_index(&i);
        }
        Mutex::new(Box::new(tcp_test_results))
    }
}

pub fn execute(
    args: ArgMatches,
    output: Arc<Mutex<Vec<u8>>>,
    run_state: ClientRunState,
) -> BoxResult<()> {
    let complete = Arc::new(AtomicBool::new(false));

    let mut tcp_port_pool = tcp::receiver::TcpPortPool::new(
        args.value_of("tcp_port_pool").unwrap().to_string(),
        args.value_of("tcp6_port_pool").unwrap().to_string(),
    );
    let mut udp_port_pool = udp::receiver::UdpPortPool::new(
        args.value_of("udp_port_pool").unwrap().to_string(),
        args.value_of("udp6_port_pool").unwrap().to_string(),
    );

    let cpu_affinity_manager = Arc::new(Mutex::new(
        crate::utils::cpu_affinity::CpuAffinityManager::new(args.value_of("affinity").unwrap())?,
    ));

    let display_json: bool;
    let display_bit: bool;
    match args.value_of("format").unwrap() {
        "json" => {
            display_json = true;
            display_bit = false;
        }
        "megabit" => {
            display_json = false;
            display_bit = true;
        }
        "megabyte" => {
            display_json = false;
            display_bit = false;
        }
        _ => {
            log::error!("unsupported display-mode; defaulting to JSON");
            display_json = true;
            display_bit = false;
        }
    }

    let is_udp = args.is_present("udp");

    let test_id = uuid::Uuid::new_v4();
    let mut upload_config = prepare_upload_configuration(&args, test_id.as_bytes())?;
    let mut download_config = prepare_download_configuration(&args, test_id.as_bytes())?;

    let mut stream = connect_to_server(
        &args.value_of("client").unwrap(),
        &(args.value_of("port").unwrap().parse()?),
    )?;
    let server_addr = stream.peer_addr()?;

    let stream_count = download_config.get("streams").unwrap().as_i64().unwrap() as usize;
    let mut parallel_streams: Vec<Arc<Mutex<dyn TestStream + Sync + Send>>> =
        Vec::with_capacity(stream_count);
    let mut parallel_streams_joinhandles = Vec::with_capacity(stream_count);
    let (results_tx, results_rx): (
        std::sync::mpsc::Sender<Box<dyn IntervalResult + Sync + Send>>,
        std::sync::mpsc::Receiver<Box<dyn IntervalResult + Sync + Send>>,
    ) = channel();

    let test_results: Mutex<Box<dyn TestResults>> =
        prepare_test_results(is_udp, stream_count as u8);

    let mut results_handler = || -> BoxResult<()> {
        loop {
            match results_rx.try_recv() {
                Ok(result) => {
                    let mut tr = test_results.lock().unwrap();
                    match result.kind() {
                        IntervalResultKind::ClientDone | IntervalResultKind::ClientFailed => {
                            if result.kind() == IntervalResultKind::ClientDone {
                                log::info!("stream {} is done", result.get_stream_idx());
                            } else {
                                log::warn!("stream {} failed", result.get_stream_idx());
                            }
                            tr.mark_stream_done(
                                &result.get_stream_idx(),
                                result.kind() == IntervalResultKind::ClientDone,
                            );
                            if tr.count_in_progress_streams() == 0 {
                                if tr.count_in_progress_streams_server() > 0 {
                                    log::info!(
                                        "Client streams done. Waiting for server results..."
                                    );
                                    run_state.start_kill_timer();
                                } else {
                                    log::info!(
                                        "Client streams done, and server reported all done."
                                    );
                                }
                            }
                        }
                        _ => {
                            tr.update_from_json(result.to_json())?;
                            if !display_json {
                                let output_str = format!("{}\n", result.to_string(display_bit));
                                output
                                    .lock()
                                    .unwrap()
                                    .extend_from_slice(output_str.as_bytes());
                            } else {
                                log::debug!("Interval result: {:?}", result.to_json());
                            }
                        }
                    }
                }
                Err(_) => break,
            }
        }
        Ok(())
    };

    // Send configuration
    if args.is_present("reverse") {
        log::debug!("running in reverse-mode: server will be uploading data");
        let mut stream_ports = Vec::with_capacity(stream_count);
        if is_udp {
            log::info!(
                "preparing for reverse-UDP test with {} streams...",
                stream_count
            );
            let test_definition = udp::UdpTestDefinition::new(&download_config)?;
            for stream_idx in 0..stream_count {
                log::debug!("preparing UDP-receiver for stream {}...", stream_idx);
                let test = udp::receiver::UdpReceiver::new(
                    test_definition.clone(),
                    &(stream_idx as u8),
                    &mut udp_port_pool,
                    &server_addr.ip(),
                    &(download_config["receive_buffer"].as_i64().unwrap() as usize),
                )?;
                stream_ports.push(test.get_port()?);
                parallel_streams.push(Arc::new(Mutex::new(test)));
            }
        } else {
            log::info!(
                "preparing for reverse-TCP test with {} streams...",
                stream_count
            );
            let test_definition = tcp::TcpTestDefinition::new(&download_config)?;
            for stream_idx in 0..stream_count {
                log::debug!("preparing TCP-receiver for stream {}...", stream_idx);
                let test = tcp::receiver::TcpReceiver::new(
                    test_definition.clone(),
                    &(stream_idx as u8),
                    &mut tcp_port_pool,
                    &server_addr.ip(),
                    &(download_config["receive_buffer"].as_i64().unwrap() as usize),
                )?;
                stream_ports.push(test.get_port()?);
                parallel_streams.push(Arc::new(Mutex::new(test)));
            }
        }
        upload_config["stream_ports"] = serde_json::json!(stream_ports);
        send(&mut stream, &upload_config)?;
    } else {
        log::debug!("running in forward-mode: server will be receiving data");
        send(&mut stream, &download_config)?;
    }

    // Handle initial connection response
    let connection_payload_result =
        communication::receive(&mut stream, &run_state, &mut results_handler);

    // Handle initial connection response
    match connection_payload_result {
        Ok(connection_payload) => {
            match connection_payload.get("kind") {
                Some(kind) => match kind.as_str().unwrap_or_default() {
                    "connect" => {
                        let stream_ports = match connection_payload.get("stream_ports") {
                            // Changed from "stream_bundle"
                            Some(ports) => ports,
                            None => {
                                log::error!(
                                    "Server response missing 'stream_ports' field: {:?}",
                                    connection_payload
                                );
                                return Err(anyhow::anyhow!(
                                    "Server response missing 'stream_ports' field"
                                )
                                .into());
                            }
                        };
                        let ports = match stream_ports.as_array() {
                            Some(arr) => arr,
                            None => {
                                log::error!("'stream_ports' is not an array: {:?}", stream_ports);
                                return Err(
                                    anyhow::anyhow!("'stream_ports' is not an array").into()
                                );
                            }
                        };

                        if is_udp {
                            log::info!("preparing for UDP test with {} streams...", stream_count);
                            let test_definition = udp::UdpTestDefinition::new(&upload_config)?;
                            for (stream_idx, port) in ports.iter().enumerate() {
                                log::debug!("preparing UDP-sender for stream {}...", stream_idx);
                                let test = udp::sender::UdpSender::new(
                                    test_definition.clone(),
                                    &(stream_idx as u8),
                                    &0,
                                    &server_addr.ip(),
                                    &(port.as_i64().unwrap() as u16),
                                    &(upload_config["duration"].as_f64().unwrap() as f32),
                                    &(upload_config["send_interval"].as_f64().unwrap() as f32),
                                    &(upload_config["send_buffer"].as_i64().unwrap() as usize),
                                )?;
                                parallel_streams.push(Arc::new(Mutex::new(test)));
                            }
                        } else {
                            log::info!("preparing for TCP test with {} streams...", stream_count);
                            let test_definition = tcp::TcpTestDefinition::new(&upload_config)?;
                            for (stream_idx, port) in ports.iter().enumerate() {
                                log::debug!("preparing TCP-sender for stream {}...", stream_idx);
                                let test = tcp::sender::TcpSender::new(
                                    test_definition.clone(),
                                    &(stream_idx as u8),
                                    &server_addr.ip(),
                                    &(port.as_i64().unwrap() as u16),
                                    &(upload_config["duration"].as_f64().unwrap() as f32),
                                    &(upload_config["send_interval"].as_f64().unwrap() as f32),
                                    &(upload_config["send_buffer"].as_i64().unwrap() as usize),
                                    &(upload_config["no_delay"].as_bool().unwrap()),
                                )?;
                                parallel_streams.push(Arc::new(Mutex::new(test)));
                            }
                        }
                    }
                    "connect-ready" => {}
                    _ => {
                        log::warn!(
                            "unexpected connection data from {}: {}",
                            stream.peer_addr()?,
                            serde_json::to_string(&connection_payload)?
                        );
                        // Continue execution instead of terminating
                    }
                },
                None => {
                    log::warn!(
                        "malformed connection data from {}: {}",
                        stream.peer_addr()?,
                        serde_json::to_string(&connection_payload)?
                    );
                    // Continue execution instead of terminating
                }
            }
        }
        Err(e) => {
            log::error!("Failed to receive connection payload from server: {}", e);
            return Err(
                anyhow::anyhow!("Failed to receive connection payload from server: {}", e).into(),
            );
        }
    }

    if run_state.is_alive() {
        log::info!("informing server that testing can begin...");
        send(&mut stream, &prepare_begin())?;

        // Wait for server "ready" signal before starting streams
        log::info!("waiting for server ready signal...");
        while run_state.is_alive() {
            let payload = communication::receive(&mut stream, &run_state, &mut results_handler)?;
            match payload.get("kind").and_then(|k| k.as_str()) {
                Some("ready") => {
                    log::info!("server ready signal received");
                    break; // Exit loop to proceed with test streams
                }
                Some(kind) => {
                    log::warn!(
                        "received unexpected message while waiting for ready: {}",
                        kind
                    );
                    // Continue waiting unless shutdown is requested
                }
                None => {
                    log::warn!(
                        "received malformed message while waiting for ready: {:?}",
                        payload
                    );
                }
            }
        }

        // Add UDP-specific synchronization after receiving ready signal
        if is_udp {
            log::info!("UDP test requires additional synchronization - waiting for ready_ack...");
            while run_state.is_alive() {
                match communication::receive(&mut stream, &run_state, &mut results_handler) {
                    Ok(payload) => match payload.get("kind").and_then(|k| k.as_str()) {
                        Some("ready_ack") => {
                            log::info!("UDP ready_ack received, proceeding with test");
                            break;
                        }
                        Some(other) => {
                            log::debug!("Received {} while waiting for ready_ack, ignoring", other);
                        }
                        None => {
                            log::warn!("Received message with no kind while waiting for ready_ack");
                        }
                    },
                    Err(e) => {
                        return Err(anyhow::anyhow!("Failed to receive ready_ack: {}", e).into());
                    }
                }
            }
        }

        if !run_state.is_alive() {
            return Err(anyhow::anyhow!(
                "Shutdown requested while waiting for server ready signal"
            )
            .into());
        }

        log::debug!("spawning stream-threads");
        for (stream_idx, parallel_stream) in parallel_streams.iter_mut().enumerate() {
            log::info!("beginning execution of stream {}...", stream_idx);
            let c_ps = Arc::clone(parallel_stream);
            let c_results_tx = results_tx.clone();
            let c_cam = cpu_affinity_manager.clone();
            let handle = thread::spawn(move || {
                c_cam.lock().unwrap().set_affinity();
                let mut test = c_ps.lock().unwrap();
                loop {
                    log::debug!("beginning test-interval for stream {}", test.get_idx());
                    match test.run_interval() {
                        Some(Ok(ir)) => {
                            if let Err(e) = c_results_tx.send(ir) {
                                log::error!("unable to send interval result: {}", e);
                                break;
                            }
                        }
                        Some(Err(e)) => {
                            log::error!("stream failed: {}", e);
                            c_results_tx
                                .send(Box::new(crate::protocol::results::ClientFailedResult {
                                    stream_idx: test.get_idx(),
                                }))
                                .ok();
                            break;
                        }
                        None => {
                            log::debug!("stream completed naturally");
                            c_results_tx
                                .send(Box::new(crate::protocol::results::ClientDoneResult {
                                    stream_idx: test.get_idx(),
                                }))
                                .ok();
                            break;
                        }
                    }
                }
            });
            parallel_streams_joinhandles.push(handle);
        }

        // Main test loop with updated handling for unexpected "ready" messages
        while run_state.is_alive() {
            match communication::receive(&mut stream, &run_state, &mut results_handler) {
                Ok(payload) => match payload.get("kind") {
                    Some(kind) => match kind.as_str().unwrap_or_default() {
                        "receive" | "send" => {
                            if !display_json {
                                let result = crate::protocol::results::interval_result_from_json(
                                    payload.clone(),
                                )?;
                                let output_str = format!("{}\n", result.to_string(display_bit));
                                output
                                    .lock()
                                    .unwrap()
                                    .extend_from_slice(output_str.as_bytes());
                            }
                            let mut tr = test_results.lock().unwrap();
                            tr.update_from_json(payload)?;
                        }
                        "done" | "failed" => match payload.get("stream_idx") {
                            Some(stream_idx) => {
                                match stream_idx.as_i64() {
                                    Some(idx64) => {
                                        let mut tr = test_results.lock().unwrap();
                                        match kind.as_str().unwrap() {
                                            "done" => log::info!(
                                                "server reported completion of stream {}",
                                                idx64
                                            ),
                                            "failed" => {
                                                log::warn!(
                                                    "server reported failure with stream {}",
                                                    idx64
                                                );
                                                tr.mark_stream_done(&(idx64 as u8), false);
                                            }
                                            _ => (),
                                        }
                                        tr.mark_stream_done_server(&(idx64 as u8));
                                        if tr.count_in_progress_streams() == 0
                                            && tr.count_in_progress_streams_server() == 0
                                        {
                                            complete.store(true, Ordering::Relaxed);
                                            run_state.request_shutdown();
                                            break;
                                        }
                                    }
                                    None => {
                                        log::error!("completion from server did not include a valid stream_idx");
                                        break;
                                    }
                                }
                            }
                            None => {
                                log::error!("completion from server did not include stream_idx");
                                break;
                            }
                        },
                        "ready" => {
                            log::debug!("Received unexpected 'ready' during test; ignoring...");
                            continue; // Gracefully ignore extra "ready" messages
                        }
                        _ => {
                            log::error!(
                                "invalid data from {}: {}",
                                stream.peer_addr()?,
                                serde_json::to_string(&payload)?
                            );
                            break;
                        }
                    },
                    None => {
                        log::error!(
                            "invalid data from {}: {}",
                            stream.peer_addr()?,
                            serde_json::to_string(&payload)?
                        );
                        break;
                    }
                },
                Err(e) => {
                    if !complete.load(Ordering::Relaxed) {
                        return Err(anyhow::anyhow!("Receive error: {}", e).into());
                    }
                    break;
                }
            }
        }

        send(&mut stream, &prepare_end()).unwrap_or_default();
        stream.shutdown(Shutdown::Both).unwrap_or_default();
    }

    send(&mut stream, &prepare_end()).unwrap_or_default();
    thread::sleep(Duration::from_millis(250));
    stream.shutdown(Shutdown::Both).unwrap_or_default();

    log::debug!("stopping any still-in-progress streams");
    for ps in parallel_streams.iter_mut() {
        let mut stream = match ps.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                log::error!(
                    "a stream-handler was poisoned; this indicates some sort of logic error"
                );
                poisoned.into_inner()
            }
        };
        stream.stop();
    }

    log::debug!("waiting for all streams to end");
    for jh in parallel_streams_joinhandles.drain(..) {
        match jh.join() {
            Ok(_) => log::debug!("Stream thread completed"),
            Err(e) => log::error!("error in parallel stream: {:?}", e),
        }
    }

    let common_config: serde_json::Value;
    {
        let upload_config_map = upload_config.as_object_mut().unwrap();
        let cc_family = upload_config_map.remove("family");
        upload_config_map.remove("kind");
        let cc_length = upload_config_map.remove("length");
        upload_config_map.remove("role");
        let cc_streams = upload_config_map.remove("streams");
        upload_config_map.remove("test_id");
        upload_config_map.remove("stream.bundle");
        if upload_config_map["send_buffer"].as_i64().unwrap() == 0 {
            upload_config_map.remove("send_buffer");
        }

        let download_config_map = download_config.as_object_mut().unwrap();
        download_config_map.remove("family");
        download_config_map.remove("kind");
        download_config_map.remove("length");
        download_config_map.remove("role");
        download_config_map.remove("streams");
        download_config_map.remove("test_id");
        if download_config_map["receive_buffer"].as_i64().unwrap() == 0 {
            download_config_map.remove("receive_buffer");
        }

        common_config = serde_json::json!({
            "family": cc_family,
            "length": cc_length,
            "streams": cc_streams,
        });
    }

    log::debug!("displaying test results");
    let omit_seconds: usize = args.value_of("omit").unwrap().parse()?;
    {
        let tr = test_results.lock().unwrap();
        let output_str = if display_json {
            tr.to_json_string(
                omit_seconds,
                upload_config,
                download_config,
                common_config,
                serde_json::json!({
                    "omit_seconds": omit_seconds,
                    "ip_version": match server_addr.ip() {
                        IpAddr::V4(_) => 4,
                        IpAddr::V6(_) => 6,
                    },
                    "reverse": args.is_present("reverse"),
                }),
            )
        } else {
            format!("{}\n", tr.to_string(display_bit, omit_seconds))
        };
        let mut output_guard = output.lock().unwrap();
        output_guard.clear();
        output_guard.extend_from_slice(output_str.as_bytes());
    }

    let tr = test_results.lock().unwrap();
    if !tr.is_success() {
        log::warn!("Test did not complete successfully; some streams may have failed");
        return Err(anyhow::anyhow!("Test incomplete: some streams failed or timed out").into());
    }

    Ok(())
}
