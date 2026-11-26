// SPDX-License-Identifier: Apache-2.0

use serde_json::json;
use serviceradar_vantage_sdk::{
    ObservationOutput, VantageError, VantageFrameContext, VantageHandler, VantageWorker,
    WorkerConfig,
};

struct SyntheticHandler;

impl VantageHandler for SyntheticHandler {
    fn capability(&self) -> &str {
        "__CAPABILITY__"
    }

    fn process_frame(&self, ctx: &VantageFrameContext) -> Result<Vec<ObservationOutput>, VantageError> {
        Ok(vec![ObservationOutput {
            observation_key: format!("obs-{}-sr-0100", ctx.frame_sequence),
            fragment_sequence: ctx.fragment_sequence,
            frame_sequence: ctx.frame_sequence,
            media_pts_ns: ctx.media_pts_ns,
            timeline_ts_us: ctx.timeline_ts_us,
            time_basis: ctx.time_basis.clone(),
            track_id: Some("track-1".to_string()),
            category: "license_plate".to_string(),
            label: "SR-0100".to_string(),
            confidence: 0.94,
            bbox: Some([0.32, 0.58, 0.48, 0.66]),
            crop_jpeg_b64: None,
            attributes: json!({
                "plate_text": "SR-0100",
                "region": "US-CA",
                "camera_label": "Gate West 01",
                "confidence": 0.94
            }),
            signal_schema_id: "__SCHEMA_ID__".to_string(),
            signal_schema_version: "1.0.0".to_string(),
            display_contract_id: "__SCHEMA_ID__".to_string(),
            search_text: "SR-0100 Gate West 01 license_plate".to_string(),
        }])
    }
}

#[tokio::main]
async fn main() -> Result<(), VantageError> {
    let config = WorkerConfig::from_env()?;
    let worker = VantageWorker::new(config, SyntheticHandler)?;
    worker.run().await
}
