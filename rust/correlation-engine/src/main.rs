//! `correlation-engine` binary — the single-pod fused correlation engine.
//!
//! V1 reasoning loop skeleton: hydrate `Context` → evaluate causaloids → emit
//! verdicts. TODO(1.2–1.7): real hydration, delta-driven ticks, snapshot
//! cadence, and graceful shutdown.

use std::time::Duration;

use chrono::Utc;
use tracing::{error, info, warn};

use correlation_engine::config::Config;
use correlation_engine::context_hydrator::{ContextHydrator, ContextStore};
use correlation_engine::emitter::Emitter;
use correlation_engine::reasoner::Reasoner;
use correlation_engine::{nats, subscriber};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();

    let config = Config::from_env()?;
    info!(?config, "starting correlation-engine");

    let (nats_client, jetstream) = nats::connect(&config).await?;
    let hydrator = ContextHydrator::connect(&config.snapshot_path).await?;
    let reasoner = Reasoner::new();
    let emitter = Emitter::new(jetstream);

    // Live push input: apply `signals.state.>` deltas to the shared Context
    // between SRQL refreshes (best-effort; refresh reconciles any gaps).
    let _subscriber = subscriber::spawn(nats_client, hydrator.shared_context());

    // Two cadences: reason frequently; re-snapshot (reconcile + pick up new
    // entities) on a slower interval. Both operate on the one shared Context.
    let mut reason = tokio::time::interval(Duration::from_millis(config.tick_interval_ms));
    let mut refresh = tokio::time::interval(Duration::from_millis(config.refresh_interval_ms));
    loop {
        tokio::select! {
            _ = reason.tick() => match run_tick(&config, &hydrator, &reasoner, &emitter).await {
                Ok(count) => info!(verdicts = count, "reasoning tick complete"),
                Err(err) => error!(error = %err, "reasoning tick failed"),
            },
            _ = refresh.tick() => {
                if let Err(err) = hydrator.refresh().await {
                    warn!(error = %err, "context refresh failed");
                }
            }
        }
    }
}

/// One fused reasoning tick: hydrate → reason → emit.
async fn run_tick(
    config: &Config,
    hydrator: &ContextHydrator,
    reasoner: &Reasoner,
    emitter: &Emitter,
) -> correlation_engine::Result<usize> {
    let pruned = hydrator
        .prune_stale_operator_rules(
            Utc::now().timestamp_millis(),
            config.operator_rule_ttl_ms as i64,
        )
        .await;

    if pruned > 0 {
        info!(pruned, "pruned stale operator-rule evidence");
    }

    let context = hydrator.current_context().await?;
    let verdicts = reasoner.evaluate(&context)?;
    emitter.emit(&verdicts).await?;
    Ok(verdicts.len())
}

fn init_tracing() {
    use tracing_subscriber::{EnvFilter, fmt};

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    fmt().with_env_filter(filter).init();
}
