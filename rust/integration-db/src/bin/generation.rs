//! Explicit keyed lifecycle entrypoints. Legacy prepare_template retains its text interface.
use anyhow::{bail, Context, Result};
use serviceradar_integration_db::{self as db, generation};

#[tokio::main]
async fn main() -> Result<()> {
    let (manifest, policy) = generation::declared_inputs()?;
    let operation = std::env::args()
        .nth(1)
        .context("missing generation operation")?;
    if operation == "cleanup" {
        println!(
            "{}",
            serde_json::to_string(&generation::cleanup(&policy).await?)?
        );
        return Ok(());
    }
    let lease_id = db::database_name()?;
    match operation.as_str() {
        "prepare" => {
            let state =
                generation::prepare(&manifest, &policy, &lease_id, &db::database_owner()?).await?;
            println!("{}", serde_json::to_string(&state)?);
        }
        "clone" => {
            let owner = db::database_owner()?;
            let shards = std::env::var("SERVICERADAR_TEST_DB_SHARDS")
                .context("declared clone shard list missing")?;
            let shards: Vec<&str> = shards.split(',').collect();
            for shard in shards {
                let target = db::shard_database_name(shard)?;
                generation::clone_generation(&manifest, &policy, &lease_id, &target, &owner)
                    .await?;
            }
            println!(
                "{}",
                serde_json::json!({"status":"cloned","digest":manifest.digest,"lease_id":lease_id})
            );
        }
        "release" => {
            generation::release_lease(&manifest, &policy, &lease_id).await?;
            println!(
                "{}",
                serde_json::json!({"status":"released","digest":manifest.digest,"lease_id":lease_id})
            );
        }
        other => bail!("unknown generation operation {other:?}"),
    }
    Ok(())
}
