//! The fused single-pod causal security engine — composition root / DI + tick loop.
//!
//! SCAFFOLD ONLY in Phase 0: this binary composes the crate family so the wiring compiles, but the
//! runtime tick loop (hydrate Context → evaluate the kill-chain graph per incident hypothesis → SPRT
//! at the CSM → clear the sample cache at the tick barrier → emit) is filled by later milestones.
//! (OpenSpec `add-causal-security-foundation`.)
#![forbid(unsafe_code)]

use serviceradar_causal_ingest::{RawSignal, build_observation};
use serviceradar_causal_model::{Domain, EntityKey};
use serviceradar_causal_reasoning::clear_sample_cache_at_tick_barrier;

fn main() {
    // Phase-0 smoke of the composition: construct a calibrated Observation and prove the tick-barrier
    // cache-clear is wired. The real loop lands in add-causal-security-detections.
    let obs = build_observation(
        EntityKey::new("sr:device:example"),
        Domain::Flow,
        RawSignal::Score {
            z: 6.0,
            quality: serviceradar_causal_config::Quality {
                confirmed: true,
                ..Default::default()
            },
        },
        uuid::Uuid::nil(),
        0,
    );
    eprintln!(
        "serviceradar-causal-engine (Phase 0 scaffold): built observation = {:?}",
        obs.map(|o| o.confidence)
    );
    clear_sample_cache_at_tick_barrier();
}
