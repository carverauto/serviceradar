//! Immutable schema generations. The shared SQL contract is `../registry.sql`.
//!
//! All coordination happens on postgres: advisory locks are database-local, not
//! cluster-wide. A building database is private by registry state. The Elixir
//! migrator holds this same session lock continuously through mutation/publication.

use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::task::JoinHandle;
use tokio_postgres::{Client, Row};

use crate::{assert_disposable, connect_admin, install_extensions, quote_ident};

pub const REGISTRY_SQL: &str = include_str!("../registry.sql");
pub const GENERATION_NAMESPACE: i32 = 1_397_904_460;
pub const CAPACITY_NAMESPACE: i32 = 1_397_904_461;
pub const MANIFEST_RUNFILE: &str = "build/schema_template/manifest.json";
pub const POLICY_RUNFILE: &str = "build/schema_template/policy.json";
const MIGRATIONS_PREFIX: &str = "elixir/serviceradar_core/priv/repo/migrations/";
const IDENTITY_DOMAIN: &[u8] = b"serviceradar.schema-template.v1\0";
const COVERED_DOMAIN: &[u8] = b"serviceradar.schema-template.covered-migrations.v1\0";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub version: u32,
    pub digest: String,
    pub database: String,
    pub inputs: Vec<Input>,
    pub migration_versions: Vec<i64>,
    pub covered_migrations: CoveredMigrations,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CoveredMigrations {
    pub included_through: i64,
    pub digest: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Input {
    pub path: String,
    pub sha256: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub version: u32,
    pub construction_mode: String,
    pub max_generations: i64,
    pub max_concurrent_builders: i64,
    pub max_total_bytes: i64,
    pub retention_seconds: i64,
    pub lease_seconds: i64,
    pub lock_timeout_seconds: i64,
}

impl Policy {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.version == 1, "unsupported generation policy version");
        ensure!(
            self.construction_mode == "full_replay",
            "only qualified full_replay construction is supported"
        );
        for (name, value) in [
            ("max_generations", self.max_generations),
            ("max_concurrent_builders", self.max_concurrent_builders),
            ("max_total_bytes", self.max_total_bytes),
            ("retention_seconds", self.retention_seconds),
            ("lease_seconds", self.lease_seconds),
            ("lock_timeout_seconds", self.lock_timeout_seconds),
        ] {
            ensure!(
                value > 0 && value <= i64::from(i32::MAX) * 1024,
                "{name} must be positive and bounded"
            );
        }
        ensure!(
            self.max_concurrent_builders <= self.max_generations,
            "builder capacity exceeds generation capacity"
        );
        Ok(())
    }
}

fn valid_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn input_digest(inputs: &[Input]) -> String {
    digest_inputs(
        inputs.iter().collect::<Vec<_>>().as_slice(),
        IDENTITY_DOMAIN,
    )
}

