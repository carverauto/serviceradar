use super::{ClearPassDecoder, Decoder, RFC3164Decoder, RFC5424Decoder};
use crate::flowgger::config::Config;
use crate::flowgger::record::{Record, SDValue, StructuredData};
use crate::flowgger::utils;
use std::sync::atomic::{AtomicU64, Ordering};
use time::OffsetDateTime;

static FALLBACK_COUNT: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
pub struct AutoDecoder {
    rfc5424: RFC5424Decoder,
    rfc3164: RFC3164Decoder,
    clearpass: ClearPassDecoder,
}

impl AutoDecoder {
    pub fn new(config: &Config) -> AutoDecoder {
        AutoDecoder {
            rfc5424: RFC5424Decoder::new(config),
            rfc3164: RFC3164Decoder::new(config),
            clearpass: ClearPassDecoder::new(config),
        }
    }

    fn mark(record: &mut Record, format: &str, fallback: bool) {
        let mut metadata = StructuredData::new(Some("serviceradar@1"));
        metadata.pairs.push((
            "_syslog_format".to_owned(),
            SDValue::String(format.to_owned()),
        ));
        if fallback {
            metadata
                .pairs
                .push(("_syslog_parse_fallback".to_owned(), SDValue::Bool(true)));
        }

        let mut structured_data = record.sd.take().unwrap_or_default();
        structured_data.push(metadata);
        record.sd = Some(structured_data);
    }

    fn fallback(line: &str) -> Record {
        let (facility, severity) = parse_priority(line);
        let mut record = Record {
            ts: utils::PreciseTimestamp::from_offset_datetime(OffsetDateTime::now_utc()).as_f64(),
            hostname: "unknown".to_owned(),
            remote_addr: None,
            facility,
            severity,
            appname: Some("syslog".to_owned()),
            procid: None,
            msgid: None,
            msg: Some(line.to_owned()),
            full_msg: Some(line.to_owned()),
            sd: None,
        };
        Self::mark(&mut record, "unknown", true);
        record
    }
}

impl Decoder for AutoDecoder {
    fn decode(&self, line: &str) -> Result<Record, &'static str> {
        if let Ok(mut record) = self.rfc5424.decode(line) {
            Self::mark(&mut record, "rfc5424", false);
            return Ok(record);
        }

        if let Ok(mut record) = self.rfc3164.decode(line) {
            Self::mark(&mut record, "rfc3164", false);
            return Ok(record);
        }

        if let Ok(mut record) = self.clearpass.decode(line) {
            Self::mark(&mut record, "clearpass", false);
            return Ok(record);
        }

        let count = FALLBACK_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
        if count <= 5 || count.is_multiple_of(1_000) {
            eprintln!(
                "Syslog parse fallback for {}-byte message (fallback count {})",
                line.len(),
                count
            );
        }

        Ok(Self::fallback(line))
    }
}

