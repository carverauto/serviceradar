use std::{path::Path, time::Duration};

use anyhow::{Context, Result};
use serviceradar_integration_db::{
    connect_admin,
    connection_observer::{
        capacity, completion_status, emit_startup_terminal_summary, emit_terminal_summary,
        epoch_millis, remaining_until, sample, terminal_summary_line, within_deadline, Capacity,
        ObserverArgs, Peaks, Quiescence, SampleWindow, SAMPLE_INTERVAL_MS,
    },
    database_name,
};

#[tokio::main]
async fn main() -> Result<()> {
    let args = ObserverArgs::parse(std::env::args())?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(args.max_seconds);
    let run_prefix = database_name()?;
    let start_ms = epoch_millis()?;
    let mut peaks = Peaks::default();
    let (client, _connection) =
        match within_deadline(deadline, connect_admin(None), "admin connection").await {
            Ok(connection) => connection,
            Err(error) => return finish_startup(Err(error), peaks, &run_prefix, start_ms),
        };
    let capacity = match within_deadline(deadline, capacity(&client), "connection capacity").await {
        Ok(capacity) => capacity,
        Err(error) => return finish_startup(Err(error), peaks, &run_prefix, start_ms),
    };
    if let Err(error) = capacity.validate_required_pool_slots(args.required_pool_slots) {
        return finish(Err(error), peaks, &run_prefix, start_ms, capacity);
    }
    let mut quiescence = Quiescence::default();
    let mut quiescent = false;

    if let Err(error) = record_sample(deadline, &client, &run_prefix, &mut peaks).await {
        return finish(Err(error), peaks, &run_prefix, start_ms, capacity);
    }
    if let Err(error) = write_marker(&args.ready_file) {
        return finish(Err(error), peaks, &run_prefix, start_ms, capacity);
    }

    loop {
        if remaining_until(deadline).is_err() {
            return finish(
                completion_status(quiescent, false, true).map_err(anyhow::Error::msg),
                peaks,
                &run_prefix,
                start_ms,
                capacity,
            );
        }

        if args.stop_file.exists() {
            return finish(
                completion_status(quiescent, true, false).map_err(anyhow::Error::msg),
                peaks,
                &run_prefix,
                start_ms,
                capacity,
            );
        }

        if let Err(error) = within_deadline(
            deadline,
            async {
                tokio::time::sleep(Duration::from_millis(SAMPLE_INTERVAL_MS)).await;
                Ok(())
            },
            "sample interval",
        )
        .await
        {
            return finish(Err(error), peaks, &run_prefix, start_ms, capacity);
        }
        let counts = match within_deadline(
            deadline,
            sample(&client, &run_prefix),
            "sample pg_stat_activity",
        )
        .await
        {
            Ok(counts) => counts,
            Err(error) => return finish(Err(error), peaks, &run_prefix, start_ms, capacity),
        };
        peaks.record(counts.run_scoped, counts.fixture_wide);

        if quiescence.record(args.suite_complete_file.exists(), counts.run_scoped) && !quiescent {
            if let Err(error) = write_marker(&args.quiescent_file) {
                return finish(Err(error), peaks, &run_prefix, start_ms, capacity);
            }
            quiescent = true;
        }
    }
}

async fn record_sample(
    deadline: tokio::time::Instant,
    client: &tokio_postgres::Client,
    run_prefix: &str,
    peaks: &mut Peaks,
) -> Result<()> {
    let counts = within_deadline(
        deadline,
        sample(client, run_prefix),
        "sample pg_stat_activity",
    )
    .await?;
    peaks.record(counts.run_scoped, counts.fixture_wide);
    Ok(())
}

fn write_marker(path: &Path) -> Result<()> {
    std::fs::write(path, b"").with_context(|| format!("write observer marker {}", path.display()))
}

fn finish(
    status: Result<()>,
    peaks: Peaks,
    run_prefix: &str,
    start_ms: u64,
    capacity: Capacity,
) -> Result<()> {
    let end_ms = epoch_millis().unwrap_or(start_ms);
    emit_terminal_summary(
        status,
        terminal_summary_line(
            peaks,
            run_prefix,
            SampleWindow { start_ms, end_ms },
            capacity,
        ),
        |line| println!("{line}"),
    )
}

fn finish_startup(status: Result<()>, peaks: Peaks, run_prefix: &str, start_ms: u64) -> Result<()> {
    let end_ms = epoch_millis().unwrap_or(start_ms);
    emit_startup_terminal_summary(
        status,
        peaks,
        run_prefix,
        SampleWindow { start_ms, end_ms },
        |line| println!("{line}"),
    )
}
