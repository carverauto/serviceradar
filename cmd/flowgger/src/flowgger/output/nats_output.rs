//! A Flowgger output that publishes every log record to a NATS JetStream subject.
//! Enable with `--features nats-output`.

#[cfg(all(feature = "nats-output", feature = "gelf"))]
use serde_json::Value;
#[cfg(feature = "nats-output")]
use {
    super::Output,
    crate::flowgger::{config::Config, merger::Merger},
    async_nats::jetstream::{context::PublishAckFuture, stream::StorageType},
    async_nats::{jetstream, Client, ConnectOptions},
    std::{
        cmp::min,
        path::PathBuf,
        sync::{mpsc::Receiver, Arc, Mutex},
        thread,
        time::Duration,
    },
    tokio::{
        runtime::Builder as RtBuilder,
        time::{sleep, timeout},
    },
};

#[cfg(feature = "nats-output")]
pub struct NATSOutput {
    cfg: NATSConfig,
    workers: u32,
}

#[cfg(feature = "nats-output")]
#[derive(Clone)]
struct NATSConfig {
    url: String,
    subject: String,
    stream: String,
    partition: String,
    timeout: Duration,
    tls_cert: Option<PathBuf>,
    tls_key: Option<PathBuf>,
    tls_ca: Option<PathBuf>,
    connect_attempts: u32,
    connect_initial_backoff: Duration,
    connect_max_backoff: Duration,
}

#[cfg(feature = "nats-output")]
impl NATSOutput {
    pub fn new(cfg: &Config) -> Self {
        // ---- mandatory ----
        let url = cfg
            .lookup("output.nats_url")
            .expect("output.nats_url is required")
            .as_str()
            .unwrap()
            .to_owned();
        let subject = cfg
            .lookup("output.nats_subject")
            .unwrap_or_else(|| panic!("output.nats_subject is required"))
            .as_str()
            .unwrap()
            .to_owned();

        // ---- optional w/ sane defaults ----
        let stream = cfg
            .lookup("output.nats_stream")
            .map_or("events".into(), |v| v.as_str().unwrap().to_owned());
        let partition = cfg
            .lookup("output.partition")
            .map_or("default".into(), |v| v.as_str().unwrap().to_owned());
        let timeout = Duration::from_millis(
            cfg.lookup("output.nats_timeout")
                .map_or(30_000, |v| v.as_integer().unwrap() as u64),
        );

        let tls_cert = cfg
            .lookup("output.nats_tls_cert")
            .and_then(|v| Some(PathBuf::from(v.as_str().unwrap())));
        let tls_key = cfg
            .lookup("output.nats_tls_key")
            .and_then(|v| Some(PathBuf::from(v.as_str().unwrap())));
        let tls_ca = cfg
            .lookup("output.nats_tls_ca_file")
            .and_then(|v| Some(PathBuf::from(v.as_str().unwrap())));

        let workers = cfg
            .lookup("output.nats_threads")
            .map_or(1, |v| v.as_integer().unwrap() as u32);
        let connect_attempts = cfg
            .lookup("output.nats_connect_attempts")
            .map_or(0, |v| v.as_integer().unwrap() as u32);
        let mut connect_initial_backoff = Duration::from_millis(
            cfg.lookup("output.nats_connect_initial_backoff_ms")
                .map_or(500, |v| v.as_integer().unwrap() as u64),
        );
        let mut connect_max_backoff = Duration::from_millis(
            cfg.lookup("output.nats_connect_max_backoff_ms")
                .map_or(30_000, |v| v.as_integer().unwrap() as u64),
        );
        if connect_initial_backoff.is_zero() {
            connect_initial_backoff = Duration::from_millis(1);
        }
        if connect_max_backoff.is_zero() {
            connect_max_backoff = connect_initial_backoff;
        }

        Self {
            cfg: NATSConfig {
                url,
                subject,
                stream,
                partition,
                timeout,
                tls_cert,
                tls_key,
                tls_ca,
                connect_attempts,
                connect_initial_backoff,
                connect_max_backoff,
            },
            workers,
        }
    }
}

#[cfg(feature = "nats-output")]
struct NATSWorker {
    arx: Arc<Mutex<Receiver<Vec<u8>>>>,
    cfg: NATSConfig,
    merger: Option<Box<dyn Merger + Send>>,
}

