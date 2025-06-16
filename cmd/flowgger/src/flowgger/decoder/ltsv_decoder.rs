use super::Decoder;
use crate::flowgger::config::Config;
use crate::flowgger::record::{Record, SDValue, SDValueType, StructuredData};
use crate::flowgger::utils;
use std::collections::HashMap;
use time::format_description::well_known::Rfc3339;
use time::{format_description, OffsetDateTime};

#[derive(Clone)]
struct Suffixes {
    s_bool: Option<String>,
    s_f64: Option<String>,
    s_i64: Option<String>,
    s_u64: Option<String>,
}

#[derive(Clone)]
pub struct LTSVDecoder {
    schema: Option<HashMap<String, SDValueType>>,
    suffixes: Suffixes,
}

impl LTSVDecoder {
    pub fn new(config: &Config) -> LTSVDecoder {
        let schema = match config.lookup("input.ltsv_schema") {
            None => None,
            Some(pairs) => {
                let mut schema = HashMap::new();
                for (name, sdtype) in pairs
                    .as_table()
                    .expect("input.ltsv_schema must be a list of key/type pairs")
                {
                    let sdtype = match sdtype
                        .as_str()
                        .expect("input.ltsv_schema types must be strings")
                        .to_lowercase()
                        .as_ref()
                    {
                        "string" => SDValueType::String,
                        "bool" => SDValueType::Bool,
                        "f64" => SDValueType::F64,
                        "i64" => SDValueType::I64,
                        "u64" => SDValueType::U64,
                        _ => panic!("Unsupported type in input.ltsv_schema for name [{}]", name),
                    };
                    schema.insert(name.to_owned(), sdtype);
                }
                Some(schema)
            }
        };
        let mut suffixes = Suffixes {
            s_bool: None,
            s_f64: None,
            s_i64: None,
            s_u64: None,
        };
        match config.lookup("input.ltsv_suffixes") {
            None => {}
            Some(pairs) => {
                for (sdtype, suffix) in pairs
                    .as_table()
                    .expect("input.ltsv_suffixes must be a list of type/suffixes pairs")
                {
                    let suffix = suffix
                        .as_str()
                        .expect("input.ltsv_suffixes suffixes must be strings")
                        .to_owned();
                    match sdtype.to_lowercase().as_ref() {
                        "string" => panic!("Strings cannot be suffixed"),
                        "bool" => suffixes.s_bool = Some(suffix),
                        "f64" => suffixes.s_f64 = Some(suffix),
                        "i64" => suffixes.s_i64 = Some(suffix),
                        "u64" => suffixes.s_u64 = Some(suffix),
                        _ => panic!(
                            "Unsupported type in input.ltsv_suffixes for type [{}]",
                            sdtype
                        ),
                    }
                }
            }
        };
        LTSVDecoder { schema, suffixes }
    }
}

impl Decoder for LTSVDecoder {
    fn decode(&self, line: &str) -> Result<Record, &'static str> {
        let mut sd = StructuredData::new(None);
        let mut ts = None;
        let mut hostname = None;
        let mut msg = None;
        let mut severity = None;

        for part in line.split('\t') {
            let mut pair = part.splitn(2, ':');
            let k = pair.next();
            let v = pair.next();
            match (k, v) {
                (Some(name), None) => println!("Missing value for name '{}'", name),
                (None, None) => println!("Missing name and value for a LTSV record"),
                (None, Some(value)) => println!("Missing name for value '{}'", value),
                (Some(name), Some(value)) => {
                    match name {
                        "time" => {
                            let ts_s = if value.starts_with('[') && value.ends_with(']') {
                                &value[1..(value.len() - 1)]
                            } else {
                                value
                            };
                            ts = Some(parse_ts(ts_s)?);
                        }
                        "host" => hostname = Some(value.to_owned()),
                        "message" => msg = Some(value.to_owned()),
                        "level" => {
                            let severity_given: u8 =
                                value.parse().or(Err("Invalid severity level"))?;
                            if severity_given > 7 {
                                return Err("Severity level should be <= 7");
                            }
                            severity = Some(severity_given);
                        }
                        name => {
                            let (final_name, value): (String, SDValue) = if let Some(ref schema) =
                                self.schema
                            {
                                match schema.get(name) {
                                    None | Some(&SDValueType::String) => {
                                        (format!("_{}", name), SDValue::String(value.to_owned()))
                                    }
                                    Some(&SDValueType::Bool) => {
                                        let final_name = match self.suffixes.s_bool {
                                            Some(ref suffix) if !name.ends_with(suffix) => {
                                                format!("_{}{}", name, suffix)
                                            }
                                            _ => format!("_{}", name),
                                        };
                                        (
                                            final_name,
                                            SDValue::Bool(
                                                value
                                                    .parse::<bool>()
                                                    .or(Err("Type error; boolean was expected"))?,
                                            ),
                                        )
                                    }
                                    Some(&SDValueType::F64) => {
                                        let final_name = match self.suffixes.s_f64 {
                                            Some(ref suffix) if !name.ends_with(suffix) => {
                                                format!("_{}{}", name, suffix)
                                            }
                                            _ => format!("_{}", name),
                                        };
                                        (
                                            final_name,
                                            SDValue::F64(
                                                value
                                                    .parse::<f64>()
                                                    .or(Err("Type error; f64 was expected"))?,
                                            ),
                                        )
                                    }
                                    Some(&SDValueType::I64) => {
                                        let final_name = match self.suffixes.s_i64 {
                                            Some(ref suffix) if !name.ends_with(suffix) => {
                                                format!("_{}{}", name, suffix)
                                            }
                                            _ => format!("_{}", name),
                                        };
                                        (
                                            final_name,
                                            SDValue::I64(
                                                value
                                                    .parse::<i64>()
                                                    .or(Err("Type error; i64 was expected"))?,
                                            ),
                                        )
                                    }
                                    Some(&SDValueType::U64) => {
                                        let final_name = match self.suffixes.s_u64 {
                                            Some(ref suffix) if !name.ends_with(suffix) => {
                                                format!("_{}{}", name, suffix)
                                            }
                                            _ => format!("_{}", name),
                                        };
                                        (
                                            final_name,
                                            SDValue::U64(
                                                value
                                                    .parse::<u64>()
                                                    .or(Err("Type error; u64 was expected"))?,
                                            ),
                                        )
                                    }
                                }
                            } else {
                                (format!("_{}", name), SDValue::String(value.to_owned()))
                            };
                            sd.pairs.push((final_name, value));
                        }
                    };
                }
            };
        }
        let record = Record {
            ts: ts.ok_or("Missing timestamp")?,
            hostname: hostname.ok_or("Missing hostname")?,
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
            full_msg: Some(line.to_owned()),
        };
        Ok(record)
    }
}

