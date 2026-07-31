//! Tests for template event hooks: registration, callback invocation,
//! and event details for template lifecycle monitoring.

use netflow_parser::{NetflowParser, TemplateEvent, TemplateProtocol};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

// Verify that a template event hook can be registered via the builder without triggering
#[test]
fn test_hook_registration() {
    let counter = Arc::new(AtomicUsize::new(0));
    let counter_clone = counter.clone();

    let _parser = NetflowParser::builder()
        .on_template_event(move |_event| {
            counter_clone.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .build()
        .unwrap();

    // Hook is registered (count is still 0 until events are triggered)
    assert_eq!(counter.load(Ordering::SeqCst), 0);
}

// Verify that multiple hooks receive the correct events based on variant filtering
#[test]
fn test_multiple_hooks() {
    let learned_count = Arc::new(AtomicUsize::new(0));
    let collision_count = Arc::new(AtomicUsize::new(0));
    let all_events_count = Arc::new(AtomicUsize::new(0));

    let lc = learned_count.clone();
    let cc = collision_count.clone();
    let ac = all_events_count.clone();

    let mut parser = NetflowParser::builder()
        .on_template_event(move |event| {
            match event {
                TemplateEvent::Learned { .. } => {
                    lc.fetch_add(1, Ordering::SeqCst);
                }
                TemplateEvent::Collision { .. } => {
                    cc.fetch_add(1, Ordering::SeqCst);
                }
                _ => {}
            }
            Ok(())
        })
        .on_template_event(move |_event| {
            ac.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .build()
        .unwrap();

    // Manually trigger some events to test the hooks
    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });

    parser.trigger_template_event(TemplateEvent::Collision {
        template_id: Some(300),
        protocol: TemplateProtocol::Ipfix,
    });

    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(400),
        protocol: TemplateProtocol::V9,
    });

    // First hook should have seen 2 learned events and 1 collision
    assert_eq!(learned_count.load(Ordering::SeqCst), 2);
    assert_eq!(collision_count.load(Ordering::SeqCst), 1);

    // Second hook should have seen all 3 events
    assert_eq!(all_events_count.load(Ordering::SeqCst), 3);
}

