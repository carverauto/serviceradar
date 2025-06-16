//! A Flowgger output that publishes every log record to a NATS JetStream subject.
//! Enable with `--features nats-output`.

#[cfg(feature = "nats-output")]
use {
    super::Output,
    crate::flowgger::{config::Config, merger::Merger},
    async_nats::{jetstream, Client, ConnectOptions},
    async_nats::jetstream::{context::PublishAckFuture, stream::StorageType},
    std::{
        path::PathBuf,
        sync::{mpsc::Receiver, Arc, Mutex},
        thread,
        time::Duration,
    },
    tokio::{runtime::Builder as RtBuilder, time::timeout},
};

#[cfg(feature = "nats-output")]
pub struct NATSOutput {
    cfg: NATSConfig,
    workers: u32,
}

#[cfg(feature = "nats-output")]
#[derive(Clone)]
struct NATSConfig {
    url:      String,
    subject:  String,
    stream:   String,
    timeout:  Duration,
    tls_cert: Option<PathBuf>,
    tls_key:  Option<PathBuf>,
    tls_ca:   Option<PathBuf>,
}

#[cfg(feature = "nats-output")]
impl NATSOutput {
    pub fn new(cfg: &Config) -> Self {
        // ---- mandatory ----
        let url     = cfg.lookup("output.nats_url")
            .expect("output.nats_url is required")
            .as_str().unwrap().to_owned();
        let subject = cfg.lookup("output.nats_subject")
            .unwrap_or_else(|| panic!("output.nats_subject is required"))
            .as_str().unwrap().to_owned();

        // ---- optional w/ sane defaults ----
        let stream  = cfg.lookup("output.nats_stream")
            .map_or("FLOWGGER".into(), |v| v.as_str().unwrap().to_owned());
        let timeout = Duration::from_millis(
            cfg.lookup("output.nats_timeout")
                .map_or(30_000, |v| v.as_integer().unwrap() as u64));

        let tls_cert = cfg.lookup("output.nats_tls_cert")
            .and_then(|v| Some(PathBuf::from(v.as_str().unwrap())));
        let tls_key  = cfg.lookup("output.nats_tls_key")
            .and_then(|v| Some(PathBuf::from(v.as_str().unwrap())));
        let tls_ca   = cfg.lookup("output.nats_tls_ca_file")
            .and_then(|v| Some(PathBuf::from(v.as_str().unwrap())));

        let workers  = cfg.lookup("output.nats_threads")
            .map_or(1, |v| v.as_integer().unwrap() as u32);

        Self {
            cfg: NATSConfig { url, subject, stream, timeout, tls_cert, tls_key, tls_ca },
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
    async fn connect(&self) -> Result<(Client, jetstream::Context), async_nats::Error> {
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
            name:     self.cfg.stream.clone(),
            subjects: vec![self.cfg.subject.clone()],
            storage:  StorageType::File,
            ..Default::default()
        };
        let _ = js.get_or_create_stream(stream_config).await?;

        Ok((client, js))
    }

    async fn run(self) {
        let (_, js) = self.connect().await.expect("NATS connection failed");

        loop {
            // Pull a record from Flowgger’s queue synchronously.
            let mut bytes = match { self.arx.lock().unwrap().recv() } {
                Ok(b) => b,
                Err(_) => return, // channel closed – shut the worker down
            };

            if let Some(m) = &self.merger { m.frame(&mut bytes); }

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
    fn start(&self,
             arx: Arc<Mutex<Receiver<Vec<u8>>>>,
             merger: Option<Box<dyn Merger>>) {

        for _ in 0..self.workers {
            let arx     = Arc::clone(&arx);
            let cfg     = self.cfg.clone();
            let merger  = merger.as_ref().map(|m| m.clone_boxed());

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
