//! Synthetic registry qualification. Run ONLY in the guarded in-cluster workflow.
//! This exercises independent PostgreSQL sessions and schema artifacts; the real
//! Elixir full-replay/baseline qualification is a separate rollout prerequisite.
use anyhow::{ensure, Context, Result};
use serviceradar_integration_db::{self as db, generation};
use sha2::{Digest, Sha256};
use tokio_postgres::Client;

const PREFIX: &str = "elixir/serviceradar_core/priv/repo/migrations/";

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn manifest_hash(inputs: &[generation::Input], domain: &[u8]) -> String {
    let mut bytes = domain.to_vec();
    bytes.extend((inputs.len() as u64).to_be_bytes());
    for input in inputs {
        bytes.extend((input.path.len() as u64).to_be_bytes());
        bytes.extend(input.path.as_bytes());
        for i in (0..64).step_by(2) {
            bytes.push(u8::from_str_radix(&input.sha256[i..i + 2], 16).unwrap());
        }
    }
    hash(&bytes)
}

fn manifest(run: &str, branch: &str) -> generation::Manifest {
    let mut inputs = vec![generation::Input {
        path: format!("{PREFIX}1_synthetic.exs"),
        // This input is invented here, never copied from a fixture deployment.
        sha256: hash(format!("synthetic-schema-base-{run}").as_bytes()),
    }];
    let migration_versions = match branch {
        // Branch A models the staging-equivalent subset. Branch B has that exact
        // history plus one invented migration, reproducing the shape that poisoned
        // the mutable singleton when an unmerged checkout advanced it first.
        "a" => vec![1],
        "b" => {
            inputs.push(generation::Input {
                path: format!("{PREFIX}2_synthetic.exs"),
                sha256: hash(format!("synthetic-schema-extra-{run}").as_bytes()),
            });
            vec![1, 2]
        }
        // The failed builder edits migration 1 without changing its version. Its
        // distinct manifest must never reuse branch A's ready generation.
        "failed" => {
            inputs[0].sha256 = hash(format!("synthetic-schema-edited-{run}").as_bytes());
            vec![1]
        }
        _ => panic!("unsupported synthetic branch"),
    };
    let digest = manifest_hash(&inputs, b"serviceradar.schema-template.v1\0");
    let included_through = 1;
    let covered_count = migration_versions.partition_point(|version| *version <= included_through);
    let covered = manifest_hash(
        &inputs[..covered_count],
        b"serviceradar.schema-template.covered-migrations.v1\0",
    );
    generation::Manifest {
        version: 1,
        database: generation::database_for_digest(&digest).unwrap(),
        digest,
        inputs,
        migration_versions,
        covered_migrations: generation::CoveredMigrations {
            included_through,
            digest: covered,
        },
    }
}

#[test]
fn synthetic_manifest_contracts_are_valid() {
    for branch in ["a", "b", "failed"] {
        manifest("example01", branch).validate().unwrap();
    }
}

async fn exists(admin: &Client, database: &str) -> Result<bool> {
    Ok(admin
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)",
            &[&database],
        )
        .await?
        .get(0))
}

async fn lock(admin: &Client, manifest: &generation::Manifest) -> Result<()> {
    admin
        .query_one(
            "SELECT pg_advisory_lock($1::int,$2::int)",
            &[
                &generation::GENERATION_NAMESPACE,
                &generation::lock_key(&manifest.digest)?,
            ],
        )
        .await?;
    Ok(())
}

async fn unlock(admin: &Client, manifest: &generation::Manifest) -> Result<()> {
    let unlocked: bool = admin
        .query_one(
            "SELECT pg_advisory_unlock($1::int,$2::int)",
            &[
                &generation::GENERATION_NAMESPACE,
                &generation::lock_key(&manifest.digest)?,
            ],
        )
        .await?
        .get(0);
    ensure!(unlocked, "qualification did not own generation lock");
    Ok(())
}

