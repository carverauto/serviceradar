use super::Decoder;
use crate::flowgger::config::Config;
use crate::flowgger::record::Record;
use crate::flowgger::utils;
use std::io::{stderr, Write};
use time::{format_description, OffsetDateTime, PrimitiveDateTime};
use time_tz::timezones::get_by_name;
use time_tz::PrimitiveDateTimeExt;

#[derive(Clone)]
pub struct RFC3164Decoder {}

impl RFC3164Decoder {
    pub fn new(_config: &Config) -> RFC3164Decoder {
        RFC3164Decoder {}
    }
}

impl Decoder for RFC3164Decoder {
    /// Implementation of the RF3164 decoder. Decode a string into a record object.alloc
    /// RFC3164 is quite lenient and allow many different implementation.
    /// This decoder starts decoding the most common format, as exampled provided in RFC.
    /// If this fails, device specific implementations are looked for.
    ///
    /// # Arguments
    /// * `line` - String to decode
    ///
    /// # Returns
    /// * Record object containing the log info extracted
    ///
    fn decode(&self, line: &str) -> Result<Record, &'static str> {
        // Get the optional pri part and remove it from the string
        let (pri, _msg) = parse_strip_pri(line)?;

        let mut res = decode_rfc_standard(&pri, _msg, line);
        if let Ok(record) = res {
            return Ok(record);
        }

        // Specific implementation
        res = decode_rfc_custom(&pri, _msg, line);
        if let Ok(record) = res {
            return Ok(record);
        }

        let _ = writeln!(stderr(), "Unable to parse the rfc3164 input: '{line}'");
        res
    }
}

struct Pri {
    facility: Option<u8>,
    severity: Option<u8>,
}

fn decode_rfc_standard(pri: &Pri, msg: &str, line: &str) -> Result<Record, &'static str> {
    // Decoding "recommended" rfc input as advised in the rfc: [<pri>]<datetime> <hostname> <message>

    // The event may have several consecutive spaces as separator
    let tokens_vec = msg.split_whitespace().collect::<Vec<&str>>();

    // If we have less than 4 tokens, the input can't be valid
    if tokens_vec.len() > 3 {
        // Parse the date, the next token is the hostname
        let (ts, _log_tokens) = parse_date_token(&tokens_vec)?;
        let _hostname = _log_tokens[0];

        // All that remains is the message that may contain several spaces, so rebuild it
        let _message = _log_tokens[1..].join(" ");

        let record = Record {
            ts,
            hostname: _hostname.to_owned(),
            remote_addr: None,
            facility: pri.facility,
            severity: pri.severity,
            appname: None,
            procid: None,
            msgid: None,
            msg: Some(_message.to_owned()),
            full_msg: Some(line.trim_end().to_owned()),
            sd: None,
        };
        Ok(record)
    } else {
        Err("Malformed RFC3164 standard event: Invalid timestamp or hostname")
    }
}

fn decode_rfc_custom(pri: &Pri, msg: &str, line: &str) -> Result<Record, &'static str> {
    // Decoding custom rfc input formatted as : [<pri>]<hostname>: <datetime>: <message>

    // The event separator for hostname/timestamp/message is ": "
    let tokens_vec = msg.split(": ").collect::<Vec<&str>>();

    // If we have less than 2 tokens, the input can't be valid
    if tokens_vec.len() > 2 {
        let _hostname = tokens_vec[0];

        // The date is space separated, but make sure to remove consecutive spaces
        let date_tokens_vec = tokens_vec[1].split_whitespace().collect::<Vec<&str>>();
        let (ts, _) = parse_date_token(&date_tokens_vec)?;

        // All that remains is the message, rebuild it
        let _message = tokens_vec[2..].join(": ");

        let record = Record {
            ts,
            hostname: _hostname.to_owned(),
            remote_addr: None,
            facility: pri.facility,
            severity: pri.severity,
            appname: None,
            procid: None,
            msgid: None,
            msg: Some(_message.to_owned()),
            full_msg: Some(line.trim_end().to_owned()),
            sd: None,
        };
        Ok(record)
    } else {
        Err("Malformed RFC3164 event: Invalid timestamp or hostname")
    }
}

fn parse_strip_pri(event: &str) -> Result<(Pri, &str), &'static str> {
    if event.starts_with('<') {
        let pri_end_index = event
            .find('>')
            .ok_or("Malformed RFC3164 event: Invalid priority")?;
        let (pri, msg) = event.split_at(pri_end_index + 1);
        let npri: u8 = pri
            .trim_start_matches('<')
            .trim_end_matches('>')
            .parse()
            .or(Err("Invalid priority"))?;
        Ok((
            Pri {
                facility: Some(npri >> 3),
                severity: Some(npri & 7),
            },
            msg,
        ))
    } else {
        Ok((
            Pri {
                facility: None,
                severity: None,
            },
            event,
        ))
    }
}

