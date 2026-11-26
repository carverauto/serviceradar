# SPDX-License-Identifier: Apache-2.0
"""Synthetic reference handler for serviceradar-vantage."""

from __future__ import annotations

from typing import Any


def process_frame(ctx: Any) -> list[dict[str, Any]]:
    """Process a single recorded_block or live_keyframe_tap FrameContext."""
    detections = getattr(ctx, "upstream_detections", None) or []
    bbox = detections[0].get("bbox", [0.32, 0.58, 0.48, 0.66]) if detections else [0.32, 0.58, 0.48, 0.66]
    return [
        {
            "observation_key": f"obs-{getattr(ctx, 'frame_sequence', 1)}-sr-0100",
            "fragment_sequence": getattr(ctx, "fragment_sequence", 1),
            "frame_sequence": getattr(ctx, "frame_sequence", 1),
            "media_pts_ns": getattr(ctx, "media_pts_ns", 1_000_000_000),
            "timeline_ts_us": getattr(ctx, "timeline_ts_us", 1_700_000_000_000_000),
            "time_basis": getattr(ctx, "time_basis", "received"),
            "track_id": "track-1",
            "category": "license_plate",
            "label": "SR-0100",
            "confidence": 0.94,
            "bbox": bbox,
            "attributes": {
                "plate_text": "SR-0100",
                "region": "US-CA",
                "camera_label": "Gate West 01",
                "confidence": 0.94,
            },
            "signal_schema_id": "__SCHEMA_ID__",
            "signal_schema_version": "1.0.0",
            "display_contract_id": "__SCHEMA_ID__",
            "search_text": "SR-0100 Gate West 01 license_plate",
        }
    ]
