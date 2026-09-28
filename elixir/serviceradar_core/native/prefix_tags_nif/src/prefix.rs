// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Canonical network address. IPv4 uses the most significant 32 bits so both
/// families share the same prefix comparison and branch operations.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Prefix {
    pub(crate) network: u128,
    pub(crate) length: u8,
    pub(crate) ipv4: bool,
}

impl Prefix {
    pub fn parse(text: &str) -> Option<Self> {
        let (address, length) = match text.trim().split_once('/') {
            Some((address, length)) => (address, Some(length.trim().parse::<u8>().ok()?)),
            None => (text, None),
        };
        let (address, ipv4) = parse_address(address)?;
        let width = if ipv4 { 32 } else { 128 };
        let length = length.unwrap_or(width);
        if length > width {
            return None;
        }
        Some(Self {
            network: mask(address, length),
            length,
            ipv4,
        })
    }

    pub fn length(self) -> u8 {
        self.length
    }

    pub fn is_ipv4(self) -> bool {
        self.ipv4
    }

    pub(crate) fn contains(self, address: u128) -> bool {
        mask(address, self.length) == self.network
    }
}

impl std::fmt::Display for Prefix {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let address = if self.ipv4 {
            IpAddr::V4(Ipv4Addr::from((self.network >> 96) as u32))
        } else {
            IpAddr::V6(Ipv6Addr::from(self.network))
        };
        write!(f, "{address}/{}", self.length)
    }
}

pub(crate) fn parse_address(text: &str) -> Option<(u128, bool)> {
    match text.trim().parse::<IpAddr>().ok()? {
        IpAddr::V4(address) => Some((u128::from(u32::from(address)) << 96, true)),
        IpAddr::V6(address) => match address.to_ipv4_mapped() {
            Some(address) => Some((u128::from(u32::from(address)) << 96, true)),
            None => Some((u128::from(address), false)),
        },
    }
}

pub(crate) fn mask(address: u128, length: u8) -> u128 {
    if length == 0 {
        0
    } else {
        address & (u128::MAX << (128 - length))
    }
}

pub(crate) fn branch(address: u128, depth: u8) -> usize {
    ((address >> (127 - depth)) & 1) as usize
}
