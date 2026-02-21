use super::Splitter;
use crate::flowgger::decoder::Decoder;
use crate::flowgger::encoder::Encoder;
use crate::flowgger::record::{Record, SDValue, StructuredData, FACILITY_MAX, SEVERITY_MAX};
use crate::record_capnp;
use capnp;
use capnp::message::ReaderOptions;
use std::io::{stderr, BufReader, Read, Write};
use std::sync::mpsc::SyncSender;
use std::thread;
use std::time::Duration;

pub struct CapnpSplitter;

impl<T: Read> Splitter<T> for CapnpSplitter {
    fn run(
        &self,
        buf_reader: BufReader<T>,
        tx: SyncSender<Vec<u8>>,
        _decoder: Box<dyn Decoder>,
        encoder: Box<dyn Encoder>,
    ) {
        let mut buf_reader = buf_reader;
        loop {
            let message_reader =
                match capnp::serialize::read_message(&mut buf_reader, ReaderOptions::new()) {
                    Err(e) => match e.kind {
                        capnp::ErrorKind::Failed | capnp::ErrorKind::Unimplemented => {
                            let _ = writeln!(stderr(), "Capnp decoding error: {}", e.description);
                            return;
                        }
                        capnp::ErrorKind::Overloaded => {
                            thread::sleep(Duration::from_millis(250));
                            continue;
                        }
                        capnp::ErrorKind::Disconnected => {
                            let _ = writeln!(
                                stderr(),
                                "Client hasn't sent any data for a while - Closing \
                                 idle connection"
                            );
                            return;
                        }
                    },
                    Ok(message_reader) => message_reader,
                };
            let message: record_capnp::record::Reader = message_reader.get_root().unwrap();
            let record = match handle_message(message) {
                Err(e) => {
                    let _ = writeln!(stderr(), "{}", e);
                    continue;
                }
                Ok(record) => record,
            };
            match encoder.encode(record) {
                Err(e) => {
                    let _ = writeln!(stderr(), "{}", e);
                }
                Ok(reencoded) => tx.send(reencoded).unwrap(),
            };
        }
    }
}

fn get_pairs(
    message_pairs: Option<capnp::struct_list::Reader<record_capnp::pair::Owned>>,
    message_extra: Option<capnp::struct_list::Reader<record_capnp::pair::Owned>>,
) -> Vec<(String, SDValue)> {
    let pairs_count = message_pairs
        .and_then(|x| Some(x.len()))
        .or(Some(0))
        .unwrap() as usize
        + message_extra
            .and_then(|x| Some(x.len()))
            .or(Some(0))
            .unwrap() as usize;
    let mut pairs = Vec::with_capacity(pairs_count);
    if let Some(message_pairs) = message_pairs {
        for message_pair in message_pairs.iter() {
            let name = match message_pair.get_key() {
                Ok(name) => {
                    if name.starts_with('_') {
                        name.to_owned()
                    } else {
                        format!("_{}", name)
                    }
                }
                _ => continue,
            };
            let value = match message_pair.get_value().which() {
                Ok(record_capnp::pair::value::String(Ok(x))) => SDValue::String(x.to_owned()),
                Ok(record_capnp::pair::value::Bool(x)) => SDValue::Bool(x),
                Ok(record_capnp::pair::value::F64(x)) => SDValue::F64(x),
                Ok(record_capnp::pair::value::I64(x)) => SDValue::I64(x),
                Ok(record_capnp::pair::value::U64(x)) => SDValue::U64(x),
                Ok(record_capnp::pair::value::Null(())) => SDValue::Null,
                _ => continue,
            };
            pairs.push((name, value));
        }
    }
    if let Some(message_extra) = message_extra {
        for message_pair in message_extra.iter() {
            match (message_pair.get_key(), message_pair.get_value().which()) {
                (Ok(name), Ok(record_capnp::pair::value::String(Ok(value)))) => {
                    pairs.push((name.to_owned(), SDValue::String(value.to_owned())))
                }
                _ => continue,
            }
        }
    }
    pairs
}

fn get_sd(
    message: record_capnp::record::Reader,
) -> Result<Option<Vec<StructuredData>>, &'static str> {
    let sd_id = message.get_sd_id().and_then(|x| Ok(x.to_owned())).ok();
    let pairs = message.get_pairs().ok();
    let extra = message.get_extra().ok();
    let pairs = if pairs.is_none() && extra.is_none() {
        if sd_id.is_none() {
            return Ok(None);
        }
        Vec::new()
    } else {
        get_pairs(pairs, extra)
    };
    Ok(Some(vec![StructuredData { sd_id, pairs }]))
}

