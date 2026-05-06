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

extern crate nix;

use nix::sys::socket::{setsockopt, sockopt::RcvBuf, sockopt::SndBuf};

use crate::protocol::results::{
    get_unix_timestamp, IntervalResult, TcpReceiveResult, TcpSendResult,
};

use super::{parse_port_spec, TestStream, INTERVAL};

use std::error::Error;
type BoxResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

pub const TEST_HEADER_SIZE: usize = 16;

#[derive(Clone)]
pub struct TcpTestDefinition {
    //a UUID used to identify packets associated with this test
    pub test_id: [u8; 16],
    //bandwidth target, in bytes/sec
    pub bandwidth: u64,
    //the length of the buffer to exchange
    pub length: usize,
}
impl TcpTestDefinition {
    pub fn new(details: &serde_json::Value) -> super::BoxResult<TcpTestDefinition> {
        let mut test_id_bytes = [0_u8; 16];
        for (i, v) in details
            .get("test_id")
            .unwrap_or(&serde_json::json!([]))
            .as_array()
            .unwrap()
            .iter()
            .enumerate()
        {
            if i >= 16 {
                //avoid out-of-bounds if given malicious data
                break;
            }
            test_id_bytes[i] = v.as_i64().unwrap_or(0) as u8;
        }

        let length = details
            .get("length")
            .unwrap_or(&serde_json::json!(TEST_HEADER_SIZE))
            .as_i64()
            .unwrap() as usize;
        if length < TEST_HEADER_SIZE {
            return Err(Box::new(simple_error::simple_error!(std::format!(
                "{} is too short of a length to satisfy testing requirements",
                length
            ))));
        }

        Ok(TcpTestDefinition {
            test_id: test_id_bytes,
            bandwidth: details
                .get("bandwidth")
                .unwrap_or(&serde_json::json!(0.0))
                .as_f64()
                .unwrap() as u64,
            length: length,
        })
    }
}

pub mod receiver {
    use std::io::Read;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
    use std::os::unix::io::AsRawFd;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    use mio::net::{TcpListener, TcpStream};
    use mio::{Events, Poll, PollOpt, Ready, Token};

    const POLL_TIMEOUT: Duration = Duration::from_millis(250);
    const RECEIVE_TIMEOUT: Duration = Duration::from_secs(3);

    pub struct TcpPortPool {
        pub ports_ip4: Vec<u16>,
        pub ports_ip6: Vec<u16>,
        pos_ip4: usize,
        pos_ip6: usize,
        lock_ip4: Mutex<u8>,
        lock_ip6: Mutex<u8>,
    }
    impl TcpPortPool {
        pub fn new(port_spec: String, port_spec6: String) -> TcpPortPool {
            let ports = super::parse_port_spec(port_spec);
            if !ports.is_empty() {
                log::debug!("configured IPv4 TCP port pool: {:?}", ports);
            } else {
                log::debug!("using OS assignment for IPv4 TCP ports");
            }

            let ports6 = super::parse_port_spec(port_spec6);
            if !ports.is_empty() {
                log::debug!("configured IPv6 TCP port pool: {:?}", ports6);
            } else {
                log::debug!("using OS assignment for IPv6 TCP ports");
            }

            TcpPortPool {
                ports_ip4: ports,
                pos_ip4: 0,
                lock_ip4: Mutex::new(0),

                ports_ip6: ports6,
                pos_ip6: 0,
                lock_ip6: Mutex::new(0),
            }
        }

