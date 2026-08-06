use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
};

use anyhow::{Context, Result, anyhow};
use quick_xml::{Reader, events::BytesStart, events::Event};

#[derive(Debug, Clone, Copy, Eq, PartialEq, Ord, PartialOrd)]
pub enum SatoriAxis {
    Tcp,
    Dhcp,
    Dhcpv6,
    Dns,
    Icmp,
    Ntp,
    Sip,
    Smb,
    SmbBrowser,
    Ssh,
    SslTls,
    HttpServer,
    HttpUserAgent,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct SatoriObservation {
    fields: BTreeMap<String, String>,
}

impl SatoriObservation {
    pub fn new() -> Self {
        Self {
            fields: BTreeMap::new(),
        }
    }

    pub fn with_field(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        let value = value.into();

        if !value.is_empty() {
            self.fields.insert(name.into(), value);
        }

        self
    }

    pub fn fields(&self) -> &BTreeMap<String, String> {
        &self.fields
    }
}

impl Default for SatoriObservation {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct SatoriMatch {
    pub axis: SatoriAxis,
    pub source: String,
    pub label: String,
    pub os_name: Option<String>,
    pub os_class: Option<String>,
    pub os_vendor: Option<String>,
    pub device_type: Option<String>,
    pub device_vendor: Option<String>,
    pub confidence_weight: u32,
    pub matched_fields: BTreeMap<String, String>,
}

#[derive(Debug, Clone)]
pub struct SatoriCorpus {
    entries: Vec<SatoriEntry>,
}

#[derive(Debug, Clone)]
struct SatoriEntry {
    axis: SatoriAxis,
    source: String,
    label: String,
    os_name: Option<String>,
    os_class: Option<String>,
    os_vendor: Option<String>,
    device_type: Option<String>,
    device_vendor: Option<String>,
    tests: Vec<SatoriTest>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
struct SatoriTest {
    weight: u32,
    match_type: MatchType,
    fields: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum MatchType {
    Exact,
    Partial,
}

impl SatoriCorpus {
    pub fn load_from_dir(dir: impl AsRef<Path>) -> Result<Self> {
        let dir = dir.as_ref();
        let mut xml_paths = Vec::new();

        for entry in fs::read_dir(dir)
            .with_context(|| format!("failed to read Satori corpus directory {}", dir.display()))?
        {
            let path = entry?.path();
            if path.extension().is_some_and(|extension| extension == "xml") {
                xml_paths.push(path);
            }
        }

        xml_paths.sort();

        let mut entries = Vec::new();
        for path in xml_paths {
            entries.extend(parse_satori_file(&path)?);
        }

        Ok(Self { entries })
    }

    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    pub fn axes(&self) -> BTreeSet<SatoriAxis> {
        self.entries.iter().map(|entry| entry.axis).collect()
    }

    pub fn match_axis(
        &self,
        axis: SatoriAxis,
        observation: &SatoriObservation,
    ) -> Option<SatoriMatch> {
        self.entries
            .iter()
            .filter(|entry| entry.axis == axis)
            .filter_map(|entry| entry.best_match(observation))
            .max_by_key(|candidate| {
                (
                    candidate.confidence_weight,
                    candidate.matched_fields.len(),
                    candidate.label.clone(),
                )
            })
    }

    pub fn match_tcp(&self, tcp_flag: &str, tcp_signature: &str) -> Option<SatoriMatch> {
        self.match_axis(
            SatoriAxis::Tcp,
            &SatoriObservation::new()
                .with_field("tcpflag", tcp_flag)
                .with_field("tcpsig", tcp_signature),
        )
    }

    pub fn match_dhcp(
        &self,
        dhcp_type: &str,
        dhcp_options: Option<&str>,
        dhcp_option55: Option<&str>,
        dhcp_vendor_code: Option<&str>,
    ) -> Option<SatoriMatch> {
        let mut observation = SatoriObservation::new().with_field("dhcptype", dhcp_type);
        if let Some(value) = dhcp_options {
            observation = observation.with_field("dhcpoptions", value);
        }
        if let Some(value) = dhcp_option55 {
            observation = observation.with_field("dhcpoption55", value);
        }
        if let Some(value) = dhcp_vendor_code {
            observation = observation.with_field("dhcpvendorcode", value);
        }

        self.match_axis(SatoriAxis::Dhcp, &observation)
    }

    pub fn match_dhcpv6(
        &self,
        dhcpv6_type: &str,
        dhcpv6_options: Option<&str>,
        dhcpv6_option_request: Option<&str>,
        dhcpv6_vendor_code: Option<&str>,
    ) -> Option<SatoriMatch> {
        let mut observation = SatoriObservation::new().with_field("dhcpv6type", dhcpv6_type);
        if let Some(value) = dhcpv6_options {
            observation = observation.with_field("dhcpv6options", value);
        }
        if let Some(value) = dhcpv6_option_request {
            observation = observation.with_field("dhcpv6optionrequest", value);
        }
        if let Some(value) = dhcpv6_vendor_code {
            observation = observation.with_field("dhcpv6vendorcode", value);
        }

        self.match_axis(SatoriAxis::Dhcpv6, &observation)
    }