fn digest_inputs(inputs: &[&Input], domain: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    hasher.update((inputs.len() as u64).to_be_bytes());
    for input in inputs {
        hasher.update((input.path.len() as u64).to_be_bytes());
        hasher.update(input.path.as_bytes());
        // validate() checks lowercase hex before this function is called.
        for offset in (0..64).step_by(2) {
            hasher
                .update([u8::from_str_radix(&input.sha256[offset..offset + 2], 16)
                    .expect("validated hex")]);
        }
    }
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn database_for_digest(digest: &str) -> Result<String> {
    ensure!(
        valid_digest(digest),
        "digest must be 64 lowercase hex characters"
    );
    Ok(format!("sr_tpl_{}", &digest[..48]))
}

/// Cross-language wire contract: first 32 digest bits interpreted as signed int32.
/// Collisions serialize unrelated digests; registry full-identity checks prevent reuse.
pub fn lock_key(digest: &str) -> Result<i32> {
    database_for_digest(digest)?;
    Ok(u32::from_str_radix(&digest[..8], 16)? as i32)
}

impl Manifest {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.version == 1, "unsupported manifest version");
        ensure!(
            self.database == database_for_digest(&self.digest)?,
            "manifest database/digest mismatch"
        );
        ensure!(!self.inputs.is_empty(), "empty schema input inventory");
        ensure!(
            self.covered_migrations.included_through > 0
                && valid_digest(&self.covered_migrations.digest),
            "invalid covered migration metadata"
        );
        let mut previous = None;
        for input in &self.inputs {
            ensure!(valid_digest(&input.sha256), "invalid input hash");
            ensure!(
                !input.path.is_empty()
                    && input
                        .path
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"_./-".contains(&b))
                    && input
                        .path
                        .split('/')
                        .all(|part| !part.is_empty() && part != "." && part != ".."),
                "input must be a normalized relative path"
            );
            ensure!(
                previous.is_none_or(|path: &str| path < input.path.as_str()),
                "input paths must be sorted and unique"
            );
            previous = Some(input.path.as_str());
        }
        ensure!(
            input_digest(&self.inputs) == self.digest,
            "manifest content digest mismatch"
        );
        ensure!(
            !self.migration_versions.is_empty()
                && self.migration_versions.iter().all(|v| *v > 0)
                && self
                    .migration_versions
                    .windows(2)
                    .all(|pair| pair[0] < pair[1]),
            "migration versions must be nonempty, positive, sorted and unique"
        );
        let mut versions = Vec::new();
        let mut covered = Vec::new();
        for input in &self.inputs {
            let Some(filename) = input.path.strip_prefix(MIGRATIONS_PREFIX) else {
                continue;
            };
            let (digits, suffix) = filename
                .split_once('_')
                .context("malformed migration filename")?;
            let suffix = suffix
                .strip_suffix(".exs")
                .context("malformed migration extension")?;
            ensure!(
                !digits.is_empty()
                    && digits.bytes().all(|b| b.is_ascii_digit())
                    && !suffix.is_empty()
                    && suffix
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'_'),
                "malformed migration filename"
            );
            let version: i64 = digits.parse().context("migration version outside bigint")?;
            ensure!(version > 0, "migration version must be positive");
            versions.push(version);
            if version <= self.covered_migrations.included_through {
                covered.push(input);
            }
        }
        versions.sort_unstable();
        ensure!(
            versions == self.migration_versions,
            "manifest ledger differs from migration input paths"
        );
        ensure!(
            digest_inputs(&covered, COVERED_DOMAIN) == self.covered_migrations.digest,
            "covered migration content digest mismatch"
        );
        Ok(())
    }

    pub fn from_json(json: &str) -> Result<Self> {
        let manifest: Self = serde_json::from_str(json).context("invalid generation manifest")?;
        manifest.validate()?;
        Ok(manifest)
    }
}

pub fn declared_inputs() -> Result<(Manifest, Policy)> {
    let manifest = Manifest::from_json(&std::fs::read_to_string(crate::config::runfile(
        MANIFEST_RUNFILE,
    )?)?)?;
    let policy: Policy = serde_json::from_str(&std::fs::read_to_string(crate::config::runfile(
        POLICY_RUNFILE,
    )?)?)?;
    policy.validate()?;
    Ok((manifest, policy))
}

/// Own the driving task too: cancellation or any early error releases session locks.
struct Session {
    client: Client,
    driver: JoinHandle<()>,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.driver.abort();
    }
}

impl Session {
    async fn connect(policy: &Policy) -> Result<Self> {
        policy.validate()?;
        let (client, driver) = connect_admin(Some("postgres")).await?;
        let session = Self { client, driver };
        let timeout = format!("{}s", policy.lock_timeout_seconds);
        session
            .client
            .query_one(
                "SELECT set_config('statement_timeout', $1, false)",
                &[&timeout],
            )
            .await?;
        Ok(session)
    }

