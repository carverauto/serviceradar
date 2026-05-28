use std::{
    collections::HashSet,
    env,
    fs::File,
    io::{BufWriter, Write},
    path::Path,
};

#[path = "src/p0f_corpus.rs"]
#[allow(dead_code)]
mod p0f_corpus;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=ebpf/Cargo.toml");
    println!("cargo:rerun-if-changed=ebpf/src/lib.rs");
    println!("cargo:rerun-if-changed=p0f-corpus/p0f.fp");
    println!("cargo:rerun-if-changed=p0f-corpus/serviceradar-additions.fp");
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

fn generate_p0f_tables(out_dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    let corpus_path = if Path::new("p0f-corpus/p0f.fp").exists() {
        "p0f-corpus/p0f.fp"
    } else {
        "rust/netprobe/p0f-corpus/p0f.fp"
    };
    let additions_path = if Path::new("p0f-corpus/serviceradar-additions.fp").exists() {
        "p0f-corpus/serviceradar-additions.fp"
    } else {
        "rust/netprobe/p0f-corpus/serviceradar-additions.fp"
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
        if let Some(key) = entry.signature.exact_lookup_key() {
            if seen.insert(key.clone()) {
                map.entry(key, &index.to_string());
            }
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
