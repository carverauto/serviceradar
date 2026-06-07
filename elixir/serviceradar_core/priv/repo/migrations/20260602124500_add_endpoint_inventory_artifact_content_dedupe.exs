defmodule ServiceRadar.Repo.Migrations.AddEndpointInventoryArtifactContentDedupe do
  @moduledoc false
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - schema-critical bounded
    # dedupe backfill required before artifact_content_ref can be populated.
    drop_if_exists(
      index(:endpoint_inventory_artifacts, [:object_key],
        name: "endpoint_inventory_artifacts_object_key_uidx",
        prefix: "platform"
      )
    )

    create table(:endpoint_inventory_artifact_contents, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:artifact_hash, :text, null: false)
      add(:object_key, :text, null: false)
      add(:bucket, :text)
      add(:domain, :text)
      add(:content_type, :text, null: false, default: "application/json")
      add(:format, :text, null: false, default: "CycloneDX")
      add(:spec_version, :text)
      add(:sha256, :text, null: false)
      add(:size_bytes, :bigint, null: false, default: 0)
      add(:storage_backend, :text, null: false, default: "datasvc_object_store")
      add(:first_uploaded_at, :utc_datetime_usec)
      add(:last_referenced_at, :utc_datetime_usec)
      add(:reference_count, :integer, null: false, default: 0)
      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:endpoint_inventory_artifact_contents, [:artifact_hash],
        name: "endpoint_inventory_artifact_contents_hash_uidx",
        prefix: "platform"
      )
    )

    create(
      unique_index(:endpoint_inventory_artifact_contents, [:object_key],
        name: "endpoint_inventory_artifact_contents_object_key_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_inventory_artifact_contents, [:sha256],
        name: "endpoint_inventory_artifact_contents_sha256_idx",
        prefix: "platform"
      )
    )

    alter table(:endpoint_inventory_artifacts, prefix: "platform") do
      add(
        :artifact_content_ref,
        references(:endpoint_inventory_artifact_contents,
          type: :uuid,
          on_delete: :restrict,
          prefix: "platform"
        )
      )

      add(:artifact_hash, :text)
      add(:reused_content, :boolean, null: false, default: false)
    end

    execute("""
    INSERT INTO platform.endpoint_inventory_artifact_contents (
      artifact_hash,
      object_key,
      bucket,
      domain,
      content_type,
      format,
      spec_version,
      sha256,
      size_bytes,
      storage_backend,
      first_uploaded_at,
      last_referenced_at,
      reference_count,
      metadata,
      inserted_at,
      updated_at
    )
    SELECT DISTINCT ON (COALESCE(NULLIF(a.metadata->>'artifact_hash', ''), a.sha256))
      COALESCE(NULLIF(a.metadata->>'artifact_hash', ''), a.sha256) AS artifact_hash,
      a.object_key,
      a.bucket,
      a.domain,
      a.content_type,
      a.format,
      a.spec_version,
      a.sha256,
      a.size_bytes,
      a.storage_backend,
      a.uploaded_at,
      a.inserted_at,
      0,
      jsonb_strip_nulls(
        COALESCE(a.metadata, '{}'::jsonb) ||
        jsonb_build_object('backfilled_from_scan_ref', a.scan_ref)
      ),
      a.inserted_at,
      a.inserted_at
    FROM platform.endpoint_inventory_artifacts AS a
    ORDER BY COALESCE(NULLIF(a.metadata->>'artifact_hash', ''), a.sha256), a.inserted_at ASC
    ON CONFLICT (artifact_hash) DO NOTHING
    """)

    execute("""
    UPDATE platform.endpoint_inventory_artifacts AS a
    SET artifact_content_ref = c.id,
        artifact_hash = c.artifact_hash,
        reused_content = false
    FROM platform.endpoint_inventory_artifact_contents AS c
    WHERE c.artifact_hash = COALESCE(NULLIF(a.metadata->>'artifact_hash', ''), a.sha256)
    """)

    execute("""
    UPDATE platform.endpoint_inventory_artifact_contents AS c
    SET reference_count = refs.ref_count,
        last_referenced_at = refs.last_referenced_at,
        updated_at = NOW() AT TIME ZONE 'utc'
    FROM (
      SELECT artifact_content_ref, COUNT(*)::integer AS ref_count, MAX(inserted_at) AS last_referenced_at
      FROM platform.endpoint_inventory_artifacts
      WHERE artifact_content_ref IS NOT NULL
      GROUP BY artifact_content_ref
    ) AS refs
    WHERE c.id = refs.artifact_content_ref
    """)

    create(
      index(:endpoint_inventory_artifacts, [:artifact_content_ref],
        name: "endpoint_inventory_artifacts_content_ref_idx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_inventory_artifacts, [:object_key],
        name: "endpoint_inventory_artifacts_object_key_idx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_inventory_artifacts, [:artifact_hash],
        name: "endpoint_inventory_artifacts_hash_idx",
        prefix: "platform",
        where: "artifact_hash IS NOT NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:endpoint_inventory_artifacts, [:artifact_hash],
        name: "endpoint_inventory_artifacts_hash_idx",
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:endpoint_inventory_artifacts, [:object_key],
        name: "endpoint_inventory_artifacts_object_key_idx",
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:endpoint_inventory_artifacts, [:artifact_content_ref],
        name: "endpoint_inventory_artifacts_content_ref_idx",
        prefix: "platform"
      )
    )

    alter table(:endpoint_inventory_artifacts, prefix: "platform") do
      remove(:reused_content)
      remove(:artifact_hash)
      remove(:artifact_content_ref)
    end

    drop_if_exists(table(:endpoint_inventory_artifact_contents, prefix: "platform"))

    create(
      unique_index(:endpoint_inventory_artifacts, [:object_key],
        name: "endpoint_inventory_artifacts_object_key_uidx",
        prefix: "platform"
      )
    )
  end
end
