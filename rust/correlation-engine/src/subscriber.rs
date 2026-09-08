//! Live state-change subscriber (task 1.2b, feed 3).
//!
//! Best-effort, ephemeral **core NATS** subscription to `signals.state.>`: it
//! applies `StateChangePublisher` deltas to the shared `Context` between
//! `EmbeddedSrql` refreshes. Durability/correctness comes from the hydrator's
//! periodic full re-snapshot — a missed live message is reconciled on the next
//! snapshot — so the feed needs no JetStream stream/consumer/ack machinery for
//! V1 (that is a Phase-2 reactivity/scale concern).

use std::sync::Arc;

use async_nats::Client;
use futures::StreamExt;
use tokio::sync::RwLock;
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use crate::delta::{apply_delta, parse_state_change};
use crate::domain_model::Context;
use crate::signal_evidence::{apply_signal_evidence, parse_prediction_signal};

/// Wildcard subject for all app-level state-change tables.
const STATE_SUBJECT: &str = "signals.state.>";
/// Wildcard subject for anomaly/capacity findings emitted by core-elx.
const PREDICTION_SUBJECT: &str = "signals.analytics.predictions.>";

/// Spawn the live state-change subscriber as a background task. The task runs
/// until the NATS subscription ends; failures are logged, never propagated.
pub fn spawn(client: Client, ctx: Arc<RwLock<Context>>) -> JoinHandle<()> {
    tokio::spawn(async move {
        if let Err(err) = run(client, ctx).await {
            warn!(error = %err, "state-change subscriber stopped");
        }
    })
}

async fn run(client: Client, ctx: Arc<RwLock<Context>>) -> anyhow::Result<()> {
    let mut state_subscription = client
        .subscribe(STATE_SUBJECT)
        .await
        .map_err(|e| anyhow::anyhow!("subscribe to {STATE_SUBJECT}: {e}"))?;

    let mut prediction_subscription = client
        .subscribe(PREDICTION_SUBJECT)
        .await
        .map_err(|e| anyhow::anyhow!("subscribe to {PREDICTION_SUBJECT}: {e}"))?;

    info!(
        subject = STATE_SUBJECT,
        "subscribed to live state-change feed"
    );

    info!(
        subject = PREDICTION_SUBJECT,
        "subscribed to live prediction-signal feed"
    );

    loop {
        tokio::select! {
            message = state_subscription.next() => {
                let Some(message) = message else { break; };
                handle_state_message(&ctx, message).await;
            }
            message = prediction_subscription.next() => {
                let Some(message) = message else { break; };
                handle_prediction_signal_message(&ctx, message).await;
            }
        }
    }

    Ok(())
}

async fn handle_state_message(ctx: &Arc<RwLock<Context>>, message: async_nats::Message) {
    match serde_json::from_slice::<serde_json::Value>(&message.payload) {
        Ok(envelope) => {
            if let Some(delta) = parse_state_change(&envelope) {
                let applied = {
                    let mut guard = ctx.write().await;
                    apply_delta(&mut guard, &delta)
                };
                debug!(
                    table = %delta.table,
                    entity = %delta.entity_uid,
                    field = %delta.field,
                    applied,
                    "applied state-change delta"
                );
            }
        }
        Err(e) => {
            warn!(error = %e, subject = %message.subject, "undecodable state-change envelope")
        }
    }
}

async fn handle_prediction_signal_message(
    ctx: &Arc<RwLock<Context>>,
    message: async_nats::Message,
) {
    match serde_json::from_slice::<serde_json::Value>(&message.payload) {
        Ok(envelope) => {
            if let Some(evidence) = parse_prediction_signal(&envelope) {
                let applied = {
                    let mut guard = ctx.write().await;
                    apply_signal_evidence(&mut guard, &evidence)
                };
                debug!(
                    rule = %evidence.rule_id,
                    entity = %evidence.entity_uid,
                    applied,
                    "applied prediction-signal evidence"
                );
            }
        }
        Err(e) => {
            warn!(error = %e, subject = %message.subject, "undecodable prediction-signal envelope")
        }
    }
}