fn parse_priority(line: &str) -> (Option<u8>, Option<u8>) {
    let Some(rest) = line.strip_prefix('<') else {
        return (None, None);
    };
    let Some(end) = rest.find('>') else {
        return (None, None);
    };
    let Ok(priority) = rest[..end].parse::<u8>() else {
        return (None, None);
    };
    (Some(priority >> 3), Some(priority & 7))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::flowgger::decoder::Decoder;
    use crate::flowgger::decoder::RemoteAddrDecoder;

    fn config() -> Config {
        Config::from_string("[input]\nrfc3164_timezone = \"UTC\"").unwrap()
    }

    #[test]
    fn detects_rfc5424_before_legacy_formats() {
        let decoder = AutoDecoder::new(&config());
        let record = decoder
            .decode(
                r#"<135>1 2020-01-01T00:00:00.000-00:00 CPPM-HOST-01.example.com ClearPass 1000001 4-1-0 [timeQuality tzKnown="1"][origin swVersion="1.0.0.000000" software="PolicyManager" ip="192.0.2.34" enterpriseId="1.3.6.1.4.1.14823"][clearPass@14823 eventId="3036"] ClearPass event"#,
            )
            .unwrap();

        assert_eq!(record.hostname, "CPPM-HOST-01.example.com");
        assert_eq!(record.msg.as_deref(), Some("ClearPass event"));
        assert!(
            record
                .sd
                .unwrap()
                .iter()
                .any(|sd| sd.pairs.iter().any(|(key, value)| {
                    key == "_syslog_format"
                        && matches!(value, SDValue::String(format) if format == "rfc5424")
                }))
        );
    }

    #[test]
    fn detects_clearpass_standard_header() {
        let decoder = AutoDecoder::new(&config());
        let line = r#"<135>2020-01-01 00:00:00,000 192.0.2.34 CPPM_Session_Detail 7304 1 0 id=10000001,session_id=R00000001-00-000000a1,type=INTERNAL_IN,attr_name=Endpoint:Device Insight Tags,attr_value=[Example Tag A], [Example Tag B], example-iot,timestamp=2020-01-01 00:00:00.000000-00"#;
        let record = decoder.decode(line).unwrap();

        assert_eq!(record.hostname, "192.0.2.34");
        assert_eq!(record.appname.as_deref(), Some("CPPM_Session_Detail"));
        assert_eq!(record.procid.as_deref(), Some("7304"));
        assert_eq!(record.msgid.as_deref(), Some("1"));
        assert_eq!(
            record.msg.as_deref(),
            Some(
                &line["<135>2020-01-01 00:00:00,000 192.0.2.34 CPPM_Session_Detail 7304 1 "
                    .len()..]
            )
        );
    }

    #[test]
    fn preserves_clearpass_alert_body() {
        let decoder = AutoDecoder::new(&config());
        let line = r#"<135>2020-01-01 00:00:01,000 192.0.2.34 CPPM_Alert 111 1 0 session_id=R00000002-00-000000a2,service_name=RADIUS,alert=EAP-TLS: fatal alert by server - unknown_ca\nTLS Handshake failed,timestamp=2026-07-15 14:23:41.27-05"#;
        let record = decoder.decode(line).unwrap();

        assert_eq!(record.appname.as_deref(), Some("CPPM_Alert"));
        assert!(
            record
                .msg
                .as_deref()
                .unwrap()
                .contains(r#"\nTLS Handshake"#)
        );
    }

    #[test]
    fn preserves_opaque_messages_in_fallback() {
        let decoder = AutoDecoder::new(&config());
        let line = "<134>CEF:0|Vendor|Product|1|100|An event|5|src=10.0.0.1";
        let record = decoder.decode(line).unwrap();

        assert_eq!(record.hostname, "unknown");
        assert_eq!(record.msg.as_deref(), Some(line));
        assert_eq!(record.full_msg.as_deref(), Some(line));
        assert_eq!(record.facility, Some(16));
        assert_eq!(record.severity, Some(6));
    }

    #[test]
    fn preserves_leef_messages_in_fallback() {
        let decoder = AutoDecoder::new(&config());
        let line = "<134>LEEF:2.0|Vendor|Product|1|100|An event\\tdevTime=20260715";
        let record = decoder.decode(line).unwrap();

        assert_eq!(record.msg.as_deref(), Some(line));
        assert!(
            record
                .sd
                .unwrap()
                .iter()
                .any(|sd| sd.pairs.iter().any(|(key, value)| {
                    key == "_syslog_parse_fallback" && matches!(value, SDValue::Bool(true))
                }))
        );
    }

    #[test]
    fn attaches_the_transport_peer_to_fallback_records() {
        let decoder = RemoteAddrDecoder::new(
            Box::new(AutoDecoder::new(&config())),
            "10.208.254.4".to_owned(),
        );
        let record = decoder
            .decode("<134>CEF:0|Vendor|Product|1|100|An event|5|")
            .unwrap();

        assert_eq!(record.remote_addr.as_deref(), Some("10.208.254.4"));
    }
}