/// A deliberately tiny synthetic builder using the same session lock and token
/// fencing as Elixir. It cannot qualify the application migration implementation.
async fn publish(manifest: &generation::Manifest, branch: &str) -> Result<i64> {
    ensure!(matches!(branch, "a" | "b"), "invalid synthetic branch");
    let (admin, driver) = db::connect_admin(Some("postgres")).await?;
    admin.batch_execute("SET statement_timeout='30s'").await?;
    lock(&admin, manifest).await?;
    let token: i64 = admin.query_one("UPDATE sr_template_registry.generations SET builder_token=nextval('sr_template_registry.builder_tokens') WHERE digest=$1 AND state='building' RETURNING builder_token", &[&manifest.digest]).await?.get(0);
    let (candidate, candidate_driver) = db::connect_admin(Some(&manifest.database)).await?;
    candidate.batch_execute(&format!("CREATE TABLE public.generation_probe (branch_{branch} integer NOT NULL); INSERT INTO public.generation_probe VALUES (7); CREATE TABLE platform.schema_migrations(version bigint PRIMARY KEY)")).await?;
    for version in &manifest.migration_versions {
        candidate
            .execute(
                "INSERT INTO platform.schema_migrations(version) VALUES($1)",
                &[version],
            )
            .await?;
    }
    let ledger: Vec<i64> = candidate
        .query(
            "SELECT version FROM platform.schema_migrations ORDER BY version",
            &[],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    ensure!(
        ledger == manifest.migration_versions,
        "synthetic ledger differs before publication"
    );
    // Publication must quiesce a real scheduler, not pass merely because the
    // launcher has not started one yet. Extension installation can race this
    // check and start the scheduler first; in that case start_background_workers
    // correctly returns false because there is nothing left to start. Preserve
    // the capacity gate by requiring a positive start acknowledgement only when
    // the scheduler was not already observable.
    let scheduler_was_running: bool = admin
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND backend_type='TimescaleDB Background Worker Scheduler')",
            &[&manifest.database],
        )
        .await?
        .get(0);
    if !scheduler_was_running {
        let started: bool = candidate
            .query_one(
                "SELECT _timescaledb_functions.start_background_workers()",
                &[],
            )
            .await?
            .get(0);
        ensure!(started, "synthetic scheduler start was not acknowledged");
    }
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let active: bool = admin.query_one(
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND backend_type='TimescaleDB Background Worker Scheduler')",
            &[&manifest.database],
        ).await?.get(0);
        if active {
            break;
        }
        ensure!(
            tokio::time::Instant::now() < deadline,
            "qualification never observed a scheduler"
        );
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    // The database identifier is validated by the production manifest reader.
    manifest.validate()?;
    admin
        .batch_execute(&format!(
            "ALTER DATABASE \"{}\" ALLOW_CONNECTIONS false",
            manifest.database
        ))
        .await?;
    generation::quiesce_candidate_workers(&candidate, manifest).await?;
    drop(candidate);
    candidate_driver
        .await
        .context("closing synthetic candidate session")?;
    let (_, policy) = generation::declared_inputs()?;
    generation::wait_for_no_connections(&admin, &manifest.database, &policy).await?;
    let changed = admin.execute("UPDATE sr_template_registry.generations SET state='ready',last_used_at=clock_timestamp() WHERE digest=$1 AND builder_token=$2 AND state='building'", &[&manifest.digest,&token]).await?;
    ensure!(changed == 1, "publication lost its builder fence");
    // A stale builder must not be able to publish again.
    ensure!(admin.execute("UPDATE sr_template_registry.generations SET state='ready' WHERE digest=$1 AND builder_token=$2 AND state='building'", &[&manifest.digest,&(token-1)]).await?==0,"stale builder published");
    unlock(&admin, manifest).await?;
    drop(admin);
    driver.await?;
    Ok(token)
}

