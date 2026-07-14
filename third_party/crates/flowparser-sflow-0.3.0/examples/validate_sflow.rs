//! sFlow v5 specification validation tool.
//!
//! Reads hex-encoded sFlow datagrams from stdin (one per line) or a file,
//! parses them, and reports per-field validation against the sFlow v5 spec.
//!
//! Usage:
//!   echo "00000005..." | cargo run --example validate_sflow
//!   cargo run --example validate_sflow -- <hex_file>
//!   cargo run --example validate_sflow -- --pcap <file.pcap>

use flowparser_sflow::{
    AddressType, CounterRecord, FlowRecord, ParseResult, SflowDatagram, SflowParser,
    SflowSample,
};
use std::io::{self, BufRead};
use std::{env, fs, process};

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() > 1 && (args[1] == "-h" || args[1] == "--help") {
        eprintln!("Usage:");
        eprintln!("  echo '<hex>' | cargo run --example validate_sflow");
        eprintln!("  cargo run --example validate_sflow -- <hex_file>");
        eprintln!();
        eprintln!("Validates sFlow v5 datagrams against the specification.");
        eprintln!("Input: one hex-encoded datagram per line.");
        process::exit(0);
    }

    let lines: Vec<String> = if args.len() > 1 {
        let content = fs::read_to_string(&args[1]).unwrap_or_else(|e| {
            eprintln!("Error reading file '{}': {}", args[1], e);
            process::exit(1);
        });
        content.lines().map(String::from).collect()
    } else {
        let stdin = io::stdin();
        stdin.lock().lines().map(|l| l.unwrap()).collect()
    };

    if lines.is_empty() {
        eprintln!("No input provided. Pass hex-encoded sFlow datagrams, one per line.");
        process::exit(1);
    }

    let parser = SflowParser::default();
    let mut total_datagrams = 0u64;
    let mut total_errors = 0u64;
    let mut total_warnings = 0u64;
    let mut total_samples = 0u64;
    let mut total_records = 0u64;

    for (line_num, line) in lines.iter().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let bytes = match hex::decode(line) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("[ERROR] Line {}: invalid hex: {}", line_num + 1, e);
                total_errors += 1;
                continue;
            }
        };

        let result = parser.parse_bytes(&bytes);
        let (dg_count, err_count, warn_count, sample_count, record_count) =
            validate_result(line_num + 1, &result);
        total_datagrams += dg_count;
        total_errors += err_count;
        total_warnings += warn_count;
        total_samples += sample_count;
        total_records += record_count;
    }

    println!();
    println!("=== Validation Summary ===");
    println!("  Datagrams parsed: {total_datagrams}");
    println!("  Samples:          {total_samples}");
    println!("  Records:          {total_records}");
    println!("  Errors:           {total_errors}");
    println!("  Warnings:         {total_warnings}");

    if total_errors > 0 {
        process::exit(1);
    }
}

fn validate_result(line: usize, result: &ParseResult) -> (u64, u64, u64, u64, u64) {
    let mut errors = 0u64;
    let mut warnings = 0u64;
    let mut samples = 0u64;
    let mut records = 0u64;

    if let Some(err) = &result.error {
        eprintln!("[ERROR] Line {line}: parse error: {err}");
        errors += 1;
    }

    for (di, dg) in result.datagrams.iter().enumerate() {
        let (e, w, s, r) = validate_datagram(line, di, dg);
        errors += e;
        warnings += w;
        samples += s;
        records += r;
    }

    (
        result.datagrams.len() as u64,
        errors,
        warnings,
        samples,
        records,
    )
}

