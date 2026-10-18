// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

use crate::Catalog;
use crate::{Entry, Indicator, Prefix, Stats, Trie};
use std::sync::Mutex;
use std::time::{Duration, Instant};

static CATALOG_TESTS: Mutex<()> = Mutex::new(());

fn catalog_deadline() -> Instant {
    Instant::now() + Duration::from_secs(5)
}

fn decoded_ranges(bytes: &[u8]) -> Vec<(u8, u128, u128)> {
    let (rows, remainder) = bytes.as_chunks::<33>();
    assert!(remainder.is_empty());
    rows.iter()
        .map(|row| {
            (
                row[0],
                u128::from_be_bytes(row[1..17].try_into().unwrap()),
                u128::from_be_bytes(row[17..33].try_into().unwrap()),
            )
        })
        .collect()
}

#[test]
fn catalog_returns_full_chain_network_unions_and_live_lexical_pages() {
    let _serial = CATALOG_TESTS.lock().unwrap();
    let mut trie = Trie::new();
    for (prefix, label) in [
        ("192.0.2.0/25", "office"),
        ("192.0.2.128/25", "office"),
        ("192.0.2.17/32", "office"),
        ("2001:db8::/126", "office"),
        ("2001:db8::4/126", "office"),
        ("2001:db8::1/128", "host"),
        ("0.0.0.0/0", "all"),
        ("::/0", "all"),
        ("198.51.100.1/32", "other"),
    ] {
        trie.insert(row(prefix, label));
    }
    let mut variant = row("192.0.2.0/25", "office");
    variant.vrf = Some("synthetic-isolated".into());
    trie.insert(variant);
    let catalog = Catalog::build(&trie, catalog_deadline()).unwrap();
    assert_eq!(catalog.label_count(), 4);
    let first = catalog.page(&trie, None, 2, catalog_deadline()).unwrap();
    assert_eq!(first.labels, ["all", "host"]);
    assert_eq!(first.next_after.as_deref(), Some("host"));
    let second = catalog
        .page(&trie, Some("missing"), 2, catalog_deadline())
        .unwrap();
    assert_eq!(second.labels, ["office", "other"]);
    assert!(second.next_after.is_none());
    let bytes = catalog
        .ranges(&trie, "office", 2, 66, catalog_deadline())
        .unwrap();
    assert_eq!(
        decoded_ranges(&bytes),
        [
            (4, 0xc0000200, 0xc00002ff),
            (
                6,
                0x20010db8000000000000000000000000,
                0x20010db8000000000000000000000007
            ),
        ]
    );
    assert_eq!(
        decoded_ranges(
            &catalog
                .ranges(&trie, "all", 2, 66, catalog_deadline())
                .unwrap()
        ),
        [(4, 0, u32::MAX as u128), (6, 0, u128::MAX),]
    );
    assert!(catalog
        .ranges(&trie, "absent", 2, 66, catalog_deadline())
        .unwrap()
        .is_empty());
    assert_eq!(
        catalog.ranges(&trie, "office", 1, 66, catalog_deadline()),
        Err("range_budget")
    );
    assert_eq!(
        catalog.ranges(&trie, "office", 2, 65, catalog_deadline()),
        Err("range_budget")
    );
    assert_eq!(
        catalog.ranges(&trie, "office", 2, 66, Instant::now()),
        Err("deadline_exceeded")
    );
    assert_eq!(
        catalog.ranges(&trie, &"x".repeat(257), 2, 66, catalog_deadline()),
        Err("label_budget")
    );
}

