//! Provision a local `dgraph/standalone` container.

use crate::errors::fixture_error::FixtureError;
use crate::traits::instance_provider::InstanceProvider;
use crate::types::endpoint::{Endpoint, HTTP_PORT};
use crate::types::existing_provider;
use docker_utils::{ContainerConfig, DockerUtil, Probe, ProbeContext, WaitStrategy};

/// `docker_utils` appends the connection port, so the running container is
/// `dgraph-standalone-9080`. Fixed rather than per-run: one name means at most one leftover
/// container on a workstation, and it is what makes reuse possible.
const CONTAINER_NAME: &str = "dgraph-standalone";
const IMAGE: &str = "dgraph/standalone";
/// Pinned, and pinned to the version //k8s/dgraph deploys, so what a local run certifies is what
/// the cluster runs.
const TAG: &str = "v25.4.0";

/// A cold container has to pull an image and boot; the cluster path uses a far shorter budget.
const READY_TIMEOUT_SECS: u64 = 120;
const RETRY_DELAY_MS: u64 = 500;

/// Cap the alpha's cache so peak memory is a property of the configuration rather than of how
/// much the machine happens to have.
///
/// Dgraph defaults to `size-mb=1024` and badger derives its block and index caches from that, so
/// the default reserves about a gigabyte before any data is stored. A test fixture writes a
/// handful of nodes and has no use for it. Visible in the startup log as `CacheMb:128`, so a
/// rejected value would not pass unnoticed.
const ALPHA_CACHE_ENV: &str = "DGRAPH_ALPHA_CACHE=size-mb=128";

/// Where the ACL HMAC secret is written on the host and mounted in the container.
///
/// A STABLE path, not a per-run temp file, because the container is reused: a reused alpha
/// still holds the key it read at startup, and handing it a different file would only make the
/// two disagree. Nothing here reads the key back -- a client authenticates with a password and
/// receives a JWT the alpha signed -- so its only requirement is that it exists and does not
/// change under a running alpha.
const ACL_DIR_NAME: &str = "dgraph-test-acl";
const ACL_FILE_NAME: &str = "hmac_secret_file";
const ACL_MOUNT_DIR: &str = "/dgraph-test-acl";

/// Dgraph signs ACL tokens with an HMAC read from a FILE. `--acl` has no inline form -- only
/// `secret-file=<path>` -- which is the whole reason `docker_utils` needed volume support.
fn acl_secret_path() -> Result<std::path::PathBuf, FixtureError> {
    let dir = std::env::temp_dir().join(ACL_DIR_NAME);
    std::fs::create_dir_all(&dir)
        .map_err(|err| FixtureError::docker(format!("creating {}: {err}", dir.display())))?;

    let path = dir.join(ACL_FILE_NAME);
    if !path.exists() {
        // Dgraph wants at least 256 bits. Generated rather than committed, and generated once
        // rather than per run, so a reused container keeps the key it started with.
        //
        // RandomState is seeded by the OS, which is randomness this crate can reach without a
        // dependency. Good enough precisely because nothing authenticates with this value: it
        // signs tokens inside a disposable local container and is never read back here.
        use std::hash::{BuildHasher, Hasher};
        const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        let state = std::collections::hash_map::RandomState::new();
        let secret: String = (0..48_u64)
            .map(|i| {
                let mut hasher = state.build_hasher();
                hasher.write_u64(i);
                let index = usize::try_from(hasher.finish()).unwrap_or(0) % ALPHABET.len();
                char::from(ALPHABET[index])
            })
            .collect();
        std::fs::write(&path, secret)
            .map_err(|err| FixtureError::docker(format!("writing {}: {err}", path.display())))?;
    }
    Ok(path)
}

/// Zero-sized. Starts or reuses a container and waits for it to serve.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct ContainerProvider;

