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

use std::collections::{HashMap, HashSet};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use std::error::Error;
type BoxResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

/* This module contains structures used to represent and collect the results of tests.
 * Since everything is basically just a data-container with representation methods,
 * it isn't extensively documented.
 */

#[derive(PartialEq)]
pub enum IntervalResultKind {
    ClientDone,
    ClientFailed,
    ServerDone,
    ServerFailed,
    TcpReceive,
    TcpSend,
    UdpReceive,
    UdpSend,
}

pub fn get_unix_timestamp() -> f64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(n) => n.as_secs_f64(),
        Err(_) => panic!("SystemTime before UNIX epoch"),
    }
}

pub trait IntervalResult {
    fn kind(&self) -> IntervalResultKind;

    fn get_stream_idx(&self) -> u8;

    fn to_json(&self) -> serde_json::Value;

    //produces test-results in tabular form
    fn to_string(&self, bit: bool) -> String;
}

pub struct ClientDoneResult {
    pub stream_idx: u8,
}
impl IntervalResult for ClientDoneResult {
    fn kind(&self) -> IntervalResultKind {
        IntervalResultKind::ClientDone
    }

    fn get_stream_idx(&self) -> u8 {
        self.stream_idx
    }

    fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "kind": "done",
            "origin": "client",
            "stream_idx": self.stream_idx,
        })
    }

    fn to_string(&self, _bit: bool) -> String {
        format!(
            "----------\n\
                 End of stream from client | stream: {}",
            self.stream_idx,
        )
    }
}
pub struct ServerDoneResult {
    pub stream_idx: u8,
}
impl IntervalResult for ServerDoneResult {
    fn kind(&self) -> IntervalResultKind {
        IntervalResultKind::ServerDone
    }

    fn get_stream_idx(&self) -> u8 {
        self.stream_idx
    }

    fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "kind": "done",
            "origin": "server",
            "stream_idx": self.stream_idx,
        })
    }

    fn to_string(&self, _bit: bool) -> String {
        format!(
            "----------\n\
                 End of stream from server | stream: {}",
            self.stream_idx,
        )
    }
}

pub struct ClientFailedResult {
    pub stream_idx: u8,
}
impl IntervalResult for ClientFailedResult {
    fn kind(&self) -> IntervalResultKind {
        IntervalResultKind::ClientFailed
    }

    fn get_stream_idx(&self) -> u8 {
        self.stream_idx
    }

    fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "kind": "failed",
            "origin": "client",
            "stream_idx": self.stream_idx,
        })
    }

    fn to_string(&self, _bit: bool) -> String {
        format!(
            "----------\n\
                 Failure in client stream | stream: {}",
            self.stream_idx,
        )
    }
}
pub struct ServerFailedResult {
    pub stream_idx: u8,
}
impl IntervalResult for ServerFailedResult {
    fn kind(&self) -> IntervalResultKind {
        IntervalResultKind::ServerFailed
    }

    fn get_stream_idx(&self) -> u8 {
        self.stream_idx
    }

    fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "kind": "failed",
            "origin": "server",
            "stream_idx": self.stream_idx,
        })
    }

    fn to_string(&self, _bit: bool) -> String {
        format!(
            "----------\n\
                 Failure in server stream | stream: {}",
            self.stream_idx,
        )
    }
}

#[derive(Serialize, Deserialize)]
pub struct TcpReceiveResult {
    pub timestamp: f64,

    pub stream_idx: u8,

    pub duration: f32,

    pub bytes_received: u64,
}
impl TcpReceiveResult {
    fn from_json(value: serde_json::Value) -> BoxResult<TcpReceiveResult> {
        let receive_result: TcpReceiveResult = serde_json::from_value(value)?;
        Ok(receive_result)
    }

    fn to_result_json(&self) -> serde_json::Value {
        let mut serialised = serde_json::to_value(self).unwrap();
        serialised.as_object_mut().unwrap().remove("stream_idx");
        serialised
    }
}
impl IntervalResult for TcpReceiveResult {
    fn kind(&self) -> IntervalResultKind {
        IntervalResultKind::TcpReceive
    }

    fn get_stream_idx(&self) -> u8 {
        self.stream_idx
    }

    fn to_json(&self) -> serde_json::Value {
        let mut serialised = serde_json::to_value(self).unwrap();
        serialised["family"] = serde_json::json!("tcp");
        serialised["kind"] = serde_json::json!("receive");
        serialised
    }

    fn to_string(&self, bit: bool) -> String {
        let duration_divisor;
        if self.duration == 0.0 {
            //avoid zerodiv, which can happen if the stream fails
            duration_divisor = 1.0;
        } else {
            duration_divisor = self.duration;
        }

        let bytes_per_second = self.bytes_received as f32 / duration_divisor;

        let throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                bytes_per_second / (1_000_000.00 / 8.0)
            ),
            false => format!("megabytes/second: {:.3}", bytes_per_second / 1_000_000.00),
        };

        format!(
            "----------\n\
                 TCP receive result over {:.2}s | stream: {}\n\
                 bytes: {} | per second: {:.3} | {}",
            self.duration, self.stream_idx, self.bytes_received, bytes_per_second, throughput,
        )
    }
}

#[derive(Serialize, Deserialize)]
pub struct TcpSendResult {
    pub timestamp: f64,