#[test]
fn catalogs_share_a_reservation_across_sources_and_release_it_before_retry() {
    let _serial = CATALOG_TESTS.lock().unwrap();
    let baseline = Catalog::total_native_bytes();
    let mut trie = Trie::new();
    trie.insert(Entry::new(
        Prefix::parse("192.0.2.0/24").unwrap(),
        vec!["synthetic".into(); 262_144],
    ));
    let retained = Catalog::build(&trie, catalog_deadline()).unwrap();
    assert!(retained.native_bytes() > 3_000_000);
    assert_eq!(
        Catalog::build(&trie, catalog_deadline()).unwrap_err(),
        "catalog_budget"
    );
    assert_eq!(
        Catalog::total_native_bytes(),
        baseline + retained.native_bytes()
    );
    drop(retained);
    assert_eq!(Catalog::total_native_bytes(), baseline);
    let replacement = Catalog::build(&trie, catalog_deadline()).unwrap();
    assert_eq!(replacement.label_count(), 1);
    drop(replacement);
    assert_eq!(Catalog::total_native_bytes(), baseline);
    assert_eq!(
        Catalog::build(&trie, Instant::now()).unwrap_err(),
        "deadline_exceeded"
    );
    assert_eq!(Catalog::total_native_bytes(), baseline);
}

#[test]
fn label_ranges_drop_expired_prefixes_and_keep_live_ones() {
    let _serial = CATALOG_TESTS.lock().unwrap();
    let mut trie = Trie::new();
    let mut expired = Entry::new(Prefix::parse("192.0.2.0/25").unwrap(), vec!["office".into()]);
    expired.expires_at = Some((1, 0));
    trie.insert(expired);
    let mut live = Entry::new(
        Prefix::parse("192.0.2.128/25").unwrap(),
        vec!["office".into()],
    );
    live.expires_at = Some((i64::MAX, 0));
    trie.insert(live);
    let mut retired = Entry::new(
        Prefix::parse("198.51.100.1/32").unwrap(),
        vec!["retired".into()],
    );
    retired.expires_at = Some((1, 0));
    trie.insert(retired);
    trie.insert(Entry::new(
        Prefix::parse("198.51.100.2/32").unwrap(),
        vec![" retired ".into()],
    ));
    let catalog = Catalog::build(&trie, catalog_deadline()).unwrap();
    assert_eq!(catalog.label_count(), 2);
    assert_eq!(
        catalog
            .page(&trie, None, 50, catalog_deadline())
            .unwrap()
            .labels,
        vec!["office".to_string()]
    );
    let after_office = catalog
        .page(&trie, Some("office"), 50, catalog_deadline())
        .unwrap();
    assert!(after_office.labels.is_empty());
    assert!(after_office.next_after.is_none());
    assert_eq!(
        catalog.ranges(&trie, " retired ", 8, 264, catalog_deadline()),
        Err("label_budget")
    );
    assert_eq!(
        decoded_ranges(
            &catalog
                .ranges(&trie, "office", 8, 264, catalog_deadline())
                .unwrap()
        ),
        [(4, 0xc000_0280, 0xc000_02ff)]
    );
    assert!(catalog
        .ranges(&trie, "retired", 8, 264, catalog_deadline())
        .unwrap()
        .is_empty());
}

fn row(prefix: &str, tag: &str) -> Entry {
    Entry::new(Prefix::parse(prefix).unwrap(), vec![tag.to_owned()])
}

fn tags(trie: &Trie, ip: &str) -> Vec<String> {
    trie.lookup(ip)
        .into_iter()
        .flat_map(|entry| entry.tags.iter().cloned())
        .collect()
}

#[test]
fn full_chain_survives_compressed_edge_splits_in_every_insertion_order() {
    let rows = [
        row("192.0.2.19/32", "host"),
        row("192.0.2.128/25", "sibling"),
        row("192.0.2.0/24", "network"),
        row("0.0.0.0/0", "default"),
    ];
    for a in 0..4 {
        for b in 0..4 {
            for c in 0..4 {
                for d in 0..4 {
                    let order = [a, b, c, d];
                    if (0..4).any(|i| order[..i].contains(&order[i])) {
                        continue;
                    }
                    let mut trie = Trie::new();
                    for index in order {
                        trie.insert(rows[index].clone());
                    }
                    assert_eq!(tags(&trie, "192.0.2.19"), ["host", "network", "default"]);
                    assert_eq!(
                        tags(&trie, "192.0.2.200"),
                        ["sibling", "network", "default"]
                    );
                    assert_eq!(tags(&trie, "198.51.100.1"), ["default"]);
                    assert!(trie.lookup("2001:db8::1").is_empty());
                }
            }
        }
    }
}

