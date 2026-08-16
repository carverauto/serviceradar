use std::{error::Error, fmt};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct P0fCorpus {
    pub classes: Vec<String>,
    pub tcp_signatures: Vec<TcpSignatureEntry>,
    pub other_signatures: Vec<OtherSignatureEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TcpSignatureEntry {
    pub section: String,
    pub label: P0fLabel,
    pub raw_signature: String,
    pub signature: TcpSignature,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OtherSignatureEntry {
    pub section: String,
    pub label: String,
    pub signature: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct P0fLabel {
    pub raw: String,
    pub record_type: Option<String>,
    pub class: Option<String>,
    pub name: String,
    pub flavor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TcpSignature {
    pub ip_version: IpVersionPattern,
    pub initial_ttl: NumericPattern,
    pub ip_options_len: NumericPattern,
    pub mss: NumericPattern,
    pub window_size: WindowSizePattern,
    pub window_scale: NumericPattern,
    pub options_layout: Vec<TcpOptionPattern>,
    pub quirks: Vec<String>,
    pub payload_class: PayloadClassPattern,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IpVersionPattern {
    Any,
    V4,
    V6,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NumericPattern {
    Any,
    Exact(u32),
    Max(u32),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WindowSizePattern {
    Any,
    Exact(u32),
    MultipleOfMss(u32),
    MultipleOfMtu(u32),
    Modulo(u32),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TcpOptionPattern {
    EndOfOptions { padding: Option<u32> },
    Noop,
    Mss,
    WindowScale,
    SackPermitted,
    Sack,
    Timestamp,
    Unknown(u8),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PayloadClassPattern {
    Any,
    Empty,
    NonEmpty,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    line: usize,
    message: String,
}

impl ParseError {
    fn new(line: usize, message: impl Into<String>) -> Self {
        Self {
            line,
            message: message.into(),
        }
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "p0f corpus parse error on line {}: {}",
            self.line, self.message
        )
    }
}

impl Error for ParseError {}

impl TcpSignature {
    pub fn exact_lookup_key(&self) -> Option<String> {
        if !self.quirks.is_empty() {
            return None;
        }

        Some(format!(
            "{}:{}:{}:{}:{},{}:{}:{}:{}",
            self.ip_version.exact_key()?,
            self.initial_ttl.exact_key()?,
            self.ip_options_len.exact_key()?,
            self.mss.exact_key()?,
            self.window_size.exact_key()?,
            self.window_scale.exact_key()?,
            option_layout_key(&self.options_layout),
            "",
            self.payload_class.exact_key()?,
        ))
    }

    pub fn requires_fallback_match(&self) -> bool {
        self.exact_lookup_key().is_none()
    }
}

impl IpVersionPattern {
    fn exact_key(&self) -> Option<&'static str> {
        match self {
            Self::Any => None,
            Self::V4 => Some("4"),
            Self::V6 => Some("6"),
        }
    }
}

impl NumericPattern {
    fn exact_key(&self) -> Option<String> {
        match self {
            Self::Exact(value) => Some(value.to_string()),
            Self::Any | Self::Max(_) => None,
        }
    }
}

impl WindowSizePattern {
    fn exact_key(&self) -> Option<String> {
        match self {
            Self::Exact(value) => Some(value.to_string()),
            Self::Any | Self::MultipleOfMss(_) | Self::MultipleOfMtu(_) | Self::Modulo(_) => None,
        }
    }
}

impl PayloadClassPattern {
    fn exact_key(&self) -> Option<&'static str> {
        match self {
            Self::Any => None,
            Self::Empty => Some("0"),
            Self::NonEmpty => Some("+"),
        }
    }
}

pub fn parse(input: &str) -> Result<P0fCorpus, ParseError> {
    let mut corpus = P0fCorpus {
        classes: Vec::new(),
        tcp_signatures: Vec::new(),
        other_signatures: Vec::new(),
    };
    let mut section = String::new();
    let mut label = String::new();

    for (index, raw_line) in input.lines().enumerate() {
        let line_number = index + 1;
        let line = raw_line.trim();

        if line.is_empty() || line.starts_with(';') {
            continue;
        }

        if let Some(name) = line
            .strip_prefix('[')
            .and_then(|rest| rest.strip_suffix(']'))
        {
            section = name.trim().to_string();
            label.clear();
            continue;
        }

        let Some((key, value)) = line.split_once('=') else {
            return Err(ParseError::new(line_number, "expected key = value"));
        };
        let key = key.trim();
        let value = value.trim();

        match key {
            "classes" => {
                corpus.classes = split_csv(value).into_iter().map(str::to_string).collect();
            }
            "label" => {
                label = value.to_string();
            }
            "sig" => {
                if section.is_empty() {
                    return Err(ParseError::new(line_number, "signature before section"));
                }
                if label.is_empty() {
                    return Err(ParseError::new(line_number, "signature before label"));
                }

                if section.starts_with("tcp:") {
                    corpus.tcp_signatures.push(TcpSignatureEntry {
                        section: section.clone(),
                        label: parse_label(&label),
                        raw_signature: value.to_string(),
                        signature: parse_tcp_signature_at(value, line_number)?,
                    });
                } else {
                    corpus.other_signatures.push(OtherSignatureEntry {
                        section: section.clone(),
                        label: label.clone(),
                        signature: value.to_string(),
                    });
                }
            }
            "sys" | "ua_os" => {}
            _ => return Err(ParseError::new(line_number, format!("unknown key '{key}'"))),
        }
    }

    Ok(corpus)
}

fn parse_label(value: &str) -> P0fLabel {
    let mut parts = value.splitn(4, ':');
    let first = parts.next();
    let second = parts.next();
    let third = parts.next();
    let fourth = parts.next();

    if let (Some(record_type), Some(class), Some(name)) = (first, second, third) {
        P0fLabel {
            raw: value.to_string(),
            record_type: Some(record_type.to_string()),
            class: Some(class.to_string()),
            name: name.to_string(),
            flavor: fourth.map(str::to_string),
        }
    } else {
        P0fLabel {
            raw: value.to_string(),
            record_type: None,
            class: None,
            name: value.to_string(),
            flavor: None,
        }
    }
}

pub fn parse_tcp_signature(value: &str) -> Result<TcpSignature, ParseError> {
    parse_tcp_signature_at(value, 0)
}

fn parse_tcp_signature_at(value: &str, line: usize) -> Result<TcpSignature, ParseError> {
    let parts: Vec<_> = value.split(':').collect();
    if parts.len() != 8 {
        return Err(ParseError::new(line, "TCP signature must have 8 fields"));
    }

    let (window_size, window_scale) = parse_window_and_scale(parts[4], line)?;

    Ok(TcpSignature {
        ip_version: parse_ip_version(parts[0], line)?,
        initial_ttl: parse_numeric(parts[1], line)?,
        ip_options_len: parse_numeric(parts[2], line)?,
        mss: parse_numeric(parts[3], line)?,
        window_size,
        window_scale,
        options_layout: parse_options_layout(parts[5], line)?,
        quirks: parse_quirks(parts[6]),
        payload_class: parse_payload_class(parts[7], line)?,
    })
}

fn parse_ip_version(value: &str, line: usize) -> Result<IpVersionPattern, ParseError> {
    match value {
        "*" => Ok(IpVersionPattern::Any),
        "4" => Ok(IpVersionPattern::V4),
        "6" => Ok(IpVersionPattern::V6),
        _ => Err(ParseError::new(
            line,
            format!("invalid IP version '{value}'"),
        )),
    }
}

fn parse_numeric(value: &str, line: usize) -> Result<NumericPattern, ParseError> {
    if value == "*" {
        return Ok(NumericPattern::Any);
    }
    if let Some(max) = value.strip_suffix('-') {
        return Ok(NumericPattern::Max(parse_u32(max, line)?));
    }
    Ok(NumericPattern::Exact(parse_u32(value, line)?))
}

fn parse_window_and_scale(
    value: &str,
    line: usize,
) -> Result<(WindowSizePattern, NumericPattern), ParseError> {
    let Some((window, scale)) = value.split_once(',') else {
        return Err(ParseError::new(line, "window field must contain scale"));
    };

    Ok((
        parse_window_size(window, line)?,
        parse_numeric(scale, line)?,
    ))
}

fn parse_window_size(value: &str, line: usize) -> Result<WindowSizePattern, ParseError> {
    if value == "*" {
        return Ok(WindowSizePattern::Any);
    }
    if let Some(multiplier) = value.strip_prefix("mss*") {
        return Ok(WindowSizePattern::MultipleOfMss(parse_u32(
            multiplier, line,
        )?));
    }
    if let Some(multiplier) = value.strip_prefix("mtu*") {
        return Ok(WindowSizePattern::MultipleOfMtu(parse_u32(
            multiplier, line,
        )?));
    }
    if let Some(modulo) = value.strip_prefix('%') {
        return Ok(WindowSizePattern::Modulo(parse_u32(modulo, line)?));
    }

    Ok(WindowSizePattern::Exact(parse_u32(value, line)?))
}

fn parse_options_layout(value: &str, line: usize) -> Result<Vec<TcpOptionPattern>, ParseError> {
    if value.is_empty() {
        return Ok(Vec::new());
    }

    split_csv(value)
        .into_iter()
        .map(|option| parse_option(option, line))
        .collect()
}

fn parse_option(value: &str, line: usize) -> Result<TcpOptionPattern, ParseError> {
    match value {
        "nop" => Ok(TcpOptionPattern::Noop),
        "mss" => Ok(TcpOptionPattern::Mss),
        "ws" => Ok(TcpOptionPattern::WindowScale),
        "sok" => Ok(TcpOptionPattern::SackPermitted),
        "sack" => Ok(TcpOptionPattern::Sack),
        "ts" => Ok(TcpOptionPattern::Timestamp),
        "eol" => Ok(TcpOptionPattern::EndOfOptions { padding: None }),
        _ => {
            if let Some(padding) = value.strip_prefix("eol+") {
                Ok(TcpOptionPattern::EndOfOptions {
                    padding: Some(parse_u32(padding, line)?),
                })
            } else if let Some(kind) = value.strip_prefix('?') {
                Ok(TcpOptionPattern::Unknown(parse_u8(kind, line)?))
            } else {
                Err(ParseError::new(
                    line,
                    format!("invalid TCP option '{value}'"),
                ))
            }
        }
    }
}

fn parse_quirks(value: &str) -> Vec<String> {
    if value.is_empty() {
        Vec::new()
    } else {
        split_csv(value).into_iter().map(str::to_string).collect()
    }
}

fn parse_payload_class(value: &str, line: usize) -> Result<PayloadClassPattern, ParseError> {
    match value {
        "*" => Ok(PayloadClassPattern::Any),
        "0" => Ok(PayloadClassPattern::Empty),
        "+" => Ok(PayloadClassPattern::NonEmpty),
        _ => Err(ParseError::new(
            line,
            format!("invalid payload class '{value}'"),
        )),
    }
}

fn split_csv(value: &str) -> Vec<&str> {
    value
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect()
}

fn option_layout_key(options: &[TcpOptionPattern]) -> String {
    options.iter().map(option_key).collect::<Vec<_>>().join(",")
}

fn option_key(option: &TcpOptionPattern) -> String {
    match option {
        TcpOptionPattern::EndOfOptions { padding: None } => "eol".to_string(),
        TcpOptionPattern::EndOfOptions {
            padding: Some(padding),
        } => format!("eol+{padding}"),
        TcpOptionPattern::Noop => "nop".to_string(),
        TcpOptionPattern::Mss => "mss".to_string(),
        TcpOptionPattern::WindowScale => "ws".to_string(),
        TcpOptionPattern::SackPermitted => "sok".to_string(),
        TcpOptionPattern::Sack => "sack".to_string(),
        TcpOptionPattern::Timestamp => "ts".to_string(),
        TcpOptionPattern::Unknown(kind) => format!("?{kind}"),
    }
}

fn parse_u32(value: &str, line: usize) -> Result<u32, ParseError> {
    value
        .parse()
        .map_err(|_| ParseError::new(line, format!("invalid integer '{value}'")))
}

fn parse_u8(value: &str, line: usize) -> Result<u8, ParseError> {
    value
        .parse()
        .map_err(|_| ParseError::new(line, format!("invalid integer '{value}'")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_wildcards_modulo_and_max_ttl() {
        let corpus = parse(
            r#"
[tcp:request]
label = s:unix:Example:1.0
sig = *:64-:*:*:%8192,*:mss,?30,eol+1:df,bad:+
"#,
        )
        .unwrap();

        let signature = &corpus.tcp_signatures[0].signature;
        assert_eq!(signature.ip_version, IpVersionPattern::Any);
        assert_eq!(signature.initial_ttl, NumericPattern::Max(64));
        assert_eq!(signature.ip_options_len, NumericPattern::Any);
        assert_eq!(signature.window_size, WindowSizePattern::Modulo(8192));
        assert_eq!(signature.window_scale, NumericPattern::Any);
        assert_eq!(
            signature.options_layout,
            vec![
                TcpOptionPattern::Mss,
                TcpOptionPattern::Unknown(30),
                TcpOptionPattern::EndOfOptions { padding: Some(1) },
            ]
        );
        assert_eq!(signature.quirks, vec!["df", "bad"]);
        assert_eq!(signature.payload_class, PayloadClassPattern::NonEmpty);
    }

    #[test]
    fn rejects_malformed_tcp_signature() {
        let err = parse(
            r#"
[tcp:request]
label = s:unix:Example:1.0
sig = *:64:0
"#,
        )
        .unwrap_err();

        assert!(err.to_string().contains("must have 8 fields"));
    }

    #[test]
    fn parses_full_upstream_corpus() {
        let corpus = parse(include_str!(
            "../../../third_party/netprobe_corpora/p0f/p0f.fp"
        ))
        .unwrap();
        assert_eq!(corpus.classes, vec!["win", "unix", "other"]);
        assert_eq!(corpus.tcp_signatures.len(), 192);
        assert_eq!(corpus.other_signatures.len(), 130);
    }

    #[test]
    fn parses_serviceradar_additions_corpus() {
        let _corpus = parse(include_str!(
            "../../../third_party/netprobe_corpora/p0f/serviceradar-additions.fp"
        ))
        .unwrap();
    }
}
