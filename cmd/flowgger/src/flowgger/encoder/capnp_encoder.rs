use super::Encoder;
use crate::flowgger::config::Config;
use crate::flowgger::record::{Record, SDValue, FACILITY_MISSING, SEVERITY_MISSING};
use crate::record_capnp;
use capnp;
use capnp::message::{Allocator, Builder};

#[derive(Clone)]
pub struct CapnpEncoder {
    extra: Vec<(String, String)>,
}

impl CapnpEncoder {
    pub fn new(config: &Config) -> CapnpEncoder {
        let extra = match config.lookup("output.capnp_extra") {
            None => Vec::new(),
            Some(extra) => extra
                .as_table()
                .expect("output.capnp_extra must be a list of key/value pairs")
                .iter()
                .map(|(k, v)| {
                    (
                        k.to_owned(),
                        v.as_str()
                            .expect("output.capnp_extra values must be strings")
                            .to_owned(),
                    )
                })
                .collect(),
        };
        CapnpEncoder { extra }
    }
}

impl Encoder for CapnpEncoder {
    fn encode(&self, record: Record) -> Result<Vec<u8>, &'static str> {
        let mut record_msg = Builder::new_default();
        build_record(&mut record_msg, record, &self.extra);
        let mut bytes = Vec::new();
        capnp::serialize::write_message(&mut bytes, &record_msg)
            .or(Err("Unable to serialize to Cap'n Proto format"))?;
        Ok(bytes)
    }
}