    pub fn match_dns(&self, dns_name: &str) -> Option<SatoriMatch> {
        self.match_axis(
            SatoriAxis::Dns,
            &SatoriObservation::new().with_field("dns", dns_name),
        )
    }

    pub fn match_icmp(&self, observation: &SatoriObservation) -> Option<SatoriMatch> {
        self.match_axis(SatoriAxis::Icmp, observation)
    }

    pub fn match_ntp(&self, ntp_signature: &str) -> Option<SatoriMatch> {
        self.match_axis(
            SatoriAxis::Ntp,
            &SatoriObservation::new().with_field("ntp", ntp_signature),
        )
    }

    pub fn match_sip(&self, sip_server: &str) -> Option<SatoriMatch> {
        self.match_axis(
            SatoriAxis::Sip,
            &SatoriObservation::new().with_field("sipserver", sip_server),
        )
    }

    pub fn match_smb(
        &self,
        native_name: Option<&str>,
        native_lanman: Option<&str>,
    ) -> Option<SatoriMatch> {
        let mut observation = SatoriObservation::new();
        if let Some(value) = native_name {
            observation = observation.with_field("smbnativename", value);
        }
        if let Some(value) = native_lanman {
            observation = observation.with_field("smbnativelanman", value);
        }

        self.match_axis(SatoriAxis::Smb, &observation)
    }

    pub fn match_smb_browser(
        &self,
        os_version: &str,
        browser_version: &str,
    ) -> Option<SatoriMatch> {
        self.match_axis(
            SatoriAxis::SmbBrowser,
            &SatoriObservation::new()
                .with_field("osversion", os_version)
                .with_field("browserversion", browser_version),
        )
    }

    pub fn match_ssh(&self, ssh_banner: &str) -> Option<SatoriMatch> {
        self.match_axis(
            SatoriAxis::Ssh,
            &SatoriObservation::new().with_field("ssh", ssh_banner),
        )
    }

    pub fn match_ssl_tls(&self, test_type: &str, signature: &str) -> Option<SatoriMatch> {
        self.match_axis(
            SatoriAxis::SslTls,
            &SatoriObservation::new()
                .with_field("testtype", test_type)
                .with_field("sslsig", signature),
        )
    }

    pub fn match_http_server(&self, server: &str) -> Option<SatoriMatch> {
        self.match_axis(
            SatoriAxis::HttpServer,
            &SatoriObservation::new().with_field("webserver", server),
        )
    }

    pub fn match_http_user_agent(&self, user_agent: &str) -> Option<SatoriMatch> {
        self.match_axis(
            SatoriAxis::HttpUserAgent,
            &SatoriObservation::new().with_field("webuseragent", user_agent),
        )
    }
}

impl SatoriEntry {
    fn best_match(&self, observation: &SatoriObservation) -> Option<SatoriMatch> {
        let matched_tests: Vec<&SatoriTest> = self
            .tests
            .iter()
            .filter(|test| test.matches(observation))
            .collect();

        if matched_tests.is_empty() {
            return None;
        }

        let mut matched_fields = BTreeMap::new();
        let mut confidence_weight = 0;
        for test in matched_tests {
            confidence_weight += test.weight;
            matched_fields.extend(test.fields.clone());
        }

        Some(SatoriMatch {
            axis: self.axis,
            source: self.source.clone(),
            label: self.label.clone(),
            os_name: self.os_name.clone(),
            os_class: self.os_class.clone(),
            os_vendor: self.os_vendor.clone(),
            device_type: self.device_type.clone(),
            device_vendor: self.device_vendor.clone(),
            confidence_weight,
            matched_fields,
        })
    }
}

impl SatoriTest {
    fn matches(&self, observation: &SatoriObservation) -> bool {
        self.fields.iter().all(|(field, expected)| {
            let Some(actual) = observation.fields.get(field) else {
                return false;
            };

            field_value_matches(self.match_type, expected, actual)
        })
    }
}

fn parse_satori_file(path: &Path) -> Result<Vec<SatoriEntry>> {
    let axis = axis_from_path(path)?;
    let source = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("Satori XML path has no UTF-8 filename: {}", path.display()))?
        .to_owned();
    let raw = fs::read_to_string(path)
        .with_context(|| format!("failed to read Satori XML {}", path.display()))?;
    let raw = raw.trim_start_matches('\u{feff}');
    let mut reader = Reader::from_str(raw);
    reader.config_mut().trim_text(true);

