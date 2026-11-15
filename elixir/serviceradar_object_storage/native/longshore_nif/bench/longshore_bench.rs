//! Matched synthetic Longshore native client and loopback S3 peer benchmark binary.
//!
//! Executes on the `longshore-qualification` executor pool alongside the Elixir
//! Rustler benchmark so native `longshore_s3::Client` and `ServiceRadarObjectStorage`
//! share identical kernel, cgroup, CPU, memlock, seccomp, and peer conditions.

use longshore_s3::client::{Budget, Builder};
use longshore_s3::creds::Credentials;
use longshore_s3::report::{
    ContentRange, ETag, Encryption, End, Expect, Put, ServerEncryption, VersionId,
};
use longshore_s3::s3::Checksum;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream};
#[cfg(target_os = "linux")]
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Barrier, Mutex, RwLock};
use std::time::{Duration, Instant};

#[cfg(target_os = "linux")]
fn set_tcp_quickack(stream: &TcpStream) {
    extern "C" {
        fn setsockopt(
            socket: i32,
            level: i32,
            name: i32,
            value: *const std::ffi::c_void,
            option_len: u32,
        ) -> i32;
    }
    const IPPROTO_TCP: i32 = 6;
    const TCP_QUICKACK: i32 = 12;
    let one: i32 = 1;
    unsafe {
        let _ = setsockopt(
            stream.as_raw_fd(),
            IPPROTO_TCP,
            TCP_QUICKACK,
            (&raw const one).cast(),
            std::mem::size_of::<i32>() as u32,
        );
    }
}

#[cfg(not(target_os = "linux"))]
fn set_tcp_quickack(_stream: &TcpStream) {}

const MAX_SEED_BYTES: usize = 16 * 1024 * 1024;
const BUCKET: &str = "synthetic-bench";
const REGION: &str = "us-east-1";
const ACCESS_KEY: &str = "SYNTHETICBENCHKEY01";
const SECRET_KEY: &str = "synthetic-bench-secret-access-key-000001";
const VERSION_STR: &str = "bench-v1";
const ETAG_STR: &str = "\"synthetic-bench-etag-v1\"";

fn pattern_byte(index: usize) -> u8 {
    ((index & 0xFFFF) as u32)
        .wrapping_mul(2_654_435_761)
        .to_le_bytes()[2]
        ^ 0x5a
}

fn build_seed_buffer() -> Vec<u8> {
    let mut buf = vec![0u8; MAX_SEED_BYTES];
    for (idx, byte) in buf.iter_mut().enumerate() {
        *byte = pattern_byte(idx);
    }
    buf
}

#[derive(Clone)]
struct StoredObject {
    size: usize,
    etag: String,
    version: String,
}

struct PeerState {
    seed: Vec<u8>,
    objects: RwLock<HashMap<String, StoredObject>>,
}

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("peer") => run_peer(args),
        Some("native") => run_native(args),
        _ => {
            eprintln!("usage: longshore_bench <peer|native> [options]");
            std::process::exit(2);
        }
    }
}

fn run_peer(mut args: impl Iterator<Item = String>) {
    let mut port: u16 = 0;
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--port" => {
                port = args
                    .next()
                    .and_then(|v| v.parse().ok())
                    .expect("valid --port");
            }
            other => panic!("unknown peer flag: {other}"),
        }
    }

    let listener = TcpListener::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port))
        .expect("bind loopback peer");
    let local_port = listener.local_addr().expect("local_addr").port();

    let mut initial = HashMap::new();
    for size in [
        4096usize, 65_536, 1_048_576, 4_194_304, 8_388_608, 16_777_216,
    ] {
        initial.insert(
            format!("/{BUCKET}/seeded/{size}.bin"),
            StoredObject {
                size,
                etag: ETAG_STR.to_string(),
                version: VERSION_STR.to_string(),
            },
        );
    }

    let state = Arc::new(PeerState {
        seed: build_seed_buffer(),
        objects: RwLock::new(initial),
    });

    println!("PORT={local_port}");
    let _ = std::io::stdout().flush();

    for incoming in listener.incoming() {
        let Ok(stream) = incoming else { continue };
        let _ = stream.set_nodelay(true);
        let peer_state = state.clone();
        std::thread::spawn(move || serve_connection(stream, peer_state));
    }
}

