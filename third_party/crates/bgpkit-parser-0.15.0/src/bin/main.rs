use itertools::Itertools;
use serde_json::json;
use std::io::Write;
use std::net::IpAddr;
use std::path::PathBuf;

use bgpkit_parser::{BgpElem, BgpkitParser, Elementor};
use clap::{Parser, ValueEnum};
use ipnet::IpNet;

/// Output format for the parser
#[derive(Debug, Clone, Copy, Default, ValueEnum)]
enum OutputFormat {
    /// Default pipe-separated format
    #[default]
    Default,
    /// JSON format (one object per line)
    Json,
    /// Pretty-printed JSON format
    JsonPretty,
    /// PSV format with header
    Psv,
}

/// Output level granularity
#[derive(Debug, Clone, Copy, Default, ValueEnum)]
enum OutputLevel {
    /// Output BGP elements (per-prefix)
    #[default]
    Elems,
    /// Output MRT records
    Records,
}

/// bgpkit-parser-cli is a simple cli tool that allow parsing of individual MRT files.
#[derive(Parser, Debug)]
#[clap(author, version, about, long_about = None)]
struct Opts {
    /// File path to a MRT file, local or remote.
    #[clap(name = "FILE")]
    file_path: PathBuf,

    /// Set the cache directory for caching remote files. Default behavior does not enable caching.
    #[clap(short, long)]
    cache_dir: Option<PathBuf>,

    /// Output format
    #[clap(short = 'F', long, value_enum, default_value_t = OutputFormat::Default)]
    format: OutputFormat,

    /// Output level: elems (per-prefix) or records (MRT records)
    #[clap(short = 'L', long, value_enum, default_value_t = OutputLevel::Elems)]
    level: OutputLevel,

    /// Output as JSON objects (shorthand for --format json)
    #[clap(long)]
    json: bool,

    /// Pretty-print JSON output (shorthand for --format json-pretty)
    #[clap(long)]
    pretty: bool,

    /// Output as full PSV entries with header (shorthand for --format psv)
    #[clap(long)]
    psv: bool,

    /// Count BGP elems
    #[clap(short, long)]
    elems_count: bool,

    /// Count MRT records
    #[clap(short, long)]
    records_count: bool,

    #[clap(flatten)]
    filters: Filters,
}

#[derive(Parser, Debug)]
struct Filters {
    /// Filter by origin AS Number
    #[clap(short = 'o', long)]
    origin_asn: Option<u32>,

    /// Generic filter expression (can be used multiple times)
    /// Format: "key=value" for positive match, "key!=value" for negative match
    /// Examples: --filter "origin_asn!=13335" --filter "peer_ip!=192.168.1.1"
    /// For multi-value filters: --filter "origin_asns!=13335,15169" excludes both ASNs
    /// Supported keys: origin_asn, origin_asns, prefix, prefixes, peer_ip, peer_ips, peer_asn, peer_asns, type, as_path, community, ip_version
    #[clap(short = 'f', long = "filter")]
    filters: Vec<String>,

    /// Filter by network prefix
    #[clap(short = 'p', long)]
    prefix: Option<IpNet>,

    /// Include super-prefix when filtering
    #[clap(short = 's', long)]
    include_super: bool,

    /// Include sub-prefix when filtering
    #[clap(short = 'S', long)]
    include_sub: bool,

    /// Filter by IPv4 only
    #[clap(short = '4', long)]
    ipv4_only: bool,

    /// Filter by IPv6 only
    #[clap(short = '6', long)]
    ipv6_only: bool,

    /// Filter by peer IP address
    #[clap(short = 'j', long)]
    peer_ip: Vec<IpAddr>,

    /// Filter by peer ASN
    #[clap(short = 'J', long)]
    peer_asn: Option<u32>,

    /// Filter by elem type: announce (a) or withdraw (w)
    #[clap(short = 'm', long)]
    elem_type: Option<String>,

    /// Filter by start unix timestamp inclusive
    #[clap(short = 't', long)]
    start_ts: Option<f64>,