    let mut entries = Vec::new();
    let mut current: Option<SatoriEntry> = None;

    loop {
        match reader.read_event() {
            Ok(Event::Start(start)) if start.name().as_ref() == b"fingerprint" => {
                current = Some(parse_fingerprint_start(axis, &source, &reader, &start)?);
            }
            Ok(Event::Empty(start)) if start.name().as_ref() == b"test" => {
                if let Some(entry) = current.as_mut() {
                    entry.tests.push(parse_test(&reader, &start)?);
                }
            }
            Ok(Event::End(end)) if end.name().as_ref() == b"fingerprint" => {
                if let Some(entry) = current.take()
                    && !entry.tests.is_empty()
                {
                    entries.push(entry);
                }
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to parse Satori XML {}", path.display()));
            }
        }
    }

    Ok(entries)
}

fn parse_fingerprint_start(
    axis: SatoriAxis,
    source: &str,
    reader: &Reader<&[u8]>,
    start: &BytesStart<'_>,
) -> Result<SatoriEntry> {
    let attrs = attributes(reader, start)?;

    Ok(SatoriEntry {
        axis,
        source: source.to_owned(),
        label: attrs
            .get("name")
            .cloned()
            .unwrap_or_else(|| "unknown".to_owned()),
        os_name: non_empty_attr(&attrs, "os_name"),
        os_class: non_empty_attr(&attrs, "os_class"),
        os_vendor: non_empty_attr(&attrs, "os_vendor"),
        device_type: non_empty_attr(&attrs, "device_type"),
        device_vendor: non_empty_attr(&attrs, "device_vendor"),
        tests: Vec::new(),
    })
}

fn parse_test(reader: &Reader<&[u8]>, start: &BytesStart<'_>) -> Result<SatoriTest> {
    let attrs = attributes(reader, start)?;
    let weight = attrs
        .get("weight")
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1);
    let match_type = match attrs.get("matchtype").map(String::as_str) {
        Some("partial") => MatchType::Partial,
        _ => MatchType::Exact,
    };
    let fields = attrs
        .into_iter()
        .filter(|(key, value)| key != "weight" && key != "matchtype" && !value.is_empty())
        .collect();

