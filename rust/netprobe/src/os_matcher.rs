use std::collections::BTreeMap;

use crate::p0f_corpus::P0fLabel;
use crate::p0f_matcher::P0fMatch;

const P0F_BASE_CONFIDENCE: f32 = 0.72;
const MUONFP_BASE_CONFIDENCE: f32 = 0.70;
const MUONFP_AGREEMENT_MULTIPLIER: f32 = 1.12;
const JA4_AGREEMENT_MULTIPLIER: f32 = 1.15;
const HASSH_AGREEMENT_MULTIPLIER: f32 = 1.15;
const RECOG_AGREEMENT_MULTIPLIER: f32 = 1.08;
const SATORI_AGREEMENT_MULTIPLIER: f32 = 1.08;
const SATORI_TCP_BASE_CONFIDENCE: f32 = 0.68;
const MAX_CONFIDENCE: f32 = 0.95;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OsMatchInput {
    pub p0f: Option<P0fObservation>,
    pub muonfp: Option<MuonFpObservation>,
    pub ja4: Option<FingerprintObservation>,
    pub hassh: Option<FingerprintObservation>,
    pub recog: Vec<FingerprintObservation>,
    pub satori: Vec<FingerprintObservation>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct P0fObservation {
    pub signature: String,
    pub matched: P0fMatch,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MuonFpObservation {
    pub signature: String,
    pub label: Option<String>,
    pub os_family: String,
    pub name: String,
    pub version_range: Option<String>,
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
    MuonFp,
    Ja4,
    Hassh,
    RecogHttp,
    RecogSsh,
    RecogSmb,
    RecogFtp,
    RecogSmtp,
    RecogTelnet,
    RecogSnmp,
    RecogSip,
    RecogRdp,
    RecogDns,
    RecogNtp,
    SatoriTcp,
    SatoriDhcp,
    SatoriHttp,
    SatoriSsh,
    SatoriSmb,
    SatoriSsl,
    SatoriDns,
    SatoriIcmp,
    SatoriNtp,
    SatoriSip,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OsMatch {
    pub os_family: String,
    pub name: String,
    pub version_range: Option<String>,
    pub confidence: f32,
    pub agreement_count: u32,
    pub p0f_signature: Option<String>,
    pub p0f_label: Option<P0fLabel>,
    pub muonfp_signature: Option<String>,
    pub muonfp_label: Option<String>,
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

pub fn evaluate(input: OsMatchInput) -> Option<OsMatch> {
    let primary = primary_tcp_observation(&input)?;
    let auxiliary = auxiliary_observations(&input, primary.signal);
    let selected = weighted_majority_choice(&primary, &auxiliary);
    let mut confidence = if selected.used_fallback {
        selected.weight.min(MAX_CONFIDENCE)
    } else {
        primary.base_confidence
    };
    let mut agreement_count = if selected.used_fallback { 0 } else { 1 };
    let mut agreeing_signals = Vec::new();
    let mut disagreements = Vec::new();

    for observation in auxiliary {
        if observation.family == selected.os_family {
            if !selected.used_fallback {
                confidence *= observation.multiplier;
            }
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
                observed_family: observation.family,
                observed_name: observation.name,
                version_range: observation.version_range,
            });
        }
    }

    Some(OsMatch {
        os_family: selected.os_family,
        name: selected.name,
        version_range: selected.version_range,
        confidence: confidence.min(MAX_CONFIDENCE),
        agreement_count,
        p0f_signature: input
            .p0f
            .as_ref()
            .map(|observation| observation.signature.clone()),
        p0f_label: input
            .p0f
            .as_ref()
            .map(|observation| observation.matched.label.clone()),
        muonfp_signature: input
            .muonfp
            .as_ref()
            .map(|observation| observation.signature.clone()),
        muonfp_label: input.muonfp.and_then(|observation| observation.label),
        agreeing_signals,
        disagreements,
    })
}

fn multiplier(signal: FingerprintSignal) -> f32 {
    match signal {
        FingerprintSignal::MuonFp => MUONFP_AGREEMENT_MULTIPLIER,
        FingerprintSignal::Ja4 => JA4_AGREEMENT_MULTIPLIER,
        FingerprintSignal::Hassh => HASSH_AGREEMENT_MULTIPLIER,
        FingerprintSignal::RecogHttp
        | FingerprintSignal::RecogSsh
        | FingerprintSignal::RecogSmb
        | FingerprintSignal::RecogFtp
        | FingerprintSignal::RecogSmtp
        | FingerprintSignal::RecogTelnet
        | FingerprintSignal::RecogSnmp
        | FingerprintSignal::RecogSip
        | FingerprintSignal::RecogRdp
        | FingerprintSignal::RecogDns
        | FingerprintSignal::RecogNtp => RECOG_AGREEMENT_MULTIPLIER,
        FingerprintSignal::SatoriTcp
        | FingerprintSignal::SatoriDhcp
        | FingerprintSignal::SatoriHttp
        | FingerprintSignal::SatoriSsh
        | FingerprintSignal::SatoriSmb
        | FingerprintSignal::SatoriSsl
        | FingerprintSignal::SatoriDns
        | FingerprintSignal::SatoriIcmp
        | FingerprintSignal::SatoriNtp
        | FingerprintSignal::SatoriSip => SATORI_AGREEMENT_MULTIPLIER,
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

#[derive(Clone, Debug)]
struct TcpPrimary {
    signal: Option<FingerprintSignal>,
    os_family: String,
    name: String,
    version_range: Option<String>,
    base_confidence: f32,
}

#[derive(Debug)]
struct AuxiliaryObservation {
    signal: FingerprintSignal,
    signature: String,
    family: String,
    name: String,
    version_range: Option<String>,
    multiplier: f32,
}

#[derive(Clone, Debug)]
struct MatchChoice {
    os_family: String,
    name: String,
    version_range: Option<String>,
    weight: f32,
    used_fallback: bool,
}

#[derive(Clone, Debug)]
struct VoteAggregate {
    weight: f32,
    strongest_signal_weight: f32,
    name: String,
    version_range: Option<String>,
}

fn weighted_majority_choice(
    primary: &TcpPrimary,
    auxiliary: &[AuxiliaryObservation],
) -> MatchChoice {
    let mut votes = BTreeMap::new();
    add_vote(
        &mut votes,
        &primary.os_family,
        &primary.name,
        primary.version_range.clone(),
        primary.base_confidence,
    );

    for observation in auxiliary {
        add_vote(
            &mut votes,
            &observation.family,
            &observation.name,
            observation.version_range.clone(),
            baseline_weight(observation.signal),
        );
    }

    let primary_weight = votes
        .get(&primary.os_family)
        .map(|vote| vote.weight)
        .unwrap_or(primary.base_confidence);
    let Some((family, vote)) = votes
        .iter()
        .max_by(|(left_family, left), (right_family, right)| {
            left.weight.total_cmp(&right.weight).then_with(|| {
                (left_family.as_str() == primary.os_family)
                    .cmp(&(right_family.as_str() == primary.os_family))
            })
        })
    else {
        return MatchChoice {
            os_family: primary.os_family.clone(),
            name: primary.name.clone(),
            version_range: primary.version_range.clone(),
            weight: primary.base_confidence,
            used_fallback: false,
        };
    };

    if family == &primary.os_family || vote.weight <= primary_weight {
        return MatchChoice {
            os_family: primary.os_family.clone(),
            name: primary.name.clone(),
            version_range: primary.version_range.clone(),
            weight: primary_weight,
            used_fallback: false,
        };
    }

    MatchChoice {
        os_family: family.clone(),
        name: vote.name.clone(),
        version_range: vote.version_range.clone(),
        weight: vote.weight,
        used_fallback: true,
    }
}

fn add_vote(
    votes: &mut BTreeMap<String, VoteAggregate>,
    family: &str,
    name: &str,
    version_range: Option<String>,
    weight: f32,
) {
    let entry = votes.entry(family.to_string()).or_insert(VoteAggregate {
        weight: 0.0,
        strongest_signal_weight: 0.0,
        name: name.to_string(),
        version_range: version_range.clone(),
    });
    entry.weight += weight;
    if weight >= entry.strongest_signal_weight {
        entry.strongest_signal_weight = weight;
        entry.name = name.to_string();
        entry.version_range = version_range;
    }
}

fn baseline_weight(signal: FingerprintSignal) -> f32 {
    match signal {
        FingerprintSignal::MuonFp => MUONFP_BASE_CONFIDENCE,
        FingerprintSignal::SatoriTcp => SATORI_TCP_BASE_CONFIDENCE,
        FingerprintSignal::Ja4 | FingerprintSignal::Hassh => 0.30,
        FingerprintSignal::RecogHttp
        | FingerprintSignal::RecogSsh
        | FingerprintSignal::RecogSmb
        | FingerprintSignal::RecogFtp
        | FingerprintSignal::RecogSmtp
        | FingerprintSignal::RecogTelnet
        | FingerprintSignal::RecogSnmp
        | FingerprintSignal::RecogSip
        | FingerprintSignal::RecogRdp
        | FingerprintSignal::RecogDns
        | FingerprintSignal::RecogNtp
        | FingerprintSignal::SatoriDhcp
        | FingerprintSignal::SatoriHttp
        | FingerprintSignal::SatoriSsh
        | FingerprintSignal::SatoriSmb
        | FingerprintSignal::SatoriSsl
        | FingerprintSignal::SatoriDns
        | FingerprintSignal::SatoriIcmp
        | FingerprintSignal::SatoriNtp
        | FingerprintSignal::SatoriSip => 0.25,
    }
}

fn primary_tcp_observation(input: &OsMatchInput) -> Option<TcpPrimary> {
    if let Some(p0f) = &input.p0f {
        let label = &p0f.matched.label;
        return Some(TcpPrimary {
            signal: None,
            os_family: family_from_p0f_label(label),
            name: label.name.clone(),
            version_range: label.flavor.clone(),
            base_confidence: P0F_BASE_CONFIDENCE,
        });
    }

    if let Some(muonfp) = &input.muonfp {
        return Some(TcpPrimary {
            signal: Some(FingerprintSignal::MuonFp),
            os_family: normalized_family(&muonfp.os_family),
            name: muonfp.name.clone(),
            version_range: muonfp.version_range.clone(),
            base_confidence: MUONFP_BASE_CONFIDENCE,
        });
    }

    input
        .satori
        .iter()
        .find(|observation| observation.signal == FingerprintSignal::SatoriTcp)
        .map(|observation| TcpPrimary {
            signal: Some(FingerprintSignal::SatoriTcp),
            os_family: normalized_family(&observation.os_family),
            name: observation.name.clone(),
            version_range: observation.version_range.clone(),
            base_confidence: SATORI_TCP_BASE_CONFIDENCE,
        })
}

fn auxiliary_observations(
    input: &OsMatchInput,
    primary_signal: Option<FingerprintSignal>,
) -> Vec<AuxiliaryObservation> {
    let mut observations = Vec::new();

    if input.p0f.is_some()
        && let Some(muonfp) = &input.muonfp
    {
        observations.push(AuxiliaryObservation {
            signal: FingerprintSignal::MuonFp,
            signature: muonfp.signature.clone(),
            family: normalized_family(&muonfp.os_family),
            name: muonfp.name.clone(),
            version_range: muonfp.version_range.clone(),
            multiplier: multiplier(FingerprintSignal::MuonFp),
        });
    }

    for observation in [&input.ja4, &input.hassh]
        .into_iter()
        .flatten()
        .chain(input.recog.iter())
        .chain(input.satori.iter())
        .filter(|observation| Some(observation.signal) != primary_signal)
    {
        observations.push(AuxiliaryObservation {
            signal: observation.signal,
            signature: observation.signature.clone(),
            family: normalized_family(&observation.os_family),
            name: observation.name.clone(),
            version_range: observation.version_range.clone(),
            multiplier: multiplier(observation.signal),
        });
    }

    observations
}

#[cfg(test)]
mod tests {
    use super::{
        FingerprintObservation, FingerprintSignal, HASSH_AGREEMENT_MULTIPLIER,
        JA4_AGREEMENT_MULTIPLIER, MUONFP_AGREEMENT_MULTIPLIER, MUONFP_BASE_CONFIDENCE,
        MuonFpObservation, OsMatchInput, P0F_BASE_CONFIDENCE, P0fObservation,
        RECOG_AGREEMENT_MULTIPLIER, SATORI_AGREEMENT_MULTIPLIER, SATORI_TCP_BASE_CONFIDENCE,
        evaluate,
    };
    use crate::p0f_corpus::P0fLabel;
    use crate::p0f_matcher::P0fMatch;

    #[test]
    fn emits_p0f_match_without_auxiliary_signals() {
        let matched = evaluate(OsMatchInput {
            p0f: Some(p0f_observation("Linux", Some("3.11 and newer"))),
            muonfp: None,
            ja4: None,
            hassh: None,
            ..Default::default()
        })
        .unwrap();

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
            p0f: Some(p0f_observation("Linux", None)),
            muonfp: None,
            ja4: Some(auxiliary(FingerprintSignal::Ja4, "linux")),
            hassh: None,
            ..Default::default()
        })
        .unwrap();

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
            p0f: Some(p0f_observation("Linux", None)),
            muonfp: None,
            ja4: None,
            hassh: Some(auxiliary(FingerprintSignal::Hassh, "linux")),
            ..Default::default()
        })
        .unwrap();

        assert_eq!(matched.agreement_count, 2);
        assert_eq!(matched.agreeing_signals[0].signal, FingerprintSignal::Hassh);
        assert_eq!(
            matched.confidence,
            P0F_BASE_CONFIDENCE * HASSH_AGREEMENT_MULTIPLIER
        );
    }

    #[test]
    fn boosts_confidence_when_muonfp_agrees() {
        let matched = evaluate(OsMatchInput {
            p0f: Some(p0f_observation("Linux", None)),
            muonfp: Some(muonfp_observation("linux")),
            ja4: None,
            hassh: None,
            ..Default::default()
        })
        .unwrap();

        assert_eq!(matched.agreement_count, 2);
        assert_eq!(
            matched.agreeing_signals[0].signal,
            FingerprintSignal::MuonFp
        );
        assert_eq!(
            matched.confidence,
            P0F_BASE_CONFIDENCE * MUONFP_AGREEMENT_MULTIPLIER
        );
        assert_eq!(matched.muonfp_signature.as_deref(), Some("64240:2-4:1460:"));
        assert_eq!(
            matched.muonfp_label.as_deref(),
            Some("linux synthetic rule")
        );
    }

    #[test]
    fn emits_muonfp_match_without_p0f() {
        let matched = evaluate(OsMatchInput {
            p0f: None,
            muonfp: Some(muonfp_observation("linux")),
            ja4: None,
            hassh: None,
            ..Default::default()
        })
        .unwrap();

        assert_eq!(matched.os_family, "linux");
        assert_eq!(matched.name, "MuonFP linux");
        assert_eq!(matched.agreement_count, 1);
        assert_eq!(matched.confidence, MUONFP_BASE_CONFIDENCE);
        assert!(matched.p0f_signature.is_none());
        assert!(matched.p0f_label.is_none());
    }

    #[test]
    fn returns_none_without_tcp_match() {
        assert!(
            evaluate(OsMatchInput {
                p0f: None,
                muonfp: None,
                ja4: Some(auxiliary(FingerprintSignal::Ja4, "linux")),
                hassh: None,
                ..Default::default()
            })
            .is_none()
        );
    }

    #[test]
    fn caps_confidence_when_all_signals_agree() {
        let matched = evaluate(OsMatchInput {
            p0f: Some(p0f_observation("Linux", None)),
            muonfp: Some(muonfp_observation("linux")),
            ja4: Some(auxiliary(FingerprintSignal::Ja4, "linux")),
            hassh: Some(auxiliary(FingerprintSignal::Hassh, "linux")),
            recog: vec![auxiliary(FingerprintSignal::RecogSsh, "linux")],
            satori: vec![auxiliary(FingerprintSignal::SatoriHttp, "linux")],
        })
        .unwrap();

        assert_eq!(matched.agreement_count, 6);
        assert!(matched.confidence <= super::MAX_CONFIDENCE);
    }

    #[test]
    fn boosts_confidence_when_recog_agrees() {
        let matched = evaluate(OsMatchInput {
            p0f: Some(p0f_observation("Linux", None)),
            recog: vec![auxiliary(FingerprintSignal::RecogSsh, "linux")],
            ..Default::default()
        })
        .unwrap();

        assert_eq!(matched.agreement_count, 2);
        assert_eq!(
            matched.agreeing_signals[0].signal,
            FingerprintSignal::RecogSsh
        );
        assert_eq!(
            matched.confidence,
            P0F_BASE_CONFIDENCE * RECOG_AGREEMENT_MULTIPLIER
        );
    }

    #[test]
    fn uses_satori_tcp_as_primary_when_no_p0f_or_muonfp_match_exists() {
        let matched = evaluate(OsMatchInput {
            satori: vec![
                auxiliary(FingerprintSignal::SatoriTcp, "linux"),
                auxiliary(FingerprintSignal::SatoriDns, "linux"),
            ],
            ..Default::default()
        })
        .unwrap();

        assert_eq!(matched.os_family, "linux");
        assert_eq!(matched.name, "linux auxiliary match");
        assert_eq!(matched.agreement_count, 2);
        assert_eq!(
            matched.confidence,
            SATORI_TCP_BASE_CONFIDENCE * SATORI_AGREEMENT_MULTIPLIER
        );
    }

    #[test]
    fn preserves_disagreement_metadata() {
        let matched = evaluate(OsMatchInput {
            p0f: Some(p0f_observation("Linux", None)),
            muonfp: None,
            ja4: Some(auxiliary(FingerprintSignal::Ja4, "windows")),
            hassh: None,
            ..Default::default()
        })
        .unwrap();

        assert_eq!(matched.os_family, "linux");
        assert_eq!(matched.agreement_count, 1);
        assert_eq!(matched.confidence, P0F_BASE_CONFIDENCE);
        assert!(matched.agreeing_signals.is_empty());
        assert_eq!(matched.disagreements.len(), 1);
        assert_eq!(matched.disagreements[0].signal, FingerprintSignal::Ja4);
        assert_eq!(matched.disagreements[0].observed_family, "windows");
    }

    #[test]
    fn preserves_p0f_muonfp_disagreement_metadata() {
        let matched = evaluate(OsMatchInput {
            p0f: Some(p0f_observation("Linux", None)),
            muonfp: Some(muonfp_observation("windows")),
            ja4: None,
            hassh: None,
            ..Default::default()
        })
        .unwrap();

        assert_eq!(matched.os_family, "linux");
        assert_eq!(matched.agreement_count, 1);
        assert_eq!(matched.disagreements.len(), 1);
        assert_eq!(matched.disagreements[0].signal, FingerprintSignal::MuonFp);
        assert_eq!(matched.disagreements[0].observed_family, "windows");
    }

    #[test]
    fn weighted_majority_can_override_tcp_primary() {
        let matched = evaluate(OsMatchInput {
            p0f: Some(p0f_observation("Linux", None)),
            muonfp: Some(muonfp_observation("windows")),
            ja4: Some(auxiliary(FingerprintSignal::Ja4, "windows")),
            hassh: Some(auxiliary(FingerprintSignal::Hassh, "windows")),
            ..Default::default()
        })
        .unwrap();

        assert_eq!(matched.os_family, "windows");
        assert_eq!(matched.agreement_count, 3);
        assert_eq!(matched.disagreements.len(), 0);
        assert_eq!(matched.confidence, super::MAX_CONFIDENCE);
    }

    #[test]
    fn normalizes_common_p0f_families() {
        assert_eq!(
            evaluate(OsMatchInput {
                p0f: Some(p0f_observation("Mac OS X", Some("14.x"))),
                muonfp: None,
                ja4: Some(auxiliary(FingerprintSignal::Ja4, "macos")),
                hassh: None,
                ..Default::default()
            })
            .unwrap()
            .os_family,
            "macos"
        );

        assert_eq!(
            evaluate(OsMatchInput {
                p0f: Some(p0f_observation("Windows", Some("11"))),
                muonfp: None,
                ja4: Some(auxiliary(FingerprintSignal::Ja4, "windows")),
                hassh: None,
                ..Default::default()
            })
            .unwrap()
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
                FingerprintSignal::MuonFp => "64240:2-4:1460:",
                FingerprintSignal::Ja4 => "t13d1516h2_8daaf6152771_e5627efa2ab1",
                FingerprintSignal::Hassh => "06046964c022c6407d15a27b12a6a4fb",
                FingerprintSignal::RecogHttp => "recog:http",
                FingerprintSignal::RecogSsh => "recog:ssh",
                FingerprintSignal::RecogSmb => "recog:smb",
                FingerprintSignal::RecogFtp => "recog:ftp",
                FingerprintSignal::RecogSmtp => "recog:smtp",
                FingerprintSignal::RecogTelnet => "recog:telnet",
                FingerprintSignal::RecogSnmp => "recog:snmp",
                FingerprintSignal::RecogSip => "recog:sip",
                FingerprintSignal::RecogRdp => "recog:rdp",
                FingerprintSignal::RecogDns => "recog:dns",
                FingerprintSignal::RecogNtp => "recog:ntp",
                FingerprintSignal::SatoriTcp => "satori:tcp",
                FingerprintSignal::SatoriDhcp => "satori:dhcp",
                FingerprintSignal::SatoriHttp => "satori:http",
                FingerprintSignal::SatoriSsh => "satori:ssh",
                FingerprintSignal::SatoriSmb => "satori:smb",
                FingerprintSignal::SatoriSsl => "satori:ssl",
                FingerprintSignal::SatoriDns => "satori:dns",
                FingerprintSignal::SatoriIcmp => "satori:icmp",
                FingerprintSignal::SatoriNtp => "satori:ntp",
                FingerprintSignal::SatoriSip => "satori:sip",
            }
            .to_string(),
            os_family: os_family.to_string(),
            name: format!("{os_family} auxiliary match"),
            version_range: Some("test range".to_string()),
        }
    }

    fn muonfp_observation(os_family: &str) -> MuonFpObservation {
        MuonFpObservation {
            signature: "64240:2-4:1460:".to_string(),
            label: Some(format!("{os_family} synthetic rule")),
            os_family: os_family.to_string(),
            name: format!("MuonFP {os_family}"),
            version_range: Some("test range".to_string()),
        }
    }
}
