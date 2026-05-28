use anyhow::{Context, Result};

use crate::p0f_corpus::{
    parse, parse_tcp_signature, IpVersionPattern, NumericPattern, P0fLabel, PayloadClassPattern,
    TcpOptionPattern, TcpSignature, WindowSizePattern,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct P0fMatch {
    pub label: P0fLabel,
}

#[derive(Clone, Debug)]
pub struct P0fMatcher {
    signatures: Vec<(TcpSignature, P0fLabel)>,
}

impl P0fMatcher {
    pub fn from_corpus_str(corpus: &str) -> Result<Self> {
        let corpus = parse(corpus).context("failed to parse p0f corpus")?;
        Ok(Self {
            signatures: corpus
                .tcp_signatures
                .into_iter()
                .map(|entry| (entry.signature, entry.label))
                .collect(),
        })
    }

    pub fn bundled() -> Result<Self> {
        Self::from_corpus_str(include_str!("../p0f-corpus/p0f.fp"))
    }

    pub fn match_signature(&self, observed: &str) -> Result<Option<P0fMatch>> {
        let observed =
            parse_tcp_signature(observed).context("failed to parse observed p0f signature")?;
        Ok(self.match_parsed(&observed))
    }

    pub fn match_parsed(&self, observed: &TcpSignature) -> Option<P0fMatch> {
        self.signatures
            .iter()
            .find(|(candidate, _label)| signature_matches(candidate, observed))
            .map(|(_candidate, label)| P0fMatch {
                label: label.clone(),
            })
    }
}

fn signature_matches(candidate: &TcpSignature, observed: &TcpSignature) -> bool {
    ip_version_matches(&candidate.ip_version, &observed.ip_version)
        && numeric_matches(&candidate.initial_ttl, &observed.initial_ttl)
        && numeric_matches(&candidate.ip_options_len, &observed.ip_options_len)
        && numeric_matches(&candidate.mss, &observed.mss)
        && window_matches(&candidate.window_size, &observed.window_size, &observed.mss)
        && numeric_matches(&candidate.window_scale, &observed.window_scale)
        && options_match(&candidate.options_layout, &observed.options_layout)
        && quirks_match(&candidate.quirks, &observed.quirks)
        && payload_class_matches(&candidate.payload_class, &observed.payload_class)
}

fn ip_version_matches(candidate: &IpVersionPattern, observed: &IpVersionPattern) -> bool {
    matches!(candidate, IpVersionPattern::Any) || candidate == observed
}

fn numeric_matches(candidate: &NumericPattern, observed: &NumericPattern) -> bool {
    match (candidate, observed) {
        (NumericPattern::Any, _) => true,
        (NumericPattern::Exact(left), NumericPattern::Exact(right)) => left == right,
        (NumericPattern::Max(max), NumericPattern::Exact(value)) => value <= max,
        _ => false,
    }
}

fn window_matches(
    candidate: &WindowSizePattern,
    observed: &WindowSizePattern,
    observed_mss: &NumericPattern,
) -> bool {
    match (candidate, observed) {
        (WindowSizePattern::Any, _) => true,
        (WindowSizePattern::Exact(left), WindowSizePattern::Exact(right)) => left == right,
        (WindowSizePattern::Modulo(modulo), WindowSizePattern::Exact(value)) => {
            *modulo != 0 && value % modulo == 0
        }
        (WindowSizePattern::MultipleOfMss(multiplier), WindowSizePattern::Exact(window)) => {
            numeric_exact(observed_mss)
                .is_some_and(|mss| mss != 0 && *window == mss.saturating_mul(*multiplier))
        }
        (WindowSizePattern::MultipleOfMtu(multiplier), WindowSizePattern::Exact(window)) => {
            numeric_exact(observed_mss).is_some_and(|mss| {
                let mtu = mss.saturating_add(40);
                mtu != 0 && *window == mtu.saturating_mul(*multiplier)
            })
        }
        _ => false,
    }
}

fn numeric_exact(value: &NumericPattern) -> Option<u32> {
    match value {
        NumericPattern::Exact(value) => Some(*value),
        _ => None,
    }
}

fn options_match(candidate: &[TcpOptionPattern], observed: &[TcpOptionPattern]) -> bool {
    candidate == observed
}

fn quirks_match(candidate: &[String], observed: &[String]) -> bool {
    candidate.iter().all(|quirk| observed.contains(quirk))
}

fn payload_class_matches(candidate: &PayloadClassPattern, observed: &PayloadClassPattern) -> bool {
    matches!(candidate, PayloadClassPattern::Any) || candidate == observed
}

#[cfg(test)]
mod tests {
    use super::P0fMatcher;

    #[test]
    fn matches_linux_signature_with_mss_window_multiple() {
        let matcher = P0fMatcher::bundled().unwrap();

        let matched = matcher
            .match_signature("4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0")
            .unwrap()
            .expect("expected Linux p0f match");

        assert_eq!(matched.label.name, "Linux");
        assert_eq!(matched.label.flavor.as_deref(), Some("3.11 and newer"));
    }

    #[test]
    fn returns_none_for_unknown_signature() {
        let matcher = P0fMatcher::bundled().unwrap();

        let matched = matcher
            .match_signature("4:17:0:1220:321,2:mss,nop,ws::0")
            .unwrap();

        assert!(matched.is_none());
    }

    #[test]
    fn max_ttl_pattern_matches_lower_observed_ttl() {
        let matcher = P0fMatcher::from_corpus_str(
            r#"
[tcp:request]
label = s:!:Scanner:Example
sys = @unix
sig = *:64-:0:1460:1024,0:mss::0
"#,
        )
        .unwrap();

        let matched = matcher
            .match_signature("4:48:0:1460:1024,0:mss::0")
            .unwrap()
            .expect("expected max TTL match");

        assert_eq!(matched.label.name, "Scanner");
    }
}
