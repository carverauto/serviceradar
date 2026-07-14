//! Example demonstrating template management features
//!
//! This example shows:
//! - Template cache metrics tracking
//! - Multi-source parser with RouterScopedParser
//! - Template collision detection
//! - Handling missing templates
//! - Template lifecycle management

use netflow_parser::variable_versions::ipfix::FlowSetBody;
use netflow_parser::variable_versions::ttl::TtlConfig;
use netflow_parser::{NetflowPacket, NetflowParser, RouterScopedParser};
use std::net::SocketAddr;
use std::time::Duration;

fn main() {
    println!("=== Template Management Demo ===\n");

    // Demo 1: Template Cache Metrics
    demo_cache_metrics();

    println!("\n{}\n", "=".repeat(50));

    // Demo 2: Multi-Source Deployment
    demo_multi_source();

    println!("\n{}\n", "=".repeat(50));

    // Demo 3: Template Collision Detection
    demo_collision_detection();

    println!("\n{}\n", "=".repeat(50));

    // Demo 4: Handling Missing Templates
    demo_missing_templates();

    println!("\n{}\n", "=".repeat(50));

    // Demo 5: Template Lifecycle Management
    demo_template_lifecycle();
}

fn demo_cache_metrics() {
    println!("Demo 1: Template Cache Metrics");
    println!("-------------------------------");

    let mut parser = NetflowParser::default();

    // Simulate parsing some packets (in real scenario, use actual NetFlow data)
    let dummy_data = vec![0u8; 100];
    let _ = parser.parse_bytes(&dummy_data).packets;

    // Get cache statistics
    let v9_info = parser.v9_cache_info();
    let _ipfix_info = parser.ipfix_cache_info();

    println!("\nV9 Cache Statistics:");
    println!(
        "  Current size: {}/{}",
        v9_info.current_size, v9_info.max_size_per_cache
    );
    println!(
        "  Utilization: {:.1}%",
        (v9_info.current_size as f64 / v9_info.max_size_per_cache as f64) * 100.0
    );

    let metrics = &v9_info.metrics;
    println!("\nPerformance Metrics:");
    println!("  Hits:       {}", metrics.hits);
    println!("  Misses:     {}", metrics.misses);
    println!("  Evictions:  {}", metrics.evictions);
    println!("  Collisions: {}", metrics.collisions);
    println!("  Expired:    {}", metrics.expired);
    println!("  Insertions: {}", metrics.insertions);

    if let Some(hit_rate) = metrics.hit_rate() {
        println!("\n  Hit Rate:   {:.2}%", hit_rate * 100.0);
    }

    if metrics.collisions > 0 {
        println!("\n⚠️  Warning: Template collisions detected!");
        println!("   Consider using RouterScopedParser for multi-source deployments.");
    }
}

fn demo_multi_source() {
    println!("Demo 2: Multi-Source Deployment with RouterScopedParser");
    println!("-------------------------------------------------------");

    // Create a scoped parser with custom configuration
    let builder = NetflowParser::builder()
        .with_cache_size(2000)
        .with_ttl(TtlConfig::new(Duration::from_secs(3600)));

    let mut scoped_parser =
        RouterScopedParser::<SocketAddr>::try_with_builder(builder).expect("valid config");

    // Simulate data from multiple routers
    let router1: SocketAddr = "192.168.1.1:2055".parse().unwrap();
    let router2: SocketAddr = "192.168.1.2:2055".parse().unwrap();
    let router3: SocketAddr = "192.168.1.3:2055".parse().unwrap();

    let dummy_data = vec![0u8; 100];

    println!("\nParsing packets from multiple routers...");
    let _ = scoped_parser.parse_from_source(router1, &dummy_data);
    let _ = scoped_parser.parse_from_source(router2, &dummy_data);
    let _ = scoped_parser.parse_from_source(router3, &dummy_data);

    println!("Active sources: {}", scoped_parser.source_count());
    println!("\nRegistered routers:");
    for source in scoped_parser.sources() {
        println!("  - {}", source);
    }

    // Get statistics per source
    println!("\nPer-Source Statistics:");
    for (source, stats) in scoped_parser.all_info() {
        println!("\n  Router: {}", source);
        println!(
            "    V9 templates:    {}/{}",
            stats.v9.current_size, stats.v9.max_size_per_cache
        );
        println!(
            "    IPFIX templates: {}/{}",
            stats.ipfix.current_size, stats.ipfix.max_size_per_cache
        );
        println!(
            "    V9 hit rate:     {:.2}%",
            stats.v9.metrics.hit_rate().unwrap_or(0.0) * 100.0
        );
    }

    // Demonstrate source cleanup
    println!("\nRemoving inactive source: {}", router3);
    scoped_parser.remove_source(&router3);
    println!("Active sources: {}", scoped_parser.source_count());
}