fn serve_connection(stream: TcpStream, state: Arc<PeerState>) {
    let Ok(mut writer) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::with_capacity(64 * 1024, stream);
    let mut scratch = vec![0u8; 256 * 1024];
    let mut line = String::new();

    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let req_line = line.trim_end_matches(&['\r', '\n'][..]);
        if req_line.is_empty() {
            continue;
        }
        let mut parts = req_line.split_whitespace();
        let Some(method) = parts.next() else { return };
        let Some(raw_target) = parts.next() else {
            return;
        };
        let method = method.to_string();
        let path = raw_target
            .split_once('?')
            .map(|(p, _)| p)
            .unwrap_or(raw_target)
            .to_string();

        let mut content_length: usize = 0;
        let mut if_none_match_star = false;
        let mut if_match: Option<String> = None;
        let mut range_header: Option<String> = None;
        let mut close_conn = false;

        loop {
            line.clear();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                return;
            }
            let trimmed = line.trim_end_matches(&['\r', '\n'][..]);
            if trimmed.is_empty() {
                break;
            }
            if let Some((name, val)) = trimmed.split_once(':') {
                let val = val.trim();
                if name.eq_ignore_ascii_case("content-length") {
                    content_length = val.parse().unwrap_or(0);
                } else if name.eq_ignore_ascii_case("if-none-match") && val == "*" {
                    if_none_match_star = true;
                } else if name.eq_ignore_ascii_case("if-match") {
                    if_match = Some(val.to_string());
                } else if name.eq_ignore_ascii_case("range") {
                    range_header = Some(val.to_string());
                } else if name.eq_ignore_ascii_case("connection")
                    && val.eq_ignore_ascii_case("close")
                {
                    close_conn = true;
                }
            }
        }

        // Acknowledge request headers immediately on Linux loopback so sub-MSS PUT bodies
        // do not stall 40 ms behind Nagle + TCP delayed-ACK interaction.
        if content_length > 0 {
            set_tcp_quickack(&writer);
        }

        // Drain request body without per-request heap allocation.
        let mut remaining = content_length;
        while remaining > 0 {
            let chunk = remaining.min(scratch.len());
            if reader.read_exact(&mut scratch[..chunk]).is_err() {
                return;
            }
            remaining -= chunk;
        }

        let ok = match method.as_str() {
            "PUT" => handle_put(
                &mut writer,
                &state,
                &path,
                content_length,
                if_none_match_star,
            ),
            "HEAD" => handle_head(&mut writer, &state, &path, if_match.as_deref()),
            "GET" => handle_get(
                &mut writer,
                &state,
                &path,
                if_match.as_deref(),
                range_header.as_deref(),
            ),
            _ => write_error(&mut writer, 405, "MethodNotAllowed"),
        };

        if !ok || close_conn {
            return;
        }
    }
}

fn handle_put(
    writer: &mut TcpStream,
    state: &PeerState,
    path: &str,
    content_length: usize,
    if_none_match_star: bool,
) -> bool {
    let ephemeral = path.contains("/ephemeral/");
    if !ephemeral {
        let mut map = state.objects.write().expect("objects write lock");
        if if_none_match_star && map.contains_key(path) {
            return write_error(writer, 412, "PreconditionFailed");
        }
        if map.len() < 8192 {
            map.insert(
                path.to_string(),
                StoredObject {
                    size: content_length.min(MAX_SEED_BYTES),
                    etag: ETAG_STR.to_string(),
                    version: VERSION_STR.to_string(),
                },
            );
        }
    }

    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nETag: {ETAG_STR}\r\nx-amz-version-id: {VERSION_STR}\r\nx-amz-server-side-encryption: AES256\r\nx-amz-request-id: req-put\r\n\r\n"
    );
    writer.write_all(resp.as_bytes()).is_ok()
}

