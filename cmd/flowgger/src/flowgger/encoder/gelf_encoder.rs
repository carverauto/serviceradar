use super::Encoder;
use crate::flowgger::config::Config;
use crate::flowgger::record::{Record, SDValue};
use serde_json;
use serde_json::builder::ObjectBuilder;
use serde_json::value::Value;

#[derive(Clone)]
/// Encoder for GELF Json format
/// https://docs.graylog.org/en/3.1/pages/gelf.html
pub struct GelfEncoder {
    extra: Vec<(String, String)>,
}

impl GelfEncoder {
    /// GELF Encoder constructor from parsing the output.gelf_extra section of the config
    /// https://docs.graylog.org/en/3.1/pages/gelf.html
    ///
    /// # Parameters
    ///
    /// - `config`: a configuration file that can contain an output.gelf_extra section of elements,
    /// or be empty. if the gelf_extra section is present it needs to contain a list of `key =
    /// "value"` pairs that will be added to the resulting json or overwritten if already present
    ///
    /// # Panics
    ///
    /// All the possible failures are relative to parsing the configuration file
    /// - `output.gelf_extra must be a list of key/value pairs`
    /// - `output.gelf_extra values must be strings`
    pub fn new(config: &Config) -> GelfEncoder {
        let extra = match config.lookup("output.gelf_extra") {
            None => Vec::new(),
            Some(extra) => extra
                .as_table()
                .expect("output.gelf_extra must be a list of key/value pairs")
                .iter()
                .map(|(k, v)| {
                    (
                        k.to_owned(),
                        v.as_str()
                            .expect("output.gelf_extra values must be strings")
                            .to_owned(),
                    )
                })
                .collect(),
        };
        GelfEncoder { extra }
    }
}