        pub fn bind(&mut self, peer_ip: &IpAddr) -> super::BoxResult<TcpListener> {
            match peer_ip {
                IpAddr::V6(_) => {
                    if self.ports_ip6.is_empty() {
                        return Ok(TcpListener::bind(&SocketAddr::new(
                            IpAddr::V6(Ipv6Addr::UNSPECIFIED),
                            0,
                        ))
                        .expect(format!("failed to bind OS-assigned IPv6 TCP socket").as_str()));
                    } else {
                        let _guard = self.lock_ip6.lock().unwrap();

                        for port_idx in (self.pos_ip6 + 1)..self.ports_ip6.len() {
                            //iterate to the end of the pool; this will skip the first element in the pool initially, but that's fine
                            let listener_result = TcpListener::bind(&SocketAddr::new(
                                IpAddr::V6(Ipv6Addr::UNSPECIFIED),
                                self.ports_ip6[port_idx],
                            ));
                            if listener_result.is_ok() {
                                self.pos_ip6 = port_idx;
                                return Ok(listener_result.unwrap());
                            } else {
                                log::warn!(
                                    "unable to bind IPv6 TCP port {}",
                                    self.ports_ip6[port_idx]
                                );
                            }
                        }
                        for port_idx in 0..=self.pos_ip6 {
                            //circle back to where the search started
                            let listener_result = TcpListener::bind(&SocketAddr::new(
                                IpAddr::V6(Ipv6Addr::UNSPECIFIED),
                                self.ports_ip6[port_idx],
                            ));
                            if listener_result.is_ok() {
                                self.pos_ip6 = port_idx;
                                return Ok(listener_result.unwrap());
                            } else {
                                log::warn!(
                                    "unable to bind IPv6 TCP port {}",
                                    self.ports_ip6[port_idx]
                                );
                            }
                        }
                    }
                    return Err(Box::new(simple_error::simple_error!(
                        "unable to allocate IPv6 TCP port"
                    )));
                }
                IpAddr::V4(_) => {
                    if self.ports_ip4.is_empty() {
                        return Ok(TcpListener::bind(&SocketAddr::new(
                            IpAddr::V4(Ipv4Addr::UNSPECIFIED),
                            0,
                        ))
                        .expect(format!("failed to bind OS-assigned IPv4 TCP socket").as_str()));
                    } else {
                        let _guard = self.lock_ip4.lock().unwrap();

                        for port_idx in (self.pos_ip4 + 1)..self.ports_ip4.len() {
                            //iterate to the end of the pool; this will skip the first element in the pool initially, but that's fine
                            let listener_result = TcpListener::bind(&SocketAddr::new(
                                IpAddr::V4(Ipv4Addr::UNSPECIFIED),
                                self.ports_ip4[port_idx],
                            ));
                            if listener_result.is_ok() {
                                self.pos_ip4 = port_idx;
                                return Ok(listener_result.unwrap());
                            } else {
                                log::warn!(
                                    "unable to bind IPv4 TCP port {}",
                                    self.ports_ip4[port_idx]
                                );
                            }
                        }
                        for port_idx in 0..=self.pos_ip4 {
                            //circle back to where the search started
                            let listener_result = TcpListener::bind(&SocketAddr::new(
                                IpAddr::V4(Ipv4Addr::UNSPECIFIED),
                                self.ports_ip4[port_idx],
                            ));
                            if listener_result.is_ok() {
                                self.pos_ip4 = port_idx;
                                return Ok(listener_result.unwrap());
                            } else {
                                log::warn!(
                                    "unable to bind IPv4 TCP port {}",
                                    self.ports_ip4[port_idx]
                                );
                            }
                        }
                    }
                    return Err(Box::new(simple_error::simple_error!(
                        "unable to allocate IPv4 TCP port"
                    )));
                }
            };
        }
    }

    pub struct TcpReceiver {
        active: bool,
        test_definition: super::TcpTestDefinition,
        stream_idx: u8,

        listener: Option<TcpListener>,
        stream: Option<TcpStream>,
        mio_poll_token: Token,
        mio_poll: Poll,

