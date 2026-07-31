//! Demonstrates the template event hook system for monitoring template lifecycle events.
//!
//! This example shows how to register callbacks that are invoked when templates are
//! learned, collide, get evicted, expire, or when data arrives for missing templates.

use netflow_parser::{NetflowParser, TemplateEvent, TemplateProtocol};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

fn main() {
    println!("╔═══════════════════════════════════════════════════════════╗");
    println!("║  Template Event Hooks Demo                               ║");
    println!("╚═══════════════════════════════════════════════════════════╝\n");

    demo_basic_hooks();
    println!();
    demo_metrics_collection();
    println!();
    demo_logging_hooks();
    println!();
    demo_multiple_hooks();
}

fn demo_basic_hooks() {
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("📋 Basic Hook Registration");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    let mut parser = NetflowParser::builder()
        .on_template_event(|event| {
            match event {
                TemplateEvent::Learned {
                    template_id,
                    protocol,
                } => println!("  ✓ Learned template {:?} ({:?})", template_id, protocol),
                TemplateEvent::Collision {
                    template_id,
                    protocol,
                } => println!(
                    "  ⚠️  Collision on template {:?} ({:?})",
                    template_id, protocol
                ),
                TemplateEvent::Evicted {
                    template_id,
                    protocol,
                } => println!("  ♻️  Evicted template {:?} ({:?})", template_id, protocol),
                TemplateEvent::Expired {
                    template_id,
                    protocol,
                } => println!("  ⏰ Expired template {:?} ({:?})", template_id, protocol),
                TemplateEvent::MissingTemplate {
                    template_id,
                    protocol,
                } => println!("  ❌ Missing template {:?} ({:?})", template_id, protocol),
                _ => {}
            }
            Ok(())
        })
        .build()
        .unwrap();

    // Simulate template events
    println!("Simulating template events:\n");
    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });
    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(300),
        protocol: TemplateProtocol::Ipfix,
    });
    parser.trigger_template_event(TemplateEvent::Collision {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });
    parser.trigger_template_event(TemplateEvent::MissingTemplate {
        template_id: Some(400),
        protocol: TemplateProtocol::Ipfix,
    });
}

fn demo_metrics_collection() {
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("📊 Metrics Collection with Hooks");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    let learned_count = Arc::new(AtomicUsize::new(0));
    let collision_count = Arc::new(AtomicUsize::new(0));
    let missing_count = Arc::new(AtomicUsize::new(0));

    let lc = learned_count.clone();
    let cc = collision_count.clone();
    let mc = missing_count.clone();

    let mut parser = NetflowParser::builder()
        .on_template_event(move |event| {
            match event {
                TemplateEvent::Learned { .. } => {
                    lc.fetch_add(1, Ordering::SeqCst);
                }
                TemplateEvent::Collision { .. } => {
                    cc.fetch_add(1, Ordering::SeqCst);
                }
                TemplateEvent::MissingTemplate { .. } => {
                    mc.fetch_add(1, Ordering::SeqCst);
                }
                _ => {}
            }
            Ok(())
        })
        .build()
        .unwrap();

    println!("Collecting metrics during template operations...\n");

    // Simulate various events
    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });
    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(300),
        protocol: TemplateProtocol::Ipfix,
    });
    parser.trigger_template_event(TemplateEvent::Collision {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });
    parser.trigger_template_event(TemplateEvent::MissingTemplate {
        template_id: Some(400),
        protocol: TemplateProtocol::Ipfix,
    });
    parser.trigger_template_event(TemplateEvent::MissingTemplate {
        template_id: Some(500),
        protocol: TemplateProtocol::V9,
    });

    println!("📈 Metrics Summary:");
    println!(
        "  Templates Learned:  {}",
        learned_count.load(Ordering::SeqCst)
    );
    println!(
        "  Template Collisions: {}",
        collision_count.load(Ordering::SeqCst)
    );
    println!(
        "  Missing Templates:  {}",
        missing_count.load(Ordering::SeqCst)
    );
}

fn demo_logging_hooks() {
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("📝 Structured Logging with Hooks");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    let log_buffer = Arc::new(Mutex::new(Vec::new()));
    let log_clone = log_buffer.clone();

    let mut parser = NetflowParser::builder()
        .on_template_event(move |event| {
            let log_entry = match event {
                TemplateEvent::Learned {
                    template_id,
                    protocol,
                } => format!(
                    "[INFO]  Template {:?} learned for protocol {:?}",
                    template_id, protocol
                ),
                TemplateEvent::Collision {
                    template_id,
                    protocol,
                } => format!(
                    "[WARN]  Template {:?} collision detected for protocol {:?}",
                    template_id, protocol
                ),
                TemplateEvent::Evicted {
                    template_id,
                    protocol,
                } => format!(
                    "[INFO]  Template {:?} evicted (LRU) for protocol {:?}",
                    template_id, protocol
                ),
                TemplateEvent::Expired {
                    template_id,
                    protocol,
                } => format!(
                    "[INFO]  Template {:?} expired (TTL) for protocol {:?}",
                    template_id, protocol
                ),
                TemplateEvent::MissingTemplate {
                    template_id,
                    protocol,
                } => format!(
                    "[ERROR] Missing template {:?} for protocol {:?}",
                    template_id, protocol
                ),
                _ => "[DEBUG] Unknown event".to_string(),
            };
            log_clone.lock().unwrap().push(log_entry);
            Ok(())
        })
        .build()
        .unwrap();

    println!("Generating log entries:\n");

    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });
    parser.trigger_template_event(TemplateEvent::Collision {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });
    parser.trigger_template_event(TemplateEvent::MissingTemplate {
        template_id: Some(300),
        protocol: TemplateProtocol::Ipfix,
    });
    parser.trigger_template_event(TemplateEvent::Evicted {
        template_id: Some(128),
        protocol: TemplateProtocol::V9,
    });

    println!("Log Output:");
    for entry in log_buffer.lock().unwrap().iter() {
        println!("  {}", entry);
    }
}

fn demo_multiple_hooks() {
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("🔗 Multiple Hooks Registration");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    let alert_count = Arc::new(AtomicUsize::new(0));
    let ac = alert_count.clone();

    let mut parser = NetflowParser::builder()
        // Hook 1: Log all events
        .on_template_event(|event| {
            println!("  [Hook 1] {:?}", event);
            Ok(())
        })
        // Hook 2: Count critical events
        .on_template_event(move |event| {
            match event {
                TemplateEvent::Collision { .. } | TemplateEvent::MissingTemplate { .. } => {
                    ac.fetch_add(1, Ordering::SeqCst);
                }
                _ => {}
            }
            Ok(())
        })
        // Hook 3: Custom alerting logic
        .on_template_event(|event| {
            if let TemplateEvent::Collision { template_id, .. } = event {
                println!("  [Hook 3] 🚨 ALERT: Template {:?} collision! Check multi-source configuration", template_id);
            }
            Ok(())
        })
        .build()
        .unwrap();

    println!("Triggering events with multiple hooks active:\n");

    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });
    parser.trigger_template_event(TemplateEvent::Collision {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });
    parser.trigger_template_event(TemplateEvent::MissingTemplate {
        template_id: Some(300),
        protocol: TemplateProtocol::Ipfix,
    });

    println!(
        "\nCritical Events Counter: {}",
        alert_count.load(Ordering::SeqCst)
    );
}
