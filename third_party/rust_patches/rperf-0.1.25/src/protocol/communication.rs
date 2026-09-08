/*
 * Copyright (C) 2021 Evtech Solutions, Ltd., dba 3D-P
 * Copyright (C) 2021-2025 Neil Tallim <neiltallim@3d-p.com>, Michael Freeman <mfreeman451@gmail.com>
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

use std::io::{self, Read, Write};
use std::time::Duration;

use mio::net::TcpStream;
use mio::{Events, Poll, PollOpt, Ready, Token};

use crate::protocol::state::RunState;
use std::error::Error;

type BoxResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

/// how long to wait for keepalive events
// the communications channels typically exchange data every second, so 2s is reasonable to avoid excess noise
pub const KEEPALIVE_DURATION: Duration = Duration::from_secs(2);

/// how long to block on polling operations
const POLL_TIMEOUT: Duration = Duration::from_millis(50);

/// sends JSON data over a client-server communications stream
pub fn send(stream: &mut TcpStream, message: &serde_json::Value) -> BoxResult<()> {
    let serialised_message = serde_json::to_vec(message)?;

    log::debug!(
        "sending message of length {}, {:?}, to {}...",
        serialised_message.len(),
        message,
        stream.peer_addr()?
    );
    let mut output_buffer = vec![0_u8; serialised_message.len() + 2]; // Use usize directly
    output_buffer[..2].copy_from_slice(&(serialised_message.len() as u16).to_be_bytes());
    output_buffer[2..].copy_from_slice(serialised_message.as_slice());
    // Use write_all for ensuring the entire buffer is sent
    stream.write_all(&output_buffer)?;
    // Flush might be needed depending on underlying buffering, though often handled by OS/TcpStream drop
    // stream.flush()?;
    Ok(())
}

/// receives the length-count of a pending message over a client-server communications stream
fn receive_length(
    stream: &mut TcpStream,
    run_state: &impl RunState,
    results_handler: &mut dyn FnMut() -> BoxResult<()>,
) -> BoxResult<u16> {
    // Keep try_clone for non-blocking mio operations
    let mut cloned_stream = stream.try_clone()?;

    let mio_token = Token(0);
    let poll = Poll::new()?;
    poll.register(
        &cloned_stream,
        mio_token,
        Ready::readable(),
        PollOpt::edge(), // Edge-triggered is usually preferred for mio loops
    )?;
    let mut events = Events::with_capacity(1); // Only need capacity for one event

    let mut length_bytes_read = 0;
    let mut length_spec: [u8; 2] = [0; 2];

    // OLD: while alive_check() {
    // NEW: Loop while the run state indicates alive
    while run_state.is_alive() {
        results_handler()?; // Send any outstanding results between cycles

        // Poll for readiness events
        match poll.poll(&mut events, Some(POLL_TIMEOUT)) {
            Ok(_) => {} // Continue if poll returned (even if no events)
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue, // Retry on EINTR
            Err(e) => return Err(Box::new(e)), // Other poll errors
        }

        for event in events.iter() {
            if event.token() == mio_token && event.readiness().is_readable() {
                // Read repeatedly until WouldBlock or error
                loop {
                    match cloned_stream.read(&mut length_spec[length_bytes_read..]) {
                        Ok(0) => {
                            // Connection closed by peer
                            // Check if we were expecting the closure
                            if run_state.is_alive() {
                                // Unexpected closure
                                log::error!(
                                    "Connection lost unexpectedly while reading length from {}",
                                    stream.peer_addr()?
                                );
                                return Err(Box::new(simple_error::simple_error!(
                                    "connection lost"
                                )));
                            } else {
                                // Closure happened during expected shutdown/timeout
                                log::warn!("Connection closed during shutdown while reading length from {}", stream.peer_addr()?);
                                return Err(Box::new(simple_error::simple_error!(
                                    "shutdown during receive"
                                )));
                            }
                        }
                        Ok(size) => {
                            length_bytes_read += size;
                            if length_bytes_read == 2 {
                                let length = u16::from_be_bytes(length_spec);
                                log::debug!(
                                    "received length-spec of {} from {}",
                                    length,
                                    stream.peer_addr()?
                                );
                                return Ok(length); // Successfully read length
                            }
                            // Continue reading if partial read
                        }
                        Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                            // No more data available to read right now
                            break; // Exit the inner read loop
                        }
                        Err(e) => {
                            log::error!("Error reading length from {}: {}", stream.peer_addr()?, e);
                            return Err(Box::new(e)); // Propagate other read errors
                        }
                    }
                } // end inner read loop
            } // end if event matches token and is readable
              // If we processed readable event and didn't return/error, break outer loop if needed
            if !run_state.is_alive() {
                break;
            }
        } // end for events loop

        // If the poll loop finished check the state again
        if !run_state.is_alive() {
            break; // Exit the main while loop if shutdown requested
        }

        // If poll timed out or read WouldBlock, loop will continue after POLL_TIMEOUT sleep implicit in poll
    } // end while run_state.is_alive()

    // If the loop terminated because run_state.is_alive() became false
    log::warn!(
        "Receive length loop terminated due to shutdown signal or timeout for {}",
        stream.peer_addr()?
    );
    Err(Box::new(simple_error::simple_error!(
        "shutdown requested or timeout"
    )))
}

/// receives the data-value of a pending message over a client-server communications stream
fn receive_payload(
    stream: &mut TcpStream,
    run_state: &impl RunState,
    results_handler: &mut dyn FnMut() -> BoxResult<()>,
    length: u16,
) -> BoxResult<serde_json::Value> {
    let mut cloned_stream = stream.try_clone()?;

    let mio_token = Token(0);
    let poll = Poll::new()?;
    poll.register(
        &cloned_stream,
        mio_token,
        Ready::readable(),
        PollOpt::edge(),
    )?;
    let mut events = Events::with_capacity(1);

    let mut bytes_read = 0;
    let buffer_size = length as usize; // Convert length to usize for buffer creation
    let mut buffer = vec![0_u8; buffer_size];

    while run_state.is_alive() {
        results_handler()?;

        match poll.poll(&mut events, Some(POLL_TIMEOUT)) {
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(Box::new(e)),
        }

        for event in events.iter() {
            if event.token() == mio_token && event.readiness().is_readable() {
                loop {
                    // Inner read loop
                    match cloned_stream.read(&mut buffer[bytes_read..]) {
                        Ok(0) => {
                            // Connection closed
                            if run_state.is_alive() {
                                log::error!(
                                    "Connection lost unexpectedly while reading payload from {}",
                                    stream.peer_addr()?
                                );
                                return Err(Box::new(simple_error::simple_error!(
                                    "connection lost"
                                )));
                            } else {
                                log::warn!("Connection closed during shutdown while reading payload from {}", stream.peer_addr()?);
                                return Err(Box::new(simple_error::simple_error!(
                                    "shutdown during receive"
                                )));
                            }
                        }
                        Ok(size) => {
                            bytes_read += size;
                            if bytes_read == buffer_size {
                                // Use buffer_size
                                // Successfully read the full payload
                                match serde_json::from_slice(&buffer) {
                                    Ok(v) => {
                                        log::debug!(
                                            "received payload ({}, {:?}) from {}",
                                            length,
                                            v,
                                            stream.peer_addr()?
                                        );
                                        return Ok(v);
                                    }
                                    Err(e) => {
                                        log::error!(
                                            "Failed to deserialize payload from {}: {}",
                                            stream.peer_addr()?,
                                            e
                                        );
                                        // Log the raw buffer potentially? Be careful with large payloads.
                                        // log::error!("Raw buffer: {:?}", buffer);
                                        return Err(Box::new(e));
                                    }
                                }
                            }
                            // Continue reading if partial read
                        }
                        Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                            // read_would_block = true;
                            break; // Exit inner read loop
                        }
                        Err(e) => {
                            log::error!(
                                "Error reading payload from {}: {}",
                                stream.peer_addr()?,
                                e
                            );
                            return Err(Box::new(e));
                        }
                    }
                } // end inner read loop
            } // end if event matches
            if !run_state.is_alive() {
                break;
            }
        } // end for events

        if !run_state.is_alive() {
            break; // Exit main while loop
        }
        // If poll timed out or read WouldBlock, continue looping
    } // end while run_state.is_alive()

    log::warn!(
        "Receive payload loop terminated due to shutdown signal or timeout for {}",
        stream.peer_addr()?
    );
    Err(Box::new(simple_error::simple_error!(
        "shutdown requested or timeout"
    )))
}

/// handles the full process of retrieving a message from a client-server communications stream
pub fn receive(
    stream: &mut TcpStream,
    run_state: &impl RunState,
    results_handler: &mut dyn FnMut() -> BoxResult<()>,
) -> BoxResult<serde_json::Value> {
    log::debug!("awaiting length-value from {}...", stream.peer_addr()?);
    // Pass run_state down, remove alive_check fn pointer
    let length = receive_length(stream, run_state, results_handler)?;
    log::debug!(
        "awaiting payload of length {} from {}...",
        length,
        stream.peer_addr()?
    );
    // Pass run_state down, remove alive_check fn pointer
    receive_payload(stream, run_state, results_handler, length)
}
