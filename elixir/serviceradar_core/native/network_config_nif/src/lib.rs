// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Thin Rustler ABI over `network-config-downparser`. Typed `NifMap` facts,
//! DirtyCpu, `catch_unwind` per call.

use std::panic::{catch_unwind, AssertUnwindSafe};

use network_config_downparser::{parse, InterfaceFact};
use rustler::{NifMap, NifTaggedEnum};

#[derive(Clone, Debug, NifMap)]
pub struct NifInterfaceFact {
    pub if_name: String,
    pub ipv4_prefix: Option<String>,
    pub ipv6_prefix: Option<String>,
    pub vlan: Option<i32>,
    pub description: Option<String>,
    pub shutdown: bool,
    pub vrf: Option<String>,
}

#[derive(Clone, Debug, NifTaggedEnum)]
pub enum ParseResult {
    Ok(Vec<NifInterfaceFact>),
    Error(String),
}

impl From<InterfaceFact> for NifInterfaceFact {
    fn from(fact: InterfaceFact) -> Self {
        Self {
            if_name: fact.if_name,
            ipv4_prefix: fact.ipv4_prefix,
            ipv6_prefix: fact.ipv6_prefix,
            vlan: fact.vlan,
            description: fact.description,
            shutdown: fact.shutdown,
            vrf: fact.vrf,
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn parse_running_config(body: String) -> ParseResult {
    parse_running_config_impl(body)
}

fn parse_running_config_impl(body: String) -> ParseResult {
    match catch_unwind(AssertUnwindSafe(|| parse(&body))) {
        Ok(facts) => ParseResult::Ok(facts.into_iter().map(NifInterfaceFact::from).collect()),
        Err(_) => {
            ParseResult::Error("network config downparser panicked (call isolated)".to_string())
        }
    }
}

rustler::init!("Elixir.ServiceRadar.NetworkConfig.Native");

#[cfg(test)]
mod tests {
    use super::parse_running_config_impl;

    #[test]
    fn parse_impl_returns_named_facts() {
        let body = "interface GigabitEthernet0/1\n ip address 192.0.2.1 255.255.255.0\n";
        match parse_running_config_impl(body.to_string()) {
            super::ParseResult::Ok(facts) => {
                assert_eq!(facts.len(), 1);
                assert_eq!(facts[0].if_name, "GigabitEthernet0/1");
                assert_eq!(facts[0].ipv4_prefix.as_deref(), Some("192.0.2.0/24"));
                assert!(!facts[0].shutdown);
            }
            other => panic!("expected Ok facts, got {other:?}"),
        }
    }

    #[test]
    fn empty_body_is_ok_empty() {
        match parse_running_config_impl(String::new()) {
            super::ParseResult::Ok(facts) => assert!(facts.is_empty()),
            other => panic!("expected Ok facts, got {other:?}"),
        }
    }
}
