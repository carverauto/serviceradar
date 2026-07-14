//! Demonstrates the difference between NetflowParser and AutoScopedParser
//! for multi-source deployments.
//!
//! This example shows why AutoScopedParser is essential when parsing NetFlow
//! from multiple routers to prevent template cache collisions.

use netflow_parser::{AutoScopedParser, NetflowParser};
use std::net::SocketAddr;

fn main() {
    println!("╔═══════════════════════════════════════════════════════════╗");
    println!("║  NetFlow Multi-Source Parsing Comparison                 ║");
    println!("╚═══════════════════════════════════════════════════════════╝\n");

    // Simulate multiple routers
    let sources = vec![
        "192.168.1.1:2055",
        "192.168.1.2:2055",
        "192.168.1.3:2055",
        "192.168.1.4:2055",
        "192.168.1.5:2055",
    ];

    demo_single_parser(&sources);
    println!();
    demo_scoped_parser(&sources);
}

fn demo_single_parser(sources: &[&str]) {
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("❌ NetflowParser (NOT recommended for multi-source)");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    let mut parser = NetflowParser::default();

    println!("Scenario: {} routers each send V5 packets", sources.len());
    println!("(In real V9/IPFIX, templates would collide)\n");

    for (i, source) in sources.iter().enumerate() {
        let packet = create_v5_packet();
        let _ = parser.parse_bytes(&packet);
        println!("  ✓ Parsed packet from router {} ({})", i + 1, source);
    }

    let v9_info = parser.v9_cache_info();
    let ipfix_info = parser.ipfix_cache_info();

    println!("\nCache Statistics:");
    println!(
        "  V9 Templates:    {}/{}",
        v9_info.current_size, v9_info.max_size_per_cache
    );
    println!(
        "  IPFIX Templates: {}/{}",
        ipfix_info.current_size, ipfix_info.max_size_per_cache
    );
    println!("  V9 Collisions:   {}", v9_info.metrics.collisions);
    println!("  IPFIX Collisions: {}", ipfix_info.metrics.collisions);

    println!("\n⚠️  Problem: With V9/IPFIX templates, the same template ID");
    println!("   from different routers would overwrite each other!");
    println!("   Result: Cache thrashing and parsing failures.");
}

fn demo_scoped_parser(sources: &[&str]) {
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("✅ AutoScopedParser (RECOMMENDED for multi-source)");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    let mut parser = AutoScopedParser::new();

    println!("Scenario: {} routers each send V5 packets", sources.len());
    println!("Each router gets isolated template cache\n");

    for (i, source) in sources.iter().enumerate() {
        let addr: SocketAddr = source.parse().unwrap();
        let packet = create_v5_packet();
        let _ = parser.parse_from_source(addr, &packet);
        println!("  ✓ Parsed packet from router {} ({})", i + 1, source);
    }

    println!("\nCache Statistics:");
    println!("  Total Sources: {}", parser.source_count());
    println!("  V9 Sources:    {}", parser.v9_source_count());
    println!("  IPFIX Sources: {}", parser.ipfix_source_count());

    println!("\n✅ Benefits:");
    println!("   • Each router has isolated template cache");
    println!("   • No template ID collisions possible");
    println!("   • RFC 3954 (V9) & RFC 7011 (IPFIX) compliant");
    println!("   • Better cache hit rates = better performance");
}

fn create_v5_packet() -> Vec<u8> {
    // NetFlow V5 packet with 1 flow
    vec![
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ]
}
