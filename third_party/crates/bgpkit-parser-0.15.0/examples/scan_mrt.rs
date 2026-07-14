use bgpkit_parser::BgpkitParser;
use clap::{Parser, ValueEnum};
use std::io::Read;
use std::path::PathBuf;
use tracing::info;

#[derive(Debug, Clone, ValueEnum)]
pub enum Operation {
    RawRecords,
    Records,
    Elements,
}

#[derive(Parser, Debug)]
#[command(name = "scan_mrt")]
#[command(about = "Scan over the elements of a MRT file without processing")]
struct Cli {
    #[arg(help = "Path to MRT file to parse")]
    rib_file: PathBuf,

    #[arg(short, long, action = clap::ArgAction::Count, help = "Increase verbosity (-v, -vv, -vvv)")]
    verbose: u8,

    #[arg(short, long, help = "Limit number of records to process")]
    limit: Option<usize>,

    operation: Operation,
}

fn scan_raw_records<R: Read>(
    parser: BgpkitParser<R>,
    limit: Option<usize>,
) -> Result<usize, Box<dyn std::error::Error>> {
    let mut record_count = 0;

    for (idx, _) in parser.into_raw_record_iter().enumerate() {
        if let Some(limit) = limit {
            if idx >= limit {
                break;
            }
        }

        // Just counting raw records without parsing
        record_count += 1;
    }

    Ok(record_count)
}

fn scan_records<R: Read>(
    parser: BgpkitParser<R>,
    limit: Option<usize>,
) -> Result<usize, Box<dyn std::error::Error>> {
    let mut element_count = 0;

    for (idx, _) in parser.into_record_iter().enumerate() {
        if let Some(limit) = limit {
            if idx >= limit {
                break;
            }
        }

        // Just counting elements without processing
        element_count += 1;
    }

    Ok(element_count)
}

fn scan_elements<R: Read>(
    parser: BgpkitParser<R>,
    limit: Option<usize>,
) -> Result<usize, Box<dyn std::error::Error>> {
    let mut element_count = 0;

    for (idx, _) in parser.into_elem_iter().enumerate() {
        if let Some(limit) = limit {
            if idx >= limit {
                break;
            }
        }

        // Just counting elements without processing
        element_count += 1;
    }

    Ok(element_count)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    tracing_subscriber::fmt()
        .with_max_level(match cli.verbose {
            0 => tracing::Level::INFO,
            1 => tracing::Level::DEBUG,
            2 => tracing::Level::TRACE,
            _ => tracing::Level::ERROR,
        })
        .init();

    info!("Scanning RIB file: {}", cli.rib_file.display());

    let parser = BgpkitParser::new(cli.rib_file.to_str().unwrap())?;

    let t0 = std::time::Instant::now();

    let element_count = match cli.operation {
        Operation::RawRecords => scan_raw_records(parser, cli.limit)?,
        Operation::Records => scan_records(parser, cli.limit)?,
        Operation::Elements => scan_elements(parser, cli.limit)?,
    };

    let elapsed = t0.elapsed();

    info!(
        "Scanning complete: read {} bytes of input in {:.3} seconds.",
        cli.rib_file.metadata()?.len(),
        elapsed.as_secs_f64()
    );
    info!("Total BGP elements scanned: {}", element_count);

    Ok(())
}