impl Encoder for GelfEncoder {
    /// Implements encode for GELF output types
    ///
    /// # Returns
    /// A `Result` containing
    ///
    /// - `Ok` Containing a byte vector rapresenting a valid GELF JSON
    /// - `Err` if the Record could not be serialized to a valid JSON
    fn encode(&self, record: Record) -> Result<Vec<u8>, &'static str> {
        let mut map = ObjectBuilder::new()
            .insert("version".to_owned(), Value::String("1.1".to_owned()))
            .insert(
                "host".to_owned(),
                Value::String(if record.hostname.is_empty() {
                    "unknown".to_owned()
                } else {
                    record.hostname
                }),
            )
            .insert(
                "short_message".to_owned(),
                Value::String(record.msg.unwrap_or_else(|| "-".to_owned())),
            )
            .insert("timestamp".to_owned(), Value::F64(record.ts));
        if let Some(severity) = record.severity {
            map = map.insert("level".to_owned(), Value::U64(u64::from(severity)));
        }
        if let Some(full_msg) = record.full_msg {
            map = map.insert("full_message".to_owned(), Value::String(full_msg));
        }
        if let Some(appname) = record.appname {
            map = map.insert("application_name".to_owned(), Value::String(appname));
        }
        if let Some(procid) = record.procid {
            map = map.insert("process_id".to_owned(), Value::String(procid));
        }
        if let Some(sd_vec) = record.sd {
            for &ref sd in &sd_vec {
                // Warning: Gelf doesn't have a concept of structued data. In case there are
                // several, all their attributes will be aded as fields. So if several structured
                // data have the same key, only the last value will show as it will overwrite the
                // others. We could use the sd_id to prefix the field to sove this but this is a
                // breaking change.
                if let Some(sd_id) = &sd.sd_id {
                    map = map.insert("sd_id".to_owned(), Value::String(sd_id.to_string()));
                }
                for (name, value) in &sd.pairs {
                    let value = match value {
                        SDValue::String(value) => Value::String(value.to_string()),
                        SDValue::Bool(value) => Value::Bool(*value),
                        SDValue::F64(value) => Value::F64(*value),
                        SDValue::I64(value) => Value::I64(*value),
                        SDValue::U64(value) => Value::U64(*value),
                        SDValue::Null => Value::Null,
                    };
                    map = map.insert(name, value);
                }
            }
        }
        for (name, value) in self.extra.iter().cloned() {
            map = map.insert(name, Value::String(value));
        }
        let json = serde_json::to_vec(&map.build()).or(Err("Unable to serialize to JSON"))?;
        Ok(json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::flowgger::record::{SDValue, StructuredData};

    #[test]
    fn test_gelf_encode() {
        let expected_msg = r#"{"_some_info":"foo","application_name":"appname","full_message":"Backtrace here\n\nmore stuff","host":"example.org","level":1,"process_id":"44","sd_id":"someid","secret-token":"secret","short_message":"A short message that helps you identify what is going on","timestamp":1385053862.3072,"version":"1.1"}"#;
        let config = Config::from_string("[output.gelf_extra]\nsecret-token = \"secret\"").unwrap();
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
        let encoder = GelfEncoder::new(&config);
        assert_eq!(
            String::from_utf8_lossy(&encoder.encode(record).unwrap()),
            expected_msg
        );
    }

    #[test]
    fn test_gelf_encode_empty_hostname() {
        let expected_msg = r#"{"host":"unknown","level":1,"short_message":"A short message that helps you identify what is going on","timestamp":1385053862.3072,"version":"1.1"}"#;
        let config = Config::from_string("").unwrap();
        let record = Record {
            ts: 1385053862.3072,
            hostname: "".to_string(),
            facility: None,
            severity: Some(1),
            appname: None,
            procid: None,
            msgid: None,
            msg: Some("A short message that helps you identify what is going on".to_string()),
            full_msg: None,
            sd: None,
        };
        let encoder = GelfEncoder::new(&config);
        assert_eq!(
            String::from_utf8_lossy(&encoder.encode(record).unwrap()),
            expected_msg
        );
    }

    #[test]
    fn test_gelf_encode_replace_extra() {
        let expected_msg = r#"{"a_key":"bar","host":"unknown","level":1,"short_message":"A short message that helps you identify what is going on","timestamp":1385053862.3072,"version":"1.1"}"#;
        let config = Config::from_string("[output.gelf_extra]\na_key = \"bar\"").unwrap();
        let mut sd = StructuredData::new(None);
        sd.pairs
            .push(("a_key".to_string(), SDValue::String("foo".to_string())));
        let record = Record {
            ts: 1385053862.3072,
            hostname: "".to_string(),
            facility: None,
            severity: Some(1),
            appname: None,
            procid: None,
            msgid: None,
            msg: Some("A short message that helps you identify what is going on".to_string()),
            full_msg: None,
            sd: Some(vec![sd]),
        };
        let encoder = GelfEncoder::new(&config);
        assert_eq!(
            String::from_utf8_lossy(&encoder.encode(record).unwrap()),
            expected_msg
        );
    }

    #[test]
    #[should_panic(expected = "output.gelf_extra must be a list of key/value pairs")]
    fn test_gelf_encoder_config_extra_should_be_section() {
        let _encoder =
            GelfEncoder::new(&Config::from_string("[output]\ngelf_extra = \"bar\"").unwrap());
    }

    #[test]
    #[should_panic(expected = "output.gelf_extra values must be strings")]
    fn test_gelf_encoder_config_extra_bad_type() {
        let _encoder =
            GelfEncoder::new(&Config::from_string("[output.gelf_extra]\n_some_info = 42").unwrap());
    }

    #[test]
    fn test_gelf_encode_multiple_sd() {
        let expected_msg = r#"{"_some_info":"foo","application_name":"appname","full_message":"Backtrace here\n\nmore stuff","host":"example.org","info":123.456,"level":1,"process_id":"44","sd_id":"someid2","secret-token":"secret","short_message":"A short message that helps you identify what is going on","timestamp":1385053862.3072,"version":"1.1"}"#;
        let config = Config::from_string("[output.gelf_extra]\nsecret-token = \"secret\"").unwrap();
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
        let encoder = GelfEncoder::new(&config);
        assert_eq!(
            String::from_utf8_lossy(&encoder.encode(record).unwrap()),
            expected_msg
        );
    }
}
