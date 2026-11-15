//! Merged device availability history (`device_availability_transitions`).
//!
//! Each device walks a fixed cycle of merged states inside `{window_main}`. Every row closes
//! the interval its predecessor opened, so `from_since` is the previous row's `changed_at`
//! and the first row of each device has none. The optional provenance columns are left NULL
//! on a cadence, so the text negations that keep NULL rows are exercised against both
//! backends, and every fifth row is a conflict. Device and agent ids are the fixture's own
//! invented ones.

use super::{
    AGENT_1, AGENT_2, Anchor, BATCH_ROWS, Backend, DEVICE_A, DEVICE_B, DEVICE_C, instant,
    opt_instant, opt_text, text,
};

#[derive(Debug, Clone, PartialEq)]
pub struct TransitionRow {
    pub device_uid: &'static str,
    pub changed_at: chrono::DateTime<chrono::Utc>,
    pub to_state: &'static str,
    pub from_state: &'static str,
    pub from_since: Option<chrono::DateTime<chrono::Utc>>,
    pub authority_class: Option<&'static str>,
    pub source_kind: Option<&'static str>,
    pub reporter_agent_id: Option<&'static str>,
    pub rule: Option<&'static str>,
    pub conflict: bool,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

const DEVICES: [&str; 3] = [DEVICE_A, DEVICE_B, DEVICE_C];
const CYCLE: [&str; 3] = ["available", "unavailable", "unknown"];
/// Transitions per device, 20 minutes apart from the anchor: the last lands at A+4h,
/// inside `{window_main}`.
const PER_DEVICE: i64 = 12;

pub fn rows(anchor: Anchor) -> Vec<TransitionRow> {
    let mut rows = Vec::new();
    for (d, device_uid) in DEVICES.iter().enumerate() {
        let mut from_state = "unknown";
        let mut from_since = None;
        for step in 0..PER_DEVICE {
            // Devices are offset by whole seconds, so no two rows share a `changed_at` and an
            // ordered comparison has no ties to fall back on.
            let changed_at = anchor.at(step * 1200 + d as i64 * 11);
            let to_state = CYCLE[(step as usize + d) % CYCLE.len()];
            let to_state = if to_state == from_state {
                CYCLE[(step as usize + d + 1) % CYCLE.len()]
            } else {
                to_state
            };
            rows.push(TransitionRow {
                device_uid,
                changed_at,
                to_state,
                from_state,
                from_since,
                authority_class: match step % 3 {
                    0 => Some("direct"),
                    1 => Some("inferred"),
                    _ => None,
                },
                source_kind: match step % 4 {
                    0 => None,
                    1 | 2 => Some("sweep"),
                    _ => Some("agent"),
                },
                reporter_agent_id: match step % 3 {
                    0 => Some(AGENT_1),
                    1 => Some(AGENT_2),
                    _ => None,
                },
                rule: (step % 2 == 0).then_some("merge-rule-01"),
                conflict: step % 5 == 4,
                created_at: changed_at + chrono::Duration::seconds(1),
            });
            from_state = to_state;
            from_since = Some(changed_at);
        }
    }
    rows
}

pub fn inserts(rows: &[TransitionRow], backend: Backend, qualifier: &str) -> Vec<String> {
    let columns = "device_uid, changed_at, to_state, from_state, from_since, authority_class, \
                   source_kind, reporter_agent_id, rule, conflict, created_at";
    rows.chunks(BATCH_ROWS)
        .map(|chunk| {
            let values: Vec<String> = chunk
                .iter()
                .map(|r| {
                    format!(
                        "({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {})",
                        text(r.device_uid),
                        instant(r.changed_at, backend),
                        text(r.to_state),
                        text(r.from_state),
                        opt_instant(r.from_since, backend),
                        opt_text(r.authority_class),
                        opt_text(r.source_kind),
                        opt_text(r.reporter_agent_id),
                        opt_text(r.rule),
                        if r.conflict { "TRUE" } else { "FALSE" },
                        instant(r.created_at, backend),
                    )
                })
                .collect();
            format!(
                "INSERT INTO {qualifier}.device_availability_transitions ({columns}) VALUES\n{}",
                values.join(",\n")
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, Utc};

    fn anchor() -> Anchor {
        Anchor::for_run(
            DateTime::parse_from_rfc3339("2030-03-04T15:16:17Z")
                .unwrap()
                .with_timezone(&Utc),
        )
    }

    /// The table's identity is (device_uid, changed_at, to_state) and every row is a real
    /// change; a row breaking either would be rejected or merged by one backend only.
    #[test]
    fn rows_are_distinct_changes_that_chain_and_exercise_nulls() {
        let rows = rows(anchor());
        assert_eq!(rows.len(), DEVICES.len() * PER_DEVICE as usize);
        assert!(rows.iter().all(|r| r.to_state != r.from_state));
        let times: std::collections::BTreeSet<i64> = rows
            .iter()
            .map(|r| r.changed_at.timestamp_micros())
            .collect();
        assert_eq!(times.len(), rows.len());
        for pair in rows.windows(2) {
            if pair[0].device_uid == pair[1].device_uid {
                assert_eq!(pair[1].from_state, pair[0].to_state);
                assert_eq!(pair[1].from_since, Some(pair[0].changed_at));
            }
        }
        assert!(rows.iter().any(|r| r.from_since.is_none()));
        assert!(rows.iter().any(|r| r.source_kind.is_none()));
        assert!(rows.iter().any(|r| r.conflict));
        // Everything lies inside {window_main}, [A, A+5h-30s].
        let end = anchor().at(5 * 3600 - 30);
        assert!(rows.iter().all(|r| r.changed_at < end));
    }
}