fn demo_collision_detection() {
    println!("Demo 3: Template Collision Detection");
    println!("------------------------------------");

    let mut parser = NetflowParser::default();

    // In a real scenario, parsing packets with duplicate template IDs
    // from different sources would trigger collision detection

    let dummy_data = vec![0u8; 100];
    let _ = parser.parse_bytes(&dummy_data).packets;

    let v9_info = parser.v9_cache_info();

    println!("\nCollision Monitoring:");
    println!("  Total collisions: {}", v9_info.metrics.collisions);

    if v9_info.metrics.collisions > 0 {
        let collision_rate =
            v9_info.metrics.collisions as f64 / v9_info.metrics.insertions.max(1) as f64;
        println!("  Collision rate:   {:.2}%", collision_rate * 100.0);

        println!("\n⚠️  Recommendations:");
        println!("   1. Use RouterScopedParser to isolate templates per source");
        println!("   2. Monitor which sources are causing collisions");
        println!("   3. Increase cache size if templates are being evicted prematurely");
    } else {
        println!("  ✓ No collisions detected - templates are properly isolated");
    }
}

fn demo_missing_templates() {
    println!("Demo 4: Handling Missing Templates");
    println!("----------------------------------");

    let mut parser = NetflowParser::default();

    // In a real scenario, this would be actual IPFIX data
    let dummy_data = vec![0u8; 100];
    let mut pending_data = Vec::new();

    println!("\nProcessing IPFIX packets...");

    for result in parser.iter_packets(&dummy_data) {
        if let Ok(packet) = result
            && let NetflowPacket::IPFix(ipfix) = packet
        {
            for flowset in &ipfix.flowsets {
                if let FlowSetBody::NoTemplate(info) = &flowset.body {
                    println!("\n⚠️  Missing template ID: {}", info.template_id);
                    println!("   Data size: {} bytes", info.raw_data.len());

                    // Save for retry
                    pending_data.push(info.raw_data.clone());
                }
            }
        }
    }

    if pending_data.is_empty() {
        println!("\n✓ All templates were available");
    } else {
        println!("\nSaved {} flowsets for retry", pending_data.len());
        println!("\nStrategy for missing templates:");
        println!("  1. Cache data flowsets that arrive before templates");
        println!("  2. Continue processing subsequent packets");
        println!("  3. Retry cached data after template packets arrive");
        println!("  4. Monitor miss rate to detect template delivery issues");
    }
}

fn demo_template_lifecycle() {
    println!("Demo 5: Template Lifecycle Management");
    println!("-------------------------------------");

    let mut parser = NetflowParser::builder()
        .with_cache_size(500)
        .with_ttl(TtlConfig::new(Duration::from_secs(7200)))
        .build()
        .unwrap();

    // Simulate some parsing
    let dummy_data = vec![0u8; 100];
    let _ = parser.parse_bytes(&dummy_data).packets;

    println!("\nTemplate Cache Inspection:");

    // Check specific templates
    let test_template_id = 256u16;
    if parser.has_v9_template(test_template_id) {
        println!("  ✓ Template {} is cached", test_template_id);
    } else {
        println!("  ✗ Template {} not found", test_template_id);
    }

    // List all cached templates
    let v9_templates = parser.v9_template_ids();
    let ipfix_templates = parser.ipfix_template_ids();

    println!("\n  V9 templates:    {} cached", v9_templates.len());
    if !v9_templates.is_empty() {
        println!("    IDs: {:?}", v9_templates);
    }

    println!("  IPFIX templates: {} cached", ipfix_templates.len());
    if !ipfix_templates.is_empty() {
        println!("    IDs: {:?}", ipfix_templates);
    }

    // Cache management
    println!("\nCache Management Operations:");

    let stats_before = parser.v9_cache_info();
    println!("  Templates before clear: {}", stats_before.current_size);

    // Clear templates (useful for testing or forcing re-learning)
    parser.clear_v9_templates();
    parser.clear_ipfix_templates();

    let stats_after = parser.v9_cache_info();
    println!("  Templates after clear:  {}", stats_after.current_size);

    println!("\nCache Configuration:");
    println!("  Max cache size: {}", stats_before.max_size_per_cache);
    if let Some(ttl_config) = &stats_before.ttl_config {
        println!("  TTL configured: {:?}", ttl_config.duration);
    } else {
        println!("  TTL configured: None (templates persist until LRU eviction)");
    }

    println!("\nBest Practices:");
    println!("  ✓ Reuse parser instances to maximize cache hits");
    println!("  ✓ Monitor metrics to detect template delivery issues");
    println!("  ✓ Use RouterScopedParser for multi-source deployments");
    println!("  ✓ Configure TTL for long-running applications");
    println!("  ✓ Size cache based on actual template count");
}
