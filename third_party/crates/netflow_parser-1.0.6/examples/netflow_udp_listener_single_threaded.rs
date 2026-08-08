use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

use netflow_parser::variable_versions::ttl::TtlConfig;
use netflow_parser::{NetflowParser, RouterScopedParser};

fn main() {
    // Create a RouterScopedParser with custom configuration
    // This automatically manages separate template caches per source address
    let builder = NetflowParser::builder()
        .with_cache_size(2000)
        .with_ttl(TtlConfig::new(Duration::from_secs(3600)));

    let mut scoped_parser =
        RouterScopedParser::<SocketAddr>::try_with_builder(builder).expect("valid config");

    // Metrics tracking
    let mut packet_count = 0u64;
    let mut last_report = Instant::now();
    let report_interval = Duration::from_secs(5);

    println!("NetFlow UDP listener started on 127.0.0.1:9995");
    println!("Using RouterScopedParser for automatic per-source template isolation\n");

    // Socket is created once outside the loop for better performance
    let socket = UdpSocket::bind("127.0.0.1:9995").expect("couldn't bind to address");
    let mut buf = [0; 65_535];

    loop {
        let (number_of_bytes, src_addr) =
            socket.recv_from(&mut buf).expect("Didn't receive data");

        // Parse packets from this source using RouterScopedParser
        if let Ok(iter) =
            scoped_parser.iter_packets_from_source(src_addr, &buf[..number_of_bytes])
        {
            for packet in iter {
                println!("{:?}", packet);
                packet_count += 1;
            }
        }

        // Periodic metrics report
        if last_report.elapsed() >= report_interval {
            println!("\n=== Metrics Report ===");
            println!("Total packets processed: {}", packet_count);
            println!("Active sources: {}", scoped_parser.source_count());

            if scoped_parser.source_count() > 0 {
                println!("\nPer-Source Template Cache Stats:");
                for (source, stats) in scoped_parser.all_info() {
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

            last_report = Instant::now();
        }
    }
}
