use std::{path::Path, time::Duration};

use anyhow::{Context, Result};
use serviceradar_integration_db::{
    connect_admin,
    connection_observer::{
        capacity, completion_status, epoch_millis, remaining_until, sample, within_deadline,
        ObserverArgs, Peaks, Quiescence, SampleWindow, SAMPLE_INTERVAL_MS,
    },
    database_name,
};

#[tokio::main]
async fn main() -> Result<()> {
    let args = ObserverArgs::parse(std::env::args())?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(args.max_seconds);
    let run_prefix = database_name()?;
    let (client, _connection) =
        within_deadline(deadline, connect_admin(None), "admin connection").await?;
    let capacity = within_deadline(deadline, capacity(&client), "connection capacity").await?;
    let start_ms = epoch_millis()?;
    let mut peaks = Peaks::default();
    let mut quiescence = Quiescence::default();
    let mut quiescent = false;

    record_sample(deadline, &client, &run_prefix, &mut peaks).await?;
    write_marker(&args.ready_file)?;

    loop {
        if remaining_until(deadline).is_err() {
            let status = completion_status(quiescent, false, true);
            print_summary(peaks, &run_prefix, start_ms, capacity)?;
            return status.map_err(anyhow::Error::msg);
        }

        if args.stop_file.exists() {
            let status = completion_status(quiescent, true, false);
            print_summary(peaks, &run_prefix, start_ms, capacity)?;
            return status.map_err(anyhow::Error::msg);
        }

        within_deadline(
            deadline,
            async {
                tokio::time::sleep(Duration::from_millis(SAMPLE_INTERVAL_MS)).await;
                Ok(())
            },
            "sample interval",
        )
        .await?;
        let counts = within_deadline(
            deadline,
            sample(&client, &run_prefix),
            "sample pg_stat_activity",
        )
        .await?;
        peaks.record(counts.run_scoped, counts.fixture_wide);

        if quiescence.record(args.suite_complete_file.exists(), counts.run_scoped) && !quiescent {
            write_marker(&args.quiescent_file)?;
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

fn print_summary(
    peaks: Peaks,
    run_prefix: &str,
    start_ms: u64,
    capacity: serviceradar_integration_db::connection_observer::Capacity,
) -> Result<()> {
    let end_ms = epoch_millis()?;
    println!(
        "SERVICERADAR_CONNECTION_OBSERVER {}",
        peaks.summary_json(run_prefix, SampleWindow { start_ms, end_ms }, capacity)
    );
    Ok(())
}