    pub stream_idx: u8,

    pub duration: f32,

    pub bytes_sent: u64,
    pub sends_blocked: u64,
}
impl TcpSendResult {
    fn from_json(value: serde_json::Value) -> BoxResult<TcpSendResult> {
        let mut local_value = value.clone();
        if local_value.get("sends_blocked").is_none() {
            //pre-0.1.8 peer
            local_value["sends_blocked"] = serde_json::json!(0 as u64); //report pre-0.1.8 status
        }

        let send_result: TcpSendResult = serde_json::from_value(local_value)?;
        Ok(send_result)
    }

    fn to_result_json(&self) -> serde_json::Value {
        let mut serialised = serde_json::to_value(self).unwrap();
        serialised.as_object_mut().unwrap().remove("stream_idx");
        serialised
    }
}
impl IntervalResult for TcpSendResult {
    fn kind(&self) -> IntervalResultKind {
        IntervalResultKind::TcpSend
    }

    fn get_stream_idx(&self) -> u8 {
        self.stream_idx
    }

    fn to_json(&self) -> serde_json::Value {
        let mut serialised = serde_json::to_value(self).unwrap();
        serialised["family"] = serde_json::json!("tcp");
        serialised["kind"] = serde_json::json!("send");
        serialised
    }

    fn to_string(&self, bit: bool) -> String {
        let duration_divisor;
        if self.duration == 0.0 {
            //avoid zerodiv, which can happen if the stream fails
            duration_divisor = 1.0;
        } else {
            duration_divisor = self.duration;
        }

        let bytes_per_second = self.bytes_sent as f32 / duration_divisor;

        let throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                bytes_per_second / (1_000_000.00 / 8.0)
            ),
            false => format!("megabytes/second: {:.3}", bytes_per_second / 1_000_000.00),
        };

        let mut output = format!(
            "----------\n\
                 TCP send result over {:.2}s | stream: {}\n\
                 bytes: {} | per second: {:.3} | {}",
            self.duration, self.stream_idx, self.bytes_sent, bytes_per_second, throughput,
        );
        if self.sends_blocked > 0 {
            output.push_str(&format!(
                "\nstalls due to full send-buffer: {}",
                self.sends_blocked
            ));
        }
        output
    }
}

#[derive(Serialize, Deserialize)]
pub struct UdpReceiveResult {
    pub timestamp: f64,

    pub stream_idx: u8,

    pub duration: f32,

    pub bytes_received: u64,
    pub packets_received: u64,
    pub packets_lost: i64,
    pub packets_out_of_order: u64,
    pub packets_duplicated: u64,

    pub unbroken_sequence: u64,
    pub jitter_seconds: Option<f32>,
}
impl UdpReceiveResult {
    fn from_json(value: serde_json::Value) -> BoxResult<UdpReceiveResult> {
        let receive_result: UdpReceiveResult = serde_json::from_value(value)?;
        Ok(receive_result)
    }

    fn to_result_json(&self) -> serde_json::Value {
        let mut serialised = serde_json::to_value(self).unwrap();
        serialised.as_object_mut().unwrap().remove("stream_idx");
        serialised
    }
}
impl IntervalResult for UdpReceiveResult {
    fn kind(&self) -> IntervalResultKind {
        IntervalResultKind::UdpReceive
    }

    fn get_stream_idx(&self) -> u8 {
        self.stream_idx
    }

    fn to_json(&self) -> serde_json::Value {
        let mut serialised = serde_json::to_value(self).unwrap();
        serialised["family"] = serde_json::json!("udp");
        serialised["kind"] = serde_json::json!("receive");
        serialised
    }

    fn to_string(&self, bit: bool) -> String {
        let duration_divisor;
        if self.duration == 0.0 {
            //avoid zerodiv, which can happen if the stream fails
            duration_divisor = 1.0;
        } else {
            duration_divisor = self.duration;
        }

        let bytes_per_second = self.bytes_received as f32 / duration_divisor;

        let throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                bytes_per_second / (1_000_000.00 / 8.0)
            ),
            false => format!("megabytes/second: {:.3}", bytes_per_second / 1_000_000.00),
        };

        let mut output = format!("----------\n\
                                  UDP receive result over {:.2}s | stream: {}\n\
                                  bytes: {} | per second: {:.3} | {}\n\
                                  packets: {} | lost: {} | out-of-order: {} | duplicate: {} | per second: {:.3}",
                                self.duration, self.stream_idx,
                                self.bytes_received, bytes_per_second, throughput,
                                self.packets_received, self.packets_lost, self.packets_out_of_order, self.packets_duplicated, self.packets_received as f32 / duration_divisor,
        );
        if self.jitter_seconds.is_some() {
            output.push_str(&format!(
                "\njitter: {:.6}s over {} consecutive packets",
                self.jitter_seconds.unwrap(),
                self.unbroken_sequence
            ));
        }
        output
    }
}

#[derive(Serialize, Deserialize)]
pub struct UdpSendResult {
    pub timestamp: f64,

    pub stream_idx: u8,

    pub duration: f32,