        receive_buffer: usize,
    }
    impl TcpReceiver {
        pub fn new(
            test_definition: super::TcpTestDefinition,
            stream_idx: &u8,
            port_pool: &mut TcpPortPool,
            peer_ip: &IpAddr,
            receive_buffer: &usize,
        ) -> super::BoxResult<TcpReceiver> {
            log::debug!("binding TCP listener for stream {}...", stream_idx);
            let listener: TcpListener = port_pool
                .bind(peer_ip)
                .expect(format!("failed to bind TCP socket").as_str());
            log::debug!(
                "bound TCP listener for stream {}: {}",
                stream_idx,
                listener.local_addr()?
            );

            let mio_poll_token = Token(0);
            let mio_poll = Poll::new()?;

            Ok(TcpReceiver {
                active: true,
                test_definition: test_definition,
                stream_idx: stream_idx.to_owned(),

                listener: Some(listener),
                stream: None,
                mio_poll_token: mio_poll_token,
                mio_poll: mio_poll,

                receive_buffer: receive_buffer.to_owned(),
            })
        }

        fn process_connection(&mut self) -> super::BoxResult<TcpStream> {
            log::debug!(
                "preparing to receive TCP stream {} connection...",
                self.stream_idx
            );

            let listener = self.listener.as_mut().unwrap();
            let mio_token = Token(0);
            let poll = Poll::new()?;
            poll.register(listener, mio_token, Ready::readable(), PollOpt::edge())?;
            let mut events = Events::with_capacity(1);

            let start = Instant::now();

            while self.active {
                if start.elapsed() >= RECEIVE_TIMEOUT {
                    return Err(Box::new(simple_error::simple_error!(
                        "TCP listening for stream {} timed out",
                        self.stream_idx
                    )));
                }

                poll.poll(&mut events, Some(POLL_TIMEOUT))?;
                for event in events.iter() {
                    match event.token() {
                        _ => loop {
                            match listener.accept() {
                                Ok((stream, address)) => {
                                    log::debug!(
                                        "received TCP stream {} connection from {}",
                                        self.stream_idx,
                                        address
                                    );

                                    let mut verification_stream = stream.try_clone()?;
                                    let mio_token2 = Token(0);
                                    let poll2 = Poll::new()?;
                                    poll2.register(
                                        &verification_stream,
                                        mio_token2,
                                        Ready::readable(),
                                        PollOpt::edge(),
                                    )?;

                                    let mut buffer = [0_u8; 16];
                                    let mut events2 = Events::with_capacity(1);
                                    poll2.poll(&mut events2, Some(RECEIVE_TIMEOUT))?;
                                    for event2 in events2.iter() {
                                        match event2.token() {
                                            _ => match verification_stream.read(&mut buffer) {
                                                Ok(_) => {
                                                    if buffer == self.test_definition.test_id {
                                                        log::debug!("validated TCP stream {} connection from {}", self.stream_idx, address);
                                                        if !cfg!(windows) {
                                                            //NOTE: features unsupported on Windows
                                                            if self.receive_buffer != 0 {
                                                                log::debug!("setting receive-buffer to {}...", self.receive_buffer);
                                                                super::setsockopt(
                                                                    stream.as_raw_fd(),
                                                                    super::RcvBuf,
                                                                    &self.receive_buffer,
                                                                )?;
                                                            }
                                                        }

                                                        self.mio_poll.register(
                                                            &stream,
                                                            self.mio_poll_token,
                                                            Ready::readable(),
                                                            PollOpt::edge(),
                                                        )?;
                                                        return Ok(stream);
                                                    }
                                                }
                                                Err(ref e)
                                                    if e.kind()
                                                        == std::io::ErrorKind::WouldBlock =>
                                                {
                                                    //client didn't provide anything
                                                    break;
                                                }
                                                Err(e) => {
                                                    return Err(Box::new(e));
                                                }
                                            },
                                        }
                                    }
                                    log::warn!(
                                        "could not validate TCP stream {} connection from {}",
                                        self.stream_idx,
                                        address
                                    );
                                }
                                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                    //nothing to do
                                    break;
                                }
                                Err(e) => {
                                    return Err(Box::new(e));
                                }
                            }
                        },
                    }
                }
            }
            Err(Box::new(simple_error::simple_error!(
                "did not receive a connection"
            )))
        }
    }
    impl super::TestStream for TcpReceiver {
        fn run_interval(
            &mut self,
        ) -> Option<super::BoxResult<Box<dyn super::IntervalResult + Sync + Send>>> {
            let mut bytes_received: u64 = 0;

            if self.stream.is_none() {
                //if still in the setup phase, receive the sender
                match self.process_connection() {
                    Ok(stream) => {
                        self.stream = Some(stream);
                        //NOTE: the connection process consumes the test-header; account for those bytes
                        bytes_received += super::TEST_HEADER_SIZE as u64;
                    }
                    Err(e) => {
                        return Some(Err(e));
                    }
                }
                self.listener = None; //drop it, closing the socket
            }
            let stream = self.stream.as_mut().unwrap();

            let mut events = Events::with_capacity(1); //only watching one socket
            let mut buf = vec![0_u8; self.test_definition.length];

            let peer_addr = match stream.peer_addr() {
                Ok(pa) => pa,
                Err(e) => return Some(Err(Box::new(e))),
            };
            let start = Instant::now();

            while self.active {
                if start.elapsed() >= RECEIVE_TIMEOUT {
                    return Some(Err(Box::new(simple_error::simple_error!(
                        "TCP reception for stream {} from {} timed out",
                        self.stream_idx,
                        peer_addr
                    ))));
                }

                log::trace!(
                    "awaiting TCP stream {} from {}...",
                    self.stream_idx,
                    peer_addr
                );
                let poll_result = self.mio_poll.poll(&mut events, Some(POLL_TIMEOUT));
                if poll_result.is_err() {
                    return Some(Err(Box::new(poll_result.unwrap_err())));
                }
                for event in events.iter() {
                    if event.token() == self.mio_poll_token {
                        loop {
                            match stream.read(&mut buf) {
                                Ok(packet_size) => {
                                    log::trace!(
                                        "received {} bytes in TCP stream {} from {}",
                                        packet_size,
                                        self.stream_idx,
                                        peer_addr
                                    );
                                    if packet_size == 0 {
                                        //test's over
                                        self.active = false; //HACK: can't call self.stop() because it's a double-borrow due to the unwrapped stream
                                        break;
                                    }

                                    bytes_received += packet_size as u64;

                                    let elapsed_time = start.elapsed();
                                    if elapsed_time >= super::INTERVAL {
                                        return Some(Ok(Box::new(super::TcpReceiveResult {
                                            timestamp: super::get_unix_timestamp(),

                                            stream_idx: self.stream_idx,

                                            duration: elapsed_time.as_secs_f32(),

                                            bytes_received: bytes_received,
                                        })));
                                    }
                                }
                                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                    //receive timeout
                                    break;
                                }
                                Err(e) => {
                                    return Some(Err(Box::new(e)));
                                }
                            }
                        }
                    } else {
                        log::warn!("got event for unbound token: {:?}", event);
                    }
                }
            }
            if bytes_received > 0 {
                Some(Ok(Box::new(super::TcpReceiveResult {
                    timestamp: super::get_unix_timestamp(),

                    stream_idx: self.stream_idx,

                    duration: start.elapsed().as_secs_f32(),

                    bytes_received: bytes_received,
                })))
            } else {
                None
            }
        }

        fn get_port(&self) -> super::BoxResult<u16> {
            match &self.listener {
                Some(listener) => Ok(listener.local_addr()?.port()),
                None => match &self.stream {
                    Some(stream) => Ok(stream.local_addr()?.port()),
                    None => Err(Box::new(simple_error::simple_error!(
                        "no port currently bound"
                    ))),
                },
            }
        }

        fn get_idx(&self) -> u8 {
            self.stream_idx.to_owned()
        }

        fn stop(&mut self) {
            self.active = false;
        }
    }
}

