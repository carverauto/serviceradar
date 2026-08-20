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

/// Zero-sized. Starts or reuses a container and waits for it to serve.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct ContainerProvider;

impl InstanceProvider for ContainerProvider {
    fn acquire(&self, endpoint: &Endpoint) -> Result<(u16, Option<String>), FixtureError> {
        let docker = DockerUtil::with_debug().map_err(|err| {
            FixtureError::docker(format!(
                "{err}. A local Dgraph needs a Docker daemon; \
                 SERVICERADAR_ENV=ci uses the cluster instead."
            ))
        })?;

        let (container_id, port) = docker
            .setup_container(&container_config(endpoint))
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
        Ok(report) if report.all_healthy() => Probe::Ready(()),
        Ok(report) => Probe::Retry(format!("not all healthy:\n{}", report.describe())),
        Err(err) => Probe::Retry(err.to_string()),
    }
}

/// The standalone image serves plaintext; nothing configures TLS on it.
fn plaintext() -> serviceradar_config_schema::DgraphTlsMode {
    serviceradar_config_schema::DgraphTlsMode::Disable
}

/// Host networking rather than published ports: it removes NAT from the picture, so Dgraph binds
/// 9080/8080 directly in this network namespace and no iptables rule has to exist for the test to
/// reach it.
fn container_config(endpoint: &Endpoint) -> ContainerConfig<'_> {
    ContainerConfig::builder()
        .name(CONTAINER_NAME)
        .image(IMAGE)
        .tag(TAG)
        // A connection target, not a bind address: this is forwarded to the probe and nowhere
        // else. It never reaches `docker run`.
        .url(endpoint.host())
        .connection_port(endpoint.port())
        .additional_ports(&[HTTP_PORT])
        .additional_env_vars(&[ALPHA_CACHE_ENV])
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
