use bgpkit_parser::BgpkitParser;

/// This example demonstrates using multiple filters with OR logic and negative filters.
///
/// The new filter types (origin_asns, prefixes, peer_asns) accept comma-separated
/// values and match elements that satisfy ANY of the specified values (OR logic).
///
/// Negative filters use value-based negation (e.g., `origin_asn=!13335`) to match
/// elements that do NOT satisfy the filter.
///
/// This is useful when you want to filter for elements from multiple ASNs,
/// multiple prefixes, or multiple peers in a single filter, or exclude specific values.
fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    log::info!("Example: Filtering with OR logic for multiple values");

    // Example 1: Filter by multiple origin ASNs
    // This will match elements originating from ANY of these ASNs
    let parser = BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2",
    )
    .unwrap()
    .add_filter("origin_asns", "13335,15169,8075") // Cloudflare, Google, Microsoft
    .unwrap();

    log::info!("Filtering by multiple origin ASNs (13335, 15169, 8075):");
    let count = parser.into_elem_iter().take(10).count();
    log::info!("Found {} elements (showing first 10)", count);

    // Example 2: Filter by multiple prefixes
    // This will match elements for ANY of these prefixes
    let parser = BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2",
    )
    .unwrap()
    .add_filter("prefixes", "1.1.1.0/24,8.8.8.0/24")
    .unwrap();

    log::info!("Filtering by multiple prefixes (1.1.1.0/24, 8.8.8.0/24):");
    for elem in parser.into_elem_iter().take(5) {
        log::info!("{}", elem);
    }

    // Example 3: Filter by multiple peer ASNs
    // This will match elements from ANY of these peer ASNs
    let parser = BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2",
    )
    .unwrap()
    .add_filter("peer_asns", "174,3356,6939")
    .unwrap();

    log::info!("Filtering by multiple peer ASNs (174, 3356, 6939):");
    let count = parser.into_elem_iter().take(10).count();
    log::info!("Found {} elements (showing first 10)", count);

    // Example 4: Combining multiple filter types
    // Filters of DIFFERENT types use AND logic (all must match)
    // Filters of the SAME type with multiple values use OR logic (any must match)
    let parser = BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2",
    )
    .unwrap()
    .add_filter("origin_asns", "13335,15169") // OR: origin from Cloudflare OR Google
    .unwrap()
    .add_filter("type", "a") // AND: must be announcement
    .unwrap();

    log::info!("Combining filters: announcements from Cloudflare OR Google:");
    let count = parser.into_elem_iter().take(5).count();
    log::info!("Found {} elements (showing first 5)", count);

    // Example 5: Negative filter - exclude a specific origin ASN
    // Use value-based negation: the `!` prefix on the value inverts the filter
    let parser = BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2",
    )
    .unwrap()
    .add_filter("origin_asn", "!13335") // Exclude Cloudflare
    .unwrap()
    .add_filter("type", "a") // Only announcements
    .unwrap();

    log::info!("Negative filter: announcements NOT from AS 13335:");
    let count = parser.into_elem_iter().take(10).count();
    log::info!("Found {} elements (showing first 10)", count);

    // Example 6: Negative filter with multiple values
    // Exclude elements from ANY of the specified ASNs
    // For multi-value filters, prefix each value with `!`
    let parser = BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2",
    )
    .unwrap()
    .add_filter("origin_asns", "!13335,!15169,!8075") // Exclude Cloudflare, Google, Microsoft
    .unwrap();

    log::info!("Negative filter: elements NOT from AS 13335, 15169, or 8075:");
    let count = parser.into_elem_iter().take(10).count();
    log::info!("Found {} elements (showing first 10)", count);

    // Example 7: Combining positive and negative filters
    // Get IPv4 announcements but exclude a specific peer
    let parser = BgpkitParser::new(
        "http://archive.routeviews.org/bgpdata/2021.10/UPDATES/updates.20211001.0000.bz2",
    )
    .unwrap()
    .add_filter("type", "a") // Only announcements
    .unwrap()
    .add_filter("ip_version", "4") // Only IPv4
    .unwrap()
    .add_filter("peer_asn", "!174") // Exclude peer AS 174
    .unwrap();

    log::info!("Combined: IPv4 announcements excluding peer AS 174:");
    let count = parser.into_elem_iter().take(10).count();
    log::info!("Found {} elements (showing first 10)", count);

    log::info!("Done!");
}