    Ok(SatoriTest {
        weight,
        match_type,
        fields,
    })
}

fn attributes(reader: &Reader<&[u8]>, start: &BytesStart<'_>) -> Result<BTreeMap<String, String>> {
    let mut attrs = BTreeMap::new();

    for attr in start.attributes() {
        let attr = attr?;
        let key = std::str::from_utf8(attr.key.as_ref())
            .context("Satori XML attribute key is not UTF-8")?
            .to_owned();
        let value = attr
            .decoded_and_normalized_value(quick_xml::XmlVersion::Implicit1_0, reader.decoder())
            .context("failed to decode Satori XML attribute value")?
            .trim()
            .to_owned();
        attrs.insert(key, value);
    }

    Ok(attrs)
}

fn non_empty_attr(attrs: &BTreeMap<String, String>, key: &str) -> Option<String> {
    attrs.get(key).filter(|value| !value.is_empty()).cloned()
}

fn field_value_matches(match_type: MatchType, expected: &str, actual: &str) -> bool {
    let expected = expected.trim();
    let actual = actual.trim();

    if expected == "*" || expected.eq_ignore_ascii_case("Any") {
        return !actual.is_empty();
    }

    if let Some(forbidden) = expected.strip_prefix("!=") {
        return actual != forbidden.trim();
    }

    match match_type {
        MatchType::Exact => actual == expected,
        MatchType::Partial => actual.contains(expected),
    }
}

fn axis_from_path(path: &Path) -> Result<SatoriAxis> {
    let name = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .ok_or_else(|| anyhow!("Satori XML path has no UTF-8 stem: {}", path.display()))?;

    match name {
        "tcp" => Ok(SatoriAxis::Tcp),
        "dhcp" => Ok(SatoriAxis::Dhcp),
        "dhcpv6" => Ok(SatoriAxis::Dhcpv6),
        "dns" => Ok(SatoriAxis::Dns),
        "icmp" => Ok(SatoriAxis::Icmp),
        "ntp" => Ok(SatoriAxis::Ntp),
        "sip" => Ok(SatoriAxis::Sip),
        "smb" => Ok(SatoriAxis::Smb),
        "browser" => Ok(SatoriAxis::SmbBrowser),
        "ssh" => Ok(SatoriAxis::Ssh),
        "ssl" => Ok(SatoriAxis::SslTls),
        "web" => Ok(SatoriAxis::HttpServer),
        "webuseragent" => Ok(SatoriAxis::HttpUserAgent),
        _ => Err(anyhow!("unsupported Satori XML file {}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::{SatoriAxis, SatoriCorpus};
    use std::{
        env,
        path::{Path, PathBuf},
    };

    #[test]
    fn parses_full_corpus_from_runtime_files() {
        let corpus = fixture_corpus();

        assert!(corpus.entry_count() > 1_000);
        assert_eq!(corpus.axes().len(), 13);
    }

    #[test]
    fn matches_five_dhcp_device_classes() {
        let corpus = fixture_corpus();

        assert_eq!(
            corpus
                .match_dhcp("Discover", None, Some("1,2,3,6,15,88,42,44,46,47"), None)
                .expect("2Wire DHCP match")
                .label,
            "2Wire Residential Gateway"
        );
        assert_eq!(
            corpus
                .match_dhcp(
                    "Discover",
                    None,
                    Some("1,3,6,15,35,66,58,59,120,184,26"),
                    None
                )
                .expect("3Com DHCP match")
                .label,
            "3Com IP Phone"
        );
        assert_eq!(
            corpus
                .match_dhcp("Inform", Some("43,53,55,60"), None, None)
                .expect("Adobe DHCP match")
                .label,
            "Adobe Flash Player"
        );
        assert_eq!(
            corpus
                .match_dhcp("Discover", None, None, Some("alcatel.tsc-ip.0"))
                .expect("Alcatel DHCP match")
                .label,
            "Alcatel 4037 Advanced Reflex IP Phone"
        );
        assert_eq!(
            corpus
                .match_dhcp(
                    "Request",
                    Some("53,50,57,60,12,55"),
                    Some("1,33,3,6,15,28,51,58,59"),
                    Some("dhcpcd-5.5.6")
                )
                .expect("Amazon Fire DHCP match")
                .label,
            "Amazon Fire OS 3.0"
        );
    }

    #[test]
    fn matches_representative_tcp_ssh_smb_http_and_user_agent_fixtures() {
        let corpus = fixture_corpus();

        assert_eq!(
            corpus
                .match_tcp("S", "65535:64:0:60:M1460,S,T,N,W9:.")
                .expect("Android TCP match")
                .label,
            "Android 10.x"
        );
        assert_eq!(
            corpus
                .match_ssh("SSH-2.0-Cisco-1.25")
                .expect("Cisco SSH match")
                .label,
            "Cisco Router"
        );
        assert_eq!(
            corpus
                .match_smb(None, Some("CIFS VFS Client for Linux"))
                .expect("vSphere SMB match")
                .label,
            "vSphere"
        );
        assert_eq!(
            corpus
                .match_http_server("awselb/2.0")
                .expect("AWS ELB HTTP server match")
                .label,
            "Amazon Load Balancer"
        );

        let user_agent_match = corpus
            .match_http_user_agent("Mozilla/5.0 (Linux; Android 10)")
            .expect("Android user-agent match");
        assert!(
            user_agent_match.label.starts_with("Android"),
            "unexpected user-agent label: {}",
            user_agent_match.label
        );
    }

    #[test]
    fn exposes_axis_specific_banner_and_protocol_apis() {
        let corpus = fixture_corpus();

        assert_eq!(
            corpus
                .match_dns("time.apple.com")
                .expect("Apple DNS match")
                .axis,
            SatoriAxis::Dns
        );
        assert!(corpus.match_sip("3CXPhoneSystem").is_some());
        assert!(
            corpus
                .match_ntp("client;123,0,4,0,unset,0,random,0")
                .is_some()
        );
        assert!(corpus.match_smb_browser("10.0", "15.1").is_some());
    }

    fn fixture_corpus() -> SatoriCorpus {
        SatoriCorpus::load_from_dir(fixture_corpus_dir()).expect("fixture corpus loads")
    }

    fn fixture_corpus_dir() -> PathBuf {
        if let Ok(path) = env::var("SERVICERADAR_SATORI_CORPUS_DIR") {
            return PathBuf::from(path);
        }

        if let Ok(manifest_dir) = env::var("CARGO_MANIFEST_DIR") {
            let candidate =
                Path::new(&manifest_dir).join("../../third_party/netprobe_corpora/satori/xml");
            if candidate.exists() {
                return candidate;
            }
        }

        if let Ok(test_srcdir) = env::var("TEST_SRCDIR") {
            let root = PathBuf::from(test_srcdir);
            for relative in [
                "serviceradar/third_party/netprobe_corpora/satori/xml",
                "_main/third_party/netprobe_corpora/satori/xml",
            ] {
                let candidate = root.join(relative);
                if candidate.exists() {
                    return candidate;
                }
            }
        }

        let mut current = env::current_dir().expect("current directory is available");
        loop {
            let candidate = current.join("third_party/netprobe_corpora/satori/xml");
            if candidate.exists() {
                return candidate;
            }

            if !current.pop() {
                break;
            }
        }

        panic!("could not locate runtime Satori corpus XML directory");
    }
}
