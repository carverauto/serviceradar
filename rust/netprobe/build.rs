use std::{
    collections::HashSet,
    env,
    fs::{self, File},
    io::{BufWriter, Write},
    path::{Path, PathBuf},
};

use quick_xml::{events::Event, reader::Reader};

#[path = "src/p0f_corpus.rs"]
#[allow(dead_code)]
mod p0f_corpus;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=ebpf/Cargo.toml");
    println!("cargo:rerun-if-changed=ebpf/src/lib.rs");
    println!("cargo:rerun-if-changed=../../third_party/netprobe_corpora/p0f/p0f.fp");
    println!(
        "cargo:rerun-if-changed=../../third_party/netprobe_corpora/p0f/serviceradar-additions.fp"
    );
    println!("cargo:rerun-if-changed=../../third_party/netprobe_corpora/recog/xml");
    println!(
        "cargo:rerun-if-changed=../../third_party/netprobe_corpora/recog/serviceradar-recog-additions.xml"
    );
    println!("cargo:rerun-if-changed=src/p0f_corpus.rs");
    println!("cargo:rerun-if-env-changed=SERVICERADAR_NETPROBE_BUILD_EBPF");

    let proto_path = if Path::new("proto/agent/netprobe/v1/netprobe.proto").exists() {
        "proto/agent/netprobe/v1/netprobe.proto"
    } else {
        "../../proto/agent/netprobe/v1/netprobe.proto"
    };

    println!("cargo:rerun-if-changed={proto_path}");

    let out_dir = env::var("OUT_DIR")?;
    prost_build::Config::new()
        .out_dir(&out_dir)
        .compile_protos(&[proto_path], &[".", "proto", "../../proto"])?;

    generate_p0f_tables(&out_dir)?;
    generate_recog_tables(&out_dir)?;

    if env::var_os("SERVICERADAR_NETPROBE_BUILD_EBPF").is_some() {
        aya_build::build_ebpf(
            [aya_build::Package {
                name: "serviceradar-netprobe-ebpf",
                root_dir: "ebpf",
                no_default_features: false,
                features: &[],
            }],
            aya_build::Toolchain::Nightly,
        )?;
    }

    Ok(())
}

#[derive(Debug)]
struct RecogFingerprint {
    service: &'static str,
    source: String,
    pattern: String,
    params: Vec<RecogParam>,
}

#[derive(Debug)]
struct RecogParam {
    name: String,
    value: Option<String>,
    pos: usize,
}

fn generate_recog_tables(out_dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    // Cargo path first (cwd = this crate dir), Bazel path second (cwd = execroot).
    let recog_root = if Path::new("../../third_party/netprobe_corpora/recog").exists() {
        PathBuf::from("../../third_party/netprobe_corpora/recog")
    } else {
        PathBuf::from("third_party/netprobe_corpora/recog")
    };
    let xml_dir = recog_root.join("xml");
    let mut paths = fs::read_dir(&xml_dir)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<Vec<_>, _>>()?;
    paths.sort();

    let mut fingerprints = Vec::new();
    for path in paths {
        if path.extension().and_then(|ext| ext.to_str()) != Some("xml") {
            continue;
        }
        if let Some(service) = recog_service_for_file(&path) {
            parse_recog_file(&path, Some(service), &mut fingerprints)?;
        }
    }

    let additions_path = recog_root.join("serviceradar-recog-additions.xml");
    if additions_path.exists() {
        parse_recog_file(&additions_path, None, &mut fingerprints)?;
    }

    let output_path = Path::new(out_dir).join("recog_generated.rs");
    let mut output = BufWriter::new(File::create(output_path)?);

    writeln!(
        output,
        "static RECOG_FINGERPRINTS: &[RecogFingerprintDef] = &["
    )?;
    for fingerprint in fingerprints {
        writeln!(output, "    RecogFingerprintDef {{")?;
        writeln!(
            output,
            "        service: RecogService::{},",
            fingerprint.service
        )?;
        writeln!(output, "        source: {:?},", fingerprint.source)?;
        writeln!(output, "        pattern: {:?},", fingerprint.pattern)?;
        writeln!(output, "        params: &[")?;
        for param in fingerprint.params {
            writeln!(output, "            RecogParamDef {{")?;
            writeln!(output, "                name: {:?},", param.name)?;
            match param.value {
                Some(value) => writeln!(output, "                value: Some({value:?}),")?,
                None => writeln!(output, "                value: None,")?,
            }
            writeln!(output, "                pos: {},", param.pos)?;
            writeln!(output, "            }},")?;
        }
        writeln!(output, "        ],")?;
        writeln!(output, "    }},")?;
    }
    writeln!(output, "];")?;

    Ok(())
}