    /// Filter by end unix timestamp inclusive
    #[clap(short = 'T', long)]
    end_ts: Option<f64>,

    /// Filter by AS path regex string
    #[clap(short = 'a', long)]
    as_path: Option<String>,

    /// Filter by AS path regex string
    #[clap(short = 'C', long)]
    community: Option<String>,
}

fn main() {
    let opts: Opts = Opts::parse();

    env_logger::init();

    let file_path = opts.file_path.to_str().unwrap();

    let parser_opt = match opts.cache_dir {
        None => BgpkitParser::new(file_path),
        Some(c) => BgpkitParser::new_cached(file_path, c.to_str().unwrap()),
    };

    let mut parser = match parser_opt {
        Ok(p) => p,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };

    if let Some(v) = opts.filters.as_path {
        parser = parser.add_filter("as_path", v.as_str()).unwrap();
    }
    if let Some(v) = opts.filters.community {
        parser = parser.add_filter("community", v.as_str()).unwrap();
    }
    if let Some(v) = opts.filters.origin_asn {
        parser = parser
            .add_filter("origin_asn", v.to_string().as_str())
            .unwrap();
    }
    if let Some(v) = opts.filters.prefix {
        let filter_type = match (opts.filters.include_super, opts.filters.include_sub) {
            (false, false) => "prefix",
            (true, false) => "prefix_super",
            (false, true) => "prefix_sub",
            (true, true) => "prefix_super_sub",
        };
        parser = parser
            .add_filter(filter_type, v.to_string().as_str())
            .unwrap();
    }
    if !opts.filters.peer_ip.is_empty() {
        let v = opts.filters.peer_ip.iter().map(|p| p.to_string()).join(",");
        parser = parser.add_filter("peer_ips", v.as_str()).unwrap();
    }
    if let Some(v) = opts.filters.peer_asn {
        parser = parser
            .add_filter("peer_asn", v.to_string().as_str())
            .unwrap();
    }
    if let Some(v) = opts.filters.elem_type {
        parser = parser.add_filter("type", v.as_str()).unwrap();
    }
    if let Some(v) = opts.filters.start_ts {
        parser = parser
            .add_filter("start_ts", v.to_string().as_str())
            .unwrap();
    }
    if let Some(v) = opts.filters.end_ts {
        parser = parser.add_filter("end_ts", v.to_string().as_str()).unwrap();
    }

    // Process generic filter expressions
    for filter_expr in &opts.filters.filters {
        match parse_filter_expression(filter_expr) {
            Ok((filter_type, filter_value)) => {
                parser = match parser.add_filter(&filter_type, &filter_value) {
                    Ok(p) => p,
                    Err(e) => {
                        eprintln!("Error adding filter '{}': {}", filter_expr, e);
                        std::process::exit(1);
                    }
                };
            }
            Err(e) => {
                eprintln!("Invalid filter expression '{}': {}", filter_expr, e);
                std::process::exit(1);
            }
        }
    }

    match (opts.filters.ipv4_only, opts.filters.ipv6_only) {
        (true, true) => {
            eprintln!("Error: --ipv4-only and --ipv6-only cannot be used together");
            std::process::exit(1);
        }
        (false, false) => {
            // no filters on IP version, skip
        }
        (true, false) => {
            parser = parser.add_filter("ip_version", "ipv4").unwrap();
        }
        (false, true) => {
            parser = parser.add_filter("ip_version", "ipv6").unwrap();
        }
    }

    // Determine final output format (shorthand flags override --format)
    let output_format = if opts.pretty {
        OutputFormat::JsonPretty
    } else if opts.json {
        OutputFormat::Json
    } else if opts.psv {
        OutputFormat::Psv
    } else {
        opts.format
    };

    match (opts.elems_count, opts.records_count) {
        (true, true) => {
            let mut elementor = Elementor::new();
            let (mut records_count, mut elems_count) = (0, 0);
            for record in parser.into_record_iter() {
                records_count += 1;
                elems_count += elementor.record_to_elems(record).len();
            }
            println!("total records: {records_count}");
            println!("total elems:   {elems_count}");
        }
        (false, true) => {
            println!("total records: {}", parser.into_record_iter().count());
        }
        (true, false) => {
            println!("total elems: {}", parser.into_elem_iter().count());
        }
        (false, false) => {
            let mut stdout = std::io::stdout();

            match opts.level {
                OutputLevel::Elems => {
                    for (index, elem) in parser.into_elem_iter().enumerate() {
                        let output_str = format_elem(&elem, output_format, index);
                        if let Err(e) = writeln!(stdout, "{}", &output_str) {
                            if e.kind() != std::io::ErrorKind::BrokenPipe {
                                eprintln!("{e}");
                            }
                            std::process::exit(1);
                        }
                    }
                }
                OutputLevel::Records => {
                    for record in parser.into_record_iter() {
                        let output_str = format_record(&record, output_format);
                        if let Err(e) = writeln!(stdout, "{}", &output_str) {
                            if e.kind() != std::io::ErrorKind::BrokenPipe {
                                eprintln!("{e}");
                            }
                            std::process::exit(1);
                        }
                    }
                }
            }
        }
    }
}