fn parse_date_token<'a>(ts_tokens: &'a [&str]) -> Result<(f64, Vec<&'a str>), &'static str> {
    // If we don't have at least 3 tokens, don't even try, parsing will fail
    if ts_tokens.len() < 3 {
        return Err("Invalid time format");
    }
    // Decode the date/time without year (expected), and if it fails, try  add the year
    parse_date(ts_tokens, false).or_else(|_| parse_date(ts_tokens, true))
}

fn parse_date<'a>(
    ts_tokens: &'a [&str],
    has_year: bool,
) -> Result<(f64, Vec<&'a str>), &'static str> {
    // Decode the date/time from the given tokens with optional year specified
    let ts_str;
    let mut idx;

    // If no year in the string, parse manually add the current year
    if has_year {
        idx = 4;
        ts_str = match ts_tokens.get(0..idx) {
            Some(str) => str.join(" "),
            None => return Err("Unable to parse RFC3164 date with year"),
        };
    } else {
        idx = 3;
        let current_year = OffsetDateTime::now_utc().year();
        ts_str = match ts_tokens.get(0..idx) {
            Some(str) => format!("{} {}", current_year, str.join(" ")),
            None => return Err("Unable to parse RFC3164 date without year"),
        };
    }

    let format_item = format_description::parse(
        "[year] [month repr:short] [day padding:none] [hour]:[minute]:[second]",
    )
    .unwrap();
    match PrimitiveDateTime::parse(&ts_str, &format_item) {
        Ok(primitive_date) => {
            // See if the next token is a timezone
            let ts: f64;
            let tz_res = if ts_tokens.len() > idx {
                get_by_name(ts_tokens[idx]).ok_or("No timezone".to_string())
            } else {
                Err("No timezone".to_string())
            };

            if let Ok(tz) = tz_res {
                let dt = primitive_date.assume_timezone(tz);
                ts = utils::PreciseTimestamp::from_offset_datetime(dt).as_f64();
                idx += 1;
            }
            // No timezome, give a timestamp without tz
            else {
                ts = utils::PreciseTimestamp::from_primitive_datetime(primitive_date).as_f64();
            }
            Ok((ts, ts_tokens[idx..].to_vec()))
        }
        Err(_) => Err("Unable to parse the date in RFC3164 decoder"),
    }
}

#[cfg(test)]
use crate::flowgger::utils::test_utils::rfc_test_utils::{
    ts_from_date_time, ts_from_partial_date_time,
};
#[cfg(test)]
use time::Month;

#[test]
fn test_rfc3164_decode_nopri() {
    let msg = r#"Aug  6 11:15:24 testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let expected_ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg).unwrap();
    assert_eq!(res.facility, None);
    assert_eq!(res.severity, None);
    assert_eq!(res.ts, expected_ts);
    assert_eq!(res.hostname, "testhostname");
    assert_eq!(res.appname, None);
    assert_eq!(res.procid, None);
    assert_eq!(res.msgid, None);
    assert_eq!(res.msg, Some(r#"appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#.to_string()));
    assert_eq!(res.full_msg, Some(msg.to_string()));
    assert!(res.sd.is_none());
}

#[test]
fn test_rfc3164_decode_with_pri() {
    let msg = r#"<13>Aug  6 11:15:24 testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let expected_ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg).unwrap();
    assert_eq!(res.facility, Some(1));
    assert_eq!(res.severity, Some(5));
    assert_eq!(res.ts, expected_ts);
    assert_eq!(res.hostname, "testhostname");
    assert_eq!(res.appname, None);
    assert_eq!(res.procid, None);
    assert_eq!(res.msgid, None);
    assert_eq!(res.msg, Some(r#"appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#.to_string()));
    assert_eq!(res.full_msg, Some(msg.to_string()));
    assert!(res.sd.is_none());
}

#[test]
fn test_rfc3164_decode_with_pri_year() {
    let msg = r#"<13>2020 Aug  6 11:15:24 testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let expected_ts = ts_from_date_time(2020, Month::August, 6, 11, 15, 24, 0);

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg).unwrap();
    assert_eq!(res.facility, Some(1));
    assert_eq!(res.severity, Some(5));
    assert_eq!(res.ts, expected_ts);
    assert_eq!(res.hostname, "testhostname");
    assert_eq!(res.appname, None);
    assert_eq!(res.procid, None);
    assert_eq!(res.msgid, None);
    assert_eq!(res.msg, Some(r#"appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#.to_string()));
    assert_eq!(res.full_msg, Some(msg.to_string()));
    assert!(res.sd.is_none());
}

#[test]
fn test_rfc3164_decode_with_pri_year_tz() {
    let msg = r#"<13>2020 Aug 6 05:15:24 America/Sao_Paulo testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let expected_ts = ts_from_date_time(2020, Month::August, 6, 08, 15, 24, 0);

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg).unwrap();
    assert_eq!(res.facility, Some(1));
    assert_eq!(res.severity, Some(5));
    assert_eq!(res.ts, expected_ts);
    assert_eq!(res.hostname, "testhostname");
    assert_eq!(res.appname, None);
    assert_eq!(res.procid, None);
    assert_eq!(res.msgid, None);
    assert_eq!(res.msg, Some(r#"appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#.to_string()));
    assert_eq!(res.full_msg, Some(msg.to_string()));
    assert!(res.sd.is_none());
}

#[test]
fn test_rfc3164_decode_tz_no_year() {
    let msg = r#"Aug  6 11:15:24 UTC testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let expected_ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg).unwrap();
    assert_eq!(res.facility, None);
    assert_eq!(res.severity, None);
    assert_eq!(res.ts, expected_ts);
    assert_eq!(res.hostname, "testhostname");
    assert_eq!(res.appname, None);
    assert_eq!(res.procid, None);
    assert_eq!(res.msgid, None);
    assert_eq!(res.msg, Some(r#"appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#.to_string()));
    assert_eq!(res.full_msg, Some(msg.to_string()));
    assert!(res.sd.is_none());
}

#[test]
fn test_rfc3164_decode_invalid_event() {
    let msg = "test message";
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg);
    assert!(res.is_err());
}

#[test]
fn test_rfc3164_decode_invalid_date() {
    let msg = r#"Aug  36 11:15:24 testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg);
    assert!(res.is_err());
}

#[test]
fn test_rfc3164_decode_custom_with_year() {
    let msg = r#"testhostname: 2020 Aug  6 11:15:24 UTC: appname 69 42 some test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let expected_ts = ts_from_date_time(2020, Month::August, 6, 11, 15, 24, 0);

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg).unwrap();
    assert_eq!(res.facility, None);
    assert_eq!(res.severity, None);
    assert_eq!(res.ts, expected_ts);
    assert_eq!(res.hostname, "testhostname");
    assert_eq!(res.appname, None);
    assert_eq!(res.procid, None);
    assert_eq!(res.msgid, None);
    assert_eq!(
        res.msg,
        Some(r#"appname 69 42 some test message"#.to_string())
    );
    assert_eq!(res.full_msg, Some(msg.to_string()));
    assert!(res.sd.is_none());
}

#[test]
fn test_rfc3164_decode_custom_with_year_notz() {
    let msg = r#"testhostname: 2019 Mar 27 12:09:39: appname: a test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let expected_ts = ts_from_date_time(2019, Month::March, 27, 12, 9, 39, 0);

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg).unwrap();
    assert_eq!(res.facility, None);
    assert_eq!(res.severity, None);
    assert_eq!(res.ts, expected_ts);
    assert_eq!(res.hostname, "testhostname");
    assert_eq!(res.appname, None);
    assert_eq!(res.procid, None);
    assert_eq!(res.msgid, None);
    assert_eq!(res.msg, Some(r#"appname: a test message"#.to_string()));
    assert_eq!(res.full_msg, Some(msg.to_string()));
    assert!(res.sd.is_none());
}

#[test]
fn test_rfc3164_decode_custom_with_pri() {
    let msg = r#"<13>testhostname: 2019 Mar 27 12:09:39 UTC: appname: test message"#;
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let expected_ts = ts_from_date_time(2019, Month::March, 27, 12, 9, 39, 0);

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg).unwrap();
    assert_eq!(res.facility, Some(1));
    assert_eq!(res.severity, Some(5));
    assert_eq!(res.ts, expected_ts);
    assert_eq!(res.hostname, "testhostname");
    assert_eq!(res.appname, None);
    assert_eq!(res.procid, None);
    assert_eq!(res.msgid, None);
    assert_eq!(res.msg, Some(r#"appname: test message"#.to_string()));
    assert_eq!(res.full_msg, Some(msg.to_string()));
    assert!(res.sd.is_none());
}

#[test]
fn test_rfc3164_decode_custom_trimed() {
    let msg = "<13>testhostname: 2019 Mar 27 12:09:39 UTC: appname: test message \n";
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"rfc3164\"\n").unwrap();
    let expected_ts = ts_from_date_time(2019, Month::March, 27, 12, 9, 39, 0);

    let decoder = RFC3164Decoder::new(&cfg);
    let res = decoder.decode(msg).unwrap();
    assert_eq!(res.facility, Some(1));
    assert_eq!(res.severity, Some(5));
    assert_eq!(res.ts, expected_ts);
    assert_eq!(res.hostname, "testhostname");
    assert_eq!(res.appname, None);
    assert_eq!(res.procid, None);
    assert_eq!(res.msgid, None);
    assert_eq!(
        res.full_msg,
        Some("<13>testhostname: 2019 Mar 27 12:09:39 UTC: appname: test message".to_string())
    );
    assert!(res.sd.is_none());
}
