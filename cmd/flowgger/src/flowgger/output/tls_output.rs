use crate::flowgger::config::Config;
use crate::flowgger::merger::Merger;
use openssl::bn::BigNum;
use openssl::dh::Dh;
use openssl::ssl::*;
use rand;
use rand::prelude::SliceRandom;
use rand::Rng;
use time;

use super::Output;
use std::io;
use std::io::{stderr, BufWriter, ErrorKind, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const DEFAULT_CIPHERS: &str =
    "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:\
     ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:\
     ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-GCM-SHA384:\
     ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:\
     ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:\
     AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:ECDHE-ECDSA-DES-CBC3-SHA:\
     ECDHE-RSA-DES-CBC3-SHA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:\
     !EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA";
const DEFAULT_COMPRESSION: bool = false;
const DEFAULT_RECOVERY_DELAY_INIT: u32 = 1;
const DEFAULT_RECOVERY_DELAY_MAX: u32 = 10_000;
const DEFAULT_RECOVERY_PROBE_TIME: u32 = 30_000;
const DEFAULT_ASYNC: bool = false;
const DEFAULT_TIMEOUT: u64 = 3600;
const DEFAULT_VERIFY_PEER: bool = false;
const TLS_VERIFY_DEPTH: u32 = 6;
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
    connector: SslConnector,
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
        let sslclient = match self.tls_config.connector.connect(hostname, client) {
            Err(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "SSL handshake aborted by the server",
                ))
            }
            Ok(sslclient) => sslclient,
        };
        let _ = writeln!(stderr(), "Completed SSL handshake with {connect_chosen}");
        let mut writer = BufWriter::new(sslclient);
        let merger = &self.merger;
        loop {
            let mut bytes = match self.arx.lock().unwrap().recv() {
                Ok(line) => line,
                Err(_) => {
                    return Err(io::Error::other(
                        "Cannot read the message queue any more",
                    ))
                }
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
        let mut rng = rand::thread_rng();
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
                let mut rng = rand::thread_rng();
                recovery_delay += rng.gen_range(0.0..recovery_delay);
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

fn set_fs(ctx: &mut SslContextBuilder) {
    let p = BigNum::from_hex_str("87A8E61DB4B6663CFFBBD19C651959998CEEF608660DD0F25D2CEED4435E3B00E00DF8F1D61957D4FAF7DF4561B2AA3016C3D91134096FAA3BF4296D830E9A7C209E0C6497517ABD5A8A9D306BCF67ED91F9E6725B4758C022E0B1EF4275BF7B6C5BFC11D45F9088B941F54EB1E59BB8BC39A0BF12307F5C4FDB70C581B23F76B63ACAE1CAA6B7902D52526735488A0EF13C6D9A51BFA4AB3AD8347796524D8EF6A167B5A41825D967E144E5140564251CCACB83E6B486F6B3CA3F7971506026C0B857F689962856DED4010ABD0BE621C3A3960A54E710C375F26375D7014103A4B54330C198AF126116D2276E11715F693877FAD7EF09CADB094AE91E1A1597").unwrap();
    let g = BigNum::from_hex_str("3FB32C9B73134D0B2E77506660EDBD484CA7B18F21EF205407F4793A1A0BA12510DBC15077BE463FFF4FED4AAC0BB555BE3A6C1B0C6B47B1BC3773BF7E8C6F62901228F8C28CBB18A55AE31341000A650196F931C77A57F2DDF463E5E9EC144B777DE62AAAB8A8628AC376D282D6ED3864E67982428EBC831D14348F6F2F9193B5045AF2767164E1DFC967C1FB3F2E55A4BD1BFFE83B9C80D052B985D182EA0ADB2A3B7313D3FE14C8484B1E052588B9B7D2BBD2DF016199ECD06E1557CD0915B3353BBB64E0EC377FD028370DF92B52C7891428CDC67EB6184B523D1DB246C32F63078490F00EF8D647D148D47954515E2327CFEF98C582664B4C0F6CC41659").unwrap();
    let q =
        BigNum::from_hex_str("8CF83642A709A097B447997640129DA299B1A47D1EB3750BA308B0FE64F5FBD3")
            .unwrap();
    let dh = Dh::from_params(p, g, q).unwrap();
    ctx.set_tmp_dh(&dh).unwrap();
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
    let cert: Option<PathBuf> = config.lookup("output.tls_cert").map(|x| PathBuf::from(
            x.as_str()
                .expect("output.tls_cert must be a path to a .pem file"),
        ));
    let key: Option<PathBuf> = config.lookup("output.tls_key").map(|x| PathBuf::from(
            x.as_str()
                .expect("output.tls_key must be a path to a .pem file"),
        ));
    let ciphers = config
        .lookup("output.tls_ciphers")
        .map_or(DEFAULT_CIPHERS, |x| {
            x.as_str()
                .expect("output.tls_ciphers must be a string with a cipher suite")
        })
        .to_owned();
    let verify_peer = config
        .lookup("output.tls_verify_peer")
        .map_or(DEFAULT_VERIFY_PEER, |x| {
            x.as_bool()
                .expect("output.tls_verify_peer must be a boolean")
        });
    let ca_file: Option<PathBuf> = config.lookup("output.tls_ca_file").map(|x| PathBuf::from(
            x.as_str()
                .expect("output.tls_ca_file must be a path to a file"),
        ));
    let compression = config
        .lookup("output.tls_compression")
        .map_or(DEFAULT_COMPRESSION, |x| {
            x.as_bool()
                .expect("output.tls_compression must be a boolean")
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
    let mut connector_builder = SslConnector::builder(SslMethod::tls()).unwrap();
    {
        let ctx = &mut connector_builder;
        if !verify_peer {
            ctx.set_verify(SslVerifyMode::NONE);
        } else {
            ctx.set_verify_depth(TLS_VERIFY_DEPTH);
            ctx.set_verify(SslVerifyMode::PEER | SslVerifyMode::FAIL_IF_NO_PEER_CERT);
            if let Some(ca_file) = ca_file {
                ctx.set_ca_file(&ca_file)
                    .expect("Unable to read the trusted CA file");
            }
        }
        let mut opts = SslOptions::CIPHER_SERVER_PREFERENCE
            | SslOptions::NO_SESSION_RESUMPTION_ON_RENEGOTIATION;
        if !compression {
            opts |= SslOptions::NO_COMPRESSION;
        }
        ctx.set_options(opts);
        set_fs(ctx);
        if let Some(cert) = cert {
            ctx.set_certificate_file(Path::new(&cert), SslFiletype::PEM)
                .expect("Unable to read the TLS certificate");
        }
        if let Some(key) = key {
            ctx.set_private_key_file(Path::new(&key), SslFiletype::PEM)
                .expect("Unable to read the TLS key");
        }
        ctx.set_cipher_list(&ciphers)
            .expect("Unsupported cipher suite");
    }
    let connector = connector_builder.build();
    connect.shuffle(&mut rand::thread_rng());
    let cluster = Cluster { connect, idx: 0 };
    let mx_cluster = Arc::new(Mutex::new(cluster));
    let tls_config = TlsConfig {
        mx_cluster,
        timeout: Some(Duration::from_secs(timeout)),
        connector,
        async_,
        recovery_delay_init,
        recovery_delay_max,
        recovery_probe_time,
    };
    (tls_config, threads)
}
