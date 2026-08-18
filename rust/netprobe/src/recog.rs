use std::{collections::BTreeMap, sync::OnceLock};

use regex_automata::meta::Regex;

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum RecogService {
    HttpServer,
    SshBanner,
    SmbVersion,
    FtpBanner,
    SmtpBanner,
    TelnetBanner,
    SnmpBanner,
    SipBanner,
    RdpBanner,
    DnsVersion,
    NtpReadvar,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct RecogLabel {
    pub service: RecogService,
    pub source: &'static str,
    pub pattern: &'static str,
    pub vendor: Option<String>,
    pub product: Option<String>,
    pub version: Option<String>,
    pub os_family: Option<String>,
    pub os_product: Option<String>,
    pub os_version: Option<String>,
    pub hardware_vendor: Option<String>,
    pub hardware_product: Option<String>,
    pub params: BTreeMap<String, String>,
}

#[derive(Debug, Clone)]
pub struct RecogCompileError {
    pattern: &'static str,
    error: String,
}

impl std::fmt::Display for RecogCompileError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "failed to compile Recog pattern {:?}: {}",
            self.pattern, self.error
        )
    }
}

impl std::error::Error for RecogCompileError {}

#[derive(Debug)]
struct RecogFingerprintDef {
    service: RecogService,
    source: &'static str,
    pattern: &'static str,
    params: &'static [RecogParamDef],
}

#[derive(Debug)]
struct RecogParamDef {
    name: &'static str,
    value: Option<&'static str>,
    pos: usize,
}

#[derive(Debug)]
struct CompiledRecogFingerprint {
    def: &'static RecogFingerprintDef,
    regex: Regex,
}

include!(concat!(env!("OUT_DIR"), "/recog_generated.rs"));

static RECOG_MATCHERS: OnceLock<Result<Vec<CompiledRecogFingerprint>, RecogCompileError>> =
    OnceLock::new();

pub fn match_recog(service: RecogService, banner: &str) -> Option<RecogLabel> {
    match_recog_result(service, banner).ok().flatten()
}

pub fn match_recog_result(
    service: RecogService,
    banner: &str,
) -> Result<Option<RecogLabel>, RecogCompileError> {
    let matchers = RECOG_MATCHERS
        .get_or_init(compile_recog_matchers)
        .as_ref()
        .map_err(Clone::clone)?;

    for matcher in matchers
        .iter()
        .filter(|matcher| matcher.def.service == service)
    {
        let mut captures = matcher.regex.create_captures();
        matcher.regex.captures(banner, &mut captures);
        if !captures.is_match() {
            continue;
        }

        return Ok(Some(build_label(matcher.def, banner, &captures)));
    }

    Ok(None)
}

fn compile_recog_matchers() -> Result<Vec<CompiledRecogFingerprint>, RecogCompileError> {
    RECOG_FINGERPRINTS
        .iter()
        .map(|def| {
            let pattern = rust_regex_pattern(def.pattern);
            Regex::new(&pattern)
                .map(|regex| CompiledRecogFingerprint { def, regex })
                .map_err(|error| RecogCompileError {
                    pattern: def.pattern,
                    error: error.to_string(),
                })
        })
        .collect()
}

fn rust_regex_pattern(pattern: &str) -> String {
    let mut rewritten = String::with_capacity(pattern.len());
    let mut chars = pattern.chars();
    let mut in_class = false;

    while let Some(ch) = chars.next() {
        match ch {
            '[' if !in_class => {
                in_class = true;
                rewritten.push(ch);
            }
            ']' if in_class => {
                in_class = false;
                rewritten.push(ch);
            }
            '\\' => match chars.next() {
                Some('w') if in_class => rewritten.push_str("A-Za-z0-9_"),
                Some('w') => rewritten.push_str("[A-Za-z0-9_]"),
                Some('W') if in_class => rewritten.push_str("^A-Za-z0-9_"),
                Some('W') => rewritten.push_str("[^A-Za-z0-9_]"),
                Some('d') if in_class => rewritten.push_str("0-9"),
                Some('d') => rewritten.push_str("[0-9]"),
                Some('s') if in_class => rewritten.push_str(" \\t\\r\\n\\f"),
                Some('s') => rewritten.push_str("[ \\t\\r\\n\\f]"),
                Some('S') if in_class => rewritten.push_str("^ \\t\\r\\n\\f"),
                Some('S') => rewritten.push_str("[^ \\t\\r\\n\\f]"),
                Some(next) => {
                    rewritten.push('\\');
                    rewritten.push(next);
                }
                None => rewritten.push('\\'),
            },
            _ => rewritten.push(ch),
        }
    }

    rewritten
}

