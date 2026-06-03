//! `causal-engine` binary — the single-pod fused DeepCausality engine.
//!
//! V1 reasoning loop skeleton: hydrate `Context` → evaluate causaloids → emit
//! verdicts. TODO(1.2–1.7): real hydration, delta-driven ticks, snapshot
//! cadence, and graceful shutdown.

use std::time::Duration;

use tracing::{error, info};

use causal_engine::config::Config;
use causal_engine::context_hydrator::{ContextHydrator, ContextStore};
use causal_engine::emitter::Emitter;
use causal_engine::reasoner::Reasoner;
use causal_engine::snapshot::SnapshotStore;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();

    let config = Config::from_env()?;
    info!(?config, "starting causal-engine");

    let hydrator = ContextHydrator::connect().await?;
    let reasoner = Reasoner::new();
    let emitter = Emitter::connect(&config.nats_url).await?;
    let snapshot = SnapshotStore::new();

    // TODO(1.7): restore-on-start, then catch up from the JetStream sequence.
    snapshot.restore()?;

    let mut tick = tokio::time::interval(Duration::from_millis(config.tick_interval_ms));
    loop {
        tick.tick().await;
        match run_tick(&hydrator, &reasoner, &emitter).await {
            Ok(count) => info!(verdicts = count, "reasoning tick complete"),
            Err(err) => error!(error = %err, "reasoning tick failed"),
        }
    }
}

/// One fused reasoning tick: hydrate → reason → emit.
async fn run_tick(
    hydrator: &ContextHydrator,
    reasoner: &Reasoner,
    emitter: &Emitter,
) -> causal_engine::Result<usize> {
    let context = hydrator.current_context().await?;
    let verdicts = reasoner.evaluate(&context)?;
    emitter.emit(&verdicts).await?;
    Ok(verdicts.len())
}

fn init_tracing() {
    use tracing_subscriber::{fmt, EnvFilter};

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    fmt().with_env_filter(filter).init();
}