    pub bytes_sent: u64,
    pub packets_sent: u64,
    pub sends_blocked: u64,
}
impl UdpSendResult {
    fn from_json(value: serde_json::Value) -> BoxResult<UdpSendResult> {
        let mut local_value = value.clone();
        if local_value.get("sends_blocked").is_none() {
            //pre-0.1.8 peer
            local_value["sends_blocked"] = serde_json::json!(0 as u64); //report pre-0.1.8 status
        }

        let send_result: UdpSendResult = serde_json::from_value(local_value)?;
        Ok(send_result)
    }

    fn to_result_json(&self) -> serde_json::Value {
        let mut serialised = serde_json::to_value(self).unwrap();
        serialised.as_object_mut().unwrap().remove("stream_idx");
        serialised
    }
}
impl IntervalResult for UdpSendResult {
    fn kind(&self) -> IntervalResultKind {
        IntervalResultKind::UdpSend
    }

    fn get_stream_idx(&self) -> u8 {
        self.stream_idx
    }

    fn to_json(&self) -> serde_json::Value {
        let mut serialised = serde_json::to_value(self).unwrap();
        serialised["family"] = serde_json::json!("udp");
        serialised["kind"] = serde_json::json!("send");
        serialised
    }

    fn to_string(&self, bit: bool) -> String {
        let duration_divisor;
        if self.duration == 0.0 {
            //avoid zerodiv, which can happen if the stream fails
            duration_divisor = 1.0;
        } else {
            duration_divisor = self.duration;
        }

        let bytes_per_second = self.bytes_sent as f32 / duration_divisor;

        let throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                bytes_per_second / (1_000_000.00 / 8.0)
            ),
            false => format!("megabytes/second: {:.3}", bytes_per_second / 1_000_000.00),
        };

        let mut output = format!(
            "----------\n\
                 UDP send result over {:.2}s | stream: {}\n\
                 bytes: {} | per second: {:.3} | {}\n\
                 packets: {} per second: {:.3}",
            self.duration,
            self.stream_idx,
            self.bytes_sent,
            bytes_per_second,
            throughput,
            self.packets_sent,
            self.packets_sent as f32 / duration_divisor,
        );
        if self.sends_blocked > 0 {
            output.push_str(&format!(
                "\nstalls due to full send-buffer: {}",
                self.sends_blocked
            ));
        }
        output
    }
}

pub fn interval_result_from_json(value: serde_json::Value) -> BoxResult<Box<dyn IntervalResult>> {
    match value.get("family") {
        Some(f) => match f.as_str() {
            Some(family) => match family {
                "tcp" => match value.get("kind") {
                    Some(k) => match k.as_str() {
                        Some(kind) => match kind {
                            "receive" => Ok(Box::new(TcpReceiveResult::from_json(value)?)),
                            "send" => Ok(Box::new(TcpSendResult::from_json(value)?)),
                            _ => Err(Box::new(simple_error::simple_error!(
                                "unsupported interval-result kind: {}",
                                kind
                            ))),
                        },
                        None => Err(Box::new(simple_error::simple_error!(
                            "interval-result's kind is not a string"
                        ))),
                    },
                    None => Err(Box::new(simple_error::simple_error!(
                        "interval-result has no kind"
                    ))),
                },
                "udp" => match value.get("kind") {
                    Some(k) => match k.as_str() {
                        Some(kind) => match kind {
                            "receive" => Ok(Box::new(UdpReceiveResult::from_json(value)?)),
                            "send" => Ok(Box::new(UdpSendResult::from_json(value)?)),
                            _ => Err(Box::new(simple_error::simple_error!(
                                "unsupported interval-result kind: {}",
                                kind
                            ))),
                        },
                        None => Err(Box::new(simple_error::simple_error!(
                            "interval-result's kind is not a string"
                        ))),
                    },
                    None => Err(Box::new(simple_error::simple_error!(
                        "interval-result has no kind"
                    ))),
                },
                _ => Err(Box::new(simple_error::simple_error!(
                    "unsupported interval-result family: {}",
                    family
                ))),
            },
            None => Err(Box::new(simple_error::simple_error!(
                "interval-result's family is not a string"
            ))),
        },
        None => Err(Box::new(simple_error::simple_error!(
            "interval-result has no family"
        ))),
    }
}

pub trait StreamResults {
    fn update_from_json(&mut self, value: serde_json::Value) -> BoxResult<()>;

    fn to_json(&self, omit_seconds: usize) -> serde_json::Value;
}

struct TcpStreamResults {
    receive_results: Vec<TcpReceiveResult>,
    send_results: Vec<TcpSendResult>,
}
impl StreamResults for TcpStreamResults {
    fn update_from_json(&mut self, value: serde_json::Value) -> BoxResult<()> {
        match value.get("kind") {
            Some(k) => match k.as_str() {
                Some(kind) => match kind {
                    "send" => Ok(self.send_results.push(TcpSendResult::from_json(value)?)),
                    "receive" => Ok(self
                        .receive_results
                        .push(TcpReceiveResult::from_json(value)?)),
                    _ => Err(Box::new(simple_error::simple_error!(
                        "unsupported kind for TCP stream-result: {}",
                        kind
                    ))),
                },
                None => Err(Box::new(simple_error::simple_error!(
                    "kind must be a string for TCP stream-result"
                ))),
            },
            None => Err(Box::new(simple_error::simple_error!(
                "no kind specified for TCP stream-result"
            ))),
        }
    }

