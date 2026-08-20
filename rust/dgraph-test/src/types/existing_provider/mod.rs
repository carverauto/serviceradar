//! Verify a Dgraph this process did not create.

use crate::errors::fixture_error::FixtureError;
use crate::traits::instance_provider::InstanceProvider;
use crate::types::endpoint::Endpoint;
use crate::types::health_report::HealthReport;
use std::time::{Duration, Instant};

/// How long a deployed cluster gets to answer.
///
/// Much shorter than the container budget on purpose: a deployed Dgraph is either up or broken,
/// it is not booting. Waiting two minutes to discover the cluster is down only delays the report.
const READY_TIMEOUT_SECS: u64 = 20;
const RETRY_DELAY_MS: u64 = 500;
const REQUEST_TIMEOUT_SECS: u64 = 5;

/// Zero-sized. Health-checks over HTTP and provisions nothing.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct ExistingProvider;

impl InstanceProvider for ExistingProvider {
    fn acquire(&self, endpoint: &Endpoint) -> Result<(u16, Option<String>), FixtureError> {
        let report = wait_until_healthy(endpoint)?;
        debug_assert!(report.all_healthy());
        Ok((endpoint.port(), None))
    }
}

/// Poll `/health?all` until every server reports healthy, or the budget runs out.
///
/// A deadline rather than an attempt count: attempts times delay silently shrinks the real wait
/// whenever an attempt is itself slow, which is precisely what happens on a loaded runner.
pub fn wait_until_healthy(endpoint: &Endpoint) -> Result<HealthReport, FixtureError> {
    let deadline = Instant::now() + Duration::from_secs(READY_TIMEOUT_SECS);
    let mut attempts = 0_u32;
    // Deferred: every arm below assigns before the deadline is consulted.
    let mut last;

    loop {
        attempts += 1;
        match check_once(endpoint) {
            Ok(report) if report.all_healthy() => return Ok(report),
            Ok(report) => last = format!("not all servers healthy:\n{}", report.describe()),
            Err(err) => last = err.to_string(),
        }

        if Instant::now() >= deadline {
            return Err(FixtureError::not_ready(
                endpoint.host(),
                endpoint.port(),
                attempts,
                last,
            ));
        }
        std::thread::sleep(Duration::from_millis(RETRY_DELAY_MS));
    }
}

/// One request. Public so a caller can assert on the report itself.
pub fn check_once(endpoint: &Endpoint) -> Result<HealthReport, FixtureError> {
    fetch(endpoint, &endpoint.health_url())
}

/// The whole cluster's view: one entry per server. Used to assert a deployment's shape.
pub fn check_cluster(endpoint: &Endpoint) -> Result<HealthReport, FixtureError> {
    fetch(endpoint, &endpoint.cluster_health_url())
}

fn fetch(_endpoint: &Endpoint, url: &str) -> Result<HealthReport, FixtureError> {

    // CERTIFICATE VERIFICATION IS OFF, deliberately. This asks whether something is serving at
    // the address, not who it is -- and the answer carries no secret. Verifying would drag a
    // private CA into a liveness check and, worse, make "the fixture is down" and "the CA is
    // wrong" the same failure. Proving the certificate is correct belongs to the client test,
    // which has to do it anyway to open a session.
    let tls = ureq::tls::TlsConfig::builder()
        .disable_verification(true)
        .build();
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .tls_config(tls)
        .timeout_global(Some(Duration::from_secs(REQUEST_TIMEOUT_SECS)))
        .build()
        .into();

    let body = agent
        .get(url)
        .call()
        .map_err(|err| FixtureError::health(url, err.to_string()))?
        .body_mut()
        .read_to_string()
        .map_err(|err| FixtureError::health(url, format!("reading the response: {err}")))?;

    HealthReport::parse(url, &body)
}