#[test]
fn ipv6_defaults_hosts_and_mapped_ipv4_keep_family_semantics() {
    let mut trie = Trie::new();
    for (prefix, tag) in [
        ("2001:db8:1::5/128", "host"),
        ("2001:db8:1::/48", "subnet"),
        ("2001:db8::/32", "network"),
        ("::/0", "v6"),
        ("192.0.2.0/24", "v4"),
    ] {
        trie.insert(row(prefix, tag));
    }
    assert_eq!(
        tags(&trie, "2001:db8:1::5"),
        ["host", "subnet", "network", "v6"]
    );
    assert_eq!(tags(&trie, "2001:db8:2::5"), ["network", "v6"]);
    assert_eq!(tags(&trie, "::ffff:192.0.2.5"), ["v4"]);
    assert_eq!(tags(&trie, "::192.0.2.5"), ["v6"]);
    assert!(trie.lookup("198.51.100.1").is_empty());
    assert!(trie.lookup("not-an-address").is_empty());
    assert_eq!(
        trie.stats(),
        Stats {
            ipv4_prefixes: 1,
            ipv6_prefixes: 4
        }
    );
}

#[test]
fn prefixes_are_canonical_and_invalid_masks_are_rejected() {
    for (input, expected) in [
        (" 192.0.2.129/24 ", "192.0.2.0/24"),
        ("2001:db8:abcd:1234::1/48", "2001:db8:abcd::/48"),
        ("192.0.2.7", "192.0.2.7/32"),
        ("2001:db8::7", "2001:db8::7/128"),
        ("::ffff:192.0.2.7/24", "192.0.2.0/24"),
        ("::ffff:192.0.2.7/120", "192.0.2.0/24"),
        ("::ffff:192.0.2.7/128", "192.0.2.7/32"),
        ("::ffff:192.0.2.7/96", "0.0.0.0/0"),
        ("ffff::1/0", "::/0"),
    ] {
        assert_eq!(Prefix::parse(input).unwrap().to_string(), expected);
    }
    for invalid in [
        "",
        "garbage",
        "192.0.2.0/33",
        "2001:db8::/129",
        "192.0.2.0/-1",
        "192.0.2.0/24/1",
        "::ffff:192.0.2.0/95",
    ] {
        assert!(Prefix::parse(invalid).is_none(), "accepted {invalid}");
    }
}

#[test]
fn vrf_variants_and_duplicate_merges_preserve_order_and_evidence() {
    let mut trie = Trie::new();
    let permanent = Indicator {
        source: "feed-a".into(),
        severity: Some(2),
        indicator_count: 1,
        tags: vec!["ti:a".into()],
        ..Indicator::default()
    };
    let finite = Indicator {
        source: "feed-b".into(),
        severity: Some(7),
        expires_at: Some((2_000_000, 6)),
        indicator_count: 2,
        tags: vec!["ti:b".into()],
        ..Indicator::default()
    };
    let mut first = row("192.0.2.9/24", "a");
    first.tags.push("a".into());
    first.source = Some("manual".into());
    first.severity = Some(2);
    first.indicator_count = Some(1);
    first.feed_sources = Some(vec!["feed-a".into()]);
    first.indicators = Some(vec![permanent.clone()]);
    trie.insert(first);
    let mut other_vrf = row("192.0.2.0/24", "other-vrf");
    other_vrf.vrf = Some("isolated".into());
    trie.insert(other_vrf);
    let mut duplicate = row("192.0.2.99/24", "b");
    duplicate.vrf = Some("".into()); // nil and empty VRF share the default key
    duplicate.severity = Some(7);
    duplicate.indicator_count = Some(2);
    duplicate.expires_at = Some((2_000_000, 6));
    duplicate.feed_sources = Some(vec!["feed-a".into(), "feed-b".into(), "".into()]);
    duplicate.indicators = Some(vec![finite.clone()]);
    trie.insert(duplicate);

    let matches = trie.lookup("192.0.2.1");
    assert_eq!(matches.len(), 2);
    assert_eq!(matches[0].vrf.as_deref(), Some("isolated"));
    let merged = matches[1];
    assert_eq!(merged.prefix.to_string(), "192.0.2.0/24");
    assert_eq!(merged.tags, ["a", "b"]);
    assert_eq!(merged.source.as_deref(), Some("manual"));
    assert_eq!(merged.vrf.as_deref(), Some(""));
    assert_eq!(merged.severity, Some(7));
    assert_eq!(merged.indicator_count, Some(3));
    assert_eq!(merged.expires_at, None);
    assert_eq!(merged.feed_sources.as_ref().unwrap(), &["feed-a", "feed-b"]);
    assert_eq!(merged.indicators.as_ref().unwrap(), &[permanent, finite]);
    assert_eq!(trie.stats().total_prefixes(), 2);
}