    fn to_json(&self, omit_seconds: usize) -> serde_json::Value {
        let mut duration_send: f64 = 0.0;
        let mut bytes_sent: u64 = 0;

        let mut duration_receive: f64 = 0.0;
        let mut bytes_received: u64 = 0;

        for (i, sr) in self.send_results.iter().enumerate() {
            if i < omit_seconds {
                continue;
            }

            duration_send += sr.duration as f64;
            bytes_sent += sr.bytes_sent;
        }

        for (i, rr) in self.receive_results.iter().enumerate() {
            if i < omit_seconds {
                continue;
            }

            duration_receive += rr.duration as f64;
            bytes_received += rr.bytes_received;
        }

        let summary = serde_json::json!({
            "duration_send": duration_send,
            "bytes_sent": bytes_sent,

            "duration_receive": duration_receive,
            "bytes_received": bytes_received,
        });

        serde_json::json!({
            "receive": self.receive_results.iter().map(|rr| rr.to_result_json()).collect::<Vec<serde_json::Value>>(),
            "send": self.send_results.iter().map(|sr| sr.to_result_json()).collect::<Vec<serde_json::Value>>(),
            "summary": summary,
        })
    }
}

struct UdpStreamResults {
    receive_results: Vec<UdpReceiveResult>,
    send_results: Vec<UdpSendResult>,
}
impl StreamResults for UdpStreamResults {
    fn update_from_json(&mut self, value: serde_json::Value) -> BoxResult<()> {
        match value.get("kind") {
            Some(k) => match k.as_str() {
                Some(kind) => match kind {
                    "send" => Ok(self.send_results.push(UdpSendResult::from_json(value)?)),
                    "receive" => Ok(self
                        .receive_results
                        .push(UdpReceiveResult::from_json(value)?)),
                    _ => Err(Box::new(simple_error::simple_error!(
                        "unsupported kind for UDP stream-result: {}",
                        kind
                    ))),
                },
                None => Err(Box::new(simple_error::simple_error!(
                    "kind must be a string for UDP stream-result"
                ))),
            },
            None => Err(Box::new(simple_error::simple_error!(
                "no kind specified for UDP stream-result"
            ))),
        }
    }

    fn to_json(&self, omit_seconds: usize) -> serde_json::Value {
        let mut duration_send: f64 = 0.0;

        let mut bytes_sent: u64 = 0;
        let mut packets_sent: u64 = 0;

        let mut duration_receive: f64 = 0.0;

        let mut bytes_received: u64 = 0;
        let mut packets_received: u64 = 0;
        let mut packets_out_of_order: u64 = 0;
        let mut packets_duplicated: u64 = 0;

        let mut jitter_calculated = false;
        let mut unbroken_sequence_count: u64 = 0;
        let mut jitter_weight: f64 = 0.0;

        for (i, sr) in self.send_results.iter().enumerate() {
            if i < omit_seconds {
                continue;
            }

            duration_send += sr.duration as f64;

            bytes_sent += sr.bytes_sent;
            packets_sent += sr.packets_sent;
        }

        for (i, rr) in self.receive_results.iter().enumerate() {
            if i < omit_seconds {
                continue;
            }

            duration_receive += rr.duration as f64;

            bytes_received += rr.bytes_received;
            packets_received += rr.packets_received;
            packets_out_of_order += rr.packets_out_of_order;
            packets_duplicated += rr.packets_duplicated;

            if rr.jitter_seconds.is_some() {
                jitter_weight +=
                    (rr.unbroken_sequence as f64) * (rr.jitter_seconds.unwrap() as f64);
                unbroken_sequence_count += rr.unbroken_sequence;

                jitter_calculated = true;
            }
        }

        let mut summary = serde_json::json!({
            "duration_send": duration_send,

            "bytes_sent": bytes_sent,
            "packets_sent": packets_sent,


            "duration_receive": duration_receive,

            "bytes_received": bytes_received,
            "packets_received": packets_received,
            "packets_lost": packets_sent - packets_received,
            "packets_out_of_order": packets_out_of_order,
            "packets_duplicated": packets_duplicated,
        });
        if packets_sent > 0 {
            summary["framed_packet_size"] = serde_json::json!(bytes_sent / packets_sent);
        }
        if jitter_calculated {
            summary["jitter_average"] =
                serde_json::json!(jitter_weight / (unbroken_sequence_count as f64));
            summary["jitter_packets_consecutive"] = serde_json::json!(unbroken_sequence_count);
        }

        serde_json::json!({
            "receive": self.receive_results.iter().map(|rr| rr.to_result_json()).collect::<Vec<serde_json::Value>>(),
            "send": self.send_results.iter().map(|sr| sr.to_result_json()).collect::<Vec<serde_json::Value>>(),
            "summary": summary,
        })
    }
}

pub trait TestResults {
    fn count_in_progress_streams(&self) -> u8;
    fn mark_stream_done(&mut self, idx: &u8, success: bool);

    fn count_in_progress_streams_server(&self) -> u8;
    fn mark_stream_done_server(&mut self, idx: &u8);

    fn is_success(&self) -> bool;

    fn update_from_json(&mut self, value: serde_json::Value) -> BoxResult<()>;

    fn to_json(
        &self,
        omit_seconds: usize,
        upload_config: serde_json::Value,
        download_config: serde_json::Value,
        common_config: serde_json::Value,
        additional_config: serde_json::Value,
    ) -> serde_json::Value;

