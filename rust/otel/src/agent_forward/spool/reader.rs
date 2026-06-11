//! The `(segment, offset)` cursor that drains the spool in relay_id order.
//!
//! A reader resumes from the ack watermark, survives segment release and
//! eviction underneath it (it re-locates the next live segment), and parks
//! on [`Spool::wait_for_frame_after`] when it has caught up with the tail.

use std::sync::Arc;

use addon_sdk::pb::OtlpRelayFrame;
use anyhow::Result;

use super::segments::{SegmentMeta, read_record};
use super::{Inner, Spool};

/// Cursor over the spool that yields unacked frames in relay_id order,
/// resuming from the ack watermark and skipping acked/evicted frames.
pub struct SpoolReader {
    pub(super) spool: Arc<Spool>,
    /// First relay_id of the segment the cursor is in (segment identity).
    pub(super) segment_first_id: Option<u64>,
    /// Byte offset of the next record within that segment.
    pub(super) offset: u64,
    /// Highest relay_id returned so far (or the watermark at creation).
    pub(super) position: u64,
}

impl SpoolReader {
    /// Highest relay_id this reader has returned (used as the
    /// [`Spool::wait_for_frame_after`] resume point).
    pub fn position(&self) -> u64 {
        self.position
    }

    /// Returns the next unacked frame, or `None` when the reader has caught
    /// up with the spool tail (callers then await
    /// [`Spool::wait_for_frame_after`]).
    pub fn try_next(&mut self) -> Result<Option<OtlpRelayFrame>> {
        let inner = self.spool.lock();
        let target = self.position.max(inner.watermark);
        loop {
            let seg = match self
                .segment_first_id
                .and_then(|first| inner.find_segment(first))
            {
                Some(seg) => seg,
                None => match inner.first_segment_after(target) {
                    Some(seg) => {
                        self.segment_first_id = Some(seg.first_relay_id);
                        self.offset = 0;
                        seg
                    }
                    None => {
                        // Caught up. If an active segment exists its frames
                        // are all <= target, so fast-forward the cursor past
                        // them instead of rescanning on every poll.
                        if let Some(active) = &inner.active {
                            self.segment_first_id = Some(active.meta.first_relay_id);
                            self.offset = active.meta.bytes;
                        }
                        return Ok(None);
                    }
                },
            };

            if self.offset >= seg.bytes {
                if inner.is_active(seg.first_relay_id) {
                    return Ok(None);
                }
                match inner.next_segment_after(seg.first_relay_id) {
                    Some(next) => {
                        self.segment_first_id = Some(next.first_relay_id);
                        self.offset = 0;
                        continue;
                    }
                    None => return Ok(None),
                }
            }

            let (frame, next_offset) = read_record(&seg.path, self.offset)?;
            self.segment_first_id = Some(seg.first_relay_id);
            self.offset = next_offset;
            if frame.relay_id <= target {
                continue;
            }
            self.position = frame.relay_id;
            return Ok(Some(frame));
        }
    }

    /// Awaits the next unacked frame.
    pub async fn next_frame(&mut self) -> Result<OtlpRelayFrame> {
        loop {
            if let Some(frame) = self.try_next()? {
                return Ok(frame);
            }
            let position = self.position;
            self.spool.wait_for_frame_after(position).await;
        }
    }
}

impl Inner {
    fn find_segment(&self, first_relay_id: u64) -> Option<SegmentMeta> {
        if let Some(active) = &self.active
            && active.meta.first_relay_id == first_relay_id
        {
            return Some(active.meta.clone());
        }
        self.sealed
            .iter()
            .find(|s| s.first_relay_id == first_relay_id)
            .cloned()
    }

    /// First segment (in relay_id order) containing any frame with
    /// relay_id > `target`.
    fn first_segment_after(&self, target: u64) -> Option<SegmentMeta> {
        self.sealed
            .iter()
            .find(|s| s.last_relay_id > target)
            .cloned()
            .or_else(|| {
                self.active
                    .as_ref()
                    .filter(|a| a.meta.last_relay_id > target)
                    .map(|a| a.meta.clone())
            })
    }

    /// Segment immediately following the one whose first id is `first`.
    fn next_segment_after(&self, first: u64) -> Option<SegmentMeta> {
        self.sealed
            .iter()
            .find(|s| s.first_relay_id > first)
            .cloned()
            .or_else(|| {
                self.active
                    .as_ref()
                    .filter(|a| a.meta.first_relay_id > first)
                    .map(|a| a.meta.clone())
            })
    }

    fn is_active(&self, first_relay_id: u64) -> bool {
        self.active
            .as_ref()
            .is_some_and(|a| a.meta.first_relay_id == first_relay_id)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use addon_sdk::pb::TelemetryPayloadKind;

    use crate::agent_forward::spool::Spool;
    use crate::agent_forward::spool::testutil::{small_config, test_batch};

    #[test]
    fn round_trip_preserves_frames_in_order() {
        let dir = tempfile::tempdir().unwrap();
        let spool = Arc::new(Spool::open(small_config(dir.path())).unwrap());

        let mut ids = Vec::new();
        for i in 0..10u8 {
            let id = spool
                .append_batch(test_batch(
                    TelemetryPayloadKind::OtlpTraces,
                    vec![i; 64 + i as usize],
                ))
                .unwrap();
            ids.push(id);
        }
        assert!(ids.windows(2).all(|w| w[1] == w[0] + 1), "ids monotonic");

        let mut reader = spool.reader();
        for (i, expected_id) in ids.iter().enumerate() {
            let frame = reader.try_next().unwrap().expect("frame available");
            assert_eq!(frame.relay_id, *expected_id);
            let batch = frame.batch.expect("batch present");
            assert_eq!(batch.records.len(), 1);
            assert_eq!(batch.records[0].payload, vec![i as u8; 64 + i]);
            let counters = batch.counters.expect("spool stamps counters");
            assert_eq!(counters.dropped, 0);
        }
        assert!(reader.try_next().unwrap().is_none(), "caught up");
    }

    #[test]
    fn reader_resumes_from_watermark() {
        let dir = tempfile::tempdir().unwrap();
        let spool = Arc::new(Spool::open(small_config(dir.path())).unwrap());

        let mut ids = Vec::new();
        for _ in 0..6 {
            ids.push(
                spool
                    .append_batch(test_batch(TelemetryPayloadKind::OtlpLogs, vec![1; 32]))
                    .unwrap(),
            );
        }
        spool.advance_watermark(ids[2]).unwrap();

        let mut reader = spool.reader();
        let first = reader.try_next().unwrap().expect("unacked frame");
        assert_eq!(first.relay_id, ids[3], "resumes just past the watermark");
    }

    #[tokio::test]
    async fn wait_for_frame_after_wakes_on_append() {
        let dir = tempfile::tempdir().unwrap();
        let spool = Arc::new(Spool::open(small_config(dir.path())).unwrap());

        let waiter = Arc::clone(&spool);
        let wait = tokio::spawn(async move { waiter.wait_for_frame_after(0).await });
        tokio::task::yield_now().await;

        spool
            .append_batch(test_batch(TelemetryPayloadKind::OtlpTraces, vec![1; 8]))
            .unwrap();
        tokio::time::timeout(Duration::from_secs(5), wait)
            .await
            .expect("waiter wakes after append")
            .unwrap();
    }
}
