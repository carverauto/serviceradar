use super::Decoder;
use crate::flowgger::config::Config;
use crate::flowgger::record::{Record, SDValue, StructuredData, SEVERITY_MAX};
use crate::flowgger::utils;
use serde_json::de;
use serde_json::error::Error::Syntax;
use serde_json::error::ErrorCode;
use serde_json::value::Value;

#[derive(Clone)]
pub struct GelfDecoder;

impl GelfDecoder {
    /// The GELF decoder doesn't support any configuration, the config is passed as an argument
    /// just to respect the interface https://docs.graylog.org/en/3.1/pages/gelf.html
    pub fn new(_config: &Config) -> GelfDecoder {
        GelfDecoder
    }
}

impl Decoder for GelfDecoder {
    /// Implements decode from a GELF formated text line to a Record object
    /// https://docs.graylog.org/en/3.1/pages/gelf.html
    ///
    /// # Parameters
    /// - `line`: A string slice containing a JSON with valid GELF data
    ///
    /// # Returns
    /// A `Result` that contain:
    ///
    /// - `Ok`: A record containing all the line parsed as a Record data struct
    /// - `Err`: if there was any error parsing the line, that could be missing values, bad json or wrong
    ///   types associated with specific fields
    fn decode(&self, line: &str) -> Result<Record, &'static str> {
        let mut sd = StructuredData::new(None);
        let mut ts = None;
        let mut hostname = None;
        let mut msg = None;
        let mut full_msg = None;
        let mut severity = None;

        let obj = match de::from_str(line) {
            x @ Ok(_) => x,
            Err(Syntax(ErrorCode::InvalidUnicodeCodePoint, ..)) => {
                de::from_str(&line.replace('\n', r"\n"))
            }
            x => x,
        };
        let obj: Value = obj.or(Err("Invalid GELF input, unable to parse as a JSON object"))?;
        let obj = obj.as_object().ok_or("Empty GELF input")?;
        for (key, value) in obj {
            match key.as_ref() {
                "timestamp" => ts = Some(value.as_f64().ok_or("Invalid GELF timestamp")?),
                "host" => {
                    hostname = Some(
                        value
                            .as_str()
                            .ok_or("GELF host name must be a string")?
                            .to_owned(),
                    )
                }
                "short_message" => {
                    msg = Some(
                        value
                            .as_str()
                            .ok_or("GELF short message must be a string")?
                            .to_owned(),
                    )
                }
                "full_message" => {
                    full_msg = Some(
                        value
                            .as_str()
                            .ok_or("GELF full message must be a string")?
                            .to_owned(),
                    )
                }
                "version" => match value.as_str().ok_or("GELF version must be a string")? {
                    "1.0" | "1.1" => {}
                    _ => return Err("Unsupported GELF version"),
                },
                "level" => {
                    let severity_given = value.as_u64().ok_or("Invalid severity level")?;
                    if severity_given > u64::from(SEVERITY_MAX) {
                        return Err("Invalid severity level (too high)");
                    }
                    severity = Some(severity_given as u8)
                }
                name => {
                    let sd_value: SDValue = match *value {
                        Value::String(ref value) => SDValue::String(value.to_owned()),
                        Value::Bool(value) => SDValue::Bool(value),
                        Value::F64(value) => SDValue::F64(value),
                        Value::I64(value) => SDValue::I64(value),
                        Value::U64(value) => SDValue::U64(value),
                        Value::Null => SDValue::Null,
                        _ => return Err("Invalid value type in structured data"),
                    };
                    let name = if name.starts_with('_') {
                        name.to_owned()
                    } else {
                        format!("_{name}")
                    };
                    sd.pairs.push((name, sd_value));
                }
            }
        }
        let record = Record {
            ts: ts.unwrap_or_else(|| utils::PreciseTimestamp::now().as_f64()),
            hostname: hostname.ok_or("Missing hostname")?,
            remote_addr: None,
            facility: None,
            severity,
            appname: None,
            procid: None,
            msgid: None,
            sd: if sd.pairs.is_empty() {
                None
            } else {
                Some(vec![sd])
            },
            msg,
            full_msg,
        };
        Ok(record)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::flowgger::record::SEVERITY_MAX;

    #[test]
    fn test_gelf_decoder() {
        let msg = r#"{"version":"1.1", "host": "example.org","short_message": "A short message that helps you identify what is going on", "full_message": "Backtrace here\n\nmore stuff", "timestamp": 1385053862.3072, "level": 1, "_user_id": 9001, "_some_info": "foo", "_some_env_var": "bar"}"#;
        let res = GelfDecoder.decode(msg).unwrap();
        assert!(res.ts == 1_385_053_862.307_2);
        assert!(res.hostname == "example.org");
        assert!(res.msg.unwrap() == "A short message that helps you identify what is going on");
        assert!(res.full_msg.unwrap() == "Backtrace here\n\nmore stuff");
        assert!(res.severity.unwrap() == 1);

        let sd = &res.sd.unwrap();
        assert!(sd.len() == 1);
        let pairs = &sd[0].pairs;
        assert!(pairs
            .iter()
            .cloned()
            .any(|(k, v)| if let SDValue::U64(v) = v {
                k == "_user_id" && v == 9001
            } else {
                false
            }));
        assert!(pairs
            .iter()
            .cloned()
            .any(|(k, v)| if let SDValue::String(v) = v {
                k == "_some_info" && v == "foo"
            } else {
                false
            }));
        assert!(pairs
            .iter()
            .cloned()
            .any(|(k, v)| if let SDValue::String(v) = v {
                k == "_some_env_var" && v == "bar"
            } else {
                false
            }));
    }

    #[test]
    #[should_panic(expected = "Invalid value type in structured data")]
    fn test_gelf_decoder_bad_key() {
        let msg = r#"{"some_key": []}"#;
        let _res = GelfDecoder.decode(&msg).unwrap();
    }

    #[test]
    #[should_panic(expected = "Invalid GELF timestamp")]
    fn test_gelf_decoder_bad_timestamp() {
        let msg = r#"{"timestamp": "a string not a timestamp", "host": "anhostname"}"#;
        let _res = GelfDecoder.decode(&msg).unwrap();
    }

    #[test]
    #[should_panic(expected = "Invalid GELF input, unable to parse as a JSON object")]
    fn test_gelf_decoder_invalid_input() {
        let _res = GelfDecoder.decode("{some_key = \"some_value\"}").unwrap();
    }

    #[test]
    #[should_panic(expected = "Unsupported GELF version")]
    fn test_gelf_decoder_wrong_version() {
        let msg = r#"{"version":"42"}"#;
        let _res = GelfDecoder.decode(msg).unwrap();
    }

    #[test]
    #[should_panic(expected = "Invalid severity level (too high)")]
    fn test_gelf_decoder_severity_to_high() {
        let _res = GelfDecoder
            .decode(format!("{{\"level\": {}}}", SEVERITY_MAX + 1).as_str())
            .unwrap();
    }
}
