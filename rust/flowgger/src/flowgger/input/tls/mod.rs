use crate::flowgger::config::Config;
use crate::flowgger::tls_utils::{load_certs, load_private_key, load_root_store, provider};
use rustls::ServerConfig;
use rustls::server::WebPkiClientVerifier;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub mod tls_input;
#[cfg(feature = "coroutines")]
pub mod tlsco_input;

pub use super::Input;

const DEFAULT_CERT: &str = "flowgger.pem";
const DEFAULT_FRAMING: &str = "line";
const DEFAULT_KEY: &str = "flowgger.pem";
const DEFAULT_LISTEN: &str = "0.0.0.0:6514";
#[cfg(feature = "coroutines")]
const DEFAULT_THREADS: usize = 1;
const DEFAULT_TIMEOUT: u64 = 3600;
const DEFAULT_VERIFY_PEER: bool = false;

#[derive(Clone)]
pub struct TlsConfig {
    pub(crate) framing: String,
    #[allow(dead_code)]
    pub(crate) threads: usize,
    pub(crate) server_config: Arc<ServerConfig>,
}

#[cfg(feature = "coroutines")]
fn get_default_threads(config: &Config) -> usize {
    config
        .lookup("input.tls_threads")
        .map_or(DEFAULT_THREADS, |x| {
            x.as_integer()
                .expect("input.tls_threads must be an unsigned integer") as usize
        })
}

#[cfg(not(feature = "coroutines"))]
fn get_default_threads(_config: &Config) -> usize {
    1
}

pub fn config_parse(config: &Config) -> (TlsConfig, String, u64) {
    let listen = config
        .lookup("input.listen")
        .map_or(DEFAULT_LISTEN, |x| {
            x.as_str().expect("input.listen must be an ip:port string")
        })
        .to_owned();
    let threads = get_default_threads(config);
    let cert = config
        .lookup("input.tls_cert")
        .map_or(DEFAULT_CERT, |x| {
            x.as_str()
                .expect("input.tls_cert must be a path to a .pem file")
        })
        .to_owned();
    let key = config
        .lookup("input.tls_key")
        .map_or(DEFAULT_KEY, |x| {
            x.as_str()
                .expect("input.tls_key must be a path to a .pem file")
        })
        .to_owned();
    let verify_peer = config
        .lookup("input.tls_verify_peer")
        .map_or(DEFAULT_VERIFY_PEER, |x| {
            x.as_bool()
                .expect("input.tls_verify_peer must be a boolean")
        });
    let ca_file: Option<PathBuf> = config.lookup("input.tls_ca_file").map(|x| {
        PathBuf::from(
            x.as_str()
                .expect("input.tls_ca_file must be a path to a file"),
        )
    });
    let timeout = config.lookup("input.timeout").map_or(DEFAULT_TIMEOUT, |x| {
        x.as_integer().expect("input.timeout must be an integer") as u64
    });
    let framing = if config
        .lookup("input.framed")
        .is_some_and(|x| x.as_bool().expect("input.framed must be a boolean"))
    {
        "syslen"
    } else {
        DEFAULT_FRAMING
    };
    let framing = config
        .lookup("input.framing")
        .map_or(framing, |x| {
            x.as_str()
                .expect(r#"input.framing must be a string set to "line", "nul" or "syslen""#)
        })
        .to_owned();

    let certs = load_certs(Path::new(&cert));
    let key = load_private_key(Path::new(&key));
    let provider = provider();
    let builder = ServerConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .expect("Failed to configure TLS protocol versions");
    let server_config = if verify_peer {
        let ca_file =
            ca_file.expect("input.tls_ca_file is required when input.tls_verify_peer is true");
        let roots = Arc::new(load_root_store(&ca_file));
        let verifier = WebPkiClientVerifier::builder_with_provider(roots, provider)
            .build()
            .expect("Unable to build the client certificate verifier");
        builder
            .with_client_cert_verifier(verifier)
            .with_single_cert(certs, key)
    } else {
        builder.with_no_client_auth().with_single_cert(certs, key)
    }
    .expect("Unable to configure the TLS certificate chain and key");

    let tls_config = TlsConfig {
        framing,
        threads,
        server_config: Arc::new(server_config),
    };
    (tls_config, listen, timeout)
}