fn rfc3339_to_unix(rfc3339: &str) -> Result<f64, &'static str> {
    match OffsetDateTime::parse(rfc3339, &Rfc3339) {
        Ok(date) => Ok(utils::PreciseTimestamp::from_offset_datetime(date).as_f64()),
        Err(_) => Err("Unable to parse the date from RFC3339 to Unix in LTSV decoder"),
    }
}

fn english_time_to_unix(et: &str) -> Result<f64, &'static str> {
    english_time_to_unix_with_subsecond(et, false)
        .or_else(|_| english_time_to_unix_with_subsecond(et, true))
}

fn english_time_to_unix_with_subsecond(
    et: &str,
    with_subsecond: bool,
) -> Result<f64, &'static str> {
    let mut format_str =
        "[day padding:none]/[month repr:short]/[year]:[hour]:[minute]:[second].[subsecond] \
        [offset_hour sign:mandatory][offset_minute]"
            .to_string();

    if !with_subsecond {
        format_str = format_str.replace(".[subsecond]", "");
    }

    let format_item = format_description::parse(&format_str).unwrap();
    match OffsetDateTime::parse(&et, &format_item) {
        Ok(date) => Ok(utils::PreciseTimestamp::from_offset_datetime(date).as_f64()),
        Err(_) => Err("Unable to parse the English to Unix timestamp in LTSV decoder"),
    }
}

fn unix_strtime_to_unix(et: &str) -> Result<f64, &'static str> {
    match et.parse::<f64>() {
        Ok(ts) => Ok(ts),
        Err(_) => Err("Unable to parse the date from Unix strtime to Unix in LTSV decoder"),
    }
}

fn parse_ts(line: &str) -> Result<f64, &'static str> {
    unix_strtime_to_unix(line)
        .or_else(|_| rfc3339_to_unix(line))
        .or_else(|_| english_time_to_unix(line))
}

