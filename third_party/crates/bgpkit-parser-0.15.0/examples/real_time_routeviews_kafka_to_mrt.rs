//! This example shows how to consume BGP messages from RouteViews AMSIX peer at AS34968 and archive
//! the received BGP messages to a MRT file.
pub use bgpkit_parser::parse_bmp_msg;
use bgpkit_parser::parse_openbmp_header;
use bytes::Bytes;
use kafka::consumer::{Consumer, FetchOffset, GroupOffsetStorage};
use kafka::error::Error as KafkaError;
use std::io::Write;
use std::process::exit;
use std::thread::sleep;
use std::time::Duration;
use tracing::{error, info};
const MRT_OUTPUT_FILE: &str = "bgpkit_routeviews_archive_example.mrt.bz2";

fn consume_and_archive(
    group: String,
    topic: String,
    brokers: Vec<String>,
) -> Result<(), KafkaError> {
    let mut con = Consumer::from_hosts(brokers)
        .with_topic(topic)
        .with_group(group)
        .with_fetch_max_bytes_per_partition(100_000)
        .with_retry_max_bytes_limit(1_000_000)
        .with_fallback_offset(FetchOffset::Earliest)
        .with_offset_storage(Some(GroupOffsetStorage::Kafka))
        .create()?;

    let mut archive_writer = oneio::get_writer(MRT_OUTPUT_FILE).unwrap();
    info!(
        "Start archiving BGP messages from RouteViews AMSIX peer at AS34968 to {}",
        MRT_OUTPUT_FILE
    );
    let mut records_count = 0;

    loop {
        let mss = con.poll()?;
        if mss.is_empty() {
            info!("No messages available right now, wait for 5 seconds.");
            sleep(Duration::from_secs(5));
            continue;
        }

        for ms in mss.iter() {
            for m in ms.messages() {
                let mut bytes = Bytes::from(m.value.to_vec());
                let _header = parse_openbmp_header(&mut bytes).unwrap();
                let bmp_msg = parse_bmp_msg(&mut bytes);
                match bmp_msg {
                    Ok(msg) => {
                        let mrt_record = match bgpkit_parser::models::MrtRecord::try_from(&msg) {
                            Ok(r) => r,
                            Err(msg) => {
                                dbg!(msg);
                                continue;
                            }
                        };

                        let bytes = mrt_record.encode();
                        archive_writer.write_all(&bytes).unwrap();
                        archive_writer.flush().unwrap();
                        records_count += 1;
                        if records_count % 1000 == 0 {
                            info!("Archived {} records", records_count);
                        }
                    }
                    Err(_e) => {
                        let hex = hex::encode(bytes);
                        error!("cannot parse BMP: {}", hex);
                        break;
                    }
                }
            }
            let _ = con.consume_messageset(ms);
        }
        con.commit_consumed()?;
    }
}

pub fn main() {
    tracing_subscriber::fmt::init();

    ctrlc::set_handler(move || {
        info!("received Ctrl+C!");
        info!(
            "BGP messages from RouteViews AMSIX peer at AS34968 archived to {}",
            MRT_OUTPUT_FILE
        );
        info!("bgpkit-parser {}", MRT_OUTPUT_FILE);
        exit(0);
    })
    .expect("Error setting Ctrl-C handler");

    let broker = "stream.routeviews.org:9092".to_owned();
    let topic = "routeviews.amsix.34968.bmp_raw".to_owned();
    let group = "bgpkit-parser-example".to_owned();

    consume_and_archive(group, topic, vec![broker]).unwrap();
}