    //produces a pretty-printed JSON string with the test results
    fn to_json_string(
        &self,
        omit_seconds: usize,
        upload_config: serde_json::Value,
        download_config: serde_json::Value,
        common_config: serde_json::Value,
        additional_config: serde_json::Value,
    ) -> String {
        serde_json::to_string_pretty(&self.to_json(
            omit_seconds,
            upload_config,
            download_config,
            common_config,
            additional_config,
        ))
        .unwrap()
    }

    //produces test-results in tabular form
    fn to_string(&self, bit: bool, omit_seconds: usize) -> String;
}

pub struct TcpTestResults {
    stream_results: HashMap<u8, TcpStreamResults>,
    pending_tests: HashSet<u8>,
    failed_tests: HashSet<u8>,
    server_tests_finished: HashSet<u8>,
}
impl TcpTestResults {
    pub fn new() -> TcpTestResults {
        TcpTestResults {
            stream_results: HashMap::new(),
            pending_tests: HashSet::new(),
            failed_tests: HashSet::new(),
            server_tests_finished: HashSet::new(),
        }
    }
    pub fn prepare_index(&mut self, idx: &u8) {
        self.stream_results.insert(
            *idx,
            TcpStreamResults {
                receive_results: Vec::new(),
                send_results: Vec::new(),
            },
        );
        self.pending_tests.insert(*idx);
    }
}
impl TestResults for TcpTestResults {
    fn count_in_progress_streams(&self) -> u8 {
        self.pending_tests.len() as u8
    }
    fn mark_stream_done(&mut self, idx: &u8, success: bool) {
        self.pending_tests.remove(idx);
        if !success {
            self.failed_tests.insert(*idx);
        }
    }

    fn count_in_progress_streams_server(&self) -> u8 {
        let mut count: u8 = 0;
        for idx in self.stream_results.keys() {
            if !self.server_tests_finished.contains(idx) {
                count += 1;
            }
        }
        count
    }
    fn mark_stream_done_server(&mut self, idx: &u8) {
        self.server_tests_finished.insert(*idx);
    }

    fn is_success(&self) -> bool {
        self.pending_tests.len() == 0 && self.failed_tests.len() == 0
    }

    fn update_from_json(&mut self, value: serde_json::Value) -> BoxResult<()> {
        match value.get("family") {
            Some(f) => match f.as_str() {
                Some(family) => match family {
                    "tcp" => match value.get("stream_idx") {
                        Some(idx) => match idx.as_i64() {
                            Some(idx64) => match self.stream_results.get_mut(&(idx64 as u8)) {
                                Some(stream_results) => stream_results.update_from_json(value),
                                None => Err(Box::new(simple_error::simple_error!(
                                    "stream-index {} is not a valid identifier",
                                    idx64
                                ))),
                            },
                            None => Err(Box::new(simple_error::simple_error!(
                                "stream-index is not an integer"
                            ))),
                        },
                        None => Err(Box::new(simple_error::simple_error!(
                            "no stream-index specified"
                        ))),
                    },
                    _ => Err(Box::new(simple_error::simple_error!(
                        "unsupported family for TCP stream-result: {}",
                        family
                    ))),
                },
                None => Err(Box::new(simple_error::simple_error!(
                    "kind must be a string for TCP stream-result"
                ))),
            },
            None => Err(Box::new(simple_error::simple_error!(
                "no kind specified for TCP stream-result"
            ))),
        }
    }

    fn to_json(
        &self,
        omit_seconds: usize,
        upload_config: serde_json::Value,
        download_config: serde_json::Value,
        common_config: serde_json::Value,
        additional_config: serde_json::Value,
    ) -> serde_json::Value {
        let mut duration_send: f64 = 0.0;
        let mut bytes_sent: u64 = 0;

        let mut duration_receive: f64 = 0.0;
        let mut bytes_received: u64 = 0;

        let mut streams = Vec::with_capacity(self.stream_results.len());
        for (idx, stream) in self.stream_results.iter() {
            streams.push(serde_json::json!({
                "intervals": stream.to_json(omit_seconds),
                "abandoned": self.pending_tests.contains(idx),
                "failed": self.failed_tests.contains(idx),
            }));

            for (i, sr) in stream.send_results.iter().enumerate() {
                if i < omit_seconds {
                    continue;
                }

                duration_send += sr.duration as f64;
                bytes_sent += sr.bytes_sent;
            }

            for (i, rr) in stream.receive_results.iter().enumerate() {
                if i < omit_seconds {
                    continue;
                }

                duration_receive += rr.duration as f64;
                bytes_received += rr.bytes_received;
            }
        }

        let summary = serde_json::json!({
            "duration_send": duration_send,
            "bytes_sent": bytes_sent,

            "duration_receive": duration_receive,
            "bytes_received": bytes_received,
        });

        serde_json::json!({
            "config": {
                "upload": upload_config,
                "download": download_config,
                "common": common_config,
                "additional": additional_config,
            },
            "streams": streams,
            "summary": summary,
            "success": self.is_success(),
        })
    }