fn build_label(
    def: &'static RecogFingerprintDef,
    banner: &str,
    captures: &regex_automata::util::captures::Captures,
) -> RecogLabel {
    let mut params = BTreeMap::new();

    for param in def.params {
        if let Some(value) = param_value(param, banner, captures, &params) {
            params.insert(param.name.to_owned(), value);
        }
    }

    RecogLabel {
        service: def.service,
        source: def.source,
        pattern: def.pattern,
        vendor: first_param(&params, &["service.vendor", "os.vendor"]).cloned(),
        product: first_param(&params, &["service.product", "os.product"]).cloned(),
        version: first_param(&params, &["service.version", "os.version"]).cloned(),
        os_family: params.get("os.family").cloned(),
        os_product: params.get("os.product").cloned(),
        os_version: params.get("os.version").cloned(),
        hardware_vendor: params.get("hw.vendor").cloned(),
        hardware_product: first_param(&params, &["hw.product", "hw.model"]).cloned(),
        params,
    }
}

fn param_value(
    param: &RecogParamDef,
    banner: &str,
    captures: &regex_automata::util::captures::Captures,
    params: &BTreeMap<String, String>,
) -> Option<String> {
    match param.value {
        Some(value) => Some(expand_placeholders(value, params)),
        None => captures
            .get_group(param.pos)
            .map(|span| banner[span.range()].to_owned()),
    }
}

fn expand_placeholders(value: &str, params: &BTreeMap<String, String>) -> String {
    let mut expanded = String::with_capacity(value.len());
    let mut rest = value;

    while let Some(open) = rest.find('{') {
        expanded.push_str(&rest[..open]);
        let after_open = &rest[open + 1..];
        if let Some(close) = after_open.find('}') {
            let key = &after_open[..close];
            if let Some(replacement) = params.get(key) {
                expanded.push_str(replacement);
            } else {
                expanded.push('{');
                expanded.push_str(key);
                expanded.push('}');
            }
            rest = &after_open[close + 1..];
        } else {
            expanded.push_str(&rest[open..]);
            rest = "";
        }
    }

    expanded.push_str(rest);
    expanded
}

fn first_param<'a>(params: &'a BTreeMap<String, String>, keys: &[&str]) -> Option<&'a String> {
    keys.iter().find_map(|key| params.get(*key))
}

#[cfg(test)]
mod tests {
    use super::{RecogService, match_recog_result};

    #[test]
    fn matches_http_server_banner() {
        let label = match_recog_result(RecogService::HttpServer, "Apache/2.4.58 (Ubuntu)")
            .expect("Recog patterns compile")
            .expect("Apache banner matches");

        assert_eq!(label.vendor.as_deref(), Some("Apache"));
        assert_eq!(label.product.as_deref(), Some("HTTPD"));
        assert_eq!(label.version.as_deref(), Some("2.4.58"));
    }

    #[test]
    fn matches_ssh_banner() {
        let label = match_recog_result(RecogService::SshBanner, "OpenSSH_8.9p1 Ubuntu-3ubuntu0.10")
            .expect("Recog patterns compile")
            .expect("OpenSSH banner matches");

        assert_eq!(label.vendor.as_deref(), Some("OpenBSD"));
        assert_eq!(label.product.as_deref(), Some("OpenSSH"));
        assert_eq!(label.version.as_deref(), Some("8.9p1"));
        assert_eq!(label.os_family.as_deref(), Some("Linux"));
    }

    #[test]
    fn matches_smb_version_banner() {
        let label = match_recog_result(RecogService::SmbVersion, "Samba 4.13.17")
            .expect("Recog patterns compile")
            .expect("Samba banner matches");

        assert_eq!(label.vendor.as_deref(), Some("Samba"));
        assert_eq!(label.product.as_deref(), Some("Samba"));
        assert_eq!(label.version.as_deref(), Some("4.13.17"));
    }