async fn verify_clone(database: &str, branch: &str, expected_versions: &[i64]) -> Result<()> {
    let (client, driver) = db::connect_admin(Some(database)).await?;
    let ordinary: bool = client.query_one(
        "SELECT datallowconn AND NOT datistemplate FROM pg_database WHERE datname=current_database()", &[]
    ).await?.get(0);
    ensure!(ordinary, "clone inherited sealed/template flags");
    let restoring: String = client
        .query_one("SHOW timescaledb.restoring", &[])
        .await?
        .get(0);
    ensure!(
        restoring == "off",
        "clone has Timescale restore mode enabled"
    );
    let columns: Vec<String> = client.query("SELECT column_name::text FROM information_schema.columns WHERE table_schema='public' AND table_name='generation_probe' ORDER BY ordinal_position", &[]).await?.iter().map(|r|r.get(0)).collect();
    ensure!(
        columns == vec![format!("branch_{branch}")],
        "clone has another generation's schema: {columns:?}"
    );
    let count: i64 = client
        .query_one("SELECT count(*) FROM public.generation_probe", &[])
        .await?
        .get(0);
    ensure!(count == 1, "clone did not carry synthetic data artifact");
    let ledger: Vec<i64> = client
        .query(
            "SELECT version FROM platform.schema_migrations ORDER BY version",
            &[],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    ensure!(ledger == expected_versions, "clone ledger mismatch");
    drop(client);
    driver.await?;
    Ok(())
}

async fn expire(
    admin: &Client,
    manifest: &generation::Manifest,
    policy: &generation::Policy,
    leases: bool,
) -> Result<()> {
    admin.execute("UPDATE sr_template_registry.generations SET last_used_at=clock_timestamp()-make_interval(secs=>$2::double precision) WHERE digest=$1", &[&manifest.digest,&((policy.retention_seconds+1) as f64)]).await?;
    if leases {
        admin.execute("UPDATE sr_template_registry.leases SET expires_at=clock_timestamp()-interval '1 second' WHERE digest=$1", &[&manifest.digest]).await?;
    }
    Ok(())
}

async fn recover_interrupted_build(
    admin: &Client,
    manifest: &generation::Manifest,
    policy: &generation::Policy,
    lease: &str,
    owner: &str,
) -> Result<()> {
    let state = admin
        .query_opt(
            "SELECT state FROM sr_template_registry.generations WHERE digest=$1",
            &[&manifest.digest],
        )
        .await?
        .map(|row| row.get::<_, String>(0));
    if state.as_deref() != Some("building") {
        return Ok(());
    }

    // An explicit same-run retry may have left one of this test's invented
    // generations unpublished. Exercise the production recovery path before
    // starting the fresh assertions, then remove only that exact registered
    // digest. A ready generation is deliberately not handled here: reusing a
    // run that already published still fails the fresh-run assertion below.
    let recovered = generation::prepare(manifest, policy, lease, owner).await?;
    ensure!(
        recovered.status == "needs_migration",
        "interrupted qualification generation was not recovered as a builder"
    );
    generation::release_lease(manifest, policy, lease).await?;
    expire(admin, manifest, policy, true).await?;
    ensure!(
        generation::cleanup_digest(&manifest.digest, policy).await?,
        "recovered qualification generation was not reclaimed"
    );
    ensure!(
        !exists(admin, &manifest.database).await?,
        "recovered qualification database survived scoped cleanup"
    );
    Ok(())
}

async fn qualify() -> Result<()> {
    let (_, policy) = generation::declared_inputs()?;
    let lease = db::database_name()?;
    let owner = db::database_owner()?;
    let a = manifest(&lease, "a");
    let b = manifest(&lease, "b");
    let failed = manifest(&lease, "failed");
    ensure!(
        b.inputs.starts_with(&a.inputs)
            && b.migration_versions.starts_with(&a.migration_versions)
            && b.migration_versions.len() == a.migration_versions.len() + 1,
        "synthetic divergence must retain a staging-equivalent subset"
    );
    ensure!(
        failed.migration_versions == a.migration_versions
            && failed.digest != a.digest
            && failed.database != a.database,
        "same-version migration edit did not invalidate generation identity"
    );
    let clone_a = db::shard_database_name("gen_a")?;
    let clone_b = db::shard_database_name("gen_b")?;
    let (admin, driver) = db::connect_admin(Some("postgres")).await?;
    admin.batch_execute("SET statement_timeout='30s'").await?;

    // The workflow's guarded run-ID override exists solely to resume its own
    // interrupted synthetic run. Clear any matching unpublished candidate
    // through normal fenced recovery and exact-digest cleanup before replaying
    // the complete qualification sequence.
    for manifest in [&a, &b, &failed] {
        recover_interrupted_build(&admin, manifest, &policy, &lease, &owner).await?;
    }

    ensure!(
        generation::quiesce_candidate_workers(&admin, &a)
            .await
            .is_err(),
        "worker shutdown accepted the coordination database"
    );

    let cold = generation::prepare(&a, &policy, &lease, &owner).await?;
    ensure!(
        cold.status == "needs_migration",
        "qualification requires a unique fresh run id"
    );
    let published_token = publish(&a, "a").await?;
    // Independent sessions overlap warm reuse with construction of another digest.
    let (warm, other) = tokio::try_join!(
        generation::prepare(&a, &policy, &lease, &owner),
        generation::prepare(&b, &policy, &lease, &owner)
    )?;
    ensure!(
        warm.status == "ready" && warm.builder_token == published_token,
        "same digest was rebuilt"
    );
    ensure!(
        other.status == "needs_migration" && b.database != a.database,
        "divergent identity reused"
    );
    publish(&b, "b").await?;
    tokio::try_join!(
        generation::clone_generation(&a, &policy, &lease, &clone_a, &owner),
        generation::clone_generation(&b, &policy, &lease, &clone_b, &owner)
    )?;
    tokio::try_join!(
        verify_clone(&clone_a, "a", &a.migration_versions),
        verify_clone(&clone_b, "b", &b.migration_versions)
    )?;

    let mut tight = policy.clone();
    tight.max_generations = 1;
    tight.max_concurrent_builders = 1;
    let error = generation::prepare(&failed, &tight, &lease, &owner)
        .await
        .expect_err("capacity must fail");
    ensure!(
        error.to_string().contains("capacity"),
        "unexpected capacity error: {error:#}"
    );
    ensure!(
        !exists(&admin, &failed.database).await?,
        "capacity failure created candidate"
    );
    verify_clone(&clone_a, "a", &a.migration_versions).await?;

    let partial = generation::prepare(&failed, &policy, &lease, &owner).await?;
    let (candidate, candidate_driver) = db::connect_admin(Some(&failed.database)).await?;
    candidate
        .batch_execute("CREATE TABLE public.failed_build_marker(id integer)")
        .await?;
    let scheduler_started: bool = candidate
        .query_one(
            "SELECT _timescaledb_functions.start_background_workers()",
            &[],
        )
        .await?
        .get(0);
    ensure!(
        scheduler_started,
        "failed-builder scheduler start was not acknowledged"
    );
    ensure!(
        generation::clone_generation(&failed, &policy, &lease, &clone_a, &owner)
            .await
            .is_err(),
        "incomplete generation cloned"
    );
    verify_clone(&clone_a, "a", &a.migration_versions).await?;
    let busy_recovery = generation::prepare(&failed, &policy, &lease, &owner)
        .await
        .expect_err("recovery accepted a live client backend");
    ensure!(
        busy_recovery.to_string().contains("active client"),
        "unexpected busy recovery error: {busy_recovery:#}"
    );
    drop(candidate);
    candidate_driver.await?;
    let recovered = generation::prepare(&failed, &policy, &lease, &owner).await?;
    ensure!(
        recovered.builder_token > partial.builder_token,
        "recovery did not fence failed owner"
    );
    let (candidate, candidate_driver) = db::connect_admin(Some(&failed.database)).await?;
    let removed: bool = candidate
        .query_one(
            "SELECT to_regclass('public.failed_build_marker') IS NULL",
            &[],
        )
        .await?
        .get(0);
    ensure!(removed, "failed schema survived recovery");
    expire(&admin, &failed, &policy, true).await?;
    ensure!(
        !generation::cleanup_digest(&failed.digest, &policy).await?,
        "cleanup dropped connected candidate"
    );
    drop(candidate);
    candidate_driver.await?;
    ensure!(
        generation::cleanup_digest(&failed.digest, &policy).await?,
        "inactive failed candidate was not reclaimed"
    );

    expire(&admin, &a, &policy, false).await?;
    ensure!(
        !generation::cleanup_digest(&a.digest, &policy).await?,
        "cleanup dropped live lease"
    );
    expire(&admin, &a, &policy, true).await?;
    lock(&admin, &a).await?;
    ensure!(
        !generation::cleanup_digest(&a.digest, &policy).await?,
        "cleanup ignored clone ownership lock"
    );
    unlock(&admin, &a).await?;
    generation::clone_generation(&a, &policy, &lease, &clone_a, &owner).await?;
    let live: bool=admin.query_one("SELECT expires_at>clock_timestamp() FROM sr_template_registry.leases WHERE digest=$1 AND lease_id=$2",&[&a.digest,&lease]).await?.get(0);
    ensure!(live, "clone did not renew lease");
    verify_clone(&clone_a, "a", &a.migration_versions).await?;
    ensure!(
        !generation::cleanup_digest(&a.digest, &policy).await?,
        "cleanup removed just-cloned generation"
    );

    for m in [&a, &b] {
        generation::release_lease(m, &policy, &lease).await?;
        expire(&admin, m, &policy, true).await?;
        ensure!(
            generation::cleanup_digest(&m.digest, &policy).await?,
            "expired generation not reclaimed"
        );
        ensure!(
            !exists(&admin, &m.database).await?,
            "template still exists after cleanup"
        );
        let registered: bool = admin
            .query_one(
                "SELECT EXISTS(SELECT 1 FROM sr_template_registry.generations WHERE digest=$1)",
                &[&m.digest],
            )
            .await?
            .get(0);
        ensure!(!registered, "cleanup left registry row");
    }
    // Physical clones survive source cleanup and retain their divergent schemas.
    tokio::try_join!(
        verify_clone(&clone_a, "a", &a.migration_versions),
        verify_clone(&clone_b, "b", &b.migration_versions)
    )?;
    for database in [&clone_a, &clone_b] {
        db::teardown(database).await?;
        ensure!(
            !exists(&admin, database).await?,
            "disposable teardown left clone"
        );
    }
    ensure!(
        !exists(&admin, &failed.database).await?,
        "failed candidate reappeared"
    );
    drop(admin);
    driver.await?;
    Ok(())
}

#[test]
fn qualifies_synthetic_generation_lifecycle() {
    tokio::runtime::Runtime::new().unwrap().block_on(async {
        tokio::time::timeout(std::time::Duration::from_secs(600), qualify())
            .await
            .expect("synthetic qualification deadline exceeded")
            .expect("synthetic qualification failed; inspect owned run generations before cleanup");
    });
}