    fn to_string(&self, bit: bool, omit_seconds: usize) -> String {
        let stream_count = self.stream_results.len();
        let mut stream_send_durations = vec![0.0; stream_count];
        let mut stream_receive_durations = vec![0.0; stream_count];

        let mut duration_send: f64 = 0.0;
        let mut bytes_sent: u64 = 0;

        let mut duration_receive: f64 = 0.0;
        let mut bytes_received: u64 = 0;

        let mut sends_blocked = false;

        for (stream_idx, stream) in self.stream_results.values().enumerate() {
            for (i, sr) in stream.send_results.iter().enumerate() {
                if i < omit_seconds {
                    continue;
                }

                duration_send += sr.duration as f64;
                stream_send_durations[stream_idx] += sr.duration as f64;

                bytes_sent += sr.bytes_sent;

                sends_blocked |= sr.sends_blocked > 0;
            }

            for (i, rr) in stream.receive_results.iter().enumerate() {
                if i < omit_seconds {
                    continue;
                }

                duration_receive += rr.duration as f64;
                stream_receive_durations[stream_idx] += rr.duration as f64;

                bytes_received += rr.bytes_received;
            }
        }
        stream_send_durations.sort_by(|a, b| a.partial_cmp(b).unwrap());
        stream_receive_durations.sort_by(|a, b| a.partial_cmp(b).unwrap());

        let send_duration_divisor;
        if duration_send == 0.0 {
            //avoid zerodiv, which can happen if all streams fail
            send_duration_divisor = 1.0;
        } else {
            send_duration_divisor = duration_send;
        }
        let send_bytes_per_second = bytes_sent as f64 / send_duration_divisor;
        let send_throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                send_bytes_per_second / (1_000_000.00 / 8.0)
            ),
            false => format!(
                "megabytes/second: {:.3}",
                send_bytes_per_second / 1_000_000.00
            ),
        };
        let total_send_throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                (send_bytes_per_second / (1_000_000.00 / 8.0)) * stream_count as f64
            ),
            false => format!(
                "megabytes/second: {:.3}",
                (send_bytes_per_second / 1_000_000.00) * stream_count as f64
            ),
        };

        let receive_duration_divisor;
        if duration_receive == 0.0 {
            //avoid zerodiv, which can happen if all streams fail
            receive_duration_divisor = 1.0;
        } else {
            receive_duration_divisor = duration_receive;
        }
        let receive_bytes_per_second = bytes_received as f64 / receive_duration_divisor;
        let receive_throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                receive_bytes_per_second / (1_000_000.00 / 8.0)
            ),
            false => format!(
                "megabytes/second: {:.3}",
                receive_bytes_per_second / 1_000_000.00
            ),
        };
        let total_receive_throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                (receive_bytes_per_second / (1_000_000.00 / 8.0)) * stream_count as f64
            ),
            false => format!(
                "megabytes/second: {:.3}",
                (receive_bytes_per_second / 1_000_000.00) * stream_count as f64
            ),
        };

        let mut output = format!(
            "==========\n\
                                  TCP send result over {:.2}s | streams: {}\n\
                                  stream-average bytes per second: {:.3} | {}\n\
                                  total bytes: {} | per second: {:.3} | {}\n\
                                  ==========\n\
                                  TCP receive result over {:.2}s | streams: {}\n\
                                  stream-average bytes per second: {:.3} | {}\n\
                                  total bytes: {} | per second: {:.3} | {}",
            stream_send_durations[stream_send_durations.len() - 1],
            stream_count,
            send_bytes_per_second,
            send_throughput,
            bytes_sent,
            send_bytes_per_second * stream_count as f64,
            total_send_throughput,
            stream_receive_durations[stream_receive_durations.len() - 1],
            stream_count,
            receive_bytes_per_second,
            receive_throughput,
            bytes_received,
            receive_bytes_per_second * stream_count as f64,
            total_receive_throughput,
        );
        if sends_blocked {
            output.push_str(&format!("\nthroughput throttled by buffer limitations"));
        }
        if !self.is_success() {
            output.push_str(&format!("\nTESTING DID NOT COMPLETE SUCCESSFULLY"));
        }

        output
    }
}

pub struct UdpTestResults {
    stream_results: HashMap<u8, UdpStreamResults>,
    pending_tests: HashSet<u8>,
    failed_tests: HashSet<u8>,
    server_tests_finished: HashSet<u8>,
}
impl UdpTestResults {
    pub fn new() -> UdpTestResults {
        UdpTestResults {
            stream_results: HashMap::new(),
            pending_tests: HashSet::new(),
            failed_tests: HashSet::new(),
            server_tests_finished: HashSet::new(),
        }
    }
    pub fn prepare_index(&mut self, idx: &u8) {
        self.stream_results.insert(
            *idx,
            UdpStreamResults {
                receive_results: Vec::new(),
                send_results: Vec::new(),
            },
        );
        self.pending_tests.insert(*idx);
    }
}
impl TestResults for UdpTestResults {
    fn count_in_progress_streams(&self) -> u8 {
        self.pending_tests.len() as u8
    }
    fn mark_stream_done(&mut self, idx: &u8, success: bool) {
        self.pending_tests.remove(idx);
        if !success {
            self.failed_tests.insert(*idx);
        }
    }

    fn count_in_progress_streams_server(&self) -> u8 {
        let mut count: u8 = 0;
        for idx in self.stream_results.keys() {
            if !self.server_tests_finished.contains(idx) {
                count += 1;
            }
        }
        count
    }
    fn mark_stream_done_server(&mut self, idx: &u8) {
        self.server_tests_finished.insert(*idx);
    }

