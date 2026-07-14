use bgpkit_parser::parser::bmp::messages::BmpMessageBody;
use bgpkit_parser::Elementor;
pub use bgpkit_parser::{parse_bmp_msg, parse_openbmp_header};
use bytes::Bytes;
use kafka::client::KafkaClient;
use kafka::consumer::{Consumer, FetchOffset, GroupOffsetStorage};
use kafka::error::Error as KafkaError;
use log::{error, info};
use std::thread::sleep;
use std::time::Duration;

fn get_matching_topics(client: &mut KafkaClient, pattern: &str) -> Vec<String> {
    let re = regex::Regex::new(pattern).expect("Invalid regex pattern");
    client.load_metadata_all().expect("Failed to load metadata");
    client
        .topics()
        .iter()
        .filter(|t| re.is_match(t.name())) // Adjust pattern matching as necessary
        .map(|t| t.name().to_string())
        .collect()
}

fn consume_and_print(
    group: String,
    pattern: String,
    brokers: Vec<String>,
) -> Result<(), KafkaError> {
    let mut client = KafkaClient::new(brokers);
    client
        .load_metadata_all()
        .expect("Failed to connect to Kafka");
    let topics = get_matching_topics(&mut client, pattern.as_str());
    dbg!(&topics);

    let mut builder = Consumer::from_client(client);
    for topic in topics {
        builder = builder.with_topic(topic);
    }
    let mut con = builder
        .with_group(group)
        .with_fetch_max_bytes_per_partition(100_000)
        .with_retry_max_bytes_limit(1_000_000)
        .with_fallback_offset(FetchOffset::Earliest)
        .with_offset_storage(Some(GroupOffsetStorage::Kafka))
        .create()?;

    loop {
        let mss = con.poll()?;
        if mss.is_empty() {
            println!("No messages available right now, wait for 5 seconds.");
            sleep(Duration::from_secs(5));
            continue;
        }

        for ms in mss.iter() {
            for m in ms.messages() {
                let mut bytes = Bytes::from(m.value.to_vec());
                let header = parse_openbmp_header(&mut bytes).unwrap();
                let bmp_msg = parse_bmp_msg(&mut bytes);
                match bmp_msg {
                    Ok(msg) => {
                        let per_peer_header = msg.per_peer_header.unwrap();
                        if let BmpMessageBody::RouteMonitoring(m) = msg.message_body {
                            for elem in Elementor::bgp_to_elems(
                                m.bgp_message,
                                header.timestamp,
                                &per_peer_header.peer_ip,
                                &per_peer_header.peer_asn,
                            ) {
                                info!("{}", elem);
                            }
                        }
                    }
                    Err(_e) => {
                        let hex = hex::encode(bytes);
                        error!("{}", hex);
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

    let broker = "stream.routeviews.org:9092".to_owned();
    // "routeviews.amsix.ams.61955.bmp_raw"
    let pattern = r#"routeviews\.amsix\.ams\..*\.bmp_raw"#.to_owned();
    let group = "bgpkit-parser-example".to_owned();

    consume_and_print(group, pattern, vec![broker]).unwrap();
}
