use super::Encoder;
use crate::flowgger::config::Config;
use crate::flowgger::record::{Record, SDValue};

#[derive(Clone)]
pub struct LTSVEncoder {
    extra: Vec<(String, String)>,
}

impl LTSVEncoder {
    pub fn new(config: &Config) -> LTSVEncoder {
        let extra = match config.lookup("output.ltsv_extra") {
            None => Vec::new(),
            Some(extra) => extra
                .as_table()
                .expect("output.ltsv_extra must be a list of key/value pairs")
                .iter()
                .map(|(k, v)| {
                    (
                        k.to_owned(),
                        v.as_str()
                            .expect("output.ltsv_extra values must be strings")
                            .to_owned(),
                    )
                })
                .collect(),
        };
        LTSVEncoder { extra }
    }
}

struct LTSVString {
    out: String,
}

impl LTSVString {
    pub fn new() -> LTSVString {
        LTSVString { out: String::new() }
    }

    pub fn insert(&mut self, key: &str, value: &str) {
        if !self.out.is_empty() {
            self.out.push('\t');
        }
        if key.chars().any(|s| s == '\n' || s == '\t' || s == ':') {
            let key_esc = key.replace("\n", " ").replace("\t", " ").replace(":", "_");
            self.out.push_str(&key_esc);
        } else {
            self.out.push_str(key);
        };
        self.out.push(':');
        if value.chars().any(|s| s == '\n' || s == '\t') {
            let value_esc = value.replace("\t", " ").replace("\n", " ");
            self.out.push_str(&value_esc);
        } else {
            self.out.push_str(value);
        };
    }

    pub fn finalize(self) -> String {
        self.out
    }
}

impl Encoder for LTSVEncoder {
    fn encode(&self, record: Record) -> Result<Vec<u8>, &'static str> {
        let mut res = LTSVString::new();
        if let Some(sd_vec) = record.sd {
            for &ref sd in &sd_vec {
                // Warning: LTSV doesn't have a concept of structued data. In case there are
                // several, all their attributes will be aded as fields. So if several structured
                // data have the same key, only the last value will show as it will overwrite the
                // others. We could use the sd_id to prefix the field to sove this but this is a
                // breaking change.
                for &(ref name, ref value) in &sd.pairs {
                    let name = if (*name).starts_with('_') {
                        &name[1..] as &str
                    } else {
                        name as &str
                    };
                    match *value {
                        SDValue::String(ref value) => res.insert(name, value),
                        SDValue::Bool(ref value) => res.insert(name, &value.to_string()),
                        SDValue::F64(ref value) => res.insert(name, &value.to_string()),
                        SDValue::I64(ref value) => res.insert(name, &value.to_string()),
                        SDValue::U64(ref value) => res.insert(name, &value.to_string()),
                        SDValue::Null => res.insert(name, ""),
                    }
                }
            }
        }
        for &(ref name, ref value) in &self.extra {
            let name = if (*name).starts_with('_') {
                &name[1..] as &str
            } else {
                name as &str
            };
            res.insert(name, value);
        }
        res.insert("host", &record.hostname);
        res.insert("time", &record.ts.to_string());
        if let Some(msg) = record.msg {
            res.insert("message", &msg);
        }
        if let Some(full_msg) = record.full_msg {
            res.insert("full_message", &full_msg);
        }
        if let Some(severity) = record.severity {
            res.insert("level", &format!("{}", severity));
        }
        if let Some(facility) = record.facility {
            res.insert("facility", &format!("{}", facility));
        }
        if let Some(appname) = record.appname {
            res.insert("appname", &appname);
        }
        if let Some(procid) = record.procid {
            res.insert("procid", &procid);
        }
        if let Some(msgid) = record.msgid {
            res.insert("msgid", &msgid);
        }
        Ok(res.finalize().into_bytes())
    }
}

#[cfg(test)]
use crate::flowgger::record::StructuredData;
#[cfg(test)]
use crate::flowgger::utils::test_utils::rfc_test_utils::ts_from_partial_date_time;
#[cfg(test)]
use time::Month;

#[test]
fn test_ltsv_full_encode_no_sd() {
    let full_msg = "<23>Aug  6 11:15:24 testhostname appname[69]: 42 - some test message";
    let ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);
    let expected_msg = format!("host:testhostname\ttime:{}\tmessage:some test message\tfull_message:<23>Aug  6 11:15:24 testhostname appname[69]: 42 - some test message\tlevel:7\tfacility:2\tappname:appname\tprocid:69\tmsgid:42", ts);
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"ltsv\"\n").unwrap();

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
        full_msg: Some(full_msg.to_string()),
        sd: None,
    };

    let encoder = LTSVEncoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}

#[test]
fn test_ltsv_full_encode_multiple_sd() {
    let full_msg = "<23>Aug  6 11:15:24 testhostname appname[69]: 42 [someid a=\"b\" c=\"123456\"][someid2 a2=\"b2\" c2=\"123456\"] some test message";
    let ts = ts_from_partial_date_time(Month::August, 6, 11, 15, 24);
    let expected_msg = format!("a:b\tc:123456\ta2:b2\tc2:123456\thost:testhostname\ttime:{}\tmessage:some test message\tfull_message:<23>Aug  6 11:15:24 testhostname appname[69]: 42 [someid a=\"b\" c=\"123456\"][someid2 a2=\"b2\" c2=\"123456\"] some test message\tlevel:7\tfacility:2\tappname:appname\tprocid:69\tmsgid:42", ts);
    let cfg = Config::from_string("[input]\n[input.ltsv_schema]\nformat = \"ltsv\"\n").unwrap();

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
        full_msg: Some(full_msg.to_string()),
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

    let encoder = LTSVEncoder::new(&cfg);
    let res = encoder.encode(record).unwrap();
    assert_eq!(String::from_utf8_lossy(&res), expected_msg);
}