fn handle_head(
    writer: &mut TcpStream,
    state: &PeerState,
    path: &str,
    if_match: Option<&str>,
) -> bool {
    let obj = {
        let map = state.objects.read().expect("objects read lock");
        map.get(path).cloned()
    };
    let Some(obj) = obj else {
        return write_head_status(writer, 404);
    };
    if let Some(expected) = if_match {
        if expected != obj.etag {
            return write_head_status(writer, 412);
        }
    }
    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: {}\r\nx-amz-version-id: {}\r\nx-amz-server-side-encryption: AES256\r\nx-amz-request-id: req-head\r\n\r\n",
        obj.size, obj.etag, obj.version
    );
    writer.write_all(resp.as_bytes()).is_ok()
}

fn handle_get(
    writer: &mut TcpStream,
    state: &PeerState,
    path: &str,
    if_match: Option<&str>,
    range_header: Option<&str>,
) -> bool {
    let obj = {
        let map = state.objects.read().expect("objects read lock");
        map.get(path).cloned()
    };
    let Some(obj) = obj else {
        return write_error(writer, 404, "NoSuchKey");
    };
    if let Some(expected) = if_match {
        if expected != obj.etag {
            return write_error(writer, 412, "PreconditionFailed");
        }
    }

    if let Some(raw_range) = range_header {
        let Some((first, last)) = parse_byte_range(raw_range, obj.size) else {
            return write_error(writer, 416, "InvalidRange");
        };
        let slice = &state.seed[first..=last];
        let header = format!(
            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nETag: {}\r\nx-amz-version-id: {}\r\nx-amz-server-side-encryption: AES256\r\nx-amz-request-id: req-get\r\n\r\n",
            slice.len(),
            first,
            last,
            obj.size,
            obj.etag,
            obj.version
        );
        writer.write_all(header.as_bytes()).is_ok() && writer.write_all(slice).is_ok()
    } else {
        let slice = &state.seed[..obj.size];
        let header = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: {}\r\nx-amz-version-id: {}\r\nx-amz-server-side-encryption: AES256\r\nx-amz-request-id: req-get\r\n\r\n",
            slice.len(),
            obj.etag,
            obj.version
        );
        writer.write_all(header.as_bytes()).is_ok() && writer.write_all(slice).is_ok()
    }
}

fn parse_byte_range(header: &str, total: usize) -> Option<(usize, usize)> {
    let spec = header.strip_prefix("bytes=")?;
    let (start_s, end_s) = spec.split_once('-')?;
    let first: usize = start_s.parse().ok()?;
    let last: usize = end_s.parse().ok()?;
    if first <= last && last < total {
        Some((first, last))
    } else {
        None
    }
}

fn write_head_status(writer: &mut TcpStream, status: u16) -> bool {
    let resp = format!("HTTP/1.1 {status} Error\r\nContent-Length: 0\r\n\r\n");
    writer.write_all(resp.as_bytes()).is_ok()
}

