use super::{build_prepend_ts, config_get_prepend_ts, Encoder};
use crate::flowgger::config::Config;
use crate::flowgger::record::Record;
use time::{format_description, OffsetDateTime};

#[derive(Clone)]
pub struct RFC3164Encoder {
    header_time_format: Option<String>,
}

impl RFC3164Encoder {
    pub fn new(config: &Config) -> RFC3164Encoder {
        let header_time_format = config_get_prepend_ts(config);

        RFC3164Encoder { header_time_format }
    }
}

impl Encoder for RFC3164Encoder {
    /// Implementation of the RF3164 encoder. Encode a record object into a string
    ///
    /// # Arguments
    /// * `record` - Record object containing the log info to encode
    ///
    /// # Returns
    /// * Array of chars containing the encoded object as a string
    ///
    fn encode(&self, record: Record) -> Result<Vec<u8>, &'static str> {
        let mut res = String::new();

        // First, if specified, prepend a header
        if self.header_time_format.is_some() {
            let ts = match build_prepend_ts(self.header_time_format.as_ref().unwrap()) {
                Ok(ts) => ts,
                Err(_) => {
                    return Err("Failed to format date when building prepend timestamp for header while encoding RFC3164")
                }
            };
            res.push_str(&ts);
        }

        // If a priority is specified, add it
        if record.facility.is_some() && record.severity.is_some() {
            let npri: u8 =
                ((record.facility.unwrap() << 3) & 0xF8) + (record.severity.unwrap() & 0x7);
            res.push_str(&format!("<{}>", npri));
        }

        // Add timestamp + space
        let dt = match OffsetDateTime::from_unix_timestamp(record.ts as i64) {
            Ok(date) => date,
            Err(_) => return Err("Failed to parse unix timestamp in RFC3164 encoder"),
        };

        let format_item = format_description::parse(
            "[month repr:short]  [day padding:none] [hour]:[minute]:[second] ",
        )
        .unwrap();

        let dt_str = match dt.format(&format_item) {
            Ok(date_str) => date_str,
            Err(_) => return Err("Failed to format date in RFC3164 encoder"),
        };

        res.push_str(&dt_str);

        // Add hostname + space
        res.push_str(&record.hostname);
        res.push(' ');

        // Add appname/procid/msgid if specified
        if let Some(appname) = record.appname {
            res.push_str(&appname);
        }
        if let Some(procid) = record.procid {
            res.push_str(&format!("[{}]:", procid));
            res.push(' ');
        }
        if let Some(msgid) = record.msgid {
            res.push_str(&msgid);
            res.push(' ');
        }

        // Encode structured data is present, although not part of rfc3164
        if let Some(sd_vec) = record.sd {
            for &ref sd in &sd_vec {
                res.push_str(&sd.to_string());
            }
            res.push(' ');
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
use crate::flowgger::utils::test_utils::rfc_test_utils::ts_from_partial_date_time;
#[cfg(test)]
use time::Month;

#[test]
fn test_rfc3164_encode() {
    let expected_msg = r#"Aug  6 11:15:24 testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);

    let record = Record {
        ts,
        hostname: "testhostname".to_string(),
        remote_addr: None,
        facility: None,
        severity: None,
        appname: None,
        procid: None,
        msgid: None,
        msg: Some(r#"appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#.to_string()),
        full_msg: Some(expected_msg.to_string()),
        sd: None,
    };

    let encoder = RFC3164Encoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}

#[test]
fn test_rfc3164_withpri_encode() {
    let expected_msg = r#"<23>Aug  6 11:15:24 testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);

    let record = Record {
        ts,
        hostname: "testhostname".to_string(),
        remote_addr: None,
        facility: Some(2),
        severity: Some(7),
        appname: None,
        procid: None,
        msgid: None,
        msg: Some(r#"appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#.to_string()),
        full_msg: Some(expected_msg.to_string()),
        sd: None,
    };

    let encoder = RFC3164Encoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}

#[test]
fn test_rfc3164_encode_with_prepend() {
    const TIME_FORMAT: &str = "[year]-[month]-[day]T[hour]:[minute]Z";
    let config_str = &format!(
        "[output]\nformat = \"rfc3164\"\nsyslog_prepend_timestamp=\"{}\"",
        TIME_FORMAT
    );
    let cfg = Config::from_string(config_str).unwrap();
    let ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);
    let now = OffsetDateTime::now_utc();
    let format_item = format_description::parse(TIME_FORMAT).unwrap();
    let dt_str = now.format(&format_item).unwrap().to_string();
    let expected_msg = format!(
        r#"{}Aug  6 11:15:24 testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#,
        dt_str
    );

    let record = Record {
        ts,
        hostname: "testhostname".to_string(),
        remote_addr: None,
        facility: None,
        severity: None,
        appname: None,
        procid: None,
        msgid: None,
        msg: Some(r#"appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#.to_string()),
        full_msg: Some(expected_msg.to_string()),
        sd: None,
    };

    let encoder = RFC3164Encoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}

#[test]
#[should_panic(expected = "output.syslog_prepend_timestamp should be a string")]
fn test_rfc3164_invalid_prepend() {
    let cfg = Config::from_string("[output]\nformat = \"rfc3164\"\nsyslog_prepend_timestamp=123")
        .unwrap();
    let _ = RFC3164Encoder::new(&cfg);
}

#[test]
fn test_rfc3164_full_encode() {
    let expected_msg = r#"<23>Aug  6 11:15:24 testhostname appname[69]: 42 [someid a="b" c="123456"] some test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);

    let record = Record {
        ts,
        hostname: "testhostname".to_string(),
        remote_addr: None,
        facility: Some(2),
        severity: Some(7),
        appname: Some("appname".to_string()),
        procid: Some("69".to_string()),
        msgid: Some("42".to_string()),
        msg: Some(r#"some test message"#.to_string()),
        full_msg: Some(expected_msg.to_string()),
        sd: Some(vec![StructuredData {
            sd_id: Some("someid".to_string()),
            pairs: vec![
                ("a".to_string(), SDValue::String("b".to_string())),
                ("c".to_string(), SDValue::U64(123456)),
            ],
        }]),
    };

    let encoder = RFC3164Encoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}

#[test]
fn test_rfc3164_full_encode_multiple_sd() {
    let expected_msg = r#"<23>Aug  6 11:15:24 testhostname appname[69]: 42 [someid a="b" c="123456"][someid2 a2="b2" c2="123456"] some test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);

    let record = Record {
        ts,
        hostname: "testhostname".to_string(),
        remote_addr: None,
        facility: Some(2),
        severity: Some(7),
        appname: Some("appname".to_string()),
        procid: Some("69".to_string()),
        msgid: Some("42".to_string()),
        msg: Some(r#"some test message"#.to_string()),
        full_msg: Some(expected_msg.to_string()),
        sd: Some(vec![
            StructuredData {
                sd_id: Some("someid".to_string()),
                pairs: vec![
                    ("a".to_string(), SDValue::String("b".to_string())),
                    ("c".to_string(), SDValue::U64(123456)),
                ],
            },
            StructuredData {
                sd_id: Some("someid2".to_string()),
                pairs: vec![
                    ("a2".to_string(), SDValue::String("b2".to_string())),
                    ("c2".to_string(), SDValue::U64(123456)),
                ],
            },
        ]),
    };

    let encoder = RFC3164Encoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}
