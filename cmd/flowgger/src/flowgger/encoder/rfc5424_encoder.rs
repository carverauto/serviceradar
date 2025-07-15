use super::Encoder;
use crate::flowgger::config::Config;
use crate::flowgger::record::Record;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const DEFAULT_PRIORITY: &str = "<13>";
const DEFAULT_SYSLOG_VERSION: char = '1';

#[derive(Clone)]
pub struct RFC5424Encoder;

impl RFC5424Encoder {
    pub fn new(_config: &Config) -> RFC5424Encoder {
        RFC5424Encoder
    }
}

impl Encoder for RFC5424Encoder {
    /// Implementation of the RF5424 encoder. Encode a record object into a string
    ///
    /// # Arguments
    /// * `record` - Record object containing the log info to encode
    ///
    /// # Returns
    /// * Array of chars containing the encoded object as a string
    ///
    fn encode(&self, record: Record) -> Result<Vec<u8>, &'static str> {
        let mut res = String::new();

        // If a priority is specified, add it
        if record.facility.is_some() && record.severity.is_some() {
            let npri: u8 =
                ((record.facility.unwrap() << 3) & 0xF8) + (record.severity.unwrap() & 0x7);
            res.push_str(&format!("<{npri}>"));
        } else {
            res.push_str(DEFAULT_PRIORITY);
        }
        res.push(DEFAULT_SYSLOG_VERSION);
        res.push(' ');

        // Convert the float timestamp in seconds into a number of secs and nanosecs (rounded to ms) to create a date object
        let ts_ns = ((record.ts * 1000.0) as i128) * 1_000_000;
        let dt = match OffsetDateTime::from_unix_timestamp_nanos(ts_ns) {
            Ok(date) => date,
            Err(_) => return Err("Failed to parse date"),
        };

        // Add timestamp + space
        let date = match dt.format(&Rfc3339) {
            Ok(date_str) => date_str,
            Err(_) => return Err("Failed to parse date as Rfc3339 format"),
        };
        res.push_str(&date);
        res.push(' ');

        // Add hostname + space
        res.push_str(&record.hostname);
        res.push(' ');

        // Add appname/procid/msgid if specified
        if let Some(appname) = record.appname {
            res.push_str(&appname);
            res.push(' ');
        }
        if let Some(procid) = record.procid {
            res.push_str(&procid.to_string());
        } else {
            res.push('-');
        }
        res.push(' ');
        if let Some(msgid) = record.msgid {
            res.push_str(&msgid);
        } else {
            res.push('-');
        }
        res.push(' ');

        if let Some(sd_vec) = record.sd {
            for sd in &sd_vec {
                res.push_str(&sd.to_string());
            }
            res.push(' ');
        } else {
            res.push_str("- ");
        }

        if let Some(msg) = record.msg {
            res.push_str(&msg);
        }

        Ok(res.into_bytes())
    }
}

#[cfg(test)]
use crate::flowgger::record::{SDValue, StructuredData};
#[cfg(test)]
use crate::flowgger::utils::test_utils::rfc_test_utils::ts_from_date_time;
#[cfg(test)]
use time::Month;

#[test]
fn test_rfc5424_encode() {
    let expected_msg = r#"<13>1 2015-08-06T11:15:24.638Z testhostname - - - some test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc5424\"\n").unwrap();
    let ts = ts_from_date_time(2015, Month::August, 6, 11, 15, 24, 638);

    let record = Record {
        ts,
        hostname: "testhostname".to_string(),
        remote_addr: None,
        facility: None,
        severity: None,
        appname: None,
        procid: None,
        msgid: None,
        msg: Some("some test message".to_string()),
        full_msg: Some(expected_msg.to_string()),
        sd: None,
    };

    let encoder = RFC5424Encoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}

#[test]
fn test_rfc5424_full_encode() {
    let expected_msg = r#"<25>1 2015-08-05T15:53:45.382Z testhostname appname 69 42 [origin@123 software="test sc\"ript" swVersion="0.0.1"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc5424\"\n").unwrap();
    let ts = ts_from_date_time(2015, Month::August, 5, 15, 53, 45, 382);

    let record = Record {
        ts,
        hostname: "testhostname".to_string(),
        remote_addr: None,
        facility: Some(3),
        severity: Some(1),
        appname: Some("appname".to_string()),
        procid: Some("69".to_string()),
        msgid: Some("42".to_string()),
        msg: Some("test message".to_string()),
        full_msg: Some(expected_msg.to_string()),
        sd: Some(vec![StructuredData {
            sd_id: Some("origin@123".to_string()),
            pairs: vec![
                (
                    "software".to_string(),
                    SDValue::String(r#"test sc\"ript"#.to_string()),
                ),
                (
                    "swVersion".to_string(),
                    SDValue::String("0.0.1".to_string()),
                ),
            ],
        }]),
    };

    let encoder = RFC5424Encoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}

#[test]
fn test_rfc5424_full_encode_multiple_sd() {
    let expected_msg = r#"<25>1 2015-08-05T15:53:45.382Z testhostname appname 69 42 [origin@123 software="test sc\"ript" swVersion="0.0.1"][master@456 key1="value1" key2="value2"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc5424\"\n").unwrap();
    let ts = ts_from_date_time(2015, Month::August, 5, 15, 53, 45, 382);

    let record = Record {
        ts,
        hostname: "testhostname".to_string(),
        remote_addr: None,
        facility: Some(3),
        severity: Some(1),
        appname: Some("appname".to_string()),
        procid: Some("69".to_string()),
        msgid: Some("42".to_string()),
        msg: Some("test message".to_string()),
        full_msg: Some(expected_msg.to_string()),
        sd: Some(vec![
            StructuredData {
                sd_id: Some("origin@123".to_string()),
                pairs: vec![
                    (
                        "software".to_string(),
                        SDValue::String(r#"test sc\"ript"#.to_string()),
                    ),
                    (
                        "swVersion".to_string(),
                        SDValue::String("0.0.1".to_string()),
                    ),
                ],
            },
            StructuredData {
                sd_id: Some("master@456".to_string()),
                pairs: vec![
                    ("key1".to_string(), SDValue::String(r#"value1"#.to_string())),
                    ("key2".to_string(), SDValue::String("value2".to_string())),
                ],
            },
        ]),
    };

    let encoder = RFC5424Encoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}