fn write_error(writer: &mut TcpStream, status: u16, code: &str) -> bool {
    let body = format!("<Error><Code>{code}</Code></Error>");
    let resp = format!(
        "HTTP/1.1 {status} Error\r\nContent-Type: application/xml\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    writer.write_all(resp.as_bytes()).is_ok()
}

fn run_native(mut args: impl Iterator<Item = String>) {
    let mut port: u16 = 0;
    let mut op = String::from("put");
    let mut size: usize = 4_194_304;
    let mut range_len: usize = 4_194_304;
    let mut concurrency: usize = 4;
    let mut buffer_size: usize = 4_194_304;
    let mut warmup_ms: u64 = 1_000;
    let mut duration_ms: u64 = 3_000;

    while let Some(flag) = args.next() {
        let val = args.next().expect("flag value");
        match flag.as_str() {
            "--port" => port = val.parse().expect("port"),
            "--op" => op = val,
            "--size" => size = val.parse().expect("size"),
            "--range-len" => range_len = val.parse().expect("range-len"),
            "--concurrency" => concurrency = val.parse().expect("concurrency"),
            "--buffer-size" => buffer_size = val.parse().expect("buffer-size"),
            "--warmup-ms" => warmup_ms = val.parse().expect("warmup-ms"),
            "--duration-ms" => duration_ms = val.parse().expect("duration-ms"),
            other => panic!("unknown native flag: {other}"),
        }
    }

    let credentials = Credentials::new(ACCESS_KEY, SECRET_KEY).expect("valid synthetic creds");
    let mut builder = Builder::new("127.0.0.1", REGION, credentials);
    builder.port = port;
    builder.tls = false;
    builder.bucket_in_path = Some(BUCKET.to_string());
    builder.address = Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port));
    builder.threads = 1;
    builder.buffers = concurrency as u32;
    builder.connections = concurrency as u32;
    builder.operations = concurrency as u32;
    builder.buffer_size = buffer_size as u32;

    let client = builder.build().expect("native Longshore client build");
    let seed = Arc::new(build_seed_buffer());
    let dummy_sha256 = [0x42u8; 32];
    let put_opts = Put {
        no_clobber: true,
        encryption: Some(Encryption::Aes256),
        checksum: Checksum::Sha256(dummy_sha256),
    };
    let expect = Expect {
        etag: ETag::new(ETAG_STR.as_bytes()),
        version: VersionId::new(VERSION_STR.as_bytes()),
    };

    let barrier = Arc::new(Barrier::new(concurrency + 1));
    let measuring = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));

    let ok_ops = Arc::new(AtomicU64::new(0));
    let failed_ops = Arc::new(AtomicU64::new(0));
    let not_sent_ops = Arc::new(AtomicU64::new(0));
    let unknown_ops = Arc::new(AtomicU64::new(0));
    let sent_attempts = Arc::new(AtomicU64::new(0));
    let payload_bytes = Arc::new(AtomicU64::new(0));
    let samples: Arc<Mutex<Vec<u64>>> = Arc::new(Mutex::new(Vec::new()));

    let mut handles = Vec::with_capacity(concurrency);
    for worker_id in 0..concurrency {
        let client = client.clone();
        let seed = seed.clone();
        let op_name = op.clone();
        let barrier = barrier.clone();
        let measuring = measuring.clone();
        let stop = stop.clone();
        let ok_ops = ok_ops.clone();
        let failed_ops = failed_ops.clone();
        let not_sent_ops = not_sent_ops.clone();
        let unknown_ops = unknown_ops.clone();
        let sent_attempts = sent_attempts.clone();
        let payload_bytes = payload_bytes.clone();
        let samples = samples.clone();

        handles.push(std::thread::spawn(move || {
            let mut local_samples = Vec::with_capacity(8192);
            let mut seq: u64 = 0;
            let seeded_key = format!("seeded/{size}.bin");
            barrier.wait();

            while !stop.load(Ordering::Relaxed) {
                seq += 1;
                let t0 = Instant::now();
                let budget = Budget::once(t0 + Duration::from_secs(30));

                let (success, xfer_bytes, sent, not_sent, unknown) = match op_name.as_str() {
                    "put" => {
                        let mut buffer = client.buffer_blocking();
                        buffer.as_mut_slice()[..size].copy_from_slice(&seed[..size]);
                        let key = format!("ephemeral/native-w{worker_id}-{seq}.bin");
                        let (res, _buf) = client.put(&key, buffer, size, &put_opts, budget).wait();
                        match res {
                            Ok(report) => match report.end {
                                End::Answered(ans)
                                    if ans.status == 200
                                        && !ans.malformed
                                        && ans.encryption == Some(ServerEncryption::Aes256) =>
                                {
                                    (true, size as u64, report.sent as u64, 0, 0)
                                }
                                End::NotSent(_) => (false, 0, report.sent as u64, 1, 0),
                                End::Unknown(_) => (false, 0, report.sent as u64, 0, 1),
                                _ => (false, 0, report.sent as u64, 0, 0),
                            },
                            Err(_) => (false, 0, 0, 1, 0),
                        }
                    }
                    "head" => match client.head(&seeded_key, &expect, budget).wait() {
                        Ok(report) => match report.end {
                            End::Answered(ans)
                                if ans.status == 200
                                    && !ans.malformed
                                    && ans.content_length == Some(size as u64) =>
                            {
                                (true, 0, report.sent as u64, 0, 0)
                            }
                            End::NotSent(_) => (false, 0, report.sent as u64, 1, 0),
                            End::Unknown(_) => (false, 0, report.sent as u64, 0, 1),
                            _ => (false, 0, report.sent as u64, 0, 0),
                        },
                        Err(_) => (false, 0, 0, 1, 0),
                    },
                    "get_range" => {
                        let buffer = client.buffer_blocking();
                        let last = (range_len - 1) as u64;
                        let (res, buf) = client
                            .get(&seeded_key, Some((0, last)), &expect, buffer, budget)
                            .wait();
                        match res {
                            Ok(report) => match report.end {
                                End::Answered(ans)
                                    if ans.status == 206
                                        && !ans.malformed
                                        && ans.body_len as usize == range_len
                                        && ans.content_range
                                            == Some(ContentRange {
                                                first: 0,
                                                last,
                                                size: Some(size as u64),
                                            })
                                        && buf.as_slice()[0] == seed[0]
                                        && buf.as_slice()[range_len - 1] == seed[range_len - 1] =>
                                {
                                    (true, range_len as u64, report.sent as u64, 0, 0)
                                }
                                End::NotSent(_) => (false, 0, report.sent as u64, 1, 0),
                                End::Unknown(_) => (false, 0, report.sent as u64, 0, 1),
                                _ => (false, 0, report.sent as u64, 0, 0),
                            },
                            Err(_) => (false, 0, 0, 1, 0),
                        }
                    }
                    other => panic!("unsupported --op {other}"),
                };

                let elapsed_us = t0.elapsed().as_micros() as u64;
                if measuring.load(Ordering::Acquire) {
                    sent_attempts.fetch_add(sent, Ordering::Relaxed);
                    if success {
                        ok_ops.fetch_add(1, Ordering::Relaxed);
                        payload_bytes.fetch_add(xfer_bytes, Ordering::Relaxed);
                        local_samples.push(elapsed_us);
                    } else {
                        failed_ops.fetch_add(1, Ordering::Relaxed);
                        not_sent_ops.fetch_add(not_sent, Ordering::Relaxed);
                        unknown_ops.fetch_add(unknown, Ordering::Relaxed);
                    }
                }
            }

            samples.lock().expect("samples lock").extend(local_samples);
        }));
    }

    barrier.wait();
    if warmup_ms > 0 {
        std::thread::sleep(Duration::from_millis(warmup_ms));
    }

    let cpu_before = process_cpu_seconds();
    let wall_start = Instant::now();
    measuring.store(true, Ordering::Release);
    std::thread::sleep(Duration::from_millis(duration_ms));
    measuring.store(false, Ordering::Release);
    let wall_s = wall_start.elapsed().as_secs_f64();
    let cpu_s = (process_cpu_seconds() - cpu_before).max(0.0);

    stop.store(true, Ordering::Release);
    for h in handles {
        let _ = h.join();
    }
    drop(client);

    let mut all_samples = samples.lock().expect("samples").clone();
    all_samples.sort_unstable();
    let ok = ok_ops.load(Ordering::Relaxed);
    let failed = failed_ops.load(Ordering::Relaxed);
    let not_sent = not_sent_ops.load(Ordering::Relaxed);
    let unknown = unknown_ops.load(Ordering::Relaxed);
    let sent = sent_attempts.load(Ordering::Relaxed);
    let bytes = payload_bytes.load(Ordering::Relaxed);

    let goodput_mb_s = (bytes as f64) / wall_s / 1_000_000.0;
    let ops_per_s = (ok as f64) / wall_s;
    let gib = (bytes as f64) / (1024.0 * 1024.0 * 1024.0);
    let cpu_s_per_gib = if gib > 0.0 { cpu_s / gib } else { 0.0 };
    let (rss_kib, hwm_kib) = process_memory_kib();
    let memlock = read_memlock_limit();
    let kernel = read_kernel_release();

    println!(
        "{{\"layer\":\"native\",\"op\":\"{op}\",\"size_bytes\":{size},\"range_bytes\":{range_len},\"concurrency\":{concurrency},\"buffer_size\":{buffer_size},\"duration_s\":{wall_s:.6},\"ok_ops\":{ok},\"failed_ops\":{failed},\"not_sent_ops\":{not_sent},\"unknown_ops\":{unknown},\"sent_attempts\":{sent},\"payload_bytes\":{bytes},\"goodput_mb_s\":{goodput_mb_s:.3},\"ops_per_s\":{ops_per_s:.2},\"cpu_seconds\":{cpu_s:.6},\"cpu_s_per_gib\":{cpu_s_per_gib:.6},\"rss_kib\":{rss_kib},\"hwm_kib\":{hwm_kib},\"memlock_limit\":\"{memlock}\",\"kernel\":\"{kernel}\",\"n\":{},\"min_us\":{},\"p50_us\":{},\"p95_us\":{},\"p99_us\":{},\"max_us\":{}}}",
        all_samples.len(),
        percentile(&all_samples, 0.0),
        percentile(&all_samples, 0.50),
        percentile(&all_samples, 0.95),
        percentile(&all_samples, 0.99),
        percentile(&all_samples, 1.0),
    );
}