pub mod sender {
    use std::io::Write;
    use std::net::{IpAddr, SocketAddr};
    use std::os::unix::io::AsRawFd;
    use std::time::{Duration, Instant};

    use mio::net::TcpStream;

    use std::thread::sleep;

    const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
    const WRITE_TIMEOUT: Duration = Duration::from_millis(50);
    const BUFFER_FULL_TIMEOUT: Duration = Duration::from_millis(1);

    pub struct TcpSender {
        active: bool,
        test_definition: super::TcpTestDefinition,
        stream_idx: u8,

        socket_addr: SocketAddr,
        stream: Option<TcpStream>,

        //the interval, in seconds, at which to send data
        send_interval: f32,

        remaining_duration: f32,
        staged_buffer: Vec<u8>,

        send_buffer: usize,
        no_delay: bool,
    }
    impl TcpSender {
        pub fn new(
            test_definition: super::TcpTestDefinition,
            stream_idx: &u8,
            receiver_ip: &IpAddr,
            receiver_port: &u16,
            send_duration: &f32,
            send_interval: &f32,
            send_buffer: &usize,
            no_delay: &bool,
        ) -> super::BoxResult<TcpSender> {
            let mut staged_buffer = vec![0_u8; test_definition.length];
            for i in super::TEST_HEADER_SIZE..(staged_buffer.len()) {
                //fill the packet with a fixed sequence
                staged_buffer[i] = (i % 256) as u8;
            }
            //embed the test ID
            staged_buffer[0..16].copy_from_slice(&test_definition.test_id);

            Ok(TcpSender {
                active: true,
                test_definition: test_definition,
                stream_idx: stream_idx.to_owned(),

                socket_addr: SocketAddr::new(*receiver_ip, *receiver_port),
                stream: None,

                send_interval: send_interval.to_owned(),

                remaining_duration: send_duration.to_owned(),
                staged_buffer: staged_buffer,

                send_buffer: send_buffer.to_owned(),
                no_delay: no_delay.to_owned(),
            })
        }

