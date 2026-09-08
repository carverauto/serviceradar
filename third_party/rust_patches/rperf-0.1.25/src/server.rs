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
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use clap::ArgMatches;

use mio::net::{TcpListener, TcpStream};
use mio::{Events, Poll, PollOpt, Ready, Token};

use crate::protocol::communication::{receive, send, KEEPALIVE_DURATION};
use crate::protocol::messaging::{prepare_connect, prepare_connect_ready};
use crate::protocol::state::RunState;
use crate::stream::tcp;
use crate::stream::udp;
use crate::stream::TestStream;

use crate::protocol::messaging;
use state::ServerRunState;

type BoxResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

const POLL_TIMEOUT: Duration = Duration::from_millis(500);

fn handle_client(
    stream: &mut TcpStream,
    run_state: &ServerRunState,
    cpu_affinity_manager: Arc<Mutex<crate::utils::cpu_affinity::CpuAffinityManager>>,
    tcp_port_pool: Arc<Mutex<tcp::receiver::TcpPortPool>>,
    udp_port_pool: Arc<Mutex<udp::receiver::UdpPortPool>>,
) -> BoxResult<()> {
    let mut started = false;
    let mut is_udp_test = false;

    let peer_addr = stream.peer_addr()?;

    let mut parallel_streams: Vec<Arc<Mutex<dyn TestStream + Sync + Send>>> = Vec::new();
    let mut parallel_streams_joinhandles = Vec::new();
    let (results_tx, results_rx): (
        std::sync::mpsc::Sender<Box<dyn crate::protocol::results::IntervalResult + Sync + Send>>,
        std::sync::mpsc::Receiver<Box<dyn crate::protocol::results::IntervalResult + Sync + Send>>,
    ) = channel();

    let mut forwarding_send_stream = stream.try_clone()?;
    let mut results_handler = || -> BoxResult<()> {
        loop {
            match results_rx.try_recv() {
                Ok(result) => {
                    send(&mut forwarding_send_stream, &result.to_json())?;
                }
                Err(_) => break,
            }
        }
        Ok(())
    };

    while run_state.is_alive() {
        // Replaced is_alive()
        let payload = receive(stream, run_state, &mut results_handler)?; // Pass run_state
        match payload.get("kind") {
            Some(kind) => {
                match kind.as_str().unwrap() {
                    "configuration" => {
                        if payload
                            .get("role")
                            .unwrap_or(&serde_json::json!("download"))
                            .as_str()
                            .unwrap()
                            == "download"
                        {
                            log::info!(
                                "[{}] running in forward-mode: server will be receiving data",
                                &peer_addr
                            );

                            let stream_count = payload
                                .get("streams")
                                .unwrap_or(&serde_json::json!(1))
                                .as_i64()
                                .unwrap();
                            let mut stream_ports = Vec::with_capacity(stream_count as usize);

                            if payload
                                .get("family")
                                .unwrap_or(&serde_json::json!("tcp"))
                                .as_str()
                                .unwrap()
                                == "udp"
                            {
                                is_udp_test = true;

                                log::info!(
                                    "[{}] preparing for UDP test with {} streams...",
                                    &peer_addr,
                                    stream_count
                                );

                                let mut c_udp_port_pool = udp_port_pool.lock().unwrap();
                                let test_definition = udp::UdpTestDefinition::new(&payload)?;
                                for stream_idx in 0..stream_count {
                                    log::debug!(
                                        "[{}] preparing UDP-receiver for stream {}...",
                                        &peer_addr,
                                        stream_idx
                                    );
                                    let test = udp::receiver::UdpReceiver::new(
                                        test_definition.clone(),
                                        &(stream_idx as u8),
                                        &mut c_udp_port_pool,
                                        &peer_addr.ip(),
                                        &(payload["receive_buffer"].as_i64().unwrap() as usize),
                                    )?;
                                    stream_ports.push(test.get_port()?);
                                    parallel_streams.push(Arc::new(Mutex::new(test)));
                                }
                            } else {
                                log::info!(
                                    "[{}] preparing for TCP test with {} streams...",
                                    &peer_addr,
                                    stream_count
                                );

                                let mut c_tcp_port_pool = tcp_port_pool.lock().unwrap();
                                let test_definition = tcp::TcpTestDefinition::new(&payload)?;
                                for stream_idx in 0..stream_count {
                                    log::debug!(
                                        "[{}] preparing TCP-receiver for stream {}...",
                                        &peer_addr,
                                        stream_idx
                                    );
                                    let test = tcp::receiver::TcpReceiver::new(
                                        test_definition.clone(),
                                        &(stream_idx as u8),
                                        &mut c_tcp_port_pool,
                                        &peer_addr.ip(),
                                        &(payload["receive_buffer"].as_i64().unwrap() as usize),
                                    )?;
                                    stream_ports.push(test.get_port()?);
                                    parallel_streams.push(Arc::new(Mutex::new(test)));
                                }
                            }

                            send(stream, &prepare_connect(&stream_ports))?;
                        } else {
                            log::info!(
                                "[{}] running in reverse-mode: server will be uploading data",
                                &peer_addr
                            );

                            let stream_ports =
                                payload.get("stream_ports").unwrap().as_array().unwrap();

                            if payload
                                .get("family")
                                .unwrap_or(&serde_json::json!("tcp"))
                                .as_str()
                                .unwrap()
                                == "udp"
                            {
                                log::info!(
                                    "[{}] preparing for UDP test with {} streams...",
                                    &peer_addr,
                                    stream_ports.len()
                                );

                                let test_definition = udp::UdpTestDefinition::new(&payload)?;
                                for (stream_idx, port) in stream_ports.iter().enumerate() {
                                    log::debug!(
                                        "[{}] preparing UDP-sender for stream {}...",
                                        &peer_addr,
                                        stream_idx
                                    );
                                    let test = udp::sender::UdpSender::new(
                                        test_definition.clone(),
                                        &(stream_idx as u8),
                                        &0,
                                        &peer_addr.ip(),
                                        &(port.as_i64().unwrap_or(0) as u16),
                                        &(payload
                                            .get("duration")
                                            .unwrap_or(&serde_json::json!(0.0))
                                            .as_f64()
                                            .unwrap()
                                            as f32),
                                        &(payload
                                            .get("send_interval")
                                            .unwrap_or(&serde_json::json!(1.0))
                                            .as_f64()
                                            .unwrap()
                                            as f32),
                                        &(payload["send_buffer"].as_i64().unwrap() as usize),
                                    )?;
                                    parallel_streams.push(Arc::new(Mutex::new(test)));
                                }
                            } else {
                                log::info!(
                                    "[{}] preparing for TCP test with {} streams...",
                                    &peer_addr,
                                    stream_ports.len()
                                );

                                let test_definition = tcp::TcpTestDefinition::new(&payload)?;
                                for (stream_idx, port) in stream_ports.iter().enumerate() {
                                    log::debug!(
                                        "[{}] preparing TCP-sender for stream {}...",
                                        &peer_addr,
                                        stream_idx
                                    );
                                    let test = tcp::sender::TcpSender::new(
                                        test_definition.clone(),
                                        &(stream_idx as u8),
                                        &peer_addr.ip(),
                                        &(port.as_i64().unwrap() as u16),
                                        &(payload["duration"].as_f64().unwrap() as f32),
                                        &(payload["send_interval"].as_f64().unwrap() as f32),
                                        &(payload["send_buffer"].as_i64().unwrap() as usize),
                                        &(payload["no_delay"].as_bool().unwrap()),
                                    )?;
                                    parallel_streams.push(Arc::new(Mutex::new(test)));
                                }
                            }

                            send(stream, &prepare_connect_ready())?;
                        }
                    }
                    "begin" => {
                        if !started {
                            for (stream_idx, parallel_stream) in
                                parallel_streams.iter_mut().enumerate()
                            {
                                log::info!(
                                    "[{}] beginning execution of stream {}...",
                                    &peer_addr,
                                    stream_idx
                                );
                                let c_ps = Arc::clone(&parallel_stream);
                                let c_results_tx = results_tx.clone();
                                let c_cam = cpu_affinity_manager.clone();
                                let handle = thread::spawn(move || {
                                    c_cam.lock().unwrap().set_affinity();
                                    loop {
                                        let mut test = c_ps.lock().unwrap();
                                        log::debug!(
                                            "[{}] beginning test-interval for stream {}",
                                            &peer_addr,
                                            test.get_idx()
                                        );
                                        match test.run_interval() {
                                            Some(interval_result) => match interval_result {
                                                Ok(ir) => match c_results_tx.send(ir) {
                                                    Ok(_) => (),
                                                    Err(e) => {
                                                        log::error!("[{}] unable to process interval-result: {}", &peer_addr, e);
                                                        break;
                                                    }
                                                },
                                                Err(e) => {
                                                    c_results_tx.send(Box::new(crate::protocol::results::ServerFailedResult { stream_idx: test.get_idx() })).ok();
                                                    log::error!(
                                                        "[{}] stream {} failed: {}",
                                                        &peer_addr,
                                                        test.get_idx(),
                                                        e
                                                    );
                                                    break;
                                                }
                                            },
                                            None => {
                                                c_results_tx.send(Box::new(crate::protocol::results::ServerDoneResult { stream_idx: test.get_idx() })).ok();
                                                break;
                                            }
                                        }
                                    }
                                });
                                parallel_streams_joinhandles.push(handle);
                            }

                            started = true;

                            log::info!(
                                "[{}] receiver threads spawned, sending ready signal",
                                &peer_addr
                            );
                            send(stream, &serde_json::json!({"kind": "ready"}))?;

                            //if payload.get("family").unwrap_or(&serde_json::json!("tcp")).as_str().unwrap() == "udp" {
                            if is_udp_test {
                                // Give the UDP receiver a moment to fully initialize
                                std::thread::sleep(std::time::Duration::from_millis(100));
                                log::info!("[{}] sending UDP ready_ack signal", &peer_addr);
                                send(stream, &messaging::prepare_ready_ack())?;
                            }
                        } else {
                            log::error!("[{}] duplicate begin-signal", &peer_addr);
                            break;
                        }
                    }
                    "end" => {
                        log::info!("[{}] end of testing signaled", &peer_addr);
                        for ps in parallel_streams.iter_mut() {
                            let mut stream = ps.lock().unwrap();
                            stream.stop();
                        }
                        send(
                            stream,
                            &serde_json::json!({"kind": "done", "stream_idx": 0}),
                        )
                        .unwrap_or_default();
                        break;
                    }
                    _ => {
                        log::error!("[{}] invalid data", &peer_addr);
                        break;
                    }
                }
            }
            None => {
                log::error!("[{}] invalid data", &peer_addr);
                break;
            }
        }
    }

    log::debug!("[{}] stopping any still-in-progress streams", &peer_addr);
    for ps in parallel_streams.iter_mut() {
        let mut stream = match (*ps).lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                log::error!(
                    "[{}] a stream-handler was poisoned; this indicates some sort of logic error",
                    &peer_addr
                );
                poisoned.into_inner()
            }
        };
        stream.stop();
    }
    log::debug!("[{}] waiting for all streams to end", &peer_addr);
    for jh in parallel_streams_joinhandles {
        match jh.join() {
            Ok(_) => (),
            Err(e) => log::error!("[{}] error in parallel stream: {:?}", &peer_addr, e),
        }
    }

    Ok(())
}

