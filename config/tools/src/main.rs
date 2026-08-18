//! Extracts one section of a compiled environment instance into its own binary message.
//!
//! Exists for Decision 6, least privilege: a target declares the section it needs, so a
//! database test's runfiles PHYSICALLY DO NOT CONTAIN the NATS configuration. That is enforced
//! by the sandbox rather than by discipline, and it is visible at the target definition instead
//! of inferred from a global union of forwarded environment variables.
//!
//! A tool rather than a protoc invocation because text format cannot be sliced: the section
//! boundary is structure, and recovering it from the source text would be a parser pretending
//! to be a grep.

use prost::Message;
use serviceradar_config_schema::EnvironmentConfig;

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let [_, section, input, output] = args.as_slice() else {
        eprintln!("usage: extract_section <database|nats|core|dgraph> <input.binpb> <output.binpb>");
        return std::process::ExitCode::FAILURE;
    };

    let bytes = match std::fs::read(input) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("read {input}: {e}");
            return std::process::ExitCode::FAILURE;
        }
    };

    let cfg = match EnvironmentConfig::decode(&*bytes) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("decode {input}: {e}");
            return std::process::ExitCode::FAILURE;
        }
    };

    // An absent section is an error, not an empty file. A component that declared a section
    // needs it; handing back zero bytes would decode to a message whose every field is absent,
    // which validation would then report as a dozen missing values rather than as the one
    // thing that is actually wrong.
    let encoded = match section.as_str() {
        "database" => cfg.database.map(|s| s.encode_to_vec()),
        "nats" => cfg.nats.map(|s| s.encode_to_vec()),
        "core" => cfg.core.map(|s| s.encode_to_vec()),
        "dgraph" => cfg.dgraph.map(|s| s.encode_to_vec()),
        other => {
            eprintln!("unknown section {other:?}");
            return std::process::ExitCode::FAILURE;
        }
    };

    let Some(encoded) = encoded else {
        eprintln!("{input} sets no {section} section");
        return std::process::ExitCode::FAILURE;
    };

    if let Err(e) = std::fs::write(output, encoded) {
        eprintln!("write {output}: {e}");
        return std::process::ExitCode::FAILURE;
    }
    std::process::ExitCode::SUCCESS
}