    fn is_success(&self) -> bool {
        self.pending_tests.len() == 0 && self.failed_tests.len() == 0
    }

    fn update_from_json(&mut self, value: serde_json::Value) -> BoxResult<()> {
        match value.get("family") {
            Some(f) => match f.as_str() {
                Some(family) => match family {
                    "udp" => match value.get("stream_idx") {
                        Some(idx) => match idx.as_i64() {
                            Some(idx64) => match self.stream_results.get_mut(&(idx64 as u8)) {
                                Some(stream_results) => stream_results.update_from_json(value),
                                None => Err(Box::new(simple_error::simple_error!(
                                    "stream-index {} is not a valid identifier",
                                    idx64
                                ))),
                            },
                            None => Err(Box::new(simple_error::simple_error!(
                                "stream-index is not an integer"
                            ))),
                        },
                        None => Err(Box::new(simple_error::simple_error!(
                            "no stream-index specified"
                        ))),
                    },
                    _ => Err(Box::new(simple_error::simple_error!(
                        "unsupported family for UDP stream-result: {}",
                        family
                    ))),
                },
                None => Err(Box::new(simple_error::simple_error!(
                    "kind must be a string for UDP stream-result"
                ))),
            },
            None => Err(Box::new(simple_error::simple_error!(
                "no kind specified for UDP stream-result"
            ))),
        }
    }

    fn to_json(
        &self,
        omit_seconds: usize,
        upload_config: serde_json::Value,
        download_config: serde_json::Value,
        common_config: serde_json::Value,
        additional_config: serde_json::Value,
    ) -> serde_json::Value {
        let mut duration_send: f64 = 0.0;

        let mut bytes_sent: u64 = 0;
        let mut packets_sent: u64 = 0;

        let mut duration_receive: f64 = 0.0;

        let mut bytes_received: u64 = 0;
        let mut packets_received: u64 = 0;
        let mut packets_out_of_order: u64 = 0;
        let mut packets_duplicated: u64 = 0;

        let mut jitter_calculated = false;
        let mut unbroken_sequence_count: u64 = 0;
        let mut jitter_weight: f64 = 0.0;

        let mut streams = Vec::with_capacity(self.stream_results.len());
        for (idx, stream) in self.stream_results.iter() {
            streams.push(serde_json::json!({
                "intervals": stream.to_json(omit_seconds),
                "abandoned": self.pending_tests.contains(idx),
                "failed": self.failed_tests.contains(idx),
            }));

            for (i, sr) in stream.send_results.iter().enumerate() {
                if i < omit_seconds {
                    continue;
                }

                duration_send += sr.duration as f64;

                bytes_sent += sr.bytes_sent;
                packets_sent += sr.packets_sent;
            }

            for (i, rr) in stream.receive_results.iter().enumerate() {
                if i < omit_seconds {
                    continue;
                }

                duration_receive += rr.duration as f64;

                bytes_received += rr.bytes_received;
                packets_received += rr.packets_received;
                packets_out_of_order += rr.packets_out_of_order;
                packets_duplicated += rr.packets_duplicated;

                if rr.jitter_seconds.is_some() {
                    jitter_weight +=
                        (rr.unbroken_sequence as f64) * (rr.jitter_seconds.unwrap() as f64);
                    unbroken_sequence_count += rr.unbroken_sequence;

                    jitter_calculated = true;
                }
            }
        }

        let mut summary = serde_json::json!({
            "duration_send": duration_send,

            "bytes_sent": bytes_sent,
            "packets_sent": packets_sent,


            "duration_receive": duration_receive,

            "bytes_received": bytes_received,
            "packets_received": packets_received,
            "packets_lost": packets_sent - packets_received,
            "packets_out_of_order": packets_out_of_order,
            "packets_duplicated": packets_duplicated,
        });
        if packets_sent > 0 {
            summary["framed_packet_size"] = serde_json::json!(bytes_sent / packets_sent);
        }
        if jitter_calculated {
            summary["jitter_average"] =
                serde_json::json!(jitter_weight / (unbroken_sequence_count as f64));
            summary["jitter_packets_consecutive"] = serde_json::json!(unbroken_sequence_count);
        }

        serde_json::json!({
            "config": {
                "upload": upload_config,
                "download": download_config,
                "common": common_config,
                "additional": additional_config,
            },
            "streams": streams,
            "summary": summary,
            "success": self.is_success(),
        })
    }

