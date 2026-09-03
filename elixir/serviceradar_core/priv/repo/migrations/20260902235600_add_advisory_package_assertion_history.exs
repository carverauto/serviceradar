defmodule ServiceRadar.Repo.Migrations.AddAdvisoryPackageAssertionHistory do
  @moduledoc """
  Retains immutable snapshots of normalized advisory assertions across feed
  generations. The current assertion table remains the only matcher input.
  """

  use Ecto.Migration

  def up do
    create table(:advisory_package_assertion_history,
             primary_key: false,
             prefix: "platform"
           ) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :assertion_key, :text, null: false
      add :advisory_ref, :uuid, null: false
      add :provider, :text, null: false
      add :feed_key, :text, null: false
      add :generation, :bigint, null: false
      add :cve_id, :text, null: false
      add :authority, :text, null: false
      add :source_kind, :text, null: false
      add :source_timestamp, :utc_datetime_usec
      add :disposition, :text, null: false
      add :statement_fingerprint, :text
      add :snapshot, :map, null: false
      add :content_sha256, :text, null: false

      add :recorded_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    # Let Postgres hash the canonical JSONB representation so rows archived by
    # the loader and rows backfilled here use exactly the same digest. A stored
    # generated column cannot use jsonb's text output function because Postgres
    # does not mark it immutable, so compute the value in a BEFORE INSERT
    # trigger instead. Loader timestamps are useful provenance, but are not
    # assertion semantics.
    execute("""
    CREATE FUNCTION platform.set_advisory_package_assertion_history_hash()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      NEW.content_sha256 := encode(
        digest(
          convert_to((NEW.snapshot - 'inserted_at' - 'updated_at')::text, 'UTF8'),
          'sha256'
        ),
        'hex'
      );
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER advisory_package_assertion_history_hash
    BEFORE INSERT ON platform.advisory_package_assertion_history
    FOR EACH ROW
    EXECUTE FUNCTION platform.set_advisory_package_assertion_history_hash()
    """)

    create unique_index(
             :advisory_package_assertion_history,
             [:assertion_key, :generation, :content_sha256],
             name: "advisory_package_assertion_history_identity_uidx",
             prefix: "platform"
           )

    create index(
             :advisory_package_assertion_history,
             [:provider, :feed_key, :generation],
             name: "advisory_package_assertion_history_feed_generation_idx",
             prefix: "platform"
           )

    create index(
             :advisory_package_assertion_history,
             [:cve_id, :source_kind],
             name: "advisory_package_assertion_history_cve_source_idx",
             prefix: "platform"
           )

    execute(
      "COMMENT ON TABLE platform.advisory_package_assertion_history IS " <>
        "'Append-only normalized assertion provenance; never an authoritative matcher input'"
    )

    execute(backfill_sql())
  end

  def down do
    drop table(:advisory_package_assertion_history, prefix: "platform")

    execute("DROP FUNCTION platform.set_advisory_package_assertion_history_hash()")
  end

  # Kept as one idempotent statement so a scratch-DB migration check can rerun
  # the backfill and prove that the history identity rejects duplicates.
  def backfill_sql do
    """
    INSERT INTO platform.advisory_package_assertion_history (
      assertion_key,
      advisory_ref,
      provider,
      feed_key,
      generation,
      cve_id,
      authority,
      source_kind,
      source_timestamp,
      disposition,
      statement_fingerprint,
      snapshot,
      recorded_at
    )
    SELECT
      assertion.assertion_key,
      assertion.advisory_ref,
      assertion.provider,
      assertion.feed_key,
      assertion.generation,
      assertion.cve_id,
      assertion.authority,
      assertion.source_kind,
      assertion.source_timestamp,
      assertion.disposition,
      assertion.statement_fingerprint,
      jsonb_build_object(
        'assertion_key', assertion.assertion_key,
        'advisory_ref', assertion.advisory_ref,
        'provider', assertion.provider,
        'feed_key', assertion.feed_key,
        'generation', assertion.generation,
        'cve_id', assertion.cve_id,
        'authority', assertion.authority,
        'source_kind', assertion.source_kind,
        'source_timestamp', CASE
          WHEN assertion.source_timestamp IS NULL THEN NULL
          ELSE to_char(assertion.source_timestamp, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        END,
        'assertion_shape', assertion.assertion_shape,
        'product_set_ref', assertion.product_set_ref,
        'statement_fingerprint', assertion.statement_fingerprint,
        'package_type', assertion.package_type,
        'namespace', assertion.namespace,
        'release', assertion.release,
        'release_channel', assertion.release_channel,
        'product_scope', assertion.product_scope,
        'source_package', assertion.source_package,
        'binary_package', assertion.binary_package,
        'architecture', assertion.architecture,
        'version_scheme', assertion.version_scheme,
        'disposition', assertion.disposition,
        'introduced_version', assertion.introduced_version,
        'fixed_version', assertion.fixed_version,
        'affected_versions', assertion.affected_versions,
        'package_purl', assertion.package_purl,
        'justification', assertion.justification,
        'status_text', assertion.status_text,
        'action_text', assertion.action_text,
        'validation', assertion.validation,
        'raw', assertion.raw,
        'metadata', assertion.metadata,
        'inserted_at', to_char(assertion.inserted_at, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'updated_at', to_char(assertion.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
      ),
      assertion.updated_at
    FROM platform.advisory_package_assertions AS assertion
    ON CONFLICT (assertion_key, generation, content_sha256) DO NOTHING
    """
  end
end
