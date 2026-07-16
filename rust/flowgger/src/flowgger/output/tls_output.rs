use crate::flowgger::config::Config;
use crate::flowgger::merger::Merger;
use crate::flowgger::tls_utils::{
    AcceptAnyServerCert, load_certs, load_private_key, load_root_store, provider,
};
use rand;
use rand::RngExt;
use rand::prelude::SliceRandom;
use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, StreamOwned};
use time;

use super::Output;
use std::convert::TryFrom;
use std::io;
use std::io::{BufWriter, ErrorKind, Write, stderr};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const DEFAULT_RECOVERY_DELAY_INIT: u32 = 1;
const DEFAULT_RECOVERY_DELAY_MAX: u32 = 10_000;
const DEFAULT_RECOVERY_PROBE_TIME: u32 = 30_000;
const DEFAULT_ASYNC: bool = false;
const DEFAULT_TIMEOUT: u64 = 3600;
const DEFAULT_VERIFY_PEER: bool = false;
const TLS_DEFAULT_THREADS: u32 = 1;

pub struct TlsOutput {
    config: TlsConfig,
    threads: u32,
}

struct Cluster {
    connect: Vec<String>,
    idx: usize,
}

#[derive(Clone)]
struct TlsConfig {
    #[allow(dead_code)]
    timeout: Option<Duration>,
    mx_cluster: Arc<Mutex<Cluster>>,
    client_config: Arc<ClientConfig>,
    async_: bool,
    recovery_delay_init: u32,
    recovery_delay_max: u32,
    recovery_probe_time: u32,
}

struct TlsWorker {
    arx: Arc<Mutex<Receiver<Vec<u8>>>>,
    merger: Option<Box<dyn Merger + Send>>,
    tls_config: TlsConfig,
}

impl TlsWorker {
    fn new(
        arx: Arc<Mutex<Receiver<Vec<u8>>>>,
        merger: Option<Box<dyn Merger + Send>>,
        tls_config: TlsConfig,
    ) -> TlsWorker {
        TlsWorker {
            arx,
            merger,
            tls_config,
        }
    }

    fn handle_connection(&self, connect_chosen: &str) -> io::Result<()> {
        let client = new_tcp(connect_chosen)?;
        let hostname = connect_chosen
            .split(':')
            .next()
            .unwrap_or_else(|| panic!("Invalid connection string: {}", connect_chosen));
        let _ = writeln!(stderr(), "Connected to {connect_chosen}");
        let server_name = ServerName::try_from(hostname.to_owned()).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("Invalid TLS server name: {hostname}"),
            )
        })?;
        let conn = ClientConnection::new(self.tls_config.client_config.clone(), server_name)
            .map_err(|e| io::Error::new(io::ErrorKind::ConnectionAborted, e.to_string()))?;
        let mut sslclient = StreamOwned::new(conn, client);
        // Drive the TLS handshake eagerly, matching the old `connector.connect()`
        // semantics: a handshake failure must surface HERE, before the loop below pulls
        // a message off the channel — otherwise that dequeued message is lost when the
        // (lazy) handshake fails on first write.
        if let Err(e) = sslclient.conn.complete_io(&mut sslclient.sock) {
            return Err(io::Error::new(io::ErrorKind::ConnectionAborted, e));
        }
        let _ = writeln!(stderr(), "Completed SSL handshake with {connect_chosen}");
        let mut writer = BufWriter::new(sslclient);
        let merger = &self.merger;
        loop {
            let mut bytes = match self.arx.lock().unwrap().recv() {
                Ok(line) => line,
                Err(_) => return Err(io::Error::other("Cannot read the message queue any more")),
            };
            if let Some(ref merger) = *merger {
                merger.frame(&mut bytes);
            }
            match writer.write_all(&bytes) {
                Ok(_) => {}
                Err(e) => match e.kind() {
                    ErrorKind::Interrupted => continue,
                    _ => return Err(e),
                },
            };
            if !self.tls_config.async_ {
                writer.flush()?;
            }
        }
    }

    fn run(self) {
        let tls_config = &self.tls_config;
        let mut rng = rand::rng();
        let mut recovery_delay = f64::from(tls_config.recovery_delay_init);
        let mut last_recovery;
        loop {
            last_recovery = time::OffsetDateTime::now_utc();
            let connect_chosen = {
                let mut cluster = tls_config.mx_cluster.lock().unwrap();
                cluster.idx += 1;
                if cluster.idx >= cluster.connect.len() {
                    cluster.connect.shuffle(&mut rng);
                    cluster.idx = 0;
                }
                cluster.connect[cluster.idx].clone()
            };
            if let Err(e) = self.handle_connection(&connect_chosen) {
                match e.kind() {
                    ErrorKind::ConnectionRefused => {
                        let _ = writeln!(stderr(), "Connection to {connect_chosen} refused");
                    }
                    ErrorKind::ConnectionAborted | ErrorKind::ConnectionReset => {
                        let _ = writeln!(
                            stderr(),
                            "Connection to {connect_chosen} aborted by the server"
                        );
                    }
                    _ => {
                        let _ = writeln!(
                            stderr(),
                            "Error while communicating with {connect_chosen} - {e}"
                        );
                    }
                }
            }
            let now = time::OffsetDateTime::now_utc();
            if now - last_recovery
                > time::Duration::milliseconds(i64::from(tls_config.recovery_probe_time))
            {
                recovery_delay = f64::from(tls_config.recovery_delay_init);
            } else if recovery_delay < f64::from(tls_config.recovery_delay_max) {
                let mut rng = rand::rng();
                recovery_delay += rng.random_range(0.0..recovery_delay);
            }
            thread::sleep(Duration::from_millis(recovery_delay.round() as u64));
            let _ = writeln!(stderr(), "Attempting to reconnect");
        }
    }
}