impl InstanceProvider for ContainerProvider {
    fn acquire(&self, endpoint: &Endpoint) -> Result<(u16, Option<String>), FixtureError> {
        // ACL ON LOCALLY TOO, which is what makes this a rehearsal rather than a weaker
        // environment. Without it the client is superadmin in namespace 0 and every operation
        // is permitted, so the permission model is simply absent -- which is how both
        // `AllocateIDs is superadmin only` and `drop all` reached CI unnoticed after passing
        // here. With it, a local run is refused exactly what the cluster refuses.
        let secret = acl_secret_path()?;
        let mount = format!(
            "{}:{ACL_MOUNT_DIR}:ro",
            secret.parent().unwrap_or(&secret).display()
        );
        let acl_env = format!("DGRAPH_ALPHA_ACL=secret-file={ACL_MOUNT_DIR}/{ACL_FILE_NAME}");
        // ContainerConfig borrows its slices, so they are owned here rather than inside the
        // function that builds it.
        let env_vars = [ALPHA_CACHE_ENV, acl_env.as_str()];
        let volumes = [mount.as_str()];

        let docker = DockerUtil::with_debug().map_err(|err| {
            FixtureError::docker(format!(
                "{err}. A local Dgraph needs a Docker daemon; \
                 SERVICERADAR_ENV=ci uses the cluster instead."
            ))
        })?;

        let (container_id, port) = docker
            .setup_container(&container_config(endpoint, &env_vars, &volumes))
            .map_err(|err| FixtureError::docker(format!("{err:?}")))?;

        Ok((port, Some(container_id)))
    }
}

/// Readiness is `/health?all` reporting every server healthy -- the same check the cluster path
/// makes, so both strategies gate on one definition of "usable" rather than two.
///
/// NOT a destructive operation. An earlier version gated on `drop_all`, which was defensible only
/// while the resolved host could not be anything but a container this code had just created. The
/// endpoint now comes from the configuration and can name a shared cluster, and a probe cannot
/// tell the difference -- so it must not be able to destroy either one.
///
/// A `ProbeFn` is a plain fn pointer by contract and cannot capture, so it rebuilds the endpoint
/// from what `docker_utils` hands it. Cheap: no I/O, and TLS is off on the standalone image.
fn container_ready(ctx: &ProbeContext) -> Probe<(), String> {
    let endpoint = Endpoint::new(ctx.host(), ctx.port(), plaintext());

    match existing_provider::check_once(&endpoint) {
        Ok(report) if report.all_healthy() => {}
        Ok(report) => return Probe::Retry(format!("not all healthy:\n{}", report.describe())),
        Err(err) => return Probe::Retry(err.to_string()),
    }

    // HEALTH IS NOT ENOUGH ONCE ACL IS ON. The alpha reports healthy while ACL is still
    // initialising -- measured at six seconds on this image -- and `groot` does not exist
    // until it finishes. Returning ready in that window hands back an instance whose first
    // login fails with "invalid username or password" from a cluster that is working fine.
    match existing_provider::check_acl_login(&endpoint, GROOT, crate::DEFAULT_GROOT_PASSWORD) {
        Ok(()) => Probe::Ready(()),
        Err(err) => Probe::Retry(err.to_string()),
    }
}

/// The user the fixture authenticates as. A container it started has no other.
const GROOT: &str = "groot";

/// The standalone image serves plaintext; nothing configures TLS on it.
fn plaintext() -> serviceradar_config_schema::DgraphTlsMode {
    serviceradar_config_schema::DgraphTlsMode::Disable
}

/// Host networking rather than published ports: it removes NAT from the picture, so Dgraph binds
/// 9080/8080 directly in this network namespace and no iptables rule has to exist for the test to
/// reach it.
fn container_config<'l>(
    endpoint: &'l Endpoint,
    env_vars: &'l [&'l str],
    volumes: &'l [&'l str],
) -> ContainerConfig<'l> {
    ContainerConfig::builder()
        .name(CONTAINER_NAME)
        .image(IMAGE)
        .tag(TAG)
        // A connection target, not a bind address: this is forwarded to the probe and nowhere
        // else. It never reaches `docker run`.
        .url(endpoint.host())
        .connection_port(endpoint.port())
        .additional_ports(&[HTTP_PORT])
        .additional_env_vars(env_vars)
        // Needs docker_utils >= 0.3.4. `--acl` takes only `secret-file=<path>`, so the key can
        // reach the container as a file or not at all.
        .volumes(volumes)
        .reuse_container(true)
        .keep_configuration(true)
        .host_network(true)
        // Readiness is part of the configuration, so it holds on every path `setup_container`
        // can take -- including handing back a REUSED container, which is where a wedged
        // leftover from a killed run would otherwise slip through.
        .wait_strategy(WaitStrategy::WaitUntilReady {
            probe: container_ready,
            timeout_secs: READY_TIMEOUT_SECS,
            retry_delay_ms: RETRY_DELAY_MS,
        })
        .build()
}