fn recog_service_for_file(path: &Path) -> Option<&'static str> {
    match path.file_name()?.to_str()? {
        "http_servers.xml" => Some("HttpServer"),
        "ssh_banners.xml" => Some("SshBanner"),
        "smb_native_lm.xml" | "smb_native_os.xml" => Some("SmbVersion"),
        "ftp_banners.xml" => Some("FtpBanner"),
        "smtp_banners.xml" => Some("SmtpBanner"),
        "telnet_banners.xml" => Some("TelnetBanner"),
        "snmp_sysdescr.xml" => Some("SnmpBanner"),
        "sip_banners.xml" | "sip_user_agents.xml" => Some("SipBanner"),
        "dns_versionbind.xml" => Some("DnsVersion"),
        "ntp_banners.xml" => Some("NtpReadvar"),
        // A file with no mapping is SILENTLY DROPPED -- it ships in the corpus, passes
        // SHA256SUMS, and contributes zero fingerprints. ntp_banners.xml sat here unmapped
        // with 75 fingerprints (44 emitting service.product="NTP"), which is why the
        // banner-grab integration test could never produce an ntp match. Adding a corpus file
        // means adding it here AND to recog_service() in src/ipc/match_banner.rs; neither
        // half fails loudly on its own.
        _ => None,
    }
}