    async fn lock(&self, namespace: i32, key: i32, policy: &Policy) -> Result<()> {
        let deadline =
            tokio::time::Instant::now() + Duration::from_secs(policy.lock_timeout_seconds as u64);
        loop {
            if self.try_lock(namespace, key).await? {
                return Ok(());
            }
            ensure!(
                tokio::time::Instant::now() < deadline,
                "timed out waiting for generation coordination lock ({namespace}, {key})"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    async fn try_lock(&self, namespace: i32, key: i32) -> Result<bool> {
        Ok(self
            .client
            .query_one(
                "SELECT pg_try_advisory_lock($1::int, $2::int)",
                &[&namespace, &key],
            )
            .await?
            .get(0))
    }
}

pub async fn initialize(policy: &Policy) -> Result<()> {
    let session = Session::connect(policy).await?;
    session.lock(CAPACITY_NAMESPACE, 0, policy).await?;
    let exists: bool = session
        .client
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='sr_template_registry')",
            &[],
        )
        .await?
        .get(0);
    if exists {
        // Never repair, stamp, or alter an existing schema while discovering its
        // version. A failed fresh transaction leaves no partial registry behind.
        validate_registry(&session.client)
            .await
            .context("incompatible or partial generation registry; no changes made")?;
    } else {
        session.client.batch_execute("BEGIN").await?;
        session
            .client
            .batch_execute(REGISTRY_SQL)
            .await
            .context("creating fresh generation registry")?;
        validate_registry(&session.client).await?;
        session.client.batch_execute("COMMIT").await?;
    }
    Ok(())
}

// Ignore only PostgreSQL deparser punctuation and explicit text casts. Do not
// normalize identifiers, operators, literal contents or referential actions.
fn normalized_definition(definition: &str) -> String {
    definition
        .replace("::text", "")
        .chars()
        .filter(|ch| !ch.is_ascii_whitespace() && !matches!(ch, '(' | ')' | '"'))
        .collect()
}

async fn validate_registry(client: &Client) -> Result<()> {
    let relations: Vec<(String,String)> = client.query(
        "SELECT c.relname::text,c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='sr_template_registry' AND c.relkind NOT IN ('i','I') ORDER BY c.relname", &[]
    ).await?.iter().map(|r|(r.get(0),r.get(1))).collect();
    ensure!(
        relations
            == [
                ("builder_tokens", "S"),
                ("generations", "r"),
                ("leases", "r"),
                ("metadata", "r")
            ]
            .map(|(a, b)| (a.to_owned(), b.to_owned())),
        "registry relation inventory differs from version 1"
    );
    let columns: Vec<(String,String,String,bool,Option<String>)> = client.query(
        "SELECT c.relname::text,a.attname::text,format_type(a.atttypid,a.atttypmod),a.attnotnull,pg_get_expr(d.adbin,d.adrelid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum WHERE n.nspname='sr_template_registry' AND c.relkind='r' AND a.attnum>0 AND NOT a.attisdropped ORDER BY c.relname,a.attnum", &[]
    ).await?.iter().map(|r|(r.get(0),r.get(1),r.get(2),r.get(3),r.get::<_,Option<String>>(4).map(|v|normalized_definition(&v)))).collect();
    let expected = [
        ("generations", "digest", "text", None),
        ("generations", "manifest", "text", None),
        ("generations", "database_name", "text", None),
        ("generations", "builder_token", "bigint", None),
        ("generations", "state", "text", None),
        ("generations", "server_major", "integer", None),
        ("generations", "extensions", "text", None),
        (
            "generations",
            "created_at",
            "timestamp with time zone",
            Some("clock_timestamp()"),
        ),
        (
            "generations",
            "last_used_at",
            "timestamp with time zone",
            Some("clock_timestamp()"),
        ),
        ("leases", "digest", "text", None),
        ("leases", "lease_id", "text", None),
        ("leases", "expires_at", "timestamp with time zone", None),
        ("metadata", "singleton", "boolean", Some("true")),
        ("metadata", "version", "integer", None),
    ]
    .map(|(table, column, ty, default)| {
        (
            table.to_owned(),
            column.to_owned(),
            ty.to_owned(),
            true,
            default.map(normalized_definition),
        )
    });
    ensure!(
        columns == expected,
        "registry columns/defaults differ from version 1"
    );
    let metadata = client
        .query(
            "SELECT singleton,version FROM sr_template_registry.metadata",
            &[],
        )
        .await?;
    ensure!(
        metadata.len() == 1 && metadata[0].get::<_, bool>(0) && metadata[0].get::<_, i32>(1) == 1,
        "registry metadata must contain exactly the version 1 singleton"
    );
    let mut constraints: Vec<(String,String)> = client.query(
        "SELECT c.relname::text,pg_get_constraintdef(k.oid) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='sr_template_registry' AND k.contype IN ('p','u','f','c') AND k.convalidated AND NOT k.condeferrable", &[]
    ).await?.iter().map(|r|(r.get(0),normalized_definition(r.get::<_,&str>(1)))).collect();
    constraints.sort();
    let mut expected_constraints: Vec<(String,String)> = [
        ("metadata","PRIMARY KEY (singleton)"),
        ("metadata","CHECK (singleton)"),
        ("metadata","CHECK (version = 1)"),
        ("generations","PRIMARY KEY (digest)"),
        ("generations","UNIQUE (database_name)"),
        ("generations","CHECK (digest ~ '^[0-9a-f]{64}$')"),
        ("generations","CHECK (database_name = 'sr_tpl_' || left(digest,48))"),
        ("generations","CHECK (builder_token > 0)"),
        ("generations","CHECK (state = ANY(ARRAY['building','ready']))"),
        ("generations","CHECK (server_major > 0)"),
        ("leases","PRIMARY KEY (digest,lease_id)"),
        ("leases","FOREIGN KEY (digest) REFERENCES sr_template_registry.generations(digest) ON DELETE CASCADE"),
        ("leases","CHECK (length(lease_id) >= 1 AND length(lease_id) <= 128)"),
    ].iter().map(|(table,definition)|(table.to_string(),normalized_definition(definition))).collect();
    expected_constraints.sort();
    ensure!(
        constraints == expected_constraints,
        "registry keys/checks differ from version 1"
    );
    let sequence_ok: bool=client.query_one(
        "SELECT seqtypid='bigint'::regtype AND seqstart=1 AND seqincrement=1 AND seqmin=1 AND seqmax=9223372036854775807 AND NOT seqcycle FROM pg_sequence WHERE seqrelid='sr_template_registry.builder_tokens'::regclass", &[]
    ).await?.get(0);
    ensure!(
        sequence_ok,
        "registry fencing sequence differs from version 1"
    );
    Ok(())
}

#[derive(Debug, Serialize)]
pub struct Status {
    pub status: &'static str,
    pub digest: String,
    pub database: String,
    pub builder_token: i64,
}

async fn row(client: &Client, digest: &str) -> Result<Option<Row>> {
    Ok(client.query_opt("SELECT manifest, database_name, builder_token, state, server_major, extensions FROM sr_template_registry.generations WHERE digest=$1", &[&digest]).await?)
}

async fn compatibility(client: &Client) -> Result<(i32, BTreeMap<String, String>)> {
    let major = client
        .query_one(
            "SELECT current_setting('server_version_num')::int / 10000",
            &[],
        )
        .await?
        .get(0);
    let rows = client
        .query(
            "SELECT name, default_version FROM pg_available_extensions WHERE name = ANY($1)",
            &[&crate::REQUIRED_EXTENSIONS],
        )
        .await?;
    let extensions: BTreeMap<String, String> = rows.iter().map(|r| (r.get(0), r.get(1))).collect();
    ensure!(
        extensions.len() == crate::REQUIRED_EXTENSIONS.len(),
        "fixture lacks required extensions"
    );
    Ok((major, extensions))
}

fn check_identity(manifest: &Manifest, record: &Row) -> Result<()> {
    let stored: Manifest = Manifest::from_json(record.get::<_, &str>(0))?;
    ensure!(
        stored == *manifest && record.get::<_, &str>(1) == manifest.database,
        "registry manifest identity mismatch (possible truncated-name collision)"
    );
    Ok(())
}

async fn check_ready(client: &Client, manifest: &Manifest, record: &Row) -> Result<()> {
    check_identity(manifest, record)?;
    ensure!(
        record.get::<_, &str>(3) == "ready",
        "generation is incomplete; run template preparation and migration"
    );
    let (major, extensions) = compatibility(client).await?;
    let stored: BTreeMap<String, String> = serde_json::from_str(record.get::<_, &str>(5))?;
    ensure!(
        record.get::<_, i32>(4) == major && stored == extensions,
        "template fixture compatibility changed; qualify a new schema manifest"
    );
    let db = client
        .query_opt(
            "SELECT datallowconn FROM pg_database WHERE datname=$1",
            &[&manifest.database],
        )
        .await?;
    ensure!(
        db.is_some_and(|r| !r.get::<_, bool>(0)),
        "ready template missing or open to mutation"
    );
    Ok(())
}

async fn no_connections(client: &Client, database: &str) -> Result<()> {
    ensure!(
        !has_connections(client, database).await?,
        "generation has active connections; refusing recovery/cleanup"
    );
    Ok(())
}

async fn has_connections(client: &Client, database: &str) -> Result<bool> {
    let active: bool = client
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=$1)",
            &[&database],
        )
        .await?
        .get(0);
    Ok(active)
}

