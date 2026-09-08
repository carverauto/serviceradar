use super::Decoder;
use crate::flowgger::config::Config;
use crate::flowgger::record::{Record, SDValue, StructuredData};
use crate::flowgger::utils;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

#[derive(Clone)]
pub struct RFC5424Decoder;

impl RFC5424Decoder {
    pub fn new(_config: &Config) -> RFC5424Decoder {
        RFC5424Decoder
    }
}

impl Decoder for RFC5424Decoder {
    fn decode(&self, line: &str) -> Result<Record, &'static str> {
        let line = line.strip_prefix('\u{feff}').unwrap_or(line);
        let (pri_version, remainder) = take_token(line).ok_or("Missing priority and version")?;
        let pri_version = parse_pri_version(pri_version)?;
        let (timestamp, remainder) = take_token(remainder).ok_or("Missing timestamp")?;
        let ts = parse_ts(timestamp)?;
        let (hostname, remainder) = take_token(remainder).ok_or("Missing hostname")?;
        let (appname, remainder) = take_token(remainder).ok_or("Missing application name")?;
        let (procid, remainder) = take_token(remainder).ok_or("Missing process id")?;
        let (msgid, remainder) = take_token(remainder).ok_or("Missing message id")?;
        let (sd_vec, msg) = parse_data(remainder)?;

        Ok(Record {
            ts,
            hostname: optional_field(hostname).unwrap_or_default(),
            remote_addr: None,
            facility: Some(pri_version.facility),
            severity: Some(pri_version.severity),
            appname: optional_field(appname),
            procid: optional_field(procid),
            msgid: optional_field(msgid),
            sd: if sd_vec.is_empty() {
                None
            } else {
                Some(sd_vec)
            },
            msg,
            full_msg: Some(line.trim_end().to_owned()),
        })
    }
}

struct Pri {
    facility: u8,
    severity: u8,
}

fn take_token(input: &str) -> Option<(&str, &str)> {
    let input = input.trim_start();
    if input.is_empty() {
        return None;
    }

    let end = input
        .char_indices()
        .find_map(|(index, character)| character.is_whitespace().then_some(index))
        .unwrap_or(input.len());
    Some((&input[..end], &input[end..]))
}

fn optional_field(value: &str) -> Option<String> {
    if value == "-" {
        None
    } else {
        Some(value.to_owned())
    }
}

fn parse_pri_version(line: &str) -> Result<Pri, &'static str> {
    if !line.starts_with('<') {
        return Err("The priority should be inside brackets");
    }

    let mut parts = line[1..].splitn(2, '>');
    let pri_encoded: u8 = parts
        .next()
        .ok_or("Empty priority")?
        .parse()
        .map_err(|_| "Invalid priority")?;
    let version = parts.next().ok_or("Missing version")?;
    if version != "1" {
        return Err("Unsupported version");
    }

    Ok(Pri {
        facility: pri_encoded >> 3,
        severity: pri_encoded & 7,
    })
}

fn parse_ts(value: &str) -> Result<f64, &'static str> {
    OffsetDateTime::parse(value, &Rfc3339)
        .map(|date| utils::PreciseTimestamp::from_offset_datetime(date).as_f64())
        .map_err(|_| "Unable to parse the date from RFC3339 to Unix time in RFC5424 decoder")
}

fn parse_data(input: &str) -> Result<(Vec<StructuredData>, Option<String>), &'static str> {
    let mut remainder = input.trim_start();
    if remainder == "-" {
        return Ok((Vec::new(), None));
    }

    if let Some(after_nil) = remainder.strip_prefix('-') {
        if !after_nil.is_empty() && !after_nil.chars().next().unwrap().is_whitespace() {
            return Err("Malformed RFC5424 structured data");
        }
        return Ok((Vec::new(), parse_msg(after_nil)));
    }

    let mut structured_data = Vec::new();
    while remainder.starts_with('[') {
        let (structured, after) = parse_sd_element(remainder)?;
        structured_data.push(structured);
        remainder = after;
    }

    if remainder.is_empty() {
        Ok((structured_data, None))
    } else if remainder.chars().next().is_some_and(char::is_whitespace) {
        Ok((structured_data, parse_msg(remainder)))
    } else {
        Err("Malformed RFC5424 message")
    }
}

fn parse_msg(input: &str) -> Option<String> {
    let message = input.trim_start().trim_end();
    if message.is_empty() {
        None
    } else {
        Some(message.to_owned())
    }
}

fn parse_sd_element(input: &str) -> Result<(StructuredData, &str), &'static str> {
    if !input.starts_with('[') {
        return Err("Missing structured data element");
    }

    let mut in_value = false;
    let mut escaped = false;
    let mut closing_bracket = None;

    for (index, character) in input.char_indices().skip(1) {
        if in_value {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_value = false;
            }
        } else if character == '"' {
            in_value = true;
        } else if character == ']' {
            closing_bracket = Some(index);
            break;
        }
    }

    let closing_bracket = closing_bracket.ok_or("Missing ] after structured data")?;
    let content = &input[1..closing_bracket];
    let remainder = &input[closing_bracket + 1..];
    Ok((parse_sd_content(content)?, remainder))
}

