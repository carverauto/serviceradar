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

use std::error::Error;
type BoxResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

/// prepares a message used to tell the server to begin operations
pub fn prepare_begin() -> serde_json::Value {
    serde_json::json!({
        "kind": "begin",
    })
}

/// prepares a message used to tell the client to connect its test-streams
pub fn prepare_connect(stream_ports: &[u16]) -> serde_json::Value {
    serde_json::json!({
        "kind": "connect",

        "stream_ports": stream_ports,
    })
}

/// prepares a message used to tell the client that the server is ready to connect to its test-streams
pub fn prepare_connect_ready() -> serde_json::Value {
    serde_json::json!({
        "kind": "connect-ready",
    })
}

/// prepares a message used to tell the server that testing is finished
pub fn prepare_end() -> serde_json::Value {
    serde_json::json!({
        "kind": "end",
    })
}

pub fn prepare_ready_ack() -> serde_json::Value {
    serde_json::json!({
        "kind": "ready_ack",
    })
}

/// prepares a message used to describe the upload role of a TCP test
fn prepare_configuration_tcp_upload(
    test_id: &[u8; 16],
    streams: u8,
    bandwidth: u64,
    seconds: f32,
    length: usize,
    send_interval: f32,
    send_buffer: u32,
    no_delay: bool,
) -> serde_json::Value {
    serde_json::json!({
        "kind": "configuration",

        "family": "tcp",
        "role": "upload",

        "test_id": test_id,
        "streams": validate_streams(streams),

        "bandwidth": validate_bandwidth(bandwidth),
        "duration": seconds,
        "length": calculate_length_tcp(length),
        "send_interval": validate_send_interval(send_interval),

        "send_buffer": send_buffer,
        "no_delay": no_delay,
    })
}

/// prepares a message used to describe the download role of a TCP test
fn prepare_configuration_tcp_download(
    test_id: &[u8; 16],
    streams: u8,
    length: usize,
    receive_buffer: u32,
) -> serde_json::Value {
    serde_json::json!({
        "kind": "configuration",

        "family": "tcp",
        "role": "download",

        "test_id": test_id,
        "streams": validate_streams(streams),

        "length": calculate_length_tcp(length),
        "receive_buffer": receive_buffer,
    })
}

/// prepares a message used to describe the upload role of a UDP test
fn prepare_configuration_udp_upload(
    test_id: &[u8; 16],
    streams: u8,
    bandwidth: u64,
    seconds: f32,
    length: u16,
    send_interval: f32,
    send_buffer: u32,
) -> serde_json::Value {
    serde_json::json!({
        "kind": "configuration",

        "family": "udp",
        "role": "upload",

        "test_id": test_id,
        "streams": validate_streams(streams),

        "bandwidth": validate_bandwidth(bandwidth),
        "duration": seconds,
        "length": calculate_length_udp(length),
        "send_interval": validate_send_interval(send_interval),

        "send_buffer": send_buffer,
    })
}

/// prepares a message used to describe the download role of a UDP test
fn prepare_configuration_udp_download(
    test_id: &[u8; 16],
    streams: u8,
    length: u16,
    receive_buffer: u32,
) -> serde_json::Value {
    serde_json::json!({
        "kind": "configuration",

        "family": "udp",
        "role": "download",

        "test_id": test_id,
        "streams": validate_streams(streams),

        "length": calculate_length_udp(length),
        "receive_buffer": receive_buffer,
    })
}

fn validate_streams(streams: u8) -> u8 {
    if streams > 0 {
        streams
    } else {
        log::warn!("parallel streams not specified; defaulting to 1");
        1
    }
}

fn validate_bandwidth(bandwidth: u64) -> u64 {
    if bandwidth > 0 {
        bandwidth
    } else {
        log::warn!("bandwidth was not specified; defaulting to 1024 bytes/second");
        1024
    }
}

fn validate_send_interval(send_interval: f32) -> f32 {
    if send_interval > 0.0 && send_interval <= 1.0 {
        send_interval
    } else {
        log::warn!("send-interval was invalid or not specified; defaulting to once per second");
        1.0
    }
}

fn calculate_length_tcp(length: usize) -> usize {
    if length < crate::stream::tcp::TEST_HEADER_SIZE {
        //length must be at least enough to hold the test data
        crate::stream::tcp::TEST_HEADER_SIZE
    } else {
        length
    }
}
fn calculate_length_udp(length: u16) -> u16 {
    if length < crate::stream::udp::TEST_HEADER_SIZE {
        //length must be at least enough to hold the test data
        crate::stream::udp::TEST_HEADER_SIZE
    } else {
        length
    }
}