#[test]
fn test_ltsv_suffixes() {
    let config = Config::from_string(
        "[input]\n[input.ltsv_schema]\ncounter = \"U64\"\nscore = \
         \"I64\"\nmean = \"f64\"\ndone = \
         \"bool\"\n[input.ltsv_suffixes]\nu64 = \"_u64\"\ni64 = \
         \"_i64\"\nF64 = \"_f64\"\nBool = \"_bool\"\n",
    );
    let ltsv_decoder = LTSVDecoder::new(&config.unwrap());
    let msg = "time:[10/Oct/2000:13:55:36 \
               -0700]\tdone:true\tscore:-1\tmean:0.42\tcounter:42\tlevel:3\thost:\
               testhostname\tname1:value1\tname 2: value 2\tn3:v3\tmessage:this is a test";
    let res = ltsv_decoder.decode(msg).unwrap();
    let sd = &res.sd.unwrap()[0];
    let pairs = &sd.pairs;
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::U64(v) = v {
            k == "_counter_u64" && v == 42
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::I64(v) = v {
            k == "_score_i64" && v == -1
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::F64(v) = v {
            k == "_mean_f64" && f64::abs(v - 0.42) < 1e-5
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::Bool(v) = v {
            k == "_done_bool" && v
        } else {
            false
        }));
}

#[test]
fn test_ltsv_suffixes_2() {
    let config = Config::from_string(
        "[input]\n[input.ltsv_schema]\ncounter_u64 = \
         \"U64\"\nscore_i64 = \"I64\"\nmean_f64 = \
         \"f64\"\ndone_bool = \"bool\"\n[input.ltsv_suffixes]\nu64 \
         = \"_u64\"\ni64 = \"_i64\"\nf64 = \"_f64\"\nbool = \
         \"_bool\"\n",
    );
    let ltsv_decoder = LTSVDecoder::new(&config.unwrap());
    let msg = "time:[10/Oct/2000:13:55:36 \
               -0700]\tdone_bool:true\tscore_i64:-1\tmean_f64:0.42\tcounter_u64:42\tlevel:3\thost:\
               testhostname\tname1:value1\tname 2: value 2\tn3:v3\tmessage:this is a test";
    let res = ltsv_decoder.decode(msg).unwrap();
    let sd = &res.sd.unwrap()[0];
    let pairs = &sd.pairs;
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::U64(v) = v {
            k == "_counter_u64" && v == 42
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::I64(v) = v {
            k == "_score_i64" && v == -1
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::F64(v) = v {
            k == "_mean_f64" && f64::abs(v - 0.42) < 1e-5
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::Bool(v) = v {
            k == "_done_bool" && v
        } else {
            false
        }));
}

#[test]
fn test_ltsv() {
    let config = Config::from_string(
        "[input]\n[input.ltsv_schema]\ncounter = \"u64\"\nscore = \
         \"i64\"\nmean = \"f64\"\ndone = \"bool\"\n",
    );
    let ltsv_decoder = LTSVDecoder::new(&config.unwrap());
    let msg = "time:1438790025.99\thost:testhostname\tname1:value1\tname 2: value \
               2\tn3:v3";
    let res = ltsv_decoder.decode(msg).unwrap();
    assert!(res.ts == 1_438_790_025.99);
}

#[test]
fn test_ltsv2() {
    let config = Config::from_string(
        "[input]\n[input.ltsv_schema]\ncounter = \"u64\"\nscore = \
         \"i64\"\nmean = \"f64\"\ndone = \"bool\"\n",
    );
    let ltsv_decoder = LTSVDecoder::new(&config.unwrap());
    let msg = "time:[2015-08-05T15:53:45.637824Z]\thost:testhostname\tname1:value1\tname 2: value \
               2\tn3:v3";
    let res = ltsv_decoder.decode(msg).unwrap();
    println!("{}", res.ts);
    assert!(res.ts == 1_438_790_025.637_824);
}

#[test]
fn test_ltsv_3() {
    let config = Config::from_string(
        "[input]\n[input.ltsv_schema]\ncounter = \"u64\"\nscore = \
         \"i64\"\nmean = \"f64\"\ndone = \"bool\"\n",
    );
    let ltsv_decoder = LTSVDecoder::new(&config.unwrap());
    let msg = "time:[10/Oct/2000:13:55:36.3 \
               -0700]\tdone:true\tscore:-1\tmean:0.42\tcounter:42\tlevel:3\thost:\
               testhostname\tname1:value1\tname 2: value 2\tn3:v3\tmessage:this is a test";
    let res = ltsv_decoder.decode(msg).unwrap();
    assert!(res.ts == 971_211_336.3);
    assert!(res.severity.unwrap() == 3);

    assert!(res.hostname == "testhostname");
    assert!(res.msg.unwrap() == "this is a test");

    let sd = &res.sd.unwrap();
    assert!(sd.len() == 1);
    let pairs = &sd[0].pairs;

    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::String(v) = v {
            k == "_name1" && v == "value1"
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::String(v) = v {
            k == "_name 2" && v == " value 2"
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::String(v) = v {
            k == "_n3" && v == "v3"
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::U64(v) = v {
            k == "_counter" && v == 42
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::I64(v) = v {
            k == "_score" && v == -1
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::F64(v) = v {
            k == "_mean" && f64::abs(v - 0.42) < 1e-5
        } else {
            false
        }));
    assert!(pairs
        .iter()
        .cloned()
        .any(|(k, v)| if let SDValue::Bool(v) = v {
            k == "_done" && v == true
        } else {
            false
        }));
}

#[test]
fn test_ltsv4() {
    let config = Config::from_string(
        "[input]\n[input.ltsv_schema]\ncounter = \"u64\"\nscore = \
         \"i64\"\nmean = \"f64\"\ndone = \"bool\"\n",
    );
    let ltsv_decoder = LTSVDecoder::new(&config.unwrap());
    let msg =
        "time:[5/Aug/2015:15:53:45.637824 -0000]\thost:testhostname\tname1:value1\tname 2: value \
               2\tn3:v3";
    let res = ltsv_decoder.decode(msg).unwrap();
    println!("{}", res.ts);
    assert!(res.ts == 1_438_790_025.637_824);
}
