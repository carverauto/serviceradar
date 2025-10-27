extern crate flowgger;

use clap::{Arg, Command};
use kvutil::KvClient;
use std::io::{stderr, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tempfile::NamedTempFile;

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
    // If CONFIG_SOURCE=kv, try to fetch config/flowgger.toml from KV first
    if std::env::var("CONFIG_SOURCE").ok().as_deref() == Some("kv") {
        if let Ok(Some(temp_path)) = try_create_config_from_kv().await {
            let _ = writeln!(stderr(), "Flowgger {FLOWGGER_VERSION_STRING}");
            return flowgger::start(&temp_path);
        }
        // Bootstrap: put file-based config into KV if missing
        let _ = bootstrap_flowgger_to_kv_if_missing(DEFAULT_CONFIG_FILE).await;
        // Watch for updates and trigger a self-restart to apply changes
        if let Ok(mut kv) = KvClient::connect_from_env().await {
            let restarting = Arc::new(AtomicBool::new(false));
            let _ = kv
                .watch_apply("config/flowgger.toml", {
                    let restarting = restarting.clone();
                    move |_| {
                        if restarting
                            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                            .is_ok()
                        {
                            // Debounce briefly, then spawn a new process with same args and exit
                            tokio::spawn(async move {
                                let _ = writeln!(
                                    stderr(),
                                    "KV updated: config/flowgger.toml; restarting to apply changes"
                                );
                                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                                if let Ok(exe) = std::env::current_exe() {
                                    let args: Vec<std::ffi::OsString> =
                                        std::env::args_os().skip(1).collect();
                                    let mut cmd = std::process::Command::new(exe);
                                    cmd.args(args);
                                    let _ = cmd.spawn(); // fire-and-forget
                                }
                                std::process::exit(0);
                            });
                        }
                    }
                })
                .await;
        }
    }

    let config_file = matches
        .get_one::<String>("config_file")
        .map(|s| s.as_ref())
        .unwrap_or(DEFAULT_CONFIG_FILE);
    let _ = writeln!(stderr(), "Flowgger {FLOWGGER_VERSION_STRING}");
    flowgger::start(config_file)
}

async fn try_create_config_from_kv() -> Result<Option<String>, Box<dyn std::error::Error>> {
    let mut kv = KvClient::connect_from_env().await?;
    let content = if let Some(bytes) = kv.get("config/flowgger.toml").await? {
        String::from_utf8(bytes)?
    } else {
        return Ok(None);
    };
    let mut tmp = NamedTempFile::new()?;
    tmp.write_all(content.as_bytes())?;
    let path = tmp.into_temp_path();
    let path_str = path.to_string_lossy().to_string();
    // Leak the file to keep it alive for the process lifetime
    path.persist(&path_str)?;
    Ok(Some(path_str))
}

async fn bootstrap_flowgger_to_kv_if_missing(path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let mut kv = KvClient::connect_from_env().await?;
    if kv.get("config/flowgger.toml").await?.is_none() {
        let content = std::fs::read_to_string(path).unwrap_or_default();
        let _ = kv
            .put_if_absent("config/flowgger.toml", content.into_bytes())
            .await;
    }
    Ok(())
}