async fn has_generation_workers(client: &Client, database: &str) -> Result<bool> {
    let active: bool = client
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND backend_type LIKE 'TimescaleDB Background Worker%')",
            &[&database],
        )
        .await?
        .get(0);
    Ok(active)
}

/// Drain only extension-owned workers from an interrupted, fenced candidate.
///
/// Acquiring the generation lock proves that no cooperating builder still owns the
/// candidate, but Timescale's scheduler outlives the session that installed the
/// extension. Treating that scheduler like an application client makes recovery
/// impossible. Fence new connections first, refuse every backend except this control
/// session and Timescale workers, then use the database-local shutdown API. Arbitrary
/// backend termination remains prohibited.
async fn quiesce_recovery_workers(
    admin: &Client,
    manifest: &Manifest,
    policy: &Policy,
) -> Result<()> {
    if !has_connections(admin, &manifest.database).await? {
        return Ok(());
    }

    let allow_connections: bool = admin
        .query_one(
            "SELECT datallowconn FROM pg_database WHERE datname=$1",
            &[&manifest.database],
        )
        .await?
        .get(0);
    ensure!(
        allow_connections,
        "sealed incomplete generation has active connections; refusing recovery"
    );

    let (candidate, candidate_driver) = crate::connect_admin(Some(&manifest.database)).await?;
    let control_pid: i32 = candidate
        .query_one("SELECT pg_backend_pid()", &[])
        .await?
        .get(0);
    let unexpected: bool = admin
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND pid<>$2 AND backend_type NOT LIKE 'TimescaleDB Background Worker%')",
            &[&manifest.database, &control_pid],
        )
        .await?
        .get(0);
    if unexpected {
        drop(candidate);
        candidate_driver.await?;
        bail!("generation has active client connections; refusing recovery");
    }

    admin
        .batch_execute(&format!(
            "ALTER DATABASE {} ALLOW_CONNECTIONS false",
            quote_ident(&manifest.database)
        ))
        .await?;
    let unexpected_after_fence: bool = admin
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND pid<>$2 AND backend_type NOT LIKE 'TimescaleDB Background Worker%')",
            &[&manifest.database, &control_pid],
        )
        .await?
        .get(0);
    if unexpected_after_fence {
        admin
            .batch_execute(&format!(
                "ALTER DATABASE {} ALLOW_CONNECTIONS true",
                quote_ident(&manifest.database)
            ))
            .await?;
        drop(candidate);
        candidate_driver.await?;
        bail!("generation acquired a client connection while fencing recovery");
    }

    if has_generation_workers(admin, &manifest.database).await? {
        let stopped: bool = candidate
            .query_one(
                "SELECT _timescaledb_functions.stop_background_workers()",
                &[],
            )
            .await?
            .get(0);
        ensure!(
            stopped || !has_generation_workers(admin, &manifest.database).await?,
            "TimescaleDB worker shutdown was not acknowledged during recovery"
        );
    }
    drop(candidate);
    candidate_driver
        .await
        .context("closing generation recovery control session")?;
    wait_for_no_connections(admin, &manifest.database, policy).await
}