#[test]
fn finite_duplicate_expiry_uses_latest_and_new_source_wins() {
    let mut trie = Trie::new();
    for (expiry, source) in [(9_000_000, "older"), (3_000_000, "newer")] {
        let mut entry = row("2001:db8::/32", "tag");
        entry.expires_at = Some((expiry, 6));
        entry.source = Some(source.into());
        trie.insert(entry);
    }
    let entries = trie.lookup("2001:db8::1");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].expires_at, Some((9_000_000, 6)));
    assert_eq!(entries[0].source.as_deref(), Some("newer"));
    assert_eq!(entries[0].tags, ["tag"]);
}

#[test]
fn mixed_prefix_lengths_match_an_independent_flat_containment_oracle() {
    // All addresses are invented within the IPv6 documentation range. This
    // oracle uses ordinary integer intervals, not the trie's masks or traversal.
    let base = 0x2001_0db8_u128 << 96;
    let mut seed = 0x193b_6a21_u64;
    let mut next = || {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
        seed
    };
    let mut trie = Trie::new();
    let mut intervals = Vec::new();
    for id in 0..700 {
        let address = base | (u128::from(next()) << 32) | u128::from(next() as u32);
        let length = 32 + (next() % 97) as u8;
        let host_mask = if length == 128 {
            0
        } else {
            u128::MAX >> length
        };
        let lower = address & !host_mask;
        let upper = lower | host_mask;
        let prefix = format!("{}/{}", std::net::Ipv6Addr::from(address), length);
        let mut entry = row(&prefix, &id.to_string());
        entry.vrf = Some(format!("variant-{id}"));
        trie.insert(entry);
        intervals.push((lower, upper, length, id));
    }
    for address in intervals
        .iter()
        .flat_map(|&(lower, upper, _, _)| [lower, upper])
    {
        let mut expected = intervals
            .iter()
            .filter(|&&(lower, upper, _, _)| lower <= address && address <= upper)
            .map(|&(_, _, length, id)| (length, id))
            .collect::<Vec<_>>();
        expected.sort_unstable_by(|a, b| b.cmp(a));
        let actual = tags(&trie, &std::net::Ipv6Addr::from(address).to_string());
        assert_eq!(
            actual,
            expected
                .iter()
                .map(|(_, id)| id.to_string())
                .collect::<Vec<_>>()
        );
    }
}

#[test]
fn synthetic_provider_scale_snapshot_keeps_every_inserted_prefix_reachable() {
    let mut trie = Trie::new();
    for id in 0..262_144u32 {
        trie.insert(row(
            &format!("2001:db8:{:x}:{:x}::/64", id >> 16, id & 0xffff),
            "provider:example",
        ));
    }
    for host in 0..256 {
        trie.insert(row(&format!("192.0.2.{host}/32"), "provider:ipv4"));
    }
    assert_eq!(
        trie.stats(),
        Stats {
            ipv4_prefixes: 256,
            ipv6_prefixes: 262_144
        }
    );
    for id in 0..262_144u32 {
        let address = format!("2001:db8:{:x}:{:x}::1", id >> 16, id & 0xffff);
        assert_eq!(tags(&trie, &address), ["provider:example"]);
    }
    assert!(trie.lookup("2001:db8:4::1").is_empty());
    for host in 0..256 {
        assert_eq!(tags(&trie, &format!("192.0.2.{host}")), ["provider:ipv4"]);
    }
}