        fn process_connection(&mut self) -> super::BoxResult<TcpStream> {
            log::debug!("preparing to connect TCP stream {}...", self.stream_idx);

            let raw_stream =
                match std::net::TcpStream::connect_timeout(&self.socket_addr, CONNECT_TIMEOUT) {
                    Ok(s) => s,
                    Err(e) => {
                        return Err(Box::new(simple_error::simple_error!(
                            "unable to connect stream {}: {}",
                            self.stream_idx,
                            e
                        )))
                    }
                };
            raw_stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
            let stream = match TcpStream::from_stream(raw_stream) {
                Ok(s) => s,
                Err(e) => {
                    return Err(Box::new(simple_error::simple_error!(
                        "unable to prepare TCP stream {}: {}",
                        self.stream_idx,
                        e
                    )))
                }
            };
            log::debug!(
                "connected TCP stream {} to {}",
                self.stream_idx,
                stream.peer_addr()?
            );

            if self.no_delay {
                log::debug!("setting no-delay...");
                stream.set_nodelay(true)?;
            }
            if !cfg!(windows) {
                //NOTE: features unsupported on Windows
                if self.send_buffer != 0 {
                    log::debug!("setting send-buffer to {}...", self.send_buffer);
                    super::setsockopt(stream.as_raw_fd(), super::SndBuf, &self.send_buffer)?;
                }
            }
            Ok(stream)
        }
    }
    impl super::TestStream for TcpSender {
        fn run_interval(
            &mut self,
        ) -> Option<super::BoxResult<Box<dyn super::IntervalResult + Sync + Send>>> {
            if self.stream.is_none() {
                //if still in the setup phase, connect to the receiver
                match self.process_connection() {
                    Ok(stream) => {
                        self.stream = Some(stream);
                    }
                    Err(e) => {
                        return Some(Err(e));
                    }
                }
            }
            let stream = self.stream.as_mut().unwrap();

            let interval_duration = Duration::from_secs_f32(self.send_interval);
            let mut interval_iteration = 0;
            let bytes_to_send =
                ((self.test_definition.bandwidth as f32) * super::INTERVAL.as_secs_f32()) as i64;
            let mut bytes_to_send_remaining = bytes_to_send;
            let bytes_to_send_per_interval_slice =
                ((bytes_to_send as f32) * self.send_interval) as i64;
            let mut bytes_to_send_per_interval_slice_remaining = bytes_to_send_per_interval_slice;

            let mut sends_blocked: u64 = 0;
            let mut bytes_sent: u64 = 0;

            let peer_addr = match stream.peer_addr() {
                Ok(pa) => pa,
                Err(e) => return Some(Err(Box::new(e))),
            };
            let cycle_start = Instant::now();

            while self.active && self.remaining_duration > 0.0 && bytes_to_send_remaining > 0 {
                log::trace!(
                    "writing {} bytes in TCP stream {} to {}...",
                    self.staged_buffer.len(),
                    self.stream_idx,
                    peer_addr
                );
                let packet_start = Instant::now();

                match stream.write(&self.staged_buffer) {
                    //it doesn't matter if the whole thing couldn't be written, since it's just garbage data
                    Ok(packet_size) => {
                        log::trace!(
                            "wrote {} bytes in TCP stream {} to {}",
                            packet_size,
                            self.stream_idx,
                            peer_addr
                        );

                        let bytes_written = packet_size as i64;
                        bytes_sent += bytes_written as u64;
                        bytes_to_send_remaining -= bytes_written;
                        bytes_to_send_per_interval_slice_remaining -= bytes_written;

                        let elapsed_time = cycle_start.elapsed();
                        if elapsed_time >= super::INTERVAL {
                            self.remaining_duration -= packet_start.elapsed().as_secs_f32();

                            return Some(Ok(Box::new(super::TcpSendResult {
                                timestamp: super::get_unix_timestamp(),

                                stream_idx: self.stream_idx,

                                duration: elapsed_time.as_secs_f32(),

                                bytes_sent: bytes_sent,
                                sends_blocked: sends_blocked,
                            })));
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        //send-buffer is full
                        //nothing to do, but avoid burning CPU cycles
                        sleep(BUFFER_FULL_TIMEOUT);
                        sends_blocked += 1;
                    }
                    Err(e) => {
                        return Some(Err(Box::new(e)));
                    }
                }

                if bytes_to_send_remaining <= 0 {
                    //interval's target is exhausted, so sleep until the end
                    let elapsed_time = cycle_start.elapsed();
                    if super::INTERVAL > elapsed_time {
                        sleep(super::INTERVAL - elapsed_time);
                    }
                } else if bytes_to_send_per_interval_slice_remaining <= 0 {
                    // interval subsection exhausted
                    interval_iteration += 1;
                    bytes_to_send_per_interval_slice_remaining = bytes_to_send_per_interval_slice;
                    let elapsed_time = cycle_start.elapsed();
                    let interval_endtime = interval_iteration * interval_duration;
                    if interval_endtime > elapsed_time {
                        sleep(interval_endtime - elapsed_time);
                    }
                }
                self.remaining_duration -= packet_start.elapsed().as_secs_f32();
            }
            if bytes_sent > 0 {
                Some(Ok(Box::new(super::TcpSendResult {
                    timestamp: super::get_unix_timestamp(),

                    stream_idx: self.stream_idx,

                    duration: cycle_start.elapsed().as_secs_f32(),

                    bytes_sent: bytes_sent,
                    sends_blocked: sends_blocked,
                })))
            } else {
                //indicate that the test is over by dropping the stream
                self.stream = None;
                None
            }
        }

        fn get_port(&self) -> super::BoxResult<u16> {
            match &self.stream {
                Some(stream) => Ok(stream.local_addr()?.port()),
                None => Err(Box::new(simple_error::simple_error!(
                    "no stream currently exists"
                ))),
            }
        }

        fn get_idx(&self) -> u8 {
            self.stream_idx.to_owned()
        }

        fn stop(&mut self) {
            self.active = false;
        }
    }
}