fn new_tcp(connect_chosen: &str) -> Result<TcpStream, io::Error> {
    TcpStream::connect(connect_chosen)
}

impl TlsOutput {
    pub fn new(config: &Config) -> TlsOutput {
        let (tls_config, threads) = config_parse(config);
        TlsOutput {
            config: tls_config,
            threads,
        }
    }
}

impl Output for TlsOutput {
    fn start(&self, arx: Arc<Mutex<Receiver<Vec<u8>>>>, merger: Option<Box<dyn Merger>>) {
        for _ in 0..self.threads {
            let arx = Arc::clone(&arx);
            let config = self.config.clone();
            let merger = match merger {
                Some(ref merger) => Some(merger.clone_boxed()) as Option<Box<dyn Merger + Send>>,
                None => None,
            };
            thread::spawn(move || {
                let worker = TlsWorker::new(arx, merger, config);
                worker.run();
            });
        }
    }
}

fn config_parse(config: &Config) -> (TlsConfig, u32) {
    let threads = config
        .lookup("output.tls_threads")
        .map_or(TLS_DEFAULT_THREADS, |x| {
            x.as_integer()
                .expect("output.tls_threads must be a 32-bit integer") as u32
        });
    let connect = config
        .lookup("output.connect")
        .expect("output.connect is required")
        .as_array()
        .expect("output.connect must be a list");
    let mut connect: Vec<String> = connect
        .iter()
        .map(|x| {
            x.as_str()
                .expect("output.connect must be a list of strings")
                .to_owned()
        })
        .collect();
    let cert: Option<PathBuf> = config.lookup("output.tls_cert").map(|x| {
        PathBuf::from(
            x.as_str()
                .expect("output.tls_cert must be a path to a .pem file"),
        )
    });
    let key: Option<PathBuf> = config.lookup("output.tls_key").map(|x| {
        PathBuf::from(
            x.as_str()
                .expect("output.tls_key must be a path to a .pem file"),
        )
    });
    let verify_peer = config
        .lookup("output.tls_verify_peer")
        .map_or(DEFAULT_VERIFY_PEER, |x| {
            x.as_bool()
                .expect("output.tls_verify_peer must be a boolean")
        });
    let ca_file: Option<PathBuf> = config.lookup("output.tls_ca_file").map(|x| {
        PathBuf::from(
            x.as_str()
                .expect("output.tls_ca_file must be a path to a file"),
        )
    });
    let timeout = config
        .lookup("output.timeout")
        .map_or(DEFAULT_TIMEOUT, |x| {
            x.as_integer().expect("output.timeout must be an integer") as u64
        });
    let async_ = config
        .lookup("output.tls_async")
        .map_or(DEFAULT_ASYNC, |x| {
            x.as_bool().expect("output.tls_async must be a boolean")
        });
    let recovery_delay_init =
        config
            .lookup("output.tls_recovery_delay_init")
            .map_or(DEFAULT_RECOVERY_DELAY_INIT, |x| {
                x.as_integer()
                    .expect("output.tls_recovery_delay_init must be an integer")
                    as u32
            });
    let recovery_delay_max =
        config
            .lookup("output.tls_recovery_delay_max")
            .map_or(DEFAULT_RECOVERY_DELAY_MAX, |x| {
                x.as_integer()
                    .expect("output.tls_recovery_delay_max must be an integer")
                    as u32
            });
    let recovery_probe_time =
        config
            .lookup("output.tls_recovery_probe_time")
            .map_or(DEFAULT_RECOVERY_PROBE_TIME, |x| {
                x.as_integer()
                    .expect("output.tls_recovery_probe_time must be an integer")
                    as u32
            });
    if recovery_delay_max < recovery_delay_init {
        panic!("output.tls_recovery_delay_max cannot be less than output.tls_recovery_delay_init");
    }
    let crypto = provider();
    let builder = ClientConfig::builder_with_provider(crypto.clone())
        .with_safe_default_protocol_versions()
        .expect("Failed to configure TLS protocol versions");
    // verify_peer=false preserves the former SslVerifyMode::NONE (accept any server
    // certificate); when enabled, a CA bundle is required to verify the peer.
    let builder = if verify_peer {
        let ca_file =
            ca_file.expect("output.tls_ca_file is required when output.tls_verify_peer is true");
        builder.with_root_certificates(load_root_store(&ca_file))
    } else {
        builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(AcceptAnyServerCert::new(crypto)))
    };
    // Optional client certificate for mutual TLS.
    let client_config = match (cert, key) {
        (Some(cert), Some(key)) => builder
            .with_client_auth_cert(
                load_certs(Path::new(&cert)),
                load_private_key(Path::new(&key)),
            )
            .expect("Unable to configure the client TLS certificate and key"),
        _ => builder.with_no_client_auth(),
    };
    connect.shuffle(&mut rand::rng());
    let cluster = Cluster { connect, idx: 0 };
    let mx_cluster = Arc::new(Mutex::new(cluster));
    let tls_config = TlsConfig {
        mx_cluster,
        timeout: Some(Duration::from_secs(timeout)),
        client_config: Arc::new(client_config),
        async_,
        recovery_delay_init,
        recovery_delay_max,
        recovery_probe_time,
    };
    (tls_config, threads)
}