async fn renew(client: &Client, digest: &str, lease_id: &str, policy: &Policy) -> Result<()> {
    ensure!(
        !lease_id.is_empty() && lease_id.len() <= 128,
        "invalid generation lease id"
    );
    // Callers hold this generation's lock. Hot generations may never be selected
    // for retention cleanup, so remove crashed runs' expired leases on renewal.
    client.execute(
        "DELETE FROM sr_template_registry.leases WHERE digest=$1 AND expires_at<=clock_timestamp()",
        &[&digest],
    ).await?;
    client.execute("INSERT INTO sr_template_registry.leases(digest,lease_id,expires_at) VALUES($1,$2,clock_timestamp()+make_interval(secs=>$3::double precision)) ON CONFLICT(digest,lease_id) DO UPDATE SET expires_at=EXCLUDED.expires_at", &[&digest, &lease_id, &(policy.lease_seconds as f64)]).await?;
    client.execute("UPDATE sr_template_registry.generations SET last_used_at=clock_timestamp() WHERE digest=$1", &[&digest]).await?;
    Ok(())
}

async fn capacity(client: &Client, policy: &Policy, allocating: bool) -> Result<()> {
    let r = client.query_one("SELECT count(*)::bigint, count(*) FILTER (WHERE state='building')::bigint FROM sr_template_registry.generations", &[]).await?;
    ensure!(
        r.get::<_, i64>(0) + i64::from(allocating) <= policy.max_generations,
        "template generation capacity reached; run guarded cleanup after leases/retention expire"
    );
    ensure!(
        r.get::<_, i64>(1) + i64::from(allocating) <= policy.max_concurrent_builders,
        "template builder capacity reached; finish or recover existing builders"
    );
    let bytes: i64 = client.query_one("SELECT COALESCE(sum(pg_database_size(d.oid)),0)::bigint FROM pg_database d WHERE left(d.datname,7)='sr_tpl_'", &[]).await?.get(0);
    ensure!(
        bytes < policy.max_total_bytes,
        "template byte capacity reached; run guarded cleanup"
    );
    Ok(())
}