    #[test]
    fn matches_telnet_banner() {
        let label = match_recog_result(
            RecogService::TelnetBanner,
            "Password required, but none set",
        )
        .expect("Recog patterns compile")
        .expect("Cisco Telnet banner matches");

        assert_eq!(label.hardware_vendor.as_deref(), Some("Cisco"));
    }

    #[test]
    fn matches_ftp_banner() {
        let label = match_recog_result(
            RecogService::FtpBanner,
            "foo.bar Microsoft FTP Service (Version 5.0).",
        )
        .expect("Recog patterns compile")
        .expect("Microsoft FTP banner matches");

        assert_eq!(label.vendor.as_deref(), Some("Microsoft"));
        assert_eq!(label.product.as_deref(), Some("IIS"));
        assert_eq!(label.os_family.as_deref(), Some("Windows"));
    }

    #[test]
    fn matches_smtp_banner() {
        let label = match_recog_result(RecogService::SmtpBanner, "foo.bar ESMTP Postfix 2.7.1")
            .expect("Recog patterns compile")
            .expect("SMTP banner matches");

        assert_eq!(label.product.as_deref(), Some("Postfix"));
        assert_eq!(label.version.as_deref(), Some("2.7.1"));
    }

    #[test]
    fn matches_snmp_banner() {
        let label = match_recog_result(RecogService::SnmpBanner, "3Com IntelliJack NJ220")
            .expect("Recog patterns compile")
            .expect("SNMP sysDescr matches");

        assert_eq!(label.vendor.as_deref(), Some("3Com"));
        assert_eq!(label.product.as_deref(), Some("NJ220"));
    }

    #[test]
    fn matches_sip_banner() {
        let label = match_recog_result(RecogService::SipBanner, "Cisco-SIPGateway/IOS-15.2.4.M3")
            .expect("Recog patterns compile")
            .expect("SIP server banner matches");

        assert_eq!(label.vendor.as_deref(), Some("Cisco"));
        assert_eq!(label.product.as_deref(), Some("IOS"));
        assert_eq!(label.version.as_deref(), Some("15.2.4.M3"));
    }

    #[test]
    fn matches_dns_version_banner() {
        let label = match_recog_result(RecogService::DnsVersion, "9.9.4-RedHat-9.9.4-38.el7_3.3")
            .expect("Recog patterns compile")
            .expect("DNS version.bind banner matches");

        assert_eq!(label.vendor.as_deref(), Some("ISC"));
        assert_eq!(label.product.as_deref(), Some("BIND"));
        assert_eq!(label.version.as_deref(), Some("9.9.4"));
    }

    // The ntp_banners.xml corpus shipped for months without a recog_service_for_file mapping,
    // so it compiled into zero fingerprints and no ntp banner could ever match. This asserts
    // the corpus is actually wired in, not merely present on disk.
    #[test]
    fn matches_ntp_readvar_banner() {
        let label = match_recog_result(
            RecogService::NtpReadvar,
            "version=\"ntpd 4.2.8p15@1.3728-o Wed Jun 23 09:31:32 UTC 2021 (1)\", \
             processor=\"x86_64\", system=\"Linux/5.15.0\", leap=00, stratum=3,",
        )
        .expect("Recog patterns compile")
        .expect("NTP readvar banner matches");

        assert_eq!(label.product.as_deref(), Some("NTP"));
        // The corpus pattern captures the whole non-space token, build tag included; this is
        // upstream Recog's behaviour, not a quirk of ours.
        assert_eq!(label.version.as_deref(), Some("4.2.8p15@1.3728-o"));
    }

    #[test]
    fn rdp_returns_none_until_a_corpus_is_available() {
        let label = match_recog_result(RecogService::RdpBanner, "RDP fixture")
            .expect("Recog patterns compile");

        assert!(label.is_none());
    }

    #[test]
    fn returns_none_for_unknown_banner() {
        let label = match_recog_result(RecogService::HttpServer, "unknown-test-banner")
            .expect("Recog patterns compile");

        assert!(label.is_none());
    }
}