// Verify that a hook fires when a MissingTemplate event is triggered on a builder-created parser
#[test]
fn test_hook_with_default_parser() {
    let event_count = Arc::new(AtomicUsize::new(0));
    let ec = event_count.clone();

    let mut parser = NetflowParser::builder()
        .on_template_event(move |_event| {
            ec.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .build()
        .unwrap();

    // Trigger an event
    parser.trigger_template_event(TemplateEvent::MissingTemplate {
        template_id: Some(500),
        protocol: TemplateProtocol::Ipfix,
    });

    assert_eq!(event_count.load(Ordering::SeqCst), 1);
}

// Verify that hook callbacks receive correct template_id and protocol from Evicted events
#[test]
fn test_hook_event_details() {
    let captured_id = Arc::new(AtomicUsize::new(0));
    let captured_protocol = Arc::new(std::sync::Mutex::new(None));

    let cid = captured_id.clone();
    let cp = captured_protocol.clone();

    let mut parser = NetflowParser::builder()
        .on_template_event(move |event| {
            if let TemplateEvent::Evicted {
                template_id,
                protocol,
            } = event
            {
                cid.store(template_id.unwrap_or(0) as usize, Ordering::SeqCst);
                *cp.lock().unwrap() = Some(*protocol);
            }
            Ok(())
        })
        .build()
        .unwrap();

    parser.trigger_template_event(TemplateEvent::Evicted {
        template_id: Some(1024),
        protocol: TemplateProtocol::V9,
    });

    assert_eq!(captured_id.load(Ordering::SeqCst), 1024);
    assert_eq!(
        *captured_protocol.lock().unwrap(),
        Some(TemplateProtocol::V9)
    );
}

// Verify that hooks can be chained with other builder options and all fire on a single event
#[test]
fn test_hook_builder_chaining() {
    let counter = Arc::new(AtomicUsize::new(0));
    let c1 = counter.clone();
    let c2 = counter.clone();

    let mut parser = NetflowParser::builder()
        .with_cache_size(2000)
        .on_template_event(move |_| {
            c1.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .with_allowed_versions(&[5, 9, 10])
        .on_template_event(move |_| {
            c2.fetch_add(10, Ordering::SeqCst);
            Ok(())
        })
        .build()
        .unwrap();

    parser.trigger_template_event(TemplateEvent::Expired {
        template_id: Some(200),
        protocol: TemplateProtocol::Ipfix,
    });

    // Both hooks should fire: +1 and +10
    assert_eq!(counter.load(Ordering::SeqCst), 11);
}

// Verify that triggering events on a parser with no hooks does not panic
#[test]
fn test_parser_without_hooks() {
    // Parser should work fine without any hooks registered
    let mut parser = NetflowParser::default();

    // This should not panic or cause issues
    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(100),
        protocol: TemplateProtocol::V9,
    });
}

// Verify that a hook can capture and format all event variants into a log buffer
#[test]
fn test_hook_with_logging() {
    use std::sync::Mutex;

    let log = Arc::new(Mutex::new(Vec::new()));
    let log_clone = log.clone();

    let mut parser = NetflowParser::builder()
        .on_template_event(move |event| {
            let msg = match event {
                TemplateEvent::Learned {
                    template_id,
                    protocol,
                } => format!("Learned template {:?} ({:?})", template_id, protocol),
                TemplateEvent::Collision {
                    template_id,
                    protocol,
                } => format!("Collision on template {:?} ({:?})", template_id, protocol),
                TemplateEvent::Evicted {
                    template_id,
                    protocol,
                } => format!("Evicted template {:?} ({:?})", template_id, protocol),
                TemplateEvent::Expired {
                    template_id,
                    protocol,
                } => format!("Expired template {:?} ({:?})", template_id, protocol),
                TemplateEvent::MissingTemplate {
                    template_id,
                    protocol,
                } => format!("Missing template {:?} ({:?})", template_id, protocol),
                _ => "Unknown event".to_string(),
            };
            log_clone.lock().unwrap().push(msg);
            Ok(())
        })
        .build()
        .unwrap();

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

    let logged = log.lock().unwrap();
    assert_eq!(logged.len(), 3);
    assert!(logged[0].contains("Learned template Some(256)"));
    assert!(logged[1].contains("Collision on template Some(256)"));
    assert!(logged[2].contains("Missing template Some(300)"));
}

// Verify that hooks fire during actual V9 template parsing (not just manual triggers)
#[test]
fn test_hooks_fire_during_parsing() {
    use std::sync::Mutex;

    let events = Arc::new(Mutex::new(Vec::<String>::new()));
    let events_clone = events.clone();

    let mut parser = NetflowParser::builder()
        .on_template_event(move |event| {
            let name = match event {
                TemplateEvent::Learned { .. } => "Learned",
                TemplateEvent::Collision { .. } => "Collision",
                TemplateEvent::MissingTemplate { .. } => "MissingTemplate",
                TemplateEvent::Evicted { .. } => "Evicted",
                TemplateEvent::Expired { .. } => "Expired",
                _ => "Unknown",
            };
            events_clone.lock().unwrap().push(name.to_string());
            Ok(())
        })
        .build()
        .unwrap();

    // V9 template packet: template ID 256 with 1 field (IN_BYTES, 4 bytes)
    let v9_template_packet: Vec<u8> = vec![
        0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 12, 1, 0, 0, 1, 0,
        1, 0, 4,
    ];
    assert!(
        !parser.parse_bytes(&v9_template_packet).packets.is_empty(),
        "Template packet should parse successfully"
    );

    let captured = events.lock().unwrap();
    assert!(
        captured.iter().any(|e| e == "Learned"),
        "Hook should fire a Learned event when parsing a V9 template. Got: {:?}",
        *captured
    );
}

// Verify that hook_error_count() tracks errors correctly
#[test]
fn test_hook_error_count() {
    let mut parser = NetflowParser::builder()
        .on_template_event(|_| Err("intentional error".into()))
        .build()
        .unwrap();

    assert_eq!(parser.hook_error_count(), 0);

    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });

    assert_eq!(
        parser.hook_error_count(),
        1,
        "hook_error_count should increment after a hook returns an error"
    );

    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(257),
        protocol: TemplateProtocol::V9,
    });

    assert_eq!(
        parser.hook_error_count(),
        2,
        "hook_error_count should accumulate across events"
    );
}

// Verify that hook errors don't prevent subsequent hooks from firing
#[test]
fn test_hook_error_isolation() {
    let counter = Arc::new(AtomicUsize::new(0));
    let c = counter.clone();

    let mut parser = NetflowParser::builder()
        .on_template_event(|_| Err("hook 1 failed".into()))
        .on_template_event(move |_| {
            c.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .build()
        .unwrap();

    parser.trigger_template_event(TemplateEvent::Learned {
        template_id: Some(256),
        protocol: TemplateProtocol::V9,
    });

    // Second hook should still fire despite first hook returning an error
    assert_eq!(counter.load(Ordering::SeqCst), 1);
}