/// Cold allocation and interrupted-build recovery; does not migrate or publish.
/// Rebuild only under ownership lock, with no candidate connections or live leases.
pub async fn prepare(
    manifest: &Manifest,
    policy: &Policy,
    lease_id: &str,
    owner: &str,
) -> Result<Status> {
    manifest.validate()?;
    initialize(policy).await?;
    let mut session = Session::connect(policy).await?;
    session
        .lock(GENERATION_NAMESPACE, lock_key(&manifest.digest)?, policy)
        .await?;
    let client = &session.client;
    let existing = row(client, &manifest.digest).await?;
    if let Some(record) = &existing {
        check_identity(manifest, record)?;
        if record.get::<_, &str>(3) == "ready" {
            check_ready(client, manifest, record).await?;
            renew(client, &manifest.digest, lease_id, policy).await?;
            return Ok(Status {
                status: "ready",
                digest: manifest.digest.clone(),
                database: manifest.database.clone(),
                builder_token: record.get(2),
            });
        }
        quiesce_recovery_workers(client, manifest, policy).await?;
        no_connections(client, &manifest.database).await?;
    } else {
        let exists: bool = client
            .query_one(
                "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)",
                &[&manifest.database],
            )
            .await?
            .get(0);
        ensure!(
            !exists,
            "unregistered template database exists; refusing adoption or deletion"
        );
    }
    session.lock(CAPACITY_NAMESPACE, 0, policy).await?;
    capacity(client, policy, existing.is_none()).await?;
    let token: i64 = client
        .query_one("SELECT nextval('sr_template_registry.builder_tokens')", &[])
        .await?
        .get(0);
    let (major, extensions) = compatibility(client).await?;
    let json = serde_json::to_string(manifest)?;
    let extensions = serde_json::to_string(&extensions)?;
    client.execute("INSERT INTO sr_template_registry.generations(digest,manifest,database_name,builder_token,state,server_major,extensions) VALUES($1,$2,$3,$4,'building',$5,$6) ON CONFLICT(digest) DO UPDATE SET builder_token=EXCLUDED.builder_token,server_major=EXCLUDED.server_major,extensions=EXCLUDED.extensions,last_used_at=clock_timestamp() WHERE sr_template_registry.generations.state='building'", &[&manifest.digest,&json,&manifest.database,&token,&major,&extensions]).await?;
    client
        .query_one(
            "SELECT pg_advisory_unlock($1::int,0::int)",
            &[&CAPACITY_NAMESPACE],
        )
        .await?;
    // Never FORCE: a non-cooperating connection makes DROP fail closed.
    if existing.is_some() {
        client
            .batch_execute(&format!(
                "DROP DATABASE IF EXISTS {}",
                quote_ident(&manifest.database)
            ))
            .await?;
    }
    client
        .batch_execute(&format!(
            "CREATE DATABASE {} OWNER {}",
            quote_ident(&manifest.database),
            quote_ident(owner)
        ))
        .await?;
    // Extension DDL needs a candidate connection, but ownership lives on postgres.
    // Cancel it immediately if that original session (and thus its lock) is lost.
    // install_extensions aborts its own driver on cancellation; recovery separately
    // refuses any still-live backend, including a statement finishing server-side.
    tokio::select! {
        result = async {
            install_extensions(&manifest.database, owner).await?;
            let (client, driver) = connect_admin(Some(&manifest.database)).await?;
            let candidate = Session { client, driver };
            quiesce_candidate_workers(&candidate.client, manifest).await
        } => result?,
        _ = &mut session.driver => bail!("generation ownership session lost during initialization"),
    }
    wait_for_no_connections(client, &manifest.database, policy).await?;
    // Pin the gap between Rust preparation and the Elixir builder acquiring its
    // session lock. Leases forbid cleanup, not recovery: a failed run must be
    // retryable before its old lease expires, and builders reread the fenced token.
    renew(client, &manifest.digest, lease_id, policy).await?;
    Ok(Status {
        status: "needs_migration",
        digest: manifest.digest.clone(),
        database: manifest.database.clone(),
        builder_token: token,
    })
}

/// Caller must own the generation lock and an unpublished candidate. This API
/// stops only this database's Timescale workers, never arbitrary client sessions.
pub async fn quiesce_candidate_workers(client: &Client, manifest: &Manifest) -> Result<()> {
    manifest.validate()?;
    let database: String = client
        .query_one("SELECT current_database()", &[])
        .await?
        .get(0);
    ensure!(
        database == manifest.database,
        "worker shutdown connected to wrong candidate"
    );
    client.batch_execute("SET statement_timeout='30s'").await?;
    let stopped: bool = client
        .query_one(
            "SELECT _timescaledb_functions.stop_background_workers()",
            &[],
        )
        .await?
        .get(0);
    ensure!(stopped, "TimescaleDB worker shutdown was not acknowledged");
    Ok(())
}

