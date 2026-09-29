//! Typed CI-only namespace ownership shared by live topology boundary tests.
use std::future::Future;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use dgraph_client::DgraphClient;
use runfiles::Runfiles;
use serviceradar_config_manager::{
    ConfigManager, DGRAPH_ADMIN_PASSWORD, Filesystem, Identity, fetch_ca_bundle,
};
use serviceradar_config_schema::DgraphTlsMode;
use serviceradar_secret_manager::{EnvironmentProvider, Manifest, Secret, SecretManager};

pub async fn with_scratch<F, Fut>(timeout: Duration, test: F)
where
    F: FnOnce(DgraphClient, String) -> Fut + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    let fixture = Fixture::ci();
    let mut ca_file = FixtureCa::create(&fixture.ca_bundle_url);
    let ca_path = ca_file.0.as_ref().expect("owned CA file");
    let admin_target = fixture.connection(0, fixture.admin_password.expose(), ca_path);
    // Upstream connection errors retain only parsed authority/structural
    // details. The migration connector's error also retains the full URL.
    let admin = tokio::time::timeout(
        Duration::from_secs(30),
        DgraphClient::connect(&admin_target),
    )
    .await
    .expect("fixture administrator connection timed out")
    .expect("connect fixture administrator");
    let namespace = tokio::time::timeout(Duration::from_secs(30), admin.create_namespace())
        .await
        .expect("namespace allocation timed out; server ownership is unknown")
        .expect("allocate owned scratch namespace");
    assert_ne!(
        namespace, 0,
        "never use the shared admin namespace as scratch"
    );
    // All fallible scratch setup and test assertions are inside the task. A
    // panic still returns control here for namespace deletion and verification.
    let ca_path = ca_path.clone();
    let mut task = tokio::spawn(async move {
        // Dgraph initializes each new namespace with this scratch credential.
        // The shared administrator credential is never changed.
        let target = fixture.connection(namespace, "password", &ca_path);
        let client = DgraphClient::connect(&target)
            .await
            .expect("connect owned scratch namespace");
        test(client, target).await;
    });
    let outcome = match tokio::time::timeout(timeout, &mut task).await {
        Ok(result) => Some(result),
        Err(_) => {
            task.abort();
            let _ = task.await;
            None
        }
    };

    let mut cleanup_errors = Vec::new();
    match tokio::time::timeout(Duration::from_secs(30), admin.drop_namespace(namespace)).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => cleanup_errors.push(format!("drop owned namespace: {error}")),
        Err(_) => cleanup_errors.push("drop owned namespace timed out".into()),
    }
    match tokio::time::timeout(Duration::from_secs(30), admin.list_namespaces()).await {
        Ok(Ok(namespaces)) if namespaces.contains_key(&namespace) => {
            cleanup_errors.push("owned namespace remains after deletion".into());
        }
        Ok(Ok(_)) => eprintln!("owned Dgraph namespace absence verified"),
        Ok(Err(error)) => cleanup_errors.push(format!("verify namespace absence: {error}")),
        Err(_) => cleanup_errors.push("verify namespace absence timed out".into()),
    }
    if let Err(error) = ca_file.remove() {
        cleanup_errors.push(format!("remove owned CA file: {error}"));
    }
    if !cleanup_errors.is_empty() {
        eprintln!(
            "Dgraph fixture cleanup failed for owned namespace {namespace}: {}",
            cleanup_errors.join("; ")
        );
    }
    match outcome {
        Some(Ok(())) => assert!(cleanup_errors.is_empty(), "scratch cleanup failed"),
        Some(Err(error)) if error.is_panic() => std::panic::resume_unwind(error.into_panic()),
        Some(Err(error)) => panic!("scratch test task failed: {error}"),
        None => panic!("scratch test exceeded its bounded deadline"),
    }
}

struct Fixture {
    authority: String,
    ca_bundle_url: String,
    admin_password: Secret,
}

impl Fixture {
    fn ci() -> Self {
        let identity = Identity::from_env().expect("typed fixture identity");
        assert_eq!(identity.to_string(), "ci", "only the CI fixture is allowed");
        let runfiles = Runfiles::create().expect("Bazel fixture runfiles");
        let path = runfiles
            .rlocation_from("serviceradar/config/environments/ci.binpb", "")
            .expect("declared CI config input");
        let bytes = std::fs::read(path).expect("read declared CI config");
        let manager = ConfigManager::load(&identity, &[("ci", &bytes)], &Filesystem)
            .expect("validated CI config");
        let config = manager.dgraph().expect("CI Dgraph config");
        assert_eq!(
            config
                .tls_mode
                .and_then(|mode| DgraphTlsMode::try_from(mode).ok()),
            Some(DgraphTlsMode::VerifyCa),
            "fixture connections must verify the Dgraph CA"
        );
        let host = config.host.as_deref().expect("CI Dgraph host");
        assert!(!host.contains(['@', '/', '?', '#']), "valid Dgraph host");
        let port = u16::try_from(config.port.expect("CI Dgraph port")).expect("valid Dgraph port");
        let authority = if host.parse::<std::net::Ipv6Addr>().is_ok() {
            format!("[{host}]:{port}")
        } else {
            format!("{host}:{port}")
        };
        let secrets = SecretManager::new(
            EnvironmentProvider::for_kind(identity.kind()),
            Manifest::new([DGRAPH_ADMIN_PASSWORD]),
        );
        Self {
            authority,
            ca_bundle_url: manager
                .dgraph_ca_bundle_url()
                .expect("CI Dgraph CA URL")
                .to_owned(),
            admin_password: secrets
                .resolve(DGRAPH_ADMIN_PASSWORD)
                .expect("typed CI Dgraph credential"),
        }
    }

    fn connection(&self, namespace: u64, password: &str, ca_path: &std::path::Path) -> String {
        format!(
            "dgraph://groot:{}@{}?sslmode=verify-ca&namespace={namespace}&sslrootcert={}",
            urlencoding::encode(password),
            self.authority,
            urlencoding::encode(ca_path.to_str().expect("CA path is UTF-8")),
        )
    }
}

struct FixtureCa(Option<PathBuf>);

impl FixtureCa {
    fn create(url: &str) -> Self {
        let pem = fetch_ca_bundle(url).expect("fixture CA bundle");
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::var_os("TEST_TMPDIR")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let path = directory.join(format!(
            "dgraph-ca-{}-{}.crt",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed),
        ));
        let mut options = std::fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&path).expect("create owned CA file");
        let guard = Self(Some(path));
        let written = file.write_all(&pem);
        drop(file);
        written.expect("write fixture CA");
        guard
    }

    fn remove(&mut self) -> std::io::Result<()> {
        if let Some(path) = &self.0 {
            std::fs::remove_file(path)?;
            if path.try_exists()? {
                return Err(std::io::Error::other("owned CA file remains after removal"));
            }
            self.0 = None;
        }
        Ok(())
    }
}

impl Drop for FixtureCa {
    fn drop(&mut self) {
        let _ = self.remove();
    }
}