fn validate_datagram(line: usize, dg_idx: usize, dg: &SflowDatagram) -> (u64, u64, u64, u64) {
    let prefix = format!("Line {line}, Datagram {dg_idx}");
    let mut errors = 0u64;
    let mut warnings = 0u64;
    let mut sample_count = 0u64;
    let mut record_count = 0u64;

    // Validate agent address
    match &dg.agent_address {
        AddressType::IPv4(ip) => {
            if ip.is_unspecified() {
                eprintln!("[WARN] {prefix}: agent address is 0.0.0.0");
                warnings += 1;
            }
        }
        AddressType::IPv6(ip) => {
            if ip.is_unspecified() {
                eprintln!("[WARN] {prefix}: agent address is ::");
                warnings += 1;
            }
        }
    }

    // Validate sequence number
    if dg.sequence_number == 0 {
        eprintln!("[WARN] {prefix}: sequence_number is 0 (agent may have just started)");
        warnings += 1;
    }

    println!(
        "[OK]   {prefix}: version=5, agent={:?}, seq={}, uptime={}ms, samples={}",
        dg.agent_address,
        dg.sequence_number,
        dg.uptime,
        dg.samples.len()
    );

    for (si, sample) in dg.samples.iter().enumerate() {
        sample_count += 1;
        let sp = format!("{prefix}, Sample {si}");

        match sample {
            SflowSample::Flow(fs) => {
                println!(
                    "[OK]   {sp}: FlowSample seq={}, rate={}, records={}",
                    fs.sequence_number,
                    fs.sampling_rate,
                    fs.records.len()
                );
                if fs.sampling_rate == 0 {
                    eprintln!("[WARN] {sp}: sampling_rate is 0");
                    warnings += 1;
                }
                for (ri, rec) in fs.records.iter().enumerate() {
                    record_count += 1;
                    let (e, w) = validate_flow_record(&format!("{sp}, Record {ri}"), rec);
                    errors += e;
                    warnings += w;
                }
            }
            SflowSample::Counter(cs) => {
                println!(
                    "[OK]   {sp}: CounterSample seq={}, records={}",
                    cs.sequence_number,
                    cs.records.len()
                );
                for (ri, rec) in cs.records.iter().enumerate() {
                    record_count += 1;
                    let (e, w) = validate_counter_record(&format!("{sp}, Record {ri}"), rec);
                    errors += e;
                    warnings += w;
                }
            }
            SflowSample::ExpandedFlow(efs) => {
                println!(
                    "[OK]   {sp}: ExpandedFlowSample seq={}, rate={}, records={}",
                    efs.sequence_number,
                    efs.sampling_rate,
                    efs.records.len()
                );
                for (ri, rec) in efs.records.iter().enumerate() {
                    record_count += 1;
                    let (e, w) = validate_flow_record(&format!("{sp}, Record {ri}"), rec);
                    errors += e;
                    warnings += w;
                }
            }
            SflowSample::ExpandedCounter(ecs) => {
                println!(
                    "[OK]   {sp}: ExpandedCounterSample seq={}, records={}",
                    ecs.sequence_number,
                    ecs.records.len()
                );
                for (ri, rec) in ecs.records.iter().enumerate() {
                    record_count += 1;
                    let (e, w) = validate_counter_record(&format!("{sp}, Record {ri}"), rec);
                    errors += e;
                    warnings += w;
                }
            }
            SflowSample::DiscardedPacket(dp) => {
                println!(
                    "[OK]   {sp}: DiscardedPacket seq={}, reason={}, records={}",
                    dp.sequence_number,
                    dp.reason,
                    dp.records.len()
                );
                for (ri, rec) in dp.records.iter().enumerate() {
                    record_count += 1;
                    let (e, w) = validate_flow_record(&format!("{sp}, Record {ri}"), rec);
                    errors += e;
                    warnings += w;
                }
            }
            SflowSample::Unknown {
                enterprise,
                format,
                data,
            } => {
                eprintln!(
                    "[WARN] {sp}: Unknown sample type enterprise={enterprise}, format={format}, len={}",
                    data.len()
                );
                warnings += 1;
            }
        }
    }

    (errors, warnings, sample_count, record_count)
}

fn validate_flow_record(prefix: &str, rec: &FlowRecord) -> (u64, u64) {
    let mut warnings = 0u64;

    match rec {
        FlowRecord::RawPacketHeader(r) => {
            let valid_protocols = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];
            if !valid_protocols.contains(&r.header_protocol) {
                eprintln!(
                    "[WARN] {prefix}: RawPacketHeader unknown header_protocol={}",
                    r.header_protocol
                );
                warnings += 1;
            }
            println!(
                "[OK]   {prefix}: RawPacketHeader proto={}, frame_len={}, header_len={}",
                r.header_protocol,
                r.frame_length,
                r.header.len()
            );
        }
        FlowRecord::ExtendedTcpInfo(t) => {
            if t.direction > 2 {
                eprintln!(
                    "[WARN] {prefix}: ExtendedTcpInfo direction={} (expected 0-2)",
                    t.direction
                );
                warnings += 1;
            }
            println!(
                "[OK]   {prefix}: ExtendedTcpInfo dir={}, rtt={}, cwnd={}",
                t.direction, t.rtt, t.snd_cwnd
            );
        }
        FlowRecord::ExtendedTimestamp(t) => {
            // Sanity: timestamp should be after 2000 and before 2100
            let year_2000_ns: u64 = 946_684_800_000_000_000;
            let year_2100_ns: u64 = 4_102_444_800_000_000_000;
            if t.nanoseconds < year_2000_ns || t.nanoseconds > year_2100_ns {
                eprintln!(
                    "[WARN] {prefix}: ExtendedTimestamp nanoseconds={} seems out of range",
                    t.nanoseconds
                );
                warnings += 1;
            }
            println!("[OK]   {prefix}: ExtendedTimestamp ns={}", t.nanoseconds);
        }
        FlowRecord::Unknown {
            enterprise,
            format,
            data,
        } => {
            eprintln!(
                "[WARN] {prefix}: Unknown flow record enterprise={enterprise}, format={format}, len={}",
                data.len()
            );
            warnings += 1;
        }
        other => {
            println!("[OK]   {prefix}: {:?}", std::mem::discriminant(other));
        }
    }

    (0, warnings)
}

fn validate_counter_record(prefix: &str, rec: &CounterRecord) -> (u64, u64) {
    let mut warnings = 0u64;

    match rec {
        CounterRecord::GenericInterface(gi) => {
            if gi.if_speed == 0 {
                eprintln!("[WARN] {prefix}: GenericInterface if_speed is 0");
                warnings += 1;
            }
            println!(
                "[OK]   {prefix}: GenericInterface index={}, speed={}",
                gi.if_index, gi.if_speed
            );
        }
        CounterRecord::NvidiaGpu(g) => {
            if g.device_count == 0 {
                eprintln!("[WARN] {prefix}: NvidiaGpu device_count is 0");
                warnings += 1;
            }
            println!(
                "[OK]   {prefix}: NvidiaGpu devices={}, temp={}C, mem_total={}",
                g.device_count, g.temperature, g.mem_total
            );
        }
        CounterRecord::Unknown {
            enterprise,
            format,
            data,
        } => {
            eprintln!(
                "[WARN] {prefix}: Unknown counter record enterprise={enterprise}, format={format}, len={}",
                data.len()
            );
            warnings += 1;
        }
        other => {
            println!("[OK]   {prefix}: {:?}", std::mem::discriminant(other));
        }
    }

    (0, warnings)
}