#[cfg(feature = "nats-output")]
impl NATSWorker {
    async fn connect_once(&self) -> Result<(Client, jetstream::Context), async_nats::Error> {
        // Start with default connect options.
        let mut options = ConnectOptions::new();

        // Apply CA file if provided, to verify the server's certificate.
        if let Some(ca_file) = &self.cfg.tls_ca {
            options = options.add_root_certificates(ca_file.clone());
        }

        // Apply client certificate and key for mTLS client authentication.
        if let (Some(cert_file), Some(key_file)) = (&self.cfg.tls_cert, &self.cfg.tls_key) {
            options = options.add_client_certificate(cert_file.clone(), key_file.clone());
        }

        // Connect to the server using the constructed options.
        let client = options.connect(&self.cfg.url).await?;
        let js = jetstream::new(client.clone());

        // Ensure the target stream exists.
        let stream_config = jetstream::stream::Config {
            name: self.cfg.stream.clone(),
            subjects: vec![self.cfg.subject.clone()],
            storage: StorageType::File,
            ..Default::default()
        };
        let _ = js.get_or_create_stream(stream_config).await?;

        Ok((client, js))
    }

    async fn connect_with_retry(&self) -> Result<(Client, jetstream::Context), async_nats::Error> {
        let mut attempt: u32 = 0;
        let mut backoff = min(
            self.cfg.connect_initial_backoff,
            self.cfg.connect_max_backoff,
        );

        loop {
            attempt += 1;
            match self.connect_once().await {
                Ok(conn) => return Ok(conn),
                Err(err) => {
                    let limit = self.cfg.connect_attempts;

                    if limit != 0 && attempt >= limit {
                        eprintln!(
                            "NATS connection attempt {attempt} failed: {err}. Giving up after {limit} attempts."
                        );
                        return Err(err);
                    }

                    eprintln!(
                        "NATS connection attempt {attempt} failed: {err}. Retrying in {:?}...",
                        backoff
                    );
                    sleep(backoff).await;

                    let doubled = backoff
                        .checked_mul(2)
                        .unwrap_or(self.cfg.connect_max_backoff);
                    backoff = min(doubled, self.cfg.connect_max_backoff);
                }
            }
        }
    }

    async fn run(self) {
        let (_, js) = match self.connect_with_retry().await {
            Ok(conn) => conn,
            Err(err) => {
                if self.cfg.connect_attempts == 0 {
                    eprintln!("NATS connection failed after unlimited retries: {err}");
                } else {
                    eprintln!(
                        "NATS connection failed after {} attempts: {err}",
                        self.cfg.connect_attempts
                    );
                }
                std::process::exit(1);
            }
        };

        loop {
            // Pull a record from Flowgger’s queue synchronously.
            let mut bytes = match { self.arx.lock().unwrap().recv() } {
                Ok(b) => b,
                Err(_) => return, // channel closed – shut the worker down
            };

            #[cfg(feature = "gelf")]
            {
                if let Ok(mut v) = serde_json::from_slice::<Value>(&bytes) {
                    if let Some(obj) = v.as_object_mut() {
                        if let Some(addr_val) = obj.get_mut("_remote_addr") {
                            if let Some(s) = addr_val.as_str() {
                                *addr_val = Value::String(format!("{}:{}", self.cfg.partition, s));
                            }
                        }
                        bytes = serde_json::to_vec(&v).unwrap_or(bytes);
                    }
                }
            }

            if let Some(m) = &self.merger {
                m.frame(&mut bytes);
            }

            // Fire-and-wait-for-ack with timeout so we can log failures.
            let ack: PublishAckFuture = js
                .publish(self.cfg.subject.clone(), bytes.into())
                .await
                .expect("publish failed");
            if timeout(self.cfg.timeout, ack).await.is_err() {
                eprintln!("NATS ack timed-out after {:?}", self.cfg.timeout);
            }
        }
    }
}

#[cfg(feature = "nats-output")]
impl Output for NATSOutput {
    fn start(&self, arx: Arc<Mutex<Receiver<Vec<u8>>>>, merger: Option<Box<dyn Merger>>) {
        for _ in 0..self.workers {
            let arx = Arc::clone(&arx);
            let cfg = self.cfg.clone();
            let merger = merger.as_ref().map(|m| m.clone_boxed());

            thread::spawn(move || {
                let rt = RtBuilder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("tokio runtime");

                rt.block_on(async { NATSWorker { arx, cfg, merger }.run().await });
            });
        }
    }
}