pub async fn wait_for_no_connections(
    client: &Client,
    database: &str,
    policy: &Policy,
) -> Result<()> {
    let deadline =
        tokio::time::Instant::now() + Duration::from_secs(policy.lock_timeout_seconds as u64);
    while has_connections(client, database).await? {
        ensure!(
            tokio::time::Instant::now() < deadline,
            "candidate backend drain timed out"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Ok(())
}

pub async fn clone_generation(
    manifest: &Manifest,
    policy: &Policy,
    lease_id: &str,
    database: &str,
    owner: &str,
) -> Result<()> {
    manifest.validate()?;
    assert_disposable(database)?;
    ensure!(
        database.len() <= 63,
        "clone identifier exceeds PostgreSQL limit"
    );
    let session = Session::connect(policy).await?;
    session
        .lock(GENERATION_NAMESPACE, lock_key(&manifest.digest)?, policy)
        .await?;
    let record = row(&session.client, &manifest.digest)
        .await?
        .context("generation missing; no legacy fallback")?;
    check_ready(&session.client, manifest, &record).await?;
    renew(&session.client, &manifest.digest, lease_id, policy).await?;
    session
        .client
        .batch_execute(&format!(
            "DROP DATABASE IF EXISTS {} WITH (FORCE)",
            quote_ident(database)
        ))
        .await?;
    session
        .client
        .batch_execute(&format!(
            "CREATE DATABASE {} TEMPLATE {} OWNER {}",
            quote_ident(database),
            quote_ident(&manifest.database),
            quote_ident(owner)
        ))
        .await
        .context("cloning pinned generation")?;
    Ok(())
}

pub async fn release_lease(manifest: &Manifest, policy: &Policy, lease_id: &str) -> Result<()> {
    manifest.validate()?;
    let session = Session::connect(policy).await?;
    session
        .lock(GENERATION_NAMESPACE, lock_key(&manifest.digest)?, policy)
        .await?;
    session
        .client
        .execute(
            "DELETE FROM sr_template_registry.leases WHERE digest=$1 AND lease_id=$2",
            &[&manifest.digest, &lease_id],
        )
        .await?;
    Ok(())
}

async fn active_lease(client: &Client, digest: &str) -> Result<bool> {
    Ok(client.query_one("SELECT EXISTS(SELECT 1 FROM sr_template_registry.leases WHERE digest=$1 AND expires_at>clock_timestamp())", &[&digest]).await?.get(0))
}

/// Only registered expired generations, synchronized with builders/pins/clones.
/// No FORCE, no broad prefix DROP, and recheck catalog after every deletion.
pub async fn cleanup(policy: &Policy) -> Result<Vec<String>> {
    initialize(policy).await?;
    let listing = Session::connect(policy).await?;
    let records = listing.client.query("SELECT digest FROM sr_template_registry.generations WHERE last_used_at < clock_timestamp()-make_interval(secs=>$1::double precision) ORDER BY last_used_at", &[&(policy.retention_seconds as f64)]).await?;
    let mut removed = Vec::new();
    for record in records {
        let digest: String = record.get(0);
        if cleanup_digest(&digest, policy).await? {
            removed.push(database_for_digest(&digest)?);
        }
    }
    Ok(removed)
}

/// Exact-generation form, useful for scoped cleanup and guarded qualification.
/// False means retained (busy, leased, within retention, or no registered row).
pub async fn cleanup_digest(digest: &str, policy: &Policy) -> Result<bool> {
    let database = database_for_digest(digest)?;
    let session = Session::connect(policy).await?;
    if !session
        .try_lock(GENERATION_NAMESPACE, lock_key(digest)?)
        .await?
    {
        return Ok(false);
    }
    let eligible = session.client.query_opt("SELECT manifest,database_name FROM sr_template_registry.generations WHERE digest=$1 AND last_used_at < clock_timestamp()-make_interval(secs=>$2::double precision)", &[&digest,&(policy.retention_seconds as f64)]).await?;
    let Some(eligible) = eligible else {
        return Ok(false);
    };
    let manifest = Manifest::from_json(eligible.get(0))?;
    ensure!(
        manifest.digest == digest
            && manifest.database == database
            && eligible.get::<_, &str>(1) == database,
        "cleanup registry ownership mismatch"
    );
    if active_lease(&session.client, digest).await?
        || has_connections(&session.client, &database).await?
    {
        return Ok(false);
    }
    // Keep the generation lock through DROP and row deletion. Allocation counts
    // this row until removal, so a racing allocator remains conservative.
    session
        .client
        .batch_execute(&format!(
            "DROP DATABASE IF EXISTS {}",
            quote_ident(&database)
        ))
        .await?;
    let still_exists: bool = session
        .client
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)",
            &[&database],
        )
        .await?
        .get(0);
    ensure!(
        !still_exists,
        "generation remains after DROP; registry retained"
    );
    session
        .client
        .execute(
            "DELETE FROM sr_template_registry.generations WHERE digest=$1",
            &[&digest],
        )
        .await?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest() -> Manifest {
        let inputs = vec![Input {
            path: format!("{MIGRATIONS_PREFIX}1_synthetic.exs"),
            sha256: "cd".repeat(32),
        }];
        let digest = input_digest(&inputs);
        let covered_digest = digest_inputs(&inputs.iter().collect::<Vec<_>>(), COVERED_DOMAIN);
        Manifest {
            version: 1,
            database: database_for_digest(&digest).unwrap(),
            digest,
            inputs,
            migration_versions: vec![1],
            covered_migrations: CoveredMigrations {
                included_through: 1,
                digest: covered_digest,
            },
        }
    }

    #[test]
    fn manifest_roundtrip_and_identifier_validation() {
        let mut m = manifest();
        assert_eq!(
            Manifest::from_json(&serde_json::to_string(&m).unwrap()).unwrap(),
            m
        );
        assert_eq!(m.database.len(), 55);
        m.database.push('a');
        assert!(m.validate().is_err());
        for bad in [
            "a".repeat(63),
            "A".repeat(64),
            "z".repeat(64),
            "é".repeat(32),
        ] {
            assert!(database_for_digest(&bad).is_err());
        }
    }

    #[test]
    fn input_digest_matches_python_wire_vector() {
        assert_eq!(
            input_digest(&[Input {
                path: "schema/001.sql".into(),
                sha256: "cd".repeat(32)
            }]),
            "86638dba8db56000c4766e005df83b26d06e8d55986d64be2d224e87a54f41ef"
        );
        let mut edited = manifest();
        edited.inputs[0].sha256 = "ef".repeat(32);
        assert!(edited.validate().is_err());
    }

    #[test]
    fn cross_language_lock_vectors() {
        for (prefix, expected) in [
            ("00000000", 0),
            ("7fffffff", i32::MAX),
            ("80000000", i32::MIN),
            ("ffffffff", -1),
        ] {
            assert_eq!(
                lock_key(&format!("{prefix}{}", "0".repeat(56))).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn rejects_ambiguous_inputs_and_ledgers() {
        for path in [
            "/root/file",
            "../file",
            "schema/../file",
            "schema//file",
            "schema\\file",
        ] {
            let mut m = manifest();
            m.inputs[0].path = path.into();
            assert!(m.validate().is_err());
        }
        let mut m = manifest();
        m.inputs.push(m.inputs[0].clone());
        assert!(m.validate().is_err());
        for versions in [vec![], vec![1, 1], vec![2, 1], vec![0]] {
            let mut m = manifest();
            m.migration_versions = versions;
            assert!(m.validate().is_err());
        }
    }

    #[test]
    fn full_identity_distinguishes_truncated_collisions() {
        let first = manifest();
        let mut second = first.clone();
        second.digest.replace_range(48..64, "0000000000000000");
        assert!(second.validate().is_err());
        assert_eq!(first.database, second.database);
        assert_ne!(first, second);
    }

    #[test]
    fn ledger_and_covered_metadata_are_bound_to_inputs() {
        let mut m = manifest();
        m.migration_versions = vec![2];
        assert!(m.validate().unwrap_err().to_string().contains("ledger"));
        let mut m = manifest();
        m.covered_migrations.digest = "00".repeat(32);
        assert!(m
            .validate()
            .unwrap_err()
            .to_string()
            .contains("covered migration"));
        let mut m = manifest();
        m.inputs[0].path = format!("{MIGRATIONS_PREFIX}9223372036854775808_overflow.exs");
        m.digest = input_digest(&m.inputs);
        m.database = database_for_digest(&m.digest).unwrap();
        assert!(m.validate().unwrap_err().to_string().contains("bigint"));
    }

    #[test]
    fn policy_is_strict_and_positive() {
        let json = r#"{"version":1,"construction_mode":"full_replay","max_generations":16,"max_concurrent_builders":1,"max_total_bytes":21474836480,"retention_seconds":86400,"lease_seconds":7200,"lock_timeout_seconds":300}"#;
        let mut p: Policy = serde_json::from_str(json).unwrap();
        p.validate().unwrap();
        p.lease_seconds = 0;
        assert!(p.validate().is_err());
        assert!(serde_json::from_str::<Policy>(
            &json.replace("\"version\":1", "\"version\":1,\"extra\":true")
        )
        .is_err());
        assert!(serde_json::from_str::<Policy>("{}").is_err());
    }
}