/// prepares a message used to describe the upload role in a test
pub fn prepare_upload_configuration(
    args: &clap::ArgMatches,
    test_id: &[u8; 16],
) -> BoxResult<serde_json::Value> {
    let parallel_streams: u8 = args.value_of("parallel").unwrap().parse()?;
    let mut seconds: f32 = args.value_of("time").unwrap().parse()?;
    let mut send_interval: f32 = args.value_of("send_interval").unwrap().parse()?;
    let mut length: u32 = args.value_of("length").unwrap().parse()?;

    let mut send_buffer: u32 = args.value_of("send_buffer").unwrap().parse()?;

    let mut bandwidth_string = args.value_of("bandwidth").unwrap();
    let bandwidth: u64;
    let bandwidth_multiplier: f64;
    match bandwidth_string.chars().last() {
        Some(v) => {
            match v {
                'k' => {
                    //kilobits
                    bandwidth_multiplier = 1000.0 / 8.0;
                }
                'K' => {
                    //kilobytes
                    bandwidth_multiplier = 1000.0;
                }
                'm' => {
                    //megabits
                    bandwidth_multiplier = 1000.0 * 1000.0 / 8.0;
                }
                'M' => {
                    //megabytes
                    bandwidth_multiplier = 1000.0 * 1000.0;
                }
                'g' => {
                    //gigabits
                    bandwidth_multiplier = 1000.0 * 1000.0 * 1000.0 / 8.0;
                }
                'G' => {
                    //gigabytes
                    bandwidth_multiplier = 1000.0 * 1000.0 * 1000.0;
                }
                _ => {
                    bandwidth_multiplier = 1.0;
                }
            }

            if bandwidth_multiplier != 1.0 {
                //the value uses a suffix
                bandwidth_string = &bandwidth_string[0..(bandwidth_string.len() - 1)];
            }

            match bandwidth_string.parse::<f64>() {
                Ok(v2) => {
                    bandwidth = (v2 * bandwidth_multiplier) as u64;
                }
                Err(_) => {
                    //invalid input; fall back to 1mbps
                    log::warn!(
                        "invalid bandwidth: {}; setting value to 1mbps",
                        args.value_of("bandwidth").unwrap()
                    );
                    bandwidth = 125000;
                }
            }
        }
        None => {
            //invalid input; fall back to 1mbps
            log::warn!(
                "invalid bandwidth: {}; setting value to 1mbps",
                args.value_of("bandwidth").unwrap()
            );
            bandwidth = 125000;
        }
    }

    if seconds <= 0.0 {
        log::warn!("time was not in an acceptable range and has been set to 0.0");
        seconds = 0.0
    }

    if send_interval > 1.0 || send_interval <= 0.0 {
        log::warn!("send-interval was not in an acceptable range and has been set to 0.05");
        send_interval = 0.05
    }

    if args.is_present("udp") {
        log::debug!("preparing UDP upload config...");
        if length == 0 {
            length = 1024;
        }
        if send_buffer != 0 && send_buffer < length {
            log::warn!("requested send-buffer, {}, is too small to hold the data to be exchanged; it will be increased to {}", send_buffer, length * 2);
            send_buffer = length * 2;
        }
        Ok(prepare_configuration_udp_upload(
            test_id,
            parallel_streams,
            bandwidth,
            seconds,
            length as u16,
            send_interval,
            send_buffer,
        ))
    } else {
        log::debug!("preparing TCP upload config...");
        if length == 0 {
            length = 32 * 1024;
        }
        if send_buffer != 0 && send_buffer < length {
            log::warn!("requested send-buffer, {}, is too small to hold the data to be exchanged; it will be increased to {}", send_buffer, length * 2);
            send_buffer = length * 2;
        }

        let no_delay: bool = args.is_present("no_delay");

        Ok(prepare_configuration_tcp_upload(
            test_id,
            parallel_streams,
            bandwidth,
            seconds,
            length as usize,
            send_interval,
            send_buffer,
            no_delay,
        ))
    }
}
/// prepares a message used to describe the download role in a test
pub fn prepare_download_configuration(
    args: &clap::ArgMatches,
    test_id: &[u8; 16],
) -> BoxResult<serde_json::Value> {
    let parallel_streams: u8 = args.value_of("parallel").unwrap().parse()?;
    let mut length: u32 = args.value_of("length").unwrap().parse()?;
    let mut receive_buffer: u32 = args.value_of("receive_buffer").unwrap().parse()?;

    if args.is_present("udp") {
        log::debug!("preparing UDP download config...");
        if length == 0 {
            length = 1024;
        }
        if receive_buffer != 0 && receive_buffer < length {
            log::warn!("requested receive-buffer, {}, is too small to hold the data to be exchanged; it will be increased to {}", receive_buffer, length * 2);
            receive_buffer = length * 2;
        }
        Ok(prepare_configuration_udp_download(
            test_id,
            parallel_streams,
            length as u16,
            receive_buffer,
        ))
    } else {
        log::debug!("preparing TCP download config...");
        if length == 0 {
            length = 32 * 1024;
        }
        if receive_buffer != 0 && receive_buffer < length {
            log::warn!("requested receive-buffer, {}, is too small to hold the data to be exchanged; it will be increased to {}", receive_buffer, length * 2);
            receive_buffer = length * 2;
        }
        Ok(prepare_configuration_tcp_download(
            test_id,
            parallel_streams,
            length as usize,
            receive_buffer,
        ))
    }
}