fn parse_recog_file(
    path: &Path,
    default_service: Option<&'static str>,
    fingerprints: &mut Vec<RecogFingerprint>,
) -> Result<(), Box<dyn std::error::Error>> {
    let source = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or("invalid Recog XML file name")?
        .to_owned();
    let xml = fs::read_to_string(path)?;
    let mut reader = Reader::from_str(&xml);
    reader.config_mut().trim_text(true);
    let mut current: Option<RecogFingerprint> = None;

    loop {
        match reader.read_event()? {
            Event::Start(element) if element.name().as_ref() == b"fingerprint" => {
                let mut pattern = None;
                let mut flags = None;
                let mut service = default_service;
                for attr in element.attributes() {
                    let attr = attr?;
                    if attr.key.as_ref() == b"pattern" {
                        pattern = Some(
                            attr.decoded_and_normalized_value(
                                quick_xml::XmlVersion::Implicit1_0,
                                reader.decoder(),
                            )?
                            .into_owned(),
                        );
                    } else if attr.key.as_ref() == b"flags" {
                        flags = Some(
                            attr.decoded_and_normalized_value(
                                quick_xml::XmlVersion::Implicit1_0,
                                reader.decoder(),
                            )?
                            .into_owned(),
                        );
                    } else if attr.key.as_ref() == b"service" {
                        let value = attr.decoded_and_normalized_value(
                            quick_xml::XmlVersion::Implicit1_0,
                            reader.decoder(),
                        )?;
                        service = Some(recog_service_for_addition(&value).ok_or_else(|| {
                            format!(
                                "unknown Recog additions service {value:?} in {}",
                                path.display()
                            )
                        })?);
                    }
                }
                let pattern = pattern.ok_or("Recog fingerprint missing pattern attribute")?;
                let service = service.ok_or_else(|| {
                    format!(
                        "Recog additions fingerprint in {} is missing a service attribute",
                        path.display()
                    )
                })?;
                current = Some(RecogFingerprint {
                    service,
                    source: source.clone(),
                    pattern: apply_recog_flags(pattern, flags.as_deref()),
                    params: Vec::new(),
                });
            }
            Event::Empty(element) if element.name().as_ref() == b"param" => {
                if let Some(fingerprint) = &mut current {
                    fingerprint
                        .params
                        .push(parse_recog_param(&reader, &element)?);
                }
            }
            Event::End(element) if element.name().as_ref() == b"fingerprint" => {
                if let Some(fingerprint) = current.take() {
                    fingerprints.push(fingerprint);
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }

    Ok(())
}

fn recog_service_for_addition(name: &str) -> Option<&'static str> {
    match name {
        "http" | "http_server" | "http_servers" => Some("HttpServer"),
        "ssh" | "ssh_banner" | "ssh_banners" => Some("SshBanner"),
        "smb" | "smb_version" | "smb_native_lm" | "smb_native_os" => Some("SmbVersion"),
        "ftp" | "ftp_banner" | "ftp_banners" => Some("FtpBanner"),
        "smtp" | "smtp_banner" | "smtp_banners" => Some("SmtpBanner"),
        "telnet" | "telnet_banner" | "telnet_banners" => Some("TelnetBanner"),
        "snmp" | "snmp_banner" | "snmp_sysdescr" => Some("SnmpBanner"),
        "sip" | "sip_banner" | "sip_banners" | "sip_user_agent" | "sip_user_agents" => {
            Some("SipBanner")
        }
        "rdp" | "rdp_banner" | "rdp_banners" => Some("RdpBanner"),
        "dns" | "dns_version" | "dns_versionbind" => Some("DnsVersion"),
        _ => None,
    }
}

fn apply_recog_flags(pattern: String, flags: Option<&str>) -> String {
    let Some(flags) = flags else {
        return pattern;
    };

    let mut inline_flags = String::new();
    if flags.contains("REG_ICASE") && !pattern.starts_with("(?i)") {
        inline_flags.push('i');
    }
    if flags.contains("REG_MULTILINE") && !pattern.starts_with("(?m)") {
        inline_flags.push('m');
    }

    if inline_flags.is_empty() {
        pattern
    } else {
        format!("(?{inline_flags}){pattern}")
    }
}

fn parse_recog_param(
    reader: &Reader<&[u8]>,
    element: &quick_xml::events::BytesStart<'_>,
) -> Result<RecogParam, Box<dyn std::error::Error>> {
    let mut name = None;
    let mut value = None;
    let mut pos = 0;

    for attr in element.attributes() {
        let attr = attr?;
        let attr_value = attr
            .decoded_and_normalized_value(quick_xml::XmlVersion::Implicit1_0, reader.decoder())?
            .into_owned();
        match attr.key.as_ref() {
            b"name" => name = Some(attr_value),
            b"value" => value = Some(attr_value),
            b"pos" => pos = attr_value.parse()?,
            _ => {}
        }
    }

    Ok(RecogParam {
        name: name.ok_or("Recog param missing name attribute")?,
        value,
        pos,
    })
}

fn generate_p0f_tables(out_dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    // The corpus lives in //third_party/netprobe_corpora/p0f. First branch is the
    // cargo path (cwd = this crate dir), second the Bazel one (cwd = execroot).
    let corpus_path = if Path::new("../../third_party/netprobe_corpora/p0f/p0f.fp").exists() {
        "../../third_party/netprobe_corpora/p0f/p0f.fp"
    } else {
        "third_party/netprobe_corpora/p0f/p0f.fp"
    };
    let additions_path =
        if Path::new("../../third_party/netprobe_corpora/p0f/serviceradar-additions.fp").exists() {
            "../../third_party/netprobe_corpora/p0f/serviceradar-additions.fp"
        } else {
            "third_party/netprobe_corpora/p0f/serviceradar-additions.fp"
        };
    let mut corpus = std::fs::read_to_string(corpus_path)?;
    let additions = std::fs::read_to_string(additions_path)?;
    p0f_corpus::parse(&additions)?;
    corpus.push('\n');
    corpus.push_str(&additions);
    let corpus = p0f_corpus::parse(&corpus)?;
    let output_path = Path::new(out_dir).join("p0f_generated.rs");
    let mut output = BufWriter::new(File::create(output_path)?);

    writeln!(
        output,
        "pub(super) static P0F_EXACT_SIGNATURES: phf::Map<&'static str, usize> = "
    )?;
    let mut map = phf_codegen::Map::new();
    let mut seen = HashSet::new();
    let mut fallback_indices = Vec::new();

    for (index, entry) in corpus.tcp_signatures.iter().enumerate() {
        if let Some(key) = entry.signature.exact_lookup_key()
            && seen.insert(key.clone())
        {
            map.entry(key, &index.to_string());
        }
        if entry.signature.requires_fallback_match() {
            fallback_indices.push(index);
        }
    }

    writeln!(output, "{};", map.build())?;
    writeln!(
        output,
        "pub(super) static P0F_FALLBACK_INDICES: &[usize] = &["
    )?;
    for index in fallback_indices {
        writeln!(output, "    {index},")?;
    }
    writeln!(output, "];")?;

    Ok(())
}
