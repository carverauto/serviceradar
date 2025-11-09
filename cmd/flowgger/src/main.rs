extern crate flowgger;

use clap::{Arg, Command};
use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat, RestartHandle};
use std::io::{stderr, Write};
use tempfile::NamedTempFile;
use toml::Value;

const DEFAULT_CONFIG_FILE: &str = "flowgger.toml";
const FLOWGGER_VERSION_STRING: &str = env!("CARGO_PKG_VERSION");

#[tokio::main]
async fn main() {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format(|buf, record| {
            writeln!(
                buf,
                "{} {} {}",
                buf.timestamp_seconds(),
                record.level(),
                record.args()
            )
        })
        .try_init();

    if let Err(err) = run().await {
        let _ = writeln!(stderr(), "flowgger bootstrap error: {err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let matches = Command::new("Flowgger")
        .version(FLOWGGER_VERSION_STRING)
        .about("A fast, simple and lightweight data collector")
        .arg(
            Arg::new("config_file")
                .help("Configuration file")
                .value_name("FILE")
                .index(1),
        )
        .get_matches();
    let config_file = matches
        .get_one::<String>("config_file")
        .map(|s| s.as_ref())
        .unwrap_or(DEFAULT_CONFIG_FILE);

    let use_kv = std::env::var("CONFIG_SOURCE").ok().as_deref() == Some("kv");
    let kv_key = use_kv.then(|| "config/flowgger.toml".to_string());
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "flowgger".to_string(),
        config_path: config_file.to_string(),
        format: ConfigFormat::Toml,
        kv_key,
        seed_kv: use_kv,
        watch_kv: use_kv,
    })
    .await?;

    let config_value: Value = bootstrap.load().await?;
    let runtime_config_path = if use_kv {
        Some(write_temp_config(&config_value)?)
    } else {
        None
    };

    if use_kv {
        if let Some(watcher) = bootstrap.watch::<Value>().await? {
            let restarter = RestartHandle::new("flowgger", "config/flowgger.toml");
            tokio::spawn(async move {
                let mut cfg_watcher = watcher;
                while cfg_watcher.recv().await.is_some() {
                    restarter.trigger();
                }
            });
        }
    }

    let _ = writeln!(stderr(), "Flowgger {FLOWGGER_VERSION_STRING}");
    let final_path = runtime_config_path.as_deref().unwrap_or(config_file);
    flowgger::start(final_path);
    Ok(())
}

fn write_temp_config(value: &Value) -> Result<String, Box<dyn std::error::Error>> {
    let serialized = toml::to_string(value)?;
    let mut tmp = NamedTempFile::new()?;
    tmp.write_all(serialized.as_bytes())?;
    let path = tmp.into_temp_path();
    let path_str = path.to_string_lossy().to_string();
    // Leak the file to keep it alive for the process lifetime
    path.persist(&path_str)?;
    Ok(path_str)
}