    fn to_string(&self, bit: bool, omit_seconds: usize) -> String {
        let stream_count = self.stream_results.len();
        let mut stream_send_durations = vec![0.0; stream_count];
        let mut stream_receive_durations = vec![0.0; stream_count];

        let mut duration_send: f64 = 0.0;

        let mut bytes_sent: u64 = 0;
        let mut packets_sent: u64 = 0;

        let mut duration_receive: f64 = 0.0;

        let mut bytes_received: u64 = 0;
        let mut packets_received: u64 = 0;
        let mut packets_out_of_order: u64 = 0;
        let mut packets_duplicated: u64 = 0;

        let mut jitter_calculated = false;
        let mut unbroken_sequence_count: u64 = 0;
        let mut jitter_weight: f64 = 0.0;

        let mut sends_blocked = false;

        for (stream_idx, stream) in self.stream_results.values().enumerate() {
            for (i, sr) in stream.send_results.iter().enumerate() {
                if i < omit_seconds {
                    continue;
                }

                duration_send += sr.duration as f64;
                stream_send_durations[stream_idx] += sr.duration as f64;

                bytes_sent += sr.bytes_sent;
                packets_sent += sr.packets_sent;

                sends_blocked |= sr.sends_blocked > 0;
            }

            for (i, rr) in stream.receive_results.iter().enumerate() {
                if i < omit_seconds {
                    continue;
                }

                duration_receive += rr.duration as f64;
                stream_receive_durations[stream_idx] += rr.duration as f64;

                bytes_received += rr.bytes_received;
                packets_received += rr.packets_received;
                packets_out_of_order += rr.packets_out_of_order;
                packets_duplicated += rr.packets_duplicated;

                if rr.jitter_seconds.is_some() {
                    jitter_weight +=
                        (rr.unbroken_sequence as f64) * (rr.jitter_seconds.unwrap() as f64);
                    unbroken_sequence_count += rr.unbroken_sequence;

                    jitter_calculated = true;
                }
            }
        }
        stream_send_durations.sort_by(|a, b| a.partial_cmp(b).unwrap());
        stream_receive_durations.sort_by(|a, b| a.partial_cmp(b).unwrap());

        let send_duration_divisor;
        if duration_send == 0.0 {
            //avoid zerodiv, which can happen if all streams fail
            send_duration_divisor = 1.0;
        } else {
            send_duration_divisor = duration_send;
        }
        let send_bytes_per_second = bytes_sent as f64 / send_duration_divisor;
        let send_throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                send_bytes_per_second / (1_000_000.00 / 8.0)
            ),
            false => format!(
                "megabytes/second: {:.3}",
                send_bytes_per_second / 1_000_000.00
            ),
        };
        let total_send_throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                (send_bytes_per_second / (1_000_000.00 / 8.0)) * stream_count as f64
            ),
            false => format!(
                "megabytes/second: {:.3}",
                (send_bytes_per_second / 1_000_000.00) * stream_count as f64
            ),
        };

        let receive_duration_divisor;
        if duration_receive == 0.0 {
            //avoid zerodiv, which can happen if all streams fail
            receive_duration_divisor = 1.0;
        } else {
            receive_duration_divisor = duration_receive;
        }
        let receive_bytes_per_second = bytes_received as f64 / receive_duration_divisor;
        let receive_throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                receive_bytes_per_second / (1_000_000.00 / 8.0)
            ),
            false => format!(
                "megabytes/second: {:.3}",
                receive_bytes_per_second / 1_000_000.00
            ),
        };
        let total_receive_throughput = match bit {
            true => format!(
                "megabits/second: {:.3}",
                (receive_bytes_per_second / (1_000_000.00 / 8.0)) * stream_count as f64
            ),
            false => format!(
                "megabytes/second: {:.3}",
                (receive_bytes_per_second / 1_000_000.00) * stream_count as f64
            ),
        };

        let packets_lost = packets_sent - (packets_received - packets_duplicated);
        let packets_sent_divisor;
        if packets_sent == 0 {
            //avoid zerodiv, which can happen if all streams fail
            packets_sent_divisor = 1.0
        } else {
            packets_sent_divisor = packets_sent as f64;
        }
        let mut output = format!("==========\n\
                                  UDP send result over {:.2}s | streams: {}\n\
                                  stream-average bytes per second: {:.3} | {}\n\
                                  total bytes: {} | per second: {:.3} | {}\n\
                                  packets: {} per second: {:.3}\n\
                                  ==========\n\
                                  UDP receive result over {:.2}s | streams: {}\n\
                                  stream-average bytes per second: {:.3} | {}\n\
                                  total bytes: {} | per second: {:.3} | {}\n\
                                  packets: {} | lost: {} ({:.1}%) | out-of-order: {} | duplicate: {} | per second: {:.3}",
                                stream_send_durations[stream_send_durations.len() - 1], stream_count,
                                send_bytes_per_second, send_throughput,
                                bytes_sent, send_bytes_per_second * stream_count as f64, total_send_throughput,
                                packets_sent, (packets_sent as f64 / send_duration_divisor) * stream_count as f64,

                                stream_receive_durations[stream_receive_durations.len() - 1], stream_count,
                                receive_bytes_per_second, receive_throughput,
                                bytes_received, receive_bytes_per_second * stream_count as f64, total_receive_throughput,
                                packets_received, packets_lost, (packets_lost as f64 / packets_sent_divisor) * 100.0, packets_out_of_order, packets_duplicated, (packets_received as f64 / receive_duration_divisor) * stream_count as f64,
        );
        if jitter_calculated {
            output.push_str(&format!(
                "\njitter: {:.6}s over {} consecutive packets",
                jitter_weight / (unbroken_sequence_count as f64),
                unbroken_sequence_count
            ));
        }
        if sends_blocked {
            output.push_str(&format!("\nthroughput throttled by buffer limitations"));
        }
        if !self.is_success() {
            output.push_str(&format!("\nTESTING DID NOT COMPLETE SUCCESSFULLY"));
        }

        output
    }
}
