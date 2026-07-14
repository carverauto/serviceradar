use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use netflow_parser::variable_versions::ttl::TtlConfig;
use netflow_parser::{NetflowParser, RouterScopedParser};

fn main() {
    // Create a RouterScopedParser with custom configuration
    // Wrapped in Arc<Mutex<>> for thread-safe sharing
    let builder = NetflowParser::builder()
        .with_cache_size(2000)
        .with_ttl(TtlConfig::new(Duration::from_secs(3600)));

    let scoped_parser = Arc::new(Mutex::new(
        RouterScopedParser::<SocketAddr>::try_with_builder(builder).expect("valid config"),
    ));

    // Metrics tracking
    let packet_count = Arc::new(AtomicU64::new(0));

    // Spawn metrics reporter thread
    let parser_clone = scoped_parser.clone();
    let packet_count_clone = packet_count.clone();
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_secs(5));

            let total_packets = packet_count_clone.load(Ordering::Relaxed);
            println!("\n=== Metrics Report ===");
            println!("Total packets processed: {}", total_packets);

            let parser = parser_clone.lock().unwrap();
            println!("Active sources: {}", parser.source_count());

            if parser.source_count() > 0 {
                println!("\nPer-Source Template Cache Stats:");
                for (source, stats) in parser.all_info() {
                    println!("\n  Source: {}", source);

                    // V9 stats
                    println!(
                        "    V9 Cache: {}/{} templates",
                        stats.v9.current_size, stats.v9.max_size_per_cache
                    );
                    let v9_metrics = &stats.v9.metrics;
                    if let Some(hit_rate) = v9_metrics.hit_rate() {
                        println!(
                            "      Hit rate: {:.1}%, Hits: {}, Misses: {}",
                            hit_rate * 100.0,
                            v9_metrics.hits,
                            v9_metrics.misses
                        );
                    }
                    if v9_metrics.collisions > 0 {
                        println!("      ⚠️  Collisions: {}", v9_metrics.collisions);
                    }

                    // IPFIX stats
                    println!(
                        "    IPFIX Cache: {}/{} templates",
                        stats.ipfix.current_size, stats.ipfix.max_size_per_cache
                    );
                    let ipfix_metrics = &stats.ipfix.metrics;
                    if let Some(hit_rate) = ipfix_metrics.hit_rate() {
                        println!(
                            "      Hit rate: {:.1}%, Hits: {}, Misses: {}",
                            hit_rate * 100.0,
                            ipfix_metrics.hits,
                            ipfix_metrics.misses
                        );
                    }
                    if ipfix_metrics.collisions > 0 {
                        println!("      ⚠️  Collisions: {}", ipfix_metrics.collisions);
                    }
                }
            }
            println!("======================\n");
        }
    });

    println!("NetFlow UDP listener started on 127.0.0.1:9995");
    println!("Using RouterScopedParser with multi-threaded processing\n");

    let socket = UdpSocket::bind("127.0.0.1:9995").expect("couldn't bind to address");
    let mut buf = [0; 65_535];

    loop {
        let (number_of_bytes, src_addr) =
            socket.recv_from(&mut buf).expect("Didn't receive data");

        let data = buf[..number_of_bytes].to_vec();
        let parser_clone = scoped_parser.clone();
        let packet_count_clone = packet_count.clone();

        // Spawn thread to process packet without blocking receive loop
        thread::spawn(move || {
            let mut parser = parser_clone.lock().unwrap();
            let count = parser
                .iter_packets_from_source(src_addr, &data)
                .map(|iter| iter.count() as u64)
                .unwrap_or(0);

            if count > 0 {
                packet_count_clone.fetch_add(count, Ordering::Relaxed);
            }
        });
    }
}