fn percentile(sorted: &[u64], q: f64) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    if q <= 0.0 {
        return sorted[0];
    }
    if q >= 1.0 {
        return *sorted.last().unwrap();
    }
    let idx = ((sorted.len() - 1) as f64 * q).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

fn process_cpu_seconds() -> f64 {
    let Ok(stat) = std::fs::read_to_string("/proc/self/stat") else {
        return 0.0;
    };
    let Some((_, rest)) = stat.rsplit_once(')') else {
        return 0.0;
    };
    let fields: Vec<&str> = rest.split_whitespace().collect();
    if fields.len() < 13 {
        return 0.0;
    }
    let utime: u64 = fields[11].parse().unwrap_or(0);
    let stime: u64 = fields[12].parse().unwrap_or(0);
    // Linux USER_HZ in /proc/[pid]/stat is fixed at 100 ticks/sec on x86_64/aarch64.
    (utime + stime) as f64 / 100.0
}

fn process_memory_kib() -> (u64, u64) {
    let Ok(status) = std::fs::read_to_string("/proc/self/status") else {
        return (0, 0);
    };
    let mut rss = 0u64;
    let mut hwm = 0u64;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            rss = rest
                .split_whitespace()
                .next()
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
        } else if let Some(rest) = line.strip_prefix("VmHWM:") {
            hwm = rest
                .split_whitespace()
                .next()
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
        }
    }
    (rss, hwm)
}

fn read_memlock_limit() -> String {
    let Ok(limits) = std::fs::read_to_string("/proc/self/limits") else {
        return "unknown".to_string();
    };
    for line in limits.lines() {
        if let Some(rest) = line.strip_prefix("Max locked memory") {
            let cols: Vec<&str> = rest.split_whitespace().collect();
            if cols.len() >= 2 {
                return format!("soft={} hard={}", cols[0], cols[1]);
            }
        }
    }
    "unknown".to_string()
}

fn read_kernel_release() -> String {
    std::fs::read_to_string("/proc/sys/kernel/osrelease")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}
