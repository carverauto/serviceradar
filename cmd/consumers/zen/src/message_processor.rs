use anyhow::Result;
use async_nats::jetstream::{self, Message};
use cloudevents::{EventBuilder, EventBuilderV10};
use log::debug;
use serde_json::Value;
use url::Url;
use uuid::Uuid;

use crate::config::Config;
use crate::engine::SharedEngine;

pub async fn process_message(
    engine: &SharedEngine,
    cfg: &Config,
    js: &jetstream::Context,
    msg: &Message,
) -> Result<()> {
    debug!("processing message on subject {}", msg.subject);
    let mut context: serde_json::Value = serde_json::from_slice(&msg.payload)?;

    let rules = cfg.ordered_rules_for_subject(&msg.subject);
    let event_type = rules.last().map(String::as_str).unwrap_or("processed");

    for key in &rules {
        let dkey = format!("{}/{}/{}", cfg.stream_name, msg.subject, key);
        let resp = match engine.evaluate(&dkey, context.clone().into()).await {
            Ok(r) => r,
            Err(e) => {
                if let zen_engine::EvaluationError::LoaderError(le) = e.as_ref() {
                    if let zen_engine::loader::LoaderError::NotFound(_) = le.as_ref() {
                        debug!("rule {} not found, skipping", dkey);
                        continue;
                    }
                }
                return Err(anyhow::anyhow!(e.to_string()));
            }
        };
        debug!("decision {} evaluated", dkey);
        context = Value::from(resp.result);
    }

    if !rules.is_empty() {
        let ce = EventBuilderV10::new()
            .id(Uuid::new_v4().to_string())
            .source(Url::parse(&format!(
                "nats://{}/{}",
                cfg.stream_name, msg.subject
            ))?)
            .ty(event_type.to_string())
            .data("application/json", context)
            .build()?;

        let data = serde_json::to_vec(&ce)?;
        if let Some(suffix) = &cfg.result_subject_suffix {
            let result_subject = format!("{}.{}", msg.subject, suffix.trim_start_matches('.'));
            debug!("published result to {}", result_subject);
            js.publish(result_subject, data.into()).await?.await?;
        } else if let Some(subject) = &cfg.result_subject {
            debug!("published result to {}", subject);
            js.publish(subject.clone(), data.into()).await?.await?;
        }
    }

    Ok(())
}