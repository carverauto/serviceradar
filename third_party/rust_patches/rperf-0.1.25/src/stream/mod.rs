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

pub mod tcp;
pub mod udp;

use std::error::Error;
type BoxResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

pub const INTERVAL: std::time::Duration = std::time::Duration::from_secs(1);

/// tests in this system are self-contained iterator-likes, where run_interval() may be invoked multiple times
/// until it returns None, indicating that the test has run its course; each invocation blocks for up to approximately
/// INTERVAL while gathering data.
pub trait TestStream {
    /// gather data; returns None when the test is over
    fn run_interval(
        &mut self,
    ) -> Option<BoxResult<Box<dyn crate::protocol::results::IntervalResult + Sync + Send>>>;
    /// return the port associated with the test-stream; this may vary over the test's lifetime
    fn get_port(&self) -> BoxResult<u16>;
    /// returns the index of the test, used to match client and server data
    fn get_idx(&self) -> u8;
    /// stops a running test
    fn stop(&mut self);
}

fn parse_port_spec(port_spec: String) -> Vec<u16> {
    let mut ports = Vec::<u16>::new();
    if !port_spec.is_empty() {
        for range in port_spec.split(',') {
            if range.contains('-') {
                let mut range_spec = range.split('-');
                let range_first = range_spec.next().unwrap().parse::<u16>().unwrap();
                let range_last = range_spec.last().unwrap().parse::<u16>().unwrap();

                for port in range_first..=range_last {
                    ports.push(port);
                }
            } else {
                ports.push(range.parse::<u16>().unwrap());
            }
        }

        ports.sort();
    }

    return ports;
}
