use crate::p0f_corpus::P0fLabel;
use crate::p0f_matcher::P0fMatch;

const P0F_BASE_CONFIDENCE: f32 = 0.72;
const JA4_AGREEMENT_MULTIPLIER: f32 = 1.15;
const HASSH_AGREEMENT_MULTIPLIER: f32 = 1.15;
const MAX_CONFIDENCE: f32 = 0.95;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OsMatchInput {
    pub p0f: P0fObservation,
    pub ja4: Option<FingerprintObservation>,
    pub hassh: Option<FingerprintObservation>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct P0fObservation {
    pub signature: String,
    pub matched: P0fMatch,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FingerprintObservation {
    pub signal: FingerprintSignal,
    pub signature: String,
    pub os_family: String,
    pub name: String,
    pub version_range: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FingerprintSignal {
    Ja4,
    Hassh,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OsMatch {
    pub os_family: String,
    pub name: String,
    pub version_range: Option<String>,
    pub confidence: f32,
    pub agreement_count: u32,
    pub p0f_signature: String,
    pub p0f_label: P0fLabel,
    pub agreeing_signals: Vec<SignalAgreement>,
    pub disagreements: Vec<SignalDisagreement>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SignalAgreement {
    pub signal: FingerprintSignal,
    pub signature: String,
    pub name: String,
    pub version_range: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SignalDisagreement {
    pub signal: FingerprintSignal,
    pub signature: String,
    pub observed_family: String,
    pub observed_name: String,
    pub version_range: Option<String>,
}

pub fn evaluate(input: OsMatchInput) -> OsMatch {
    let p0f_family = family_from_p0f_label(&input.p0f.matched.label);
    let mut confidence = P0F_BASE_CONFIDENCE;
    let mut agreement_count = 1;
    let mut agreeing_signals = Vec::new();
    let mut disagreements = Vec::new();

    for observation in [input.ja4, input.hassh].into_iter().flatten() {
        if normalized_family(&observation.os_family) == p0f_family {
            confidence *= multiplier(observation.signal);
            agreement_count += 1;
            agreeing_signals.push(SignalAgreement {
                signal: observation.signal,
                signature: observation.signature,
                name: observation.name,
                version_range: observation.version_range,
            });
        } else {
            disagreements.push(SignalDisagreement {
                signal: observation.signal,
                signature: observation.signature,
                observed_family: normalized_family(&observation.os_family),
                observed_name: observation.name,
                version_range: observation.version_range,
            });
        }
    }

    OsMatch {
        os_family: p0f_family,
        name: input.p0f.matched.label.name.clone(),
        version_range: input.p0f.matched.label.flavor.clone(),
        confidence: confidence.min(MAX_CONFIDENCE),
        agreement_count,
        p0f_signature: input.p0f.signature,
        p0f_label: input.p0f.matched.label,
        agreeing_signals,
        disagreements,
    }
}

fn multiplier(signal: FingerprintSignal) -> f32 {
    match signal {
        FingerprintSignal::Ja4 => JA4_AGREEMENT_MULTIPLIER,
        FingerprintSignal::Hassh => HASSH_AGREEMENT_MULTIPLIER,
    }
}

pub(crate) fn family_from_p0f_label(label: &P0fLabel) -> String {
    let name = normalized_family(&label.name);
    match name.as_str() {
        "mac os x" | "macos" | "os x" => "macos".to_string(),
        "windows" | "win" => "windows".to_string(),
        "linux" | "freebsd" | "openbsd" | "netbsd" | "solaris" | "ios" | "android" => name,
        _ => label
            .class
            .as_deref()
            .map(normalized_family)
            .filter(|family| !family.is_empty() && family != "unix")
            .unwrap_or(name),
    }
}

fn normalized_family(value: &str) -> String {
    value.trim().to_ascii_lowercase().replace('_', " ")
}

#[cfg(test)]
mod tests {
    use super::{
        evaluate, FingerprintObservation, FingerprintSignal, OsMatchInput, P0fObservation,
        HASSH_AGREEMENT_MULTIPLIER, JA4_AGREEMENT_MULTIPLIER, MAX_CONFIDENCE, P0F_BASE_CONFIDENCE,
    };
    use crate::p0f_corpus::P0fLabel;
    use crate::p0f_matcher::P0fMatch;

    #[test]
    fn emits_p0f_match_without_auxiliary_signals() {
        let matched = evaluate(OsMatchInput {
            p0f: p0f_observation("Linux", Some("3.11 and newer")),
            ja4: None,
            hassh: None,
        });

        assert_eq!(matched.os_family, "linux");
        assert_eq!(matched.name, "Linux");
        assert_eq!(matched.version_range.as_deref(), Some("3.11 and newer"));
        assert_eq!(matched.agreement_count, 1);
        assert_eq!(matched.confidence, P0F_BASE_CONFIDENCE);
        assert!(matched.agreeing_signals.is_empty());
        assert!(matched.disagreements.is_empty());
    }

    #[test]
    fn boosts_confidence_when_ja4_agrees() {
        let matched = evaluate(OsMatchInput {
            p0f: p0f_observation("Linux", None),
            ja4: Some(auxiliary(FingerprintSignal::Ja4, "linux")),
            hassh: None,
        });

        assert_eq!(matched.agreement_count, 2);
        assert_eq!(matched.agreeing_signals[0].signal, FingerprintSignal::Ja4);
        assert_eq!(
            matched.confidence,
            P0F_BASE_CONFIDENCE * JA4_AGREEMENT_MULTIPLIER
        );
    }

    #[test]
    fn boosts_confidence_when_hassh_agrees() {
        let matched = evaluate(OsMatchInput {
            p0f: p0f_observation("Linux", None),
            ja4: None,
            hassh: Some(auxiliary(FingerprintSignal::Hassh, "linux")),
        });

        assert_eq!(matched.agreement_count, 2);
        assert_eq!(matched.agreeing_signals[0].signal, FingerprintSignal::Hassh);
        assert_eq!(
            matched.confidence,
            P0F_BASE_CONFIDENCE * HASSH_AGREEMENT_MULTIPLIER
        );
    }

    #[test]
    fn caps_confidence_when_all_signals_agree() {
        let matched = evaluate(OsMatchInput {
            p0f: p0f_observation("Linux", None),
            ja4: Some(auxiliary(FingerprintSignal::Ja4, "linux")),
            hassh: Some(auxiliary(FingerprintSignal::Hassh, "linux")),
        });

        assert_eq!(matched.agreement_count, 3);
        assert_eq!(matched.confidence, MAX_CONFIDENCE);
    }

    #[test]
    fn preserves_disagreement_metadata() {
        let matched = evaluate(OsMatchInput {
            p0f: p0f_observation("Linux", None),
            ja4: Some(auxiliary(FingerprintSignal::Ja4, "windows")),
            hassh: None,
        });

        assert_eq!(matched.os_family, "linux");
        assert_eq!(matched.agreement_count, 1);
        assert_eq!(matched.confidence, P0F_BASE_CONFIDENCE);
        assert!(matched.agreeing_signals.is_empty());
        assert_eq!(matched.disagreements.len(), 1);
        assert_eq!(matched.disagreements[0].signal, FingerprintSignal::Ja4);
        assert_eq!(matched.disagreements[0].observed_family, "windows");
    }

    #[test]
    fn normalizes_common_p0f_families() {
        assert_eq!(
            evaluate(OsMatchInput {
                p0f: p0f_observation("Mac OS X", Some("14.x")),
                ja4: Some(auxiliary(FingerprintSignal::Ja4, "macos")),
                hassh: None,
            })
            .os_family,
            "macos"
        );

        assert_eq!(
            evaluate(OsMatchInput {
                p0f: p0f_observation("Windows", Some("11")),
                ja4: Some(auxiliary(FingerprintSignal::Ja4, "windows")),
                hassh: None,
            })
            .os_family,
            "windows"
        );
    }

    fn p0f_observation(name: &str, flavor: Option<&str>) -> P0fObservation {
        P0fObservation {
            signature: "4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0".to_string(),
            matched: P0fMatch {
                label: P0fLabel {
                    raw: format!("s:unix:{name}:{}", flavor.unwrap_or("*")),
                    record_type: Some("s".to_string()),
                    class: Some("unix".to_string()),
                    name: name.to_string(),
                    flavor: flavor.map(str::to_string),
                },
            },
        }
    }

    fn auxiliary(signal: FingerprintSignal, os_family: &str) -> FingerprintObservation {
        FingerprintObservation {
            signal,
            signature: match signal {
                FingerprintSignal::Ja4 => "t13d1516h2_8daaf6152771_e5627efa2ab1",
                FingerprintSignal::Hassh => "06046964c022c6407d15a27b12a6a4fb",
            }
            .to_string(),
            os_family: os_family.to_string(),
            name: format!("{os_family} auxiliary match"),
            version_range: Some("test range".to_string()),
        }
    }
}
