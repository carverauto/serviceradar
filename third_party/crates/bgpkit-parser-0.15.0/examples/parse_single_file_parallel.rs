//! Parse a single RIB dump file in parallel with raw iterator and crossbeam.
//!
//! Pipeline:
//! 1) Producer scans a compressed RIB file with the raw iterator and batches RawMrtRecord.
//! 2) A pool of worker threads parses batches into MrtRecord in parallel.
//! 3) Collector receives parsed records, turns them into BgpElem via Elementor, and prints.
//!
//! Tuning via env vars:
//! - BATCH_SIZE: number of raw records per batch (default: 100)
//! - WORKERS: number of worker threads (default: available parallelism)

use bgpkit_parser::{BgpkitParser, Elementor, MrtRecord, RawMrtRecord};
use crossbeam_channel as channel;
use oneio::download;
use std::env;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

fn parse_env<T: std::str::FromStr>(key: &str, default: T) -> T {
    env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn parse_env_bool(key: &str, default: bool) -> bool {
    match env::var(key) {
        Ok(v) => matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"),
        Err(_) => default,
    }
}

fn main() {
    // Source can be overridden by first CLI arg; otherwise use a small demo RIB
    let src = env::args().nth(1).unwrap_or_else(|| {
        "https://data.ris.ripe.net/rrc00/2025.10/bview.20251009.0000.gz".to_string()
        // "http://spaces.bgpkit.org/parser/rib-example.bz2".to_string()
    });

    // Tunables
    let batch_size: usize = parse_env("BATCH_SIZE", 1000);
    let workers: usize = parse_env(
        "WORKERS",
        thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4),
    );

    // Step 1: resolve local path in current directory and download only if needed
    let download_start = Instant::now();

    // Determine local path:
    // - If src is http/https, save to current directory using the trailing filename
    // - Otherwise, treat src as a local path
    let local_path: PathBuf = if src.starts_with("http://") || src.starts_with("https://") {
        let file_name = src.rsplit('/').next().unwrap_or("download.mrt");
        std::env::current_dir()
            .expect("failed to get current directory")
            .join(file_name)
    } else {
        PathBuf::from(&src)
    };
    dbg!(&local_path);

    // Download only if remote and not already present
    let mut downloaded = false;
    if src.starts_with("http://") || src.starts_with("https://") {
        if !local_path.exists() {
            download(src.as_str(), local_path.to_str().unwrap(), None)
                .expect("failed to download source to local file");
            downloaded = true;
        } else {
            eprintln!(
                "file already exists locally, skipping download: {}",
                local_path.display()
            );
        }
    }
    let download_dur = if downloaded {
        download_start.elapsed()
    } else {
        Duration::from_secs(0)
    };

    // Step 2: Parallel pipeline over the local file, count elems and time it
    println!("Parsing local file in parallel...");
    let parallel_start = Instant::now();

    // Set up parser and raw iterator from local file
    let parser = BgpkitParser::new(local_path.to_str().unwrap()).expect("failed to create parser");
    let mut raw_iter = parser.into_raw_record_iter();

    // Consume first record (PeerIndexTable) for Elementor; metrics will include it.

    // Elementor requires the peer index table for TableDumpV2
    let mut elementor = Elementor::new();
    if let Some(raw_record) = raw_iter.next() {
        let record = raw_record
            .parse()
            .expect("failed to parse initial peer index table record");
        elementor
            .set_peer_table(record)
            .expect("first record is not a PeerIndexTable; this example expects a RIB file");
    } else {
        eprintln!("empty input: no records found");
        return;
    }

    // Pipeline options and metrics
    let elem_in_workers = parse_env_bool("ELEM_IN_WORKERS", false);
    let quiet_errors = parse_env_bool("QUIET_ERRORS", true);
    let chan_cap: usize = parse_env("CHAN_CAP", workers);

    let send_blocked_nanos = Arc::new(AtomicU64::new(0));
    let worker_parse_nanos = Arc::new(AtomicU64::new(0));
    let worker_elem_nanos = Arc::new(AtomicU64::new(0));
    let collector_elem_nanos = Arc::new(AtomicU64::new(0));
    let records_parsed = Arc::new(AtomicU64::new(0));

    // Include the initial PeerIndexTable record in the records count for consistency with parse-only runs.
    records_parsed.fetch_add(1, Ordering::Relaxed);

    // Channels: batches of RawMrtRecord
    let (batch_tx, batch_rx) = channel::bounded::<Vec<RawMrtRecord>>(chan_cap);

    // Depending on mode, set up downstream channel
    let mut parallel_elem_count: u64 = 0;

    if elem_in_workers {
        // Workers will parse and convert to elems, returning per-batch counts
        let (cnt_tx, cnt_rx) = channel::bounded::<u64>(chan_cap);

        // Spawn workers
        let mut handles = Vec::with_capacity(workers);
        for _ in 0..workers {
            let rx = batch_rx.clone();
            let tx = cnt_tx.clone();
            let parse_ns = Arc::clone(&worker_parse_nanos);
            let elem_ns = Arc::clone(&worker_elem_nanos);
            let recs = Arc::clone(&records_parsed);
            // Each worker has its own Elementor configured with the peer table
            let mut elem_clone = elementor.clone();
            let handle = thread::spawn(move || {
                while let Ok(batch) = rx.recv() {
                    let mut batch_count: u64 = 0;
                    for raw in batch {
                        let t0 = Instant::now();
                        match raw.parse() {
                            Ok(rec) => {
                                let parse_elapsed = t0.elapsed();
                                parse_ns
                                    .fetch_add(parse_elapsed.as_nanos() as u64, Ordering::Relaxed);
                                recs.fetch_add(1, Ordering::Relaxed);

                                let t1 = Instant::now();
                                let cnt = elem_clone.record_to_elems(rec).len() as u64;
                                let elem_elapsed = t1.elapsed();
                                elem_ns
                                    .fetch_add(elem_elapsed.as_nanos() as u64, Ordering::Relaxed);
                                batch_count += cnt;
                            }
                            Err(e) => {
                                if !quiet_errors {
                                    eprintln!("worker parse error: {e}");
                                }
                            }
                        }
                    }
                    // Ignore send errors if collector exited
                    let _ = tx.send(batch_count);
                }
            });
            handles.push(handle);
        }
        drop(cnt_tx);

        // Producer: scan remaining raw records, batch, and send to workers
        let send_block_ns = Arc::clone(&send_blocked_nanos);
        let producer = thread::spawn(move || {
            let mut batch = Vec::with_capacity(batch_size);
            for raw in raw_iter {
                batch.push(raw);
                if batch.len() >= batch_size {
                    let s0 = Instant::now();
                    if batch_tx.send(batch).is_err() {
                        return; // collector or workers gone
                    }
                    let s_elapsed = s0.elapsed();
                    send_block_ns.fetch_add(s_elapsed.as_nanos() as u64, Ordering::Relaxed);
                    batch = Vec::with_capacity(batch_size);
                }
            }
            if !batch.is_empty() {
                let s0 = Instant::now();
                let _ = batch_tx.send(batch);
                let s_elapsed = s0.elapsed();
                send_block_ns.fetch_add(s_elapsed.as_nanos() as u64, Ordering::Relaxed);
            }
            // close channel so workers can finish
            drop(batch_tx);
        });

        // Collector: sum counts
        while let Ok(cnt) = cnt_rx.recv() {
            parallel_elem_count += cnt;
        }

        // Ensure producer and workers are done
        let _ = producer.join();
        for h in handles {
            let _ = h.join();
        }
    } else {
        // Original behavior: workers only parse to MrtRecord, collector converts to elems
        let (parsed_tx, parsed_rx) = channel::bounded::<Vec<MrtRecord>>(chan_cap);

        // Spawn workers
        let mut handles = Vec::with_capacity(workers);
        for _ in 0..workers {
            let rx = batch_rx.clone();
            let tx = parsed_tx.clone();
            let parse_ns = Arc::clone(&worker_parse_nanos);
            let recs = Arc::clone(&records_parsed);
            let handle = thread::spawn(move || {
                while let Ok(batch) = rx.recv() {
                    let mut out = Vec::with_capacity(batch.len());
                    for raw in batch {
                        let t0 = Instant::now();
                        match raw.parse() {
                            Ok(rec) => {
                                let parse_elapsed = t0.elapsed();
                                parse_ns
                                    .fetch_add(parse_elapsed.as_nanos() as u64, Ordering::Relaxed);
                                recs.fetch_add(1, Ordering::Relaxed);
                                out.push(rec)
                            }
                            Err(e) => {
                                if !quiet_errors {
                                    eprintln!("worker parse error: {e}");
                                }
                            }
                        }
                    }
                    if !out.is_empty() {
                        // Ignore send errors if collector has exited
                        let _ = tx.send(out);
                    }
                }
            });
            handles.push(handle);
        }
        // Drop the extra sender in this scope so channel closes when workers drop their clones
        drop(parsed_tx);

        // Producer: scan remaining raw records, batch, and send to workers
        let send_block_ns = Arc::clone(&send_blocked_nanos);
        let producer = thread::spawn(move || {
            let mut batch = Vec::with_capacity(batch_size);
            for raw in raw_iter {
                batch.push(raw);
                if batch.len() >= batch_size {
                    let s0 = Instant::now();
                    if batch_tx.send(batch).is_err() {
                        return; // collector or workers gone
                    }
                    let s_elapsed = s0.elapsed();
                    send_block_ns.fetch_add(s_elapsed.as_nanos() as u64, Ordering::Relaxed);
                    batch = Vec::with_capacity(batch_size);
                }
            }
            if !batch.is_empty() {
                let s0 = Instant::now();
                let _ = batch_tx.send(batch);
                let s_elapsed = s0.elapsed();
                send_block_ns.fetch_add(s_elapsed.as_nanos() as u64, Ordering::Relaxed);
            }
            // close channel so workers can finish
            drop(batch_tx);
        });

        // Collector on main thread: turn records into elems and count
        while let Ok(records) = parsed_rx.recv() {
            for rec in records {
                let t1 = Instant::now();
                let elems = elementor.record_to_elems(rec);
                let elap = t1.elapsed();
                collector_elem_nanos.fetch_add(elap.as_nanos() as u64, Ordering::Relaxed);
                parallel_elem_count += elems.len() as u64;
            }
        }

        // Ensure producer and workers are done
        let _ = producer.join();
        for h in handles {
            let _ = h.join();
        }
    }

    let parallel_dur = parallel_start.elapsed();

    // Step 3: Parallel parse-only (no Elementor) over the same local file
    println!("Parsing local file in parallel (parse-only)...");
    let po_parallel_start = Instant::now();
    let parser_po = BgpkitParser::new(local_path.to_str().unwrap())
        .expect("failed to create parser for parse-only parallel run");
    let raw_iter_po = parser_po.into_raw_record_iter();

    // Channels for parse-only pipeline
    let (batch_tx_po, batch_rx_po) = channel::bounded::<Vec<RawMrtRecord>>(chan_cap);
    let (cnt_tx_po, cnt_rx_po) = channel::bounded::<u64>(chan_cap);

    // Spawn parse-only workers
    let mut po_handles = Vec::with_capacity(workers);
    for _ in 0..workers {
        let rx = batch_rx_po.clone();
        let tx = cnt_tx_po.clone();
        let quiet = quiet_errors;
        let handle = thread::spawn(move || {
            while let Ok(batch) = rx.recv() {
                let mut cnt: u64 = 0;
                for raw in batch {
                    match raw.parse() {
                        Ok(_rec) => {
                            cnt += 1;
                        }
                        Err(e) => {
                            if !quiet {
                                eprintln!("worker parse error (parse-only): {e}");
                            }
                        }
                    }
                }
                let _ = tx.send(cnt);
            }
        });
        po_handles.push(handle);
    }
    drop(cnt_tx_po);

    // Producer for parse-only
    let producer_po = thread::spawn(move || {
        let mut batch = Vec::with_capacity(batch_size);
        for raw in raw_iter_po {
            batch.push(raw);
            if batch.len() >= batch_size {
                if batch_tx_po.send(batch).is_err() {
                    return;
                }
                batch = Vec::with_capacity(batch_size);
            }
        }
        if !batch.is_empty() {
            let _ = batch_tx_po.send(batch);
        }
        drop(batch_tx_po);
    });

    let mut parse_only_parallel_count: u64 = 0;
    while let Ok(c) = cnt_rx_po.recv() {
        parse_only_parallel_count += c;
    }
    let _ = producer_po.join();
    for h in po_handles {
        let _ = h.join();
    }
    let parse_only_parallel_dur = po_parallel_start.elapsed();

    // Step 4: Sequential parse-only run (no Elementor)
    println!("Parsing local file sequentially (parse-only)...");
    let po_seq_start = Instant::now();
    let mut po_seq_count: u64 = 0;
    let po_seq_iter = BgpkitParser::new(local_path.to_str().unwrap())
        .expect("failed to create parser for parse-only sequential run")
        .into_raw_record_iter();
    for raw in po_seq_iter {
        if raw.parse().is_ok() {
            po_seq_count += 1;
        }
    }
    let parse_only_sequential_dur = po_seq_start.elapsed();

    // Step 5: Sequential processing using regular iterator (with Elementor) over the same local file
    println!("Parsing local file sequentially (with Elementor)...");
    let sequential_start = Instant::now();
    let sequential_elem_count: usize = BgpkitParser::new(local_path.to_str().unwrap())
        .expect("failed to create parser for sequential run")
        .into_iter()
        .count();
    let sequential_dur = sequential_start.elapsed();

    // Report summary
    let file_size = std::fs::metadata(&local_path).map(|m| m.len()).unwrap_or(0);
    let worker_parse_s = (worker_parse_nanos.load(Ordering::Relaxed) as f64) / 1e9;
    let worker_elem_s = (worker_elem_nanos.load(Ordering::Relaxed) as f64) / 1e9;
    let collector_elem_s = (collector_elem_nanos.load(Ordering::Relaxed) as f64) / 1e9;
    let send_blocked_s = (send_blocked_nanos.load(Ordering::Relaxed) as f64) / 1e9;
    let recs = records_parsed.load(Ordering::Relaxed);

    println!(
        "Summary:\n  Source: {}\n  Local file: {} ({} bytes)\n  Download time: {:.3?}\n\n  Parallel: elems={}, workers={}, batch_size={}, chan_cap={}, elem_in_workers={}, time={:.3?}, rate={:.2} elems/s\n  - worker_parse: {:.3}s, worker_elem: {:.3}s, collector_elem: {:.3}s, producer_send_blocked: {:.3}s, records: {}\n  Parallel (parse-only): records={}, workers={}, batch_size={}, chan_cap={}, time={:.3?}, rate={:.2} recs/s\n  Sequential (parse-only): records={}, time={:.3?}, rate={:.2} recs/s\n  Sequential: elems={}, time={:.3?}, rate={:.2} elems/s\n  Speedup (elems): x{:.2}\n  Speedup (parse-only): x{:.2}",
        src,
        local_path.display(),
        file_size,
        download_dur,
        parallel_elem_count,
        workers,
        batch_size,
        chan_cap,
        elem_in_workers,
        parallel_dur,
        (parallel_elem_count as f64) / parallel_dur.as_secs_f64(),
        worker_parse_s,
        worker_elem_s,
        collector_elem_s,
        send_blocked_s,
        recs,
        parse_only_parallel_count,
        workers,
        batch_size,
        chan_cap,
        parse_only_parallel_dur,
        (parse_only_parallel_count as f64) / parse_only_parallel_dur.as_secs_f64(),
        po_seq_count,
        parse_only_sequential_dur,
        (po_seq_count as f64) / parse_only_sequential_dur.as_secs_f64(),
        sequential_elem_count,
        sequential_dur,
        (sequential_elem_count as f64) / sequential_dur.as_secs_f64(),
        sequential_dur.as_secs_f64() / parallel_dur.as_secs_f64(),
        parse_only_sequential_dur.as_secs_f64() / parse_only_parallel_dur.as_secs_f64()
    );
}