fn handle_message(message: record_capnp::record::Reader) -> Result<Record, &'static str> {
    let ts = message.get_ts();
    if ts.is_nan() || ts <= 0.0 {
        return Err("Missing timestamp");
    }
    let hostname = message
        .get_hostname()
        .and_then(|x| Ok(x.to_owned()))
        .or(Err("Missing host name"))?;
    let facility = match message.get_facility() {
        facility if facility <= FACILITY_MAX => Some(facility),
        _ => None,
    };
    let severity = match message.get_severity() {
        severity if severity <= SEVERITY_MAX => Some(severity),
        _ => None,
    };
    let appname = message.get_appname().and_then(|x| Ok(x.to_owned())).ok();
    let procid = message.get_procid().and_then(|x| Ok(x.to_owned())).ok();
    let msgid = message.get_msgid().and_then(|x| Ok(x.to_owned())).ok();
    let msg = message.get_msg().and_then(|x| Ok(x.to_owned())).ok();
    let full_msg = message.get_full_msg().and_then(|x| Ok(x.to_owned())).ok();
    let sd = get_sd(message)?;
    Ok(Record {
        ts,
        hostname,
        remote_addr: None,
        facility,
        severity,
        appname,
        procid,
        msgid,
        msg,
        full_msg,
        sd,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decode_message() {
        let sd = StructuredData {
            sd_id: Some("someid".to_string()),
            pairs: vec![("_some_info".to_string(), SDValue::String("foo".to_string()))],
        };
        let expected = Record {
            ts: 1385053862.3072,
            hostname: "example.org".to_string(),
            remote_addr: None,
            facility: None,
            severity: Some(1),
            appname: Some("appname".to_string()),
            procid: Some("44".to_string()),
            msgid: Some("".to_string()),
            msg: Some("A short message that helps you identify what is going on".to_string()),
            full_msg: Some("Backtrace here\n\nmore stuff".to_string()),
            sd: Some(vec![sd]),
        };

        let capnp_message = vec![
            0, 0, 0, 0, 38, 0, 0, 0, 0, 0, 0, 0, 2, 0, 9, 0, 42, 169, 147, 169, 143, 163, 212, 65,
            255, 1, 0, 0, 0, 0, 0, 0, 33, 0, 0, 0, 98, 0, 0, 0, 37, 0, 0, 0, 66, 0, 0, 0, 37, 0, 0,
            0, 26, 0, 0, 0, 37, 0, 0, 0, 10, 0, 0, 0, 37, 0, 0, 0, 202, 1, 0, 0, 65, 0, 0, 0, 218,
            0, 0, 0, 77, 0, 0, 0, 58, 0, 0, 0, 77, 0, 0, 0, 39, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            101, 120, 97, 109, 112, 108, 101, 46, 111, 114, 103, 0, 0, 0, 0, 0, 97, 112, 112, 110,
            97, 109, 101, 0, 52, 52, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 65, 32, 115, 104,
            111, 114, 116, 32, 109, 101, 115, 115, 97, 103, 101, 32, 116, 104, 97, 116, 32, 104,
            101, 108, 112, 115, 32, 121, 111, 117, 32, 105, 100, 101, 110, 116, 105, 102, 121, 32,
            119, 104, 97, 116, 32, 105, 115, 32, 103, 111, 105, 110, 103, 32, 111, 110, 0, 0, 0, 0,
            0, 0, 0, 0, 66, 97, 99, 107, 116, 114, 97, 99, 101, 32, 104, 101, 114, 101, 10, 10,
            109, 111, 114, 101, 32, 115, 116, 117, 102, 102, 0, 0, 0, 0, 0, 0, 115, 111, 109, 101,
            105, 100, 0, 0, 4, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            5, 0, 0, 0, 90, 0, 0, 0, 9, 0, 0, 0, 34, 0, 0, 0, 95, 115, 111, 109, 101, 95, 105, 110,
            102, 111, 0, 0, 0, 0, 0, 0, 102, 111, 111, 0, 0, 0, 0, 0,
        ];
        let mut reader = capnp_message.as_slice();

        let message_reader =
            capnp::serialize::read_message(&mut reader, ReaderOptions::new()).unwrap();
        let record = handle_message(message_reader.get_root().unwrap()).unwrap();

        assert_eq!(record.ts, expected.ts);
        assert_eq!(record.hostname, expected.hostname);
        assert_eq!(record.facility, expected.facility);
        assert_eq!(record.severity, expected.severity);
        assert_eq!(record.appname, expected.appname);
        assert_eq!(record.procid, expected.procid);
        assert_eq!(record.msgid, expected.msgid);
        assert_eq!(record.msg, expected.msg);
        assert_eq!(record.full_msg, expected.full_msg);
        assert_eq!(record.sd.unwrap()[0].sd_id, expected.sd.unwrap()[0].sd_id);
    }
}