/// A panic-tolerant means of indicating that a client has been disconnected
struct ClientThreadMonitor {
    client_address: String,
    run_state: ServerRunState,
}
impl Drop for ClientThreadMonitor {
    fn drop(&mut self) {
        self.run_state.client_disconnected(); // Replaced CLIENTS.fetch_sub
        if thread::panicking() {
            log::warn!("{} disconnecting due to panic", self.client_address);
        } else {
            log::info!("{} disconnected", self.client_address);
        }
    }
}

pub fn serve(args: ArgMatches, run_state: ServerRunState) -> BoxResult<()> {
    // Updated signature
    let tcp_port_pool = Arc::new(Mutex::new(tcp::receiver::TcpPortPool::new(
        args.value_of("tcp_port_pool").unwrap().to_string(),
        args.value_of("tcp6_port_pool").unwrap().to_string(),
    )));
    let udp_port_pool = Arc::new(Mutex::new(udp::receiver::UdpPortPool::new(
        args.value_of("udp_port_pool").unwrap().to_string(),
        args.value_of("udp6_port_pool").unwrap().to_string(),
    )));

    let cpu_affinity_manager = Arc::new(Mutex::new(
        crate::utils::cpu_affinity::CpuAffinityManager::new(args.value_of("affinity").unwrap())?,
    ));

    let client_limit: u16 = args.value_of("client_limit").unwrap().parse()?;
    if client_limit > 0 {
        log::debug!("limiting service to {} concurrent clients", client_limit);
    }

    let port: u16 = args.value_of("port").unwrap().parse()?;
    let mut listener: TcpListener;
    if args.is_present("version6") {
        listener = TcpListener::bind(&SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port))
            .map_err(|e| Box::new(e) as Box<dyn Error + Send + Sync>)?;
    } else {
        listener = TcpListener::bind(&SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), port))
            .map_err(|e| Box::new(e) as Box<dyn Error + Send + Sync>)?;
    }
    log::info!("server listening on {}", listener.local_addr()?);

    let mio_token = Token(0);
    let poll = Poll::new()?;
    poll.register(&mut listener, mio_token, Ready::readable(), PollOpt::edge())?;
    let mut events = Events::with_capacity(32);

    while run_state.is_alive() {
        // Replaced is_alive()
        poll.poll(&mut events, Some(POLL_TIMEOUT))?;
        for event in events.iter() {
            match event.token() {
                _ => loop {
                    match listener.accept() {
                        Ok((mut stream, address)) => {
                            log::info!("connection from {}", address);

                            stream
                                .set_nodelay(true)
                                .expect("cannot disable Nagle's algorithm");
                            stream
                                .set_keepalive(Some(KEEPALIVE_DURATION))
                                .expect("unable to set TCP keepalive");

                            let client_count = run_state.client_connected(); // Replaced CLIENTS.fetch_add
                            if client_limit > 0 && client_count > client_limit {
                                log::warn!(
                                    "client-limit ({}) reached; disconnecting {}...",
                                    client_limit,
                                    address.to_string()
                                );
                                stream.shutdown(Shutdown::Both).unwrap_or_default();
                                run_state.client_disconnected(); // Replaced CLIENTS.fetch_sub
                            } else {
                                let c_run_state = run_state.clone(); // Clone for the thread
                                let c_cam = cpu_affinity_manager.clone();
                                let c_tcp_port_pool = tcp_port_pool.clone();
                                let c_udp_port_pool = udp_port_pool.clone();
                                let thread_builder =
                                    thread::Builder::new().name(address.to_string().into());
                                thread_builder.spawn(move || {
                                    let _client_thread_monitor = ClientThreadMonitor {
                                        client_address: address.to_string(),
                                        run_state: c_run_state, // Pass run_state
                                    };

                                    match handle_client(
                                        &mut stream,
                                        &_client_thread_monitor.run_state,
                                        c_cam,
                                        c_tcp_port_pool,
                                        c_udp_port_pool,
                                    ) {
                                        Ok(_) => (),
                                        Err(e) => log::error!("error in client-handler: {}", e),
                                    }

                                    stream.shutdown(Shutdown::Both).unwrap_or_default();
                                })?;
                            }
                        }
                        Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => return Err(Box::new(e)),
                    }
                },
            }
        }
    }

    loop {
        let clients_count = run_state.client_count(); // Replaced CLIENTS.load
        if clients_count > 0 {
            log::info!("waiting for {} clients to finish...", clients_count);
            thread::sleep(POLL_TIMEOUT);
        } else {
            break;
        }
    }
    Ok(())
}