fn parse_sd_content(content: &str) -> Result<StructuredData, &'static str> {
    let (sd_id, mut remainder) = take_token(content).ok_or("Missing structured data id")?;
    let mut structured = StructuredData::new(Some(sd_id));

    loop {
        remainder = remainder.trim_start();
        if remainder.is_empty() {
            return Ok(structured);
        }

        let equals = remainder
            .find('=')
            .ok_or("Missing structured data equals")?;
        let name = &remainder[..equals];
        if name.is_empty() || name.chars().any(char::is_whitespace) {
            return Err("Invalid structured data parameter name");
        }

        let value = remainder[equals + 1..]
            .strip_prefix('"')
            .ok_or("Structured data parameter values must be quoted")?;
        let mut escaped = false;
        let mut closing_quote = None;
        for (index, character) in value.char_indices() {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                closing_quote = Some(index);
                break;
            }
        }

        let closing_quote = closing_quote.ok_or("Missing closing quote in structured data")?;
        let value = unescape_sd_value(&value[..closing_quote]);
        structured
            .pairs
            .push((format!("_{name}"), SDValue::String(value)));
        remainder = value_after_quote(&remainder[equals + 1..], closing_quote)?;
    }
}

fn value_after_quote(value: &str, closing_quote: usize) -> Result<&str, &'static str> {
    let value = &value[closing_quote + 2..];
    if value.is_empty() || value.chars().next().is_some_and(char::is_whitespace) {
        Ok(value)
    } else {
        Err("Malformed structured data parameter separator")
    }
}

fn unescape_sd_value(value: &str) -> String {
    let mut result = String::new();
    let mut escaped = false;

    for character in value.chars() {
        if escaped {
            match character {
                '"' | '\\' | ']' => result.push(character),
                _ => {
                    result.push('\\');
                    result.push(character);
                }
            }
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else {
            result.push(character);
        }
    }

    if escaped {
        result.push('\\');
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rfc5424_structured_data_and_message() {
        let msg = r#"<23>1 2015-08-05T15:53:45.637824Z testhostname appname 69 42 [origin@123 software="te\st sc\"ript" swVersion="0.0.1"] test message"#;
        let res = RFC5424Decoder.decode(msg).unwrap();
        assert_eq!(res.facility, Some(2));
        assert_eq!(res.severity, Some(7));
        assert_eq!(res.ts, 1438790025.637824);
        assert_eq!(res.hostname, "testhostname");
        assert_eq!(res.appname.as_deref(), Some("appname"));
        assert_eq!(res.procid.as_deref(), Some("69"));
        assert_eq!(res.msgid.as_deref(), Some("42"));
        assert_eq!(res.msg.as_deref(), Some("test message"));

        let sd = &res.sd.unwrap()[0];
        assert_eq!(sd.sd_id.as_deref(), Some("origin@123"));
        assert!(sd.pairs.iter().any(|(key, value)| {
            key == "_software"
                && matches!(value, SDValue::String(value) if value == r#"te\st sc"ript"#)
        }));
    }

    #[test]
    fn parses_multiple_structured_elements_without_a_message() {
        let msg = r#"<135>1 2020-01-01T00:00:00.000-00:00 host ClearPass 1000001 4-1-0 [timeQuality tzKnown="1"][origin swVersion="1.0.0.000000" software="PolicyManager" ip="192.0.2.34" enterpriseId="1.3.6.1.4.1.14823"][clearPass@14823 eventId="3036"]"#;
        let res = RFC5424Decoder.decode(msg).unwrap();
        assert_eq!(res.sd.as_ref().unwrap().len(), 3);
        assert_eq!(res.msg, None);
        assert_eq!(
            res.sd.as_ref().unwrap()[2].sd_id.as_deref(),
            Some("clearPass@14823")
        );
    }

    #[test]
    fn accepts_nil_fields_and_nil_structured_data() {
        let msg = r#"<14>1 2026-07-15T19:25:18Z - - - - -"#;
        let res = RFC5424Decoder.decode(msg).unwrap();
        assert_eq!(res.hostname, "");
        assert_eq!(res.appname, None);
        assert_eq!(res.procid, None);
        assert_eq!(res.msgid, None);
        assert!(res.sd.is_none());
        assert_eq!(res.msg, None);
    }

    #[test]
    fn rejects_unterminated_structured_data() {
        let msg = r#"<14>1 2026-07-15T19:25:18Z host app 1 id [meta value="bad""#;
        assert!(RFC5424Decoder.decode(msg).is_err());
    }
}
