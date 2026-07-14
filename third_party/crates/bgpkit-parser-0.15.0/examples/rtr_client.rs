//! Example RTR client that fetches ROAs and validates 1.1.1.0/24 -> AS13335
//!
//! This example demonstrates how to use the RTR protocol support in bgpkit-parser
//! to build a simple RTR client that:
//! 1. Connects to an RTR server
//! 2. Sends a Reset Query to get the full ROA database
//! 3. Collects IPv4 ROAs
//! 4. Validates a specific route announcement (1.1.1.0/24 -> AS13335)
//!
//! You can start a fully-functional RTR server with the `stayrtr` Docker image:
//! ```bash
//! docker run -it --rm -p 8282:8282 rpki/stayrtr -cache https://rpki.cloudflare.com/rpki.json
//! ```
//!
//! Usage:
//!   cargo run --example rtr_client -- <host> <port>
//!
//! Example:
//!   cargo run --example rtr_client -- localhost 8282
//!
//! Note: This is a simple example for demonstration purposes. A production
//! RTR client would need proper error handling, reconnection logic, and
//! session management.

use bgpkit_parser::models::rpki::rtr::*;
use bgpkit_parser::parser::rpki::rtr::{read_rtr_pdu, RtrEncode, RtrError};
use std::io::Write;
use std::net::{Ipv4Addr, TcpStream};

/// Simple ROA entry for validation
#[derive(Debug, Clone)]
struct RoaEntry {
    prefix: Ipv4Addr,
    prefix_len: u8,
    max_len: u8,
    asn: u32,
}

/// Validation result per RFC 6811
#[derive(Debug, PartialEq)]
enum ValidationState {
    /// At least one VRP matches the route announcement
    Valid,
    /// At least one VRP covers the prefix, but none match the AS
    Invalid,
    /// No VRP covers the prefix
    NotFound,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: {} <host> <port>", args[0]);
        eprintln!();
        eprintln!("Example:");
        eprintln!("  {} rtr.rpki.cloudflare.com 8282", args[0]);
        std::process::exit(1);
    }

    let host = &args[1];
    let port: u16 = args[2].parse()?;

    // Connect to RTR server
    println!("Connecting to {}:{}...", host, port);
    let mut stream = TcpStream::connect((host.as_str(), port))?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(60)))?;

    // Send Reset Query to get full database (start with v1)
    let reset_query = RtrResetQuery::new_v1();
    stream.write_all(&reset_query.encode())?;
    println!("Sent Reset Query (v1)");

    // Collect ROAs
    let mut ipv4_roas: Vec<RoaEntry> = Vec::new();
    let mut ipv6_count = 0usize;
    let mut session_id: Option<u16> = None;
    let mut serial: Option<u32> = None;

    // Read PDUs until End of Data
    loop {
        match read_rtr_pdu(&mut stream) {
            Ok(pdu) => match pdu {
                RtrPdu::CacheResponse(resp) => {
                    println!("Cache Response: session_id={}", resp.session_id);
                    session_id = Some(resp.session_id);
                }

                RtrPdu::IPv4Prefix(p) => {
                    if p.is_announcement() {
                        ipv4_roas.push(RoaEntry {
                            prefix: p.prefix,
                            prefix_len: p.prefix_length,
                            max_len: p.max_length,
                            asn: p.asn.into(),
                        });
                    }
                }

                RtrPdu::IPv6Prefix(p) => {
                    if p.is_announcement() {
                        ipv6_count += 1;
                    }
                }

                RtrPdu::RouterKey(_) => {
                    // BGPsec router keys - skip for this example
                }

                RtrPdu::EndOfData(eod) => {
                    serial = Some(eod.serial_number);
                    println!("End of Data: serial={}", eod.serial_number);
                    if let (Some(refresh), Some(retry), Some(expire)) = (
                        eod.refresh_interval,
                        eod.retry_interval,
                        eod.expire_interval,
                    ) {
                        println!(
                            "  Timing: refresh={}s, retry={}s, expire={}s",
                            refresh, retry, expire
                        );
                    }
                    break;
                }

                RtrPdu::CacheReset(_) => {
                    println!("Received Cache Reset - server has no data");
                    break;
                }

                RtrPdu::ErrorReport(err) => {
                    eprintln!("Server error: {:?} - {}", err.error_code, err.error_text);
                    // Try downgrade to v0 if version not supported
                    if err.error_code == RtrErrorCode::UnsupportedProtocolVersion {
                        println!("Retrying with v0...");
                        let reset_v0 = RtrResetQuery::new_v0();
                        stream.write_all(&reset_v0.encode())?;
                        continue;
                    }
                    break;
                }

                other => {
                    println!("Unexpected PDU: {:?}", other);
                }
            },
            Err(RtrError::IoError(ref e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                println!("Connection closed");
                break;
            }
            Err(e) => {
                eprintln!("Error reading PDU: {:?}", e);
                break;
            }
        }
    }

    println!();
    println!("Session Summary:");
    println!("  Session ID: {:?}", session_id);
    println!("  Serial: {:?}", serial);
    println!("  IPv4 ROAs: {}", ipv4_roas.len());
    println!("  IPv6 ROAs: {}", ipv6_count);

    // Validate 1.1.1.0/24 -> AS13335 (Cloudflare)
    let test_prefix = Ipv4Addr::new(1, 1, 1, 0);
    let test_prefix_len = 24u8;
    let test_asn = 13335u32;

    let result = validate_route(&ipv4_roas, test_prefix, test_prefix_len, test_asn);

    println!();
    println!(
        "Route Validation: {}/{} -> AS{}",
        test_prefix, test_prefix_len, test_asn
    );
    println!("  Result: {:?}", result);

    // Show matching/covering ROAs
    let covering: Vec<_> = ipv4_roas
        .iter()
        .filter(|roa| covers(roa, test_prefix, test_prefix_len))
        .collect();

    if !covering.is_empty() {
        println!();
        println!("Covering ROAs:");
        for roa in covering {
            let status = if test_prefix_len <= roa.max_len && test_asn == roa.asn {
                "VALID"
            } else {
                "covers but doesn't match"
            };
            println!(
                "  {}/{}-{} -> AS{} [{}]",
                roa.prefix, roa.prefix_len, roa.max_len, roa.asn, status
            );
        }
    }

    Ok(())
}

/// Check if a ROA covers a given prefix
fn covers(roa: &RoaEntry, prefix: Ipv4Addr, prefix_len: u8) -> bool {
    // The announced prefix must be at least as specific as the ROA prefix
    if prefix_len < roa.prefix_len {
        return false;
    }

    // Check if the ROA prefix is a prefix of the announced prefix
    let roa_bits: u32 = roa.prefix.into();
    let prefix_bits: u32 = prefix.into();
    let mask = if roa.prefix_len == 0 {
        0
    } else {
        !0u32 << (32 - roa.prefix_len)
    };

    (roa_bits & mask) == (prefix_bits & mask)
}

/// Validate a route announcement per RFC 6811
fn validate_route(
    roas: &[RoaEntry],
    prefix: Ipv4Addr,
    prefix_len: u8,
    asn: u32,
) -> ValidationState {
    let mut found_covering = false;

    for roa in roas {
        if !covers(roa, prefix, prefix_len) {
            continue;
        }

        found_covering = true;

        // Check if this ROA validates the announcement
        // The announced prefix length must be <= max_length
        // The origin AS must match
        if prefix_len <= roa.max_len && asn == roa.asn {
            return ValidationState::Valid;
        }
    }

    if found_covering {
        ValidationState::Invalid
    } else {
        ValidationState::NotFound
    }
}