fn format_elem(elem: &BgpElem, format: OutputFormat, index: usize) -> String {
    match format {
        OutputFormat::Json => {
            let val = json!(elem);
            val.to_string()
        }
        OutputFormat::JsonPretty => {
            let val = json!(elem);
            serde_json::to_string_pretty(&val).unwrap()
        }
        OutputFormat::Psv => {
            if index == 0 {
                format!("{}\n{}", BgpElem::get_psv_header(), elem.to_psv())
            } else {
                elem.to_psv()
            }
        }
        OutputFormat::Default => elem.to_string(),
    }
}

fn format_record(record: &bgpkit_parser::MrtRecord, format: OutputFormat) -> String {
    match format {
        OutputFormat::Json => {
            let val = json!(record);
            val.to_string()
        }
        OutputFormat::JsonPretty => {
            let val = json!(record);
            serde_json::to_string_pretty(&val).unwrap()
        }
        OutputFormat::Psv | OutputFormat::Default => {
            // Use the Display implementation for MrtRecord
            format!("{}", record)
        }
    }
}

/// Parse a filter expression in the format "key=value" or "key!=value"
/// Returns (filter_type, filter_value) where filter_value may be prefixed with "!" for negation
///
/// For multi-value filters (e.g., "origin_asns!=13335,15169"), the negation is distributed
/// to each value: ("origin_asns", "!13335,!15169")
fn parse_filter_expression(expr: &str) -> Result<(String, String), String> {
    // Multi-value filter types that support comma-separated values
    let multi_value_filters = [
        "origin_asns",
        "prefixes",
        "prefixes_super",
        "prefixes_sub",
        "prefixes_super_sub",
        "peer_ips",
        "peer_asns",
    ];

    // Check for "!=" (negative filter) first
    if let Some(pos) = expr.find("!=") {
        let key = expr[..pos].trim();
        let value = expr[pos + 2..].trim();
        if key.is_empty() {
            return Err("filter key cannot be empty".to_string());
        }
        if value.is_empty() {
            return Err("filter value cannot be empty".to_string());
        }

        // For multi-value filters, prefix each value with "!"
        if multi_value_filters.contains(&key) {
            let negated_values: Vec<String> =
                value.split(',').map(|v| format!("!{}", v.trim())).collect();
            Ok((key.to_string(), negated_values.join(",")))
        } else {
            // For single-value filters, prefix the value with "!"
            Ok((key.to_string(), format!("!{}", value)))
        }
    }
    // Check for "=" (positive filter)
    else if let Some(pos) = expr.find('=') {
        let key = expr[..pos].trim();
        let value = expr[pos + 1..].trim();
        if key.is_empty() {
            return Err("filter key cannot be empty".to_string());
        }
        if value.is_empty() {
            return Err("filter value cannot be empty".to_string());
        }
        Ok((key.to_string(), value.to_string()))
    } else {
        Err("filter expression must contain '=' or '!=' (e.g., 'origin_asn=13335' or 'origin_asn!=13335')".to_string())
    }
}