fn build_record<T: Allocator>(
    record_msg: &mut capnp::message::Builder<T>,
    record: Record,
    extra: &[(String, String)],
) {
    let mut root: record_capnp::record::Builder = record_msg.init_root();
    root.set_ts(record.ts);
    root.set_hostname(&record.hostname);
    match record.facility {
        Some(facility) => root.set_facility(facility),
        _ => root.set_facility(FACILITY_MISSING),
    };
    match record.severity {
        Some(severity) => root.set_severity(severity),
        _ => root.set_severity(SEVERITY_MISSING),
    };
    if let Some(appname) = record.appname {
        root.set_appname(&appname);
    }
    if let Some(procid) = record.procid {
        root.set_procid(&procid);
    }
    if let Some(msgid) = record.msgid {
        root.set_msgid(&msgid);
    }
    if let Some(msg) = record.msg {
        root.set_msg(&msg);
    }
    if let Some(full_msg) = record.full_msg {
        root.set_full_msg(&full_msg);
    }
    if let Some(sd_vec) = record.sd {
        // Warning: the current capnp format only support one structured data. Redefining the
        // format would be a breaking change.
        let sd = &sd_vec[0];
        sd.sd_id.as_ref().and_then(|sd_id| {
            root.set_sd_id(sd_id);
            Some(())
        });
        let mut pairs = root.reborrow().init_pairs(sd.pairs.len() as u32);
        for (i, (name, value)) in (&sd.pairs).into_iter().enumerate() {
            let mut pair = pairs.reborrow().get(i as u32);
            pair.set_key(&name);
            let mut v = pair.init_value();
            match value {
                SDValue::String(value) => v.set_string(&value),
                SDValue::Bool(value) => v.set_bool(*value),
                SDValue::F64(value) => v.set_f64(*value),
                SDValue::I64(value) => v.set_i64(*value),
                SDValue::U64(value) => v.set_u64(*value),
                SDValue::Null => v.set_null(()),
            };
        }
    }
    if !extra.is_empty() {
        let mut pairs = root.init_extra(extra.len() as u32);
        for (i, &(ref name, ref value)) in extra.iter().enumerate() {
            let mut pair = pairs.reborrow().get((i) as u32);
            pair.set_key(name);
            let mut v = pair.init_value();
            v.set_string(value)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::flowgger::record::{SDValue, StructuredData};

    #[test]
    fn test_capnp_encode() {
        let config = Config::from_string("").unwrap();
        let encoder = CapnpEncoder::new(&config);

        let sd = StructuredData {
            sd_id: Some("someid".to_string()),
            pairs: vec![("_some_info".to_string(), SDValue::String("foo".to_string()))],
        };
        let record = Record {
            ts: 1385053862.3072,
            hostname: "example.org".to_string(),
            facility: None,
            severity: Some(1),
            appname: Some("appname".to_string()),
            procid: Some("44".to_string()),
            msgid: None,
            msg: Some("A short message that helps you identify what is going on".to_string()),
            full_msg: Some("Backtrace here\n\nmore stuff".to_string()),
            sd: Some(vec![sd]),
        };

        assert_eq!(
            String::from_utf8_lossy(&encoder.encode(record).unwrap()),
            "\u{0}\u{0}\u{0}\u{0}%\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{2}\u{0}\t\u{0}*������A�\u{1}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}!\u{0}\u{0}\u{0}b\u{0}\u{0}\u{0}%\u{0}\u{0}\u{0}B\u{0}\u{0}\u{0}%\u{0}\u{0}\u{0}\u{1a}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}!\u{0}\u{0}\u{0}�\u{1}\u{0}\u{0}=\u{0}\u{0}\u{0}�\u{0}\u{0}\u{0}I\u{0}\u{0}\u{0}:\u{0}\u{0}\u{0}I\u{0}\u{0}\u{0}\'\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}example.org\u{0}\u{0}\u{0}\u{0}\u{0}appname\u{0}44\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}A short message that helps you identify what is going on\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}Backtrace here\n\nmore stuff\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}someid\u{0}\u{0}\u{4}\u{0}\u{0}\u{0}\u{2}\u{0}\u{2}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{5}\u{0}\u{0}\u{0}Z\u{0}\u{0}\u{0}\t\u{0}\u{0}\u{0}\"\u{0}\u{0}\u{0}_some_info\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}foo\u{0}\u{0}\u{0}\u{0}\u{0}"
        );
    }

    #[test]
    #[should_panic]
    fn test_wrong_extra_field_value_type_config() {
        let config = Config::from_string("[output.capnp_extra]\nx-header1 = 123").unwrap();
        CapnpEncoder::new(&config);
    }

    #[test]
    fn test_add_extra_fields() {
        let config =
            Config::from_string("[output.capnp_extra]\nx-header1 = \"header1 value\"").unwrap();
        let encoder = CapnpEncoder::new(&config);

        let record = Record {
            ts: 1385053862.3072,
            hostname: "example.org".to_string(),
            facility: None,
            severity: Some(1),
            appname: Some("appname".to_string()),
            procid: Some("44".to_string()),
            msgid: None,
            msg: Some("A short message that helps you identify what is going on".to_string()),
            full_msg: Some("Backtrace here\n\nmore stuff".to_string()),
            sd: None,
        };

        assert_eq!(
            String::from_utf8_lossy(&encoder.encode(record).unwrap()),
            "\u{0}\u{0}\u{0}\u{0}%\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{2}\u{0}\t\u{0}*������A�\u{1}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}!\u{0}\u{0}\u{0}b\u{0}\u{0}\u{0}%\u{0}\u{0}\u{0}B\u{0}\u{0}\u{0}%\u{0}\u{0}\u{0}\u{1a}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}!\u{0}\u{0}\u{0}�\u{1}\u{0}\u{0}=\u{0}\u{0}\u{0}�\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}A\u{0}\u{0}\u{0}\'\u{0}\u{0}\u{0}example.org\u{0}\u{0}\u{0}\u{0}\u{0}appname\u{0}44\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}A short message that helps you identify what is going on\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}Backtrace here\n\nmore stuff\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{4}\u{0}\u{0}\u{0}\u{2}\u{0}\u{2}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{5}\u{0}\u{0}\u{0}R\u{0}\u{0}\u{0}\t\u{0}\u{0}\u{0}r\u{0}\u{0}\u{0}x-header1\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}header1 value\u{0}\u{0}\u{0}"
        );
    }

    #[test]
    fn test_capnp_encode_multiple_sd() {
        let config = Config::from_string("").unwrap();
        let encoder = CapnpEncoder::new(&config);

        let sd_vec = vec![
            StructuredData {
                sd_id: Some("someid".to_string()),
                pairs: vec![("_some_info".to_string(), SDValue::String("foo".to_string()))],
            },
            StructuredData {
                sd_id: Some("someid2".to_string()),
                pairs: vec![("info".to_string(), SDValue::F64(123.456))],
            },
        ];
        let record = Record {
            ts: 1385053862.3072,
            hostname: "example.org".to_string(),
            facility: None,
            severity: Some(1),
            appname: Some("appname".to_string()),
            procid: Some("44".to_string()),
            msgid: None,
            msg: Some("A short message that helps you identify what is going on".to_string()),
            full_msg: Some("Backtrace here\n\nmore stuff".to_string()),
            sd: Some(sd_vec),
        };

        assert_eq!(
            String::from_utf8_lossy(&encoder.encode(record).unwrap()),
            "\u{0}\u{0}\u{0}\u{0}%\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{2}\u{0}\t\u{0}*������A�\u{1}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}!\u{0}\u{0}\u{0}b\u{0}\u{0}\u{0}%\u{0}\u{0}\u{0}B\u{0}\u{0}\u{0}%\u{0}\u{0}\u{0}\u{1a}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}!\u{0}\u{0}\u{0}�\u{1}\u{0}\u{0}=\u{0}\u{0}\u{0}�\u{0}\u{0}\u{0}I\u{0}\u{0}\u{0}:\u{0}\u{0}\u{0}I\u{0}\u{0}\u{0}\'\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}example.org\u{0}\u{0}\u{0}\u{0}\u{0}appname\u{0}44\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}A short message that helps you identify what is going on\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}Backtrace here\n\nmore stuff\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}someid\u{0}\u{0}\u{4}\u{0}\u{0}\u{0}\u{2}\u{0}\u{2}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{5}\u{0}\u{0}\u{0}Z\u{0}\u{0}\u{0}\t\u{0}\u{0}\u{0}\"\u{0}\u{0}\u{0}_some_info\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}foo\u{0}\u{0}\u{0}\u{0}\u{0}"
        );
    }
}
