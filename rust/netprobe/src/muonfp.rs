use std::{error::Error, fmt};

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct MuonTcpObservation {
    pub window_size: u16,
    pub option_kinds: Vec<u8>,
    pub mss: Option<u16>,
    pub window_scale: Option<u8>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
struct ParsedTcpOptions {
    option_kinds: Vec<u8>,
    mss: Option<u16>,
    window_scale: Option<u8>,
}

impl MuonTcpObservation {
    pub fn new(
        window_size: u16,
        option_kinds: impl Into<Vec<u8>>,
        mss: Option<u16>,
        window_scale: Option<u8>,
    ) -> Self {
        Self {
            window_size,
            option_kinds: option_kinds.into(),
            mss,
            window_scale,
        }
    }

    pub fn encode(&self) -> String {
        encode_observation(self)
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct MuonFingerprint {
    window_size: MuonField,
    options: MuonOptionsPattern,
    mss: MuonField,
    window_scale: MuonField,
    raw: String,
}

impl MuonFingerprint {
    pub fn parse(pattern: &str) -> Result<Self, MuonParseError> {
        parse_fingerprint(pattern)
    }

    pub fn raw(&self) -> &str {
        &self.raw
    }

    pub fn matches(&self, observation: &MuonTcpObservation) -> bool {
        self.window_size
            .matches(Some(u32::from(observation.window_size)))
            && self.options.matches(&observation.option_kinds)
            && self.mss.matches(observation.mss.map(u32::from))
            && self
                .window_scale
                .matches(observation.window_scale.map(u32::from))
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct MuonRule {
    pub id: String,
    pub label: Option<String>,
    pub fingerprint: MuonFingerprint,
}

impl MuonRule {
    pub fn new(
        id: impl Into<String>,
        pattern: &str,
        label: Option<impl Into<String>>,
    ) -> Result<Self, MuonParseError> {
        Ok(Self {
            id: id.into(),
            label: label.map(Into::into),
            fingerprint: MuonFingerprint::parse(pattern)?,
        })
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct MuonMatch {
    pub rule_id: String,
    pub label: Option<String>,
    pub pattern: String,
}

#[derive(Debug, Clone, Default)]
pub struct MuonMatcher {
    rules: Vec<MuonRule>,
}

impl MuonMatcher {
    pub fn new(rules: Vec<MuonRule>) -> Self {
        Self { rules }
    }

    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }

    pub fn match_observation(&self, observation: &MuonTcpObservation) -> Option<MuonMatch> {
        self.rules
            .iter()
            .find(|rule| rule.fingerprint.matches(observation))
            .map(|rule| MuonMatch {
                rule_id: rule.id.clone(),
                label: rule.label.clone(),
                pattern: rule.fingerprint.raw.clone(),
            })
    }

    pub fn match_fingerprint(
        &self,
        fingerprint: &str,
    ) -> Result<Option<MuonMatch>, MuonParseError> {
        let parsed = observed_fingerprint(fingerprint)?;
        Ok(self.match_observation(&parsed))
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
enum MuonField {
    Any,
    Empty,
    Exact(u32),
}

#[derive(Debug, Clone, Eq, PartialEq)]
enum MuonOptionsPattern {
    Any,
    Exact(Vec<u8>),
    Ordered(Vec<Option<u8>>),
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct MuonParseError {
    message: String,
}

impl MuonParseError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for MuonParseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "MuonFP parse error: {}", self.message)
    }
}

impl Error for MuonParseError {}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct MuonTcpError {
    message: String,
}

impl MuonTcpError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for MuonTcpError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "MuonFP TCP parse error: {}", self.message)
    }
}

impl Error for MuonTcpError {}

pub fn encode_observation(observation: &MuonTcpObservation) -> String {
    format!(
        "{}:{}:{}:{}",
        observation.window_size,
        encode_options(&observation.option_kinds),
        observation
            .mss
            .map_or_else(String::new, |value| value.to_string()),
        observation
            .window_scale
            .map_or_else(String::new, |value| value.to_string())
    )
}

pub fn encode_tcp_header(tcp_header: &[u8]) -> Result<String, MuonTcpError> {
    let observation = observation_from_tcp_header(tcp_header)?;
    Ok(encode_observation(&observation))
}

pub fn observation_from_tcp_header(tcp_header: &[u8]) -> Result<MuonTcpObservation, MuonTcpError> {
    if tcp_header.len() < 20 {
        return Err(MuonTcpError::new("TCP header shorter than 20 bytes"));
    }

    let data_offset = usize::from(tcp_header[12] >> 4) * 4;
    if data_offset < 20 {
        return Err(MuonTcpError::new(
            "TCP data offset shorter than base header",
        ));
    }
    if data_offset > tcp_header.len() {
        return Err(MuonTcpError::new("TCP data offset exceeds supplied bytes"));
    }

    let window_size = u16::from_be_bytes([tcp_header[14], tcp_header[15]]);
    let options = &tcp_header[20..data_offset];
    let options = parse_tcp_options(options)?;

    Ok(MuonTcpObservation {
        window_size,
        option_kinds: options.option_kinds,
        mss: options.mss,
        window_scale: options.window_scale,
    })
}

fn parse_fingerprint(pattern: &str) -> Result<MuonFingerprint, MuonParseError> {
    let parts: Vec<_> = pattern.split(':').collect();
    if parts.len() != 4 {
        return Err(MuonParseError::new("fingerprint must have four fields"));
    }

    let window_size = parse_field(parts[0], false, "window size")?;
    let options = parse_options_pattern(parts[1])?;
    let mss = parse_field(parts[2], true, "MSS")?;
    let window_scale = parse_field(parts[3], true, "window scale")?;

    Ok(MuonFingerprint {
        window_size,
        options,
        mss,
        window_scale,
        raw: pattern.to_owned(),
    })
}

fn observed_fingerprint(value: &str) -> Result<MuonTcpObservation, MuonParseError> {
    let parsed = parse_fingerprint(value)?;
    let MuonField::Exact(window_size) = parsed.window_size else {
        return Err(MuonParseError::new(
            "observed fingerprint window size must be exact",
        ));
    };
    let MuonOptionsPattern::Exact(option_kinds) = parsed.options else {
        return Err(MuonParseError::new(
            "observed fingerprint options must be exact",
        ));
    };

    Ok(MuonTcpObservation {
        window_size: u16::try_from(window_size)
            .map_err(|_| MuonParseError::new("observed window size exceeds u16"))?,
        option_kinds,
        mss: exact_optional_u16(&parsed.mss, "MSS")?,
        window_scale: exact_optional_u8(&parsed.window_scale, "window scale")?,
    })
}

fn parse_field(value: &str, allow_empty: bool, name: &str) -> Result<MuonField, MuonParseError> {
    if value == "%" {
        return Ok(MuonField::Any);
    }

    if value.is_empty() {
        return if allow_empty {
            Ok(MuonField::Empty)
        } else {
            Err(MuonParseError::new(format!("{name} may not be empty")))
        };
    }

    if !value.chars().all(|ch| ch.is_ascii_digit()) {
        return Err(MuonParseError::new(format!(
            "{name} contains non-decimal characters"
        )));
    }

    value
        .parse::<u32>()
        .map(MuonField::Exact)
        .map_err(|_| MuonParseError::new(format!("{name} is too large")))
}

fn parse_options_pattern(value: &str) -> Result<MuonOptionsPattern, MuonParseError> {
    if value == "%" {
        return Ok(MuonOptionsPattern::Any);
    }

    if value.is_empty() {
        return Ok(MuonOptionsPattern::Exact(Vec::new()));
    }

    let mut exact = Vec::new();
    let mut ordered = Vec::new();
    let mut has_order_wildcard = false;

    for token in value.split('-') {
        if token == "*" {
            has_order_wildcard = true;
            ordered.push(None);
            continue;
        }

        let option = token
            .parse::<u8>()
            .map_err(|_| MuonParseError::new("TCP option kind must be 0-255 or '*'"))?;
        exact.push(option);
        ordered.push(Some(option));
    }

    if has_order_wildcard {
        Ok(MuonOptionsPattern::Ordered(ordered))
    } else {
        Ok(MuonOptionsPattern::Exact(exact))
    }
}

impl MuonField {
    fn matches(&self, observed: Option<u32>) -> bool {
        match (self, observed) {
            (Self::Any, _) => true,
            (Self::Empty, None) => true,
            (Self::Exact(expected), Some(actual)) => *expected == actual,
            (Self::Empty | Self::Exact(_), _) => false,
        }
    }
}

impl MuonOptionsPattern {
    fn matches(&self, observed: &[u8]) -> bool {
        match self {
            Self::Any => true,
            Self::Exact(expected) => expected == observed,
            Self::Ordered(pattern) => ordered_options_match(pattern, observed),
        }
    }
}

fn ordered_options_match(pattern: &[Option<u8>], observed: &[u8]) -> bool {
    let mut observed_index = 0usize;

    for token in pattern {
        match token {
            Some(kind) => {
                let Some(position) = observed[observed_index..]
                    .iter()
                    .position(|observed_kind| observed_kind == kind)
                else {
                    return false;
                };
                observed_index += position + 1;
            }
            None => {
                if observed_index < observed.len() {
                    observed_index += 1;
                }
            }
        }
    }

    true
}

fn parse_tcp_options(options: &[u8]) -> Result<ParsedTcpOptions, MuonTcpError> {
    let mut option_kinds = Vec::new();
    let mut mss = None;
    let mut window_scale = None;
    let mut index = 0usize;

    while index < options.len() {
        let kind = options[index];
        option_kinds.push(kind);

        match kind {
            0 => break,
            1 => index += 1,
            _ => {
                let Some(length) = options.get(index + 1).copied().map(usize::from) else {
                    return Err(MuonTcpError::new("TCP option missing length byte"));
                };
                if length < 2 {
                    return Err(MuonTcpError::new("TCP option length shorter than 2 bytes"));
                }
                if index + length > options.len() {
                    return Err(MuonTcpError::new("TCP option length exceeds header"));
                }

                match kind {
                    2 if length == 4 => {
                        mss = Some(u16::from_be_bytes([options[index + 2], options[index + 3]]));
                    }
                    3 if length == 3 => {
                        window_scale = Some(options[index + 2]);
                    }
                    _ => {}
                }

                index += length;
            }
        }
    }

    Ok(ParsedTcpOptions {
        option_kinds,
        mss,
        window_scale,
    })
}

fn encode_options(option_kinds: &[u8]) -> String {
    option_kinds
        .iter()
        .map(u8::to_string)
        .collect::<Vec<_>>()
        .join("-")
}

fn exact_optional_u16(field: &MuonField, name: &str) -> Result<Option<u16>, MuonParseError> {
    match field {
        MuonField::Empty => Ok(None),
        MuonField::Exact(value) => u16::try_from(*value)
            .map(Some)
            .map_err(|_| MuonParseError::new(format!("{name} exceeds u16"))),
        MuonField::Any => Err(MuonParseError::new(format!(
            "observed {name} may not be a wildcard"
        ))),
    }
}

fn exact_optional_u8(field: &MuonField, name: &str) -> Result<Option<u8>, MuonParseError> {
    match field {
        MuonField::Empty => Ok(None),
        MuonField::Exact(value) => u8::try_from(*value)
            .map(Some)
            .map_err(|_| MuonParseError::new(format!("{name} exceeds u8"))),
        MuonField::Any => Err(MuonParseError::new(format!(
            "observed {name} may not be a wildcard"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::{MuonFingerprint, MuonMatcher, MuonRule, MuonTcpObservation, encode_tcp_header};

    #[test]
    fn parses_upstream_spec_vectors() {
        assert_eq!(
            MuonFingerprint::parse("65535:2-4-8-1-3:1412:8")
                .unwrap()
                .raw(),
            "65535:2-4-8-1-3:1412:8"
        );
        assert_eq!(
            MuonFingerprint::parse("65535:::").unwrap().raw(),
            "65535:::"
        );
        assert_eq!(
            MuonFingerprint::parse("62727:2:8961:").unwrap().raw(),
            "62727:2:8961:"
        );

        let wildcard = MuonFingerprint::parse("%:::").unwrap();
        assert!(wildcard.matches(&MuonTcpObservation::new(12345, [], None, None)));
        assert!(!wildcard.matches(&MuonTcpObservation::new(12345, [2], None, None)));
    }

    #[test]
    fn matches_exact_and_wildcard_rules() {
        let matcher = MuonMatcher::new(vec![
            MuonRule::new("scanner-empty", "%:::", Some("minimal scanner")).unwrap(),
            MuonRule::new("desktop", "65535:2-4-8-1-3:1412:8", Some("desktop")).unwrap(),
        ]);

        let scanner = matcher
            .match_observation(&MuonTcpObservation::new(64240, [], None, None))
            .expect("scanner rule matches");
        assert_eq!(scanner.rule_id, "scanner-empty");
        assert_eq!(scanner.label.as_deref(), Some("minimal scanner"));

        let desktop = matcher
            .match_fingerprint("65535:2-4-8-1-3:1412:8")
            .unwrap()
            .expect("desktop rule matches");
        assert_eq!(desktop.rule_id, "desktop");
    }

    #[test]
    fn supports_ordered_option_wildcards() {
        let rule = MuonFingerprint::parse("65535:2-*-8:1460:%").unwrap();

        assert!(rule.matches(&MuonTcpObservation::new(
            65535,
            [2, 4, 1, 1, 8],
            Some(1460),
            Some(7)
        )));
        assert!(!rule.matches(&MuonTcpObservation::new(
            65535,
            [8, 4, 2],
            Some(1460),
            Some(7)
        )));
    }

    #[test]
    fn encodes_raw_tcp_header_options() {
        let header = tcp_header(
            65535,
            &[
                2, 4, 0x05, 0xb4, // MSS 1460
                4, 2, // SACK permitted
                8, 10, 0, 0, 0, 1, 0, 0, 0, 0, // timestamp
                1, // NOP
                3, 3, 7, // window scale
            ],
        );

        assert_eq!(
            encode_tcp_header(&header).unwrap(),
            "65535:2-4-8-1-3:1460:7"
        );
    }

    #[test]
    fn rejects_malformed_fingerprints_and_tcp_headers() {
        assert!(MuonFingerprint::parse("65535:2-4:1460").is_err());
        assert!(MuonFingerprint::parse(":2-4:1460:7").is_err());
        assert!(MuonFingerprint::parse("65535:not-an-option:1460:7").is_err());
        assert!(encode_tcp_header(&[0; 19]).is_err());

        let mut bad_header = tcp_header(1024, &[2, 1]);
        bad_header[12] = 6 << 4;
        assert!(encode_tcp_header(&bad_header).is_err());
    }

    #[test]
    fn encodes_stable_fixture_syns_by_major_os_family() {
        for (family, fixtures) in stable_fixtures() {
            assert_eq!(fixtures.len(), 10, "{family} fixture count changed");
            for fixture in fixtures {
                assert_eq!(
                    fixture.observation.encode(),
                    fixture.expected,
                    "{family} fixture {} changed",
                    fixture.name
                );
            }
        }
    }

    struct Fixture {
        name: &'static str,
        observation: MuonTcpObservation,
        expected: &'static str,
    }

    fn stable_fixtures() -> Vec<(&'static str, Vec<Fixture>)> {
        vec![
            (
                "Linux",
                vec![
                    fixture("linux-1", 64240, &[2, 4, 8, 1, 3], Some(1460), Some(7)),
                    fixture("linux-2", 29200, &[2, 4, 8, 1, 3], Some(1460), Some(7)),
                    fixture("linux-3", 65160, &[2, 4, 8, 1, 3], Some(1440), Some(7)),
                    fixture("linux-4", 32120, &[2, 4, 8, 1, 3], Some(1380), Some(7)),
                    fixture("linux-5", 65535, &[2, 4, 8, 1, 3], Some(1460), Some(8)),
                    fixture("linux-6", 5840, &[2, 4, 8, 1, 3], Some(1460), Some(2)),
                    fixture("linux-7", 5792, &[2, 4, 8, 1, 3], Some(1448), Some(2)),
                    fixture("linux-8", 14600, &[2, 4, 8, 1, 3], Some(1460), Some(6)),
                    fixture("linux-9", 64240, &[2, 4, 8, 3], Some(1460), Some(7)),
                    fixture("linux-10", 64240, &[2, 4], Some(1460), None),
                ],
            ),
            (
                "Windows",
                vec![
                    fixture("windows-1", 64240, &[2, 4, 8, 1, 3], Some(1460), Some(8)),
                    fixture("windows-2", 8192, &[2, 1, 3, 1, 1, 4], Some(1460), Some(8)),
                    fixture("windows-3", 65535, &[2, 1, 3, 1, 1, 4], Some(1460), Some(8)),
                    fixture("windows-4", 65535, &[2, 1, 1, 4, 1, 3], Some(1460), Some(8)),
                    fixture("windows-5", 8192, &[2, 1, 3, 1, 1, 8], Some(1460), Some(2)),
                    fixture("windows-6", 16384, &[2, 1, 3, 1, 1, 4], Some(1460), Some(8)),
                    fixture("windows-7", 17520, &[2, 1, 3, 1, 1, 4], Some(1460), Some(8)),
                    fixture("windows-8", 64240, &[2, 4, 8, 1, 3], Some(1440), Some(8)),
                    fixture("windows-9", 65535, &[2, 4, 1, 3], Some(1460), Some(8)),
                    fixture("windows-10", 32768, &[2, 1, 1, 4], Some(1460), None),
                ],
            ),
            (
                "macOS",
                vec![
                    fixture("macos-1", 65535, &[2, 4, 8, 1, 3], Some(1460), Some(6)),
                    fixture("macos-2", 65535, &[2, 4, 8, 1, 3], Some(1440), Some(6)),
                    fixture("macos-3", 65535, &[2, 4, 8, 1, 3], Some(1380), Some(6)),
                    fixture("macos-4", 65535, &[2, 4, 8, 1, 3], Some(1200), Some(6)),
                    fixture("macos-5", 65535, &[2, 4, 8, 1, 3], Some(1460), Some(5)),
                    fixture("macos-6", 65535, &[2, 4, 8, 1, 3], Some(1460), Some(4)),
                    fixture("macos-7", 65535, &[2, 4, 8, 3], Some(1460), Some(6)),
                    fixture("macos-8", 65535, &[2, 4, 8], Some(1460), None),
                    fixture("macos-9", 65535, &[2, 4], Some(1460), None),
                    fixture("macos-10", 65535, &[], None, None),
                ],
            ),
            (
                "FreeBSD",
                vec![
                    fixture("freebsd-1", 65535, &[2, 4, 8, 1, 3], Some(1460), Some(6)),
                    fixture("freebsd-2", 65535, &[2, 4, 8, 1, 3], Some(1448), Some(6)),
                    fixture("freebsd-3", 65535, &[2, 4, 8, 1, 3], Some(1400), Some(6)),
                    fixture("freebsd-4", 65535, &[2, 4, 8, 1, 3], Some(1460), Some(5)),
                    fixture("freebsd-5", 65535, &[2, 4, 8, 1, 3], Some(1460), Some(3)),
                    fixture("freebsd-6", 65535, &[2, 4, 8, 3], Some(1460), Some(6)),
                    fixture("freebsd-7", 65535, &[2, 4, 8], Some(1460), None),
                    fixture("freebsd-8", 65535, &[2, 4], Some(1460), None),
                    fixture("freebsd-9", 57344, &[2, 4, 8, 1, 3], Some(1460), Some(6)),
                    fixture("freebsd-10", 32768, &[2, 4, 8, 1, 3], Some(1460), Some(6)),
                ],
            ),
        ]
    }

    fn fixture(
        name: &'static str,
        window_size: u16,
        option_kinds: &[u8],
        mss: Option<u16>,
        window_scale: Option<u8>,
    ) -> Fixture {
        let observation =
            MuonTcpObservation::new(window_size, option_kinds.to_vec(), mss, window_scale);
        let expected = Box::leak(observation.encode().into_boxed_str());

        Fixture {
            name,
            observation,
            expected,
        }
    }

    fn tcp_header(window_size: u16, options: &[u8]) -> Vec<u8> {
        let mut options = options.to_vec();
        while !options.len().is_multiple_of(4) {
            options.push(0);
        }

        let data_offset_words = (20 + options.len()) / 4;
        let mut header = vec![0u8; 20 + options.len()];
        header[12] = u8::try_from(data_offset_words).unwrap() << 4;
        header[13] = 0x02;
        header[14..16].copy_from_slice(&window_size.to_be_bytes());
        header[20..].copy_from_slice(&options);
        header
    }
}
