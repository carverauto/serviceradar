# Generate the Camera Semantic Clip Search tables (VisualIndexJob, VisualFrame,
# VisualEmbedding with pgvector partial HNSW cosine indexes and catalog purge trigger)
# and incremental updates on CameraRecordingPolicy, RecordingAccessAudit, and
# StorageEntitlement against their committed Ash baselines.
Mix.start()
Mix.env(:test)

defmodule ServiceRadar.CameraSemanticClipSearchSchema do
  @moduledoc false
  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource ServiceRadar.Camera.CameraRecordingPolicy
    resource ServiceRadar.Camera.RecordingAccessAudit
    resource ServiceRadar.Storage.StorageEntitlement
    resource ServiceRadar.Camera.VisualIndexJob
    resource ServiceRadar.Camera.VisualFrame
    resource ServiceRadar.Camera.VisualEmbedding
  end
end

[
  policy_output,
  access_audit_output,
  entitlement_output,
  visual_job_output,
  visual_frame_output,
  visual_embedding_output,
  migration_output,
  policy_baseline,
  policy_version_baseline,
  access_audit_baseline,
  entitlement_baseline,
  entitlement_version_baseline
] = System.argv()

scratch = Path.join(Path.dirname(migration_output), "camera_semantic_clip_search_scratch")

for {table, baseline} <- [
      {"camera_recording_policies", policy_baseline},
      {"camera_recording_policies_versions", policy_version_baseline},
      {"camera_recording_access_audits", access_audit_baseline},
      {"storage_entitlements", entitlement_baseline},
      {"storage_entitlement_versions", entitlement_version_baseline}
    ] do
  dir = Path.join(scratch, "repo/platform.#{table}")
  File.mkdir_p!(dir)
  File.cp!(baseline, Path.join(dir, Path.basename(baseline)))
end

try do
  current_by_table =
    ServiceRadar.CameraSemanticClipSearchSchema
    |> AshPostgres.MigrationGenerator.take_snapshots(ServiceRadar.Repo)
    |> Map.new(&{&1.table, &1})

  for table <- [
        "camera_recording_policies",
        "camera_recording_policies_versions",
        "camera_recording_access_audits",
        "storage_entitlements",
        "storage_entitlement_versions"
      ] do
    current = Map.fetch!(current_by_table, table)

    previous =
      AshPostgres.MigrationGenerator.get_existing_snapshot(
        current,
        %AshPostgres.MigrationGenerator{snapshot_path: scratch}
      )

    if !previous, do: raise("#{table} baseline snapshot was not found")
  end

  AshPostgres.MigrationGenerator.generate(ServiceRadar.CameraSemanticClipSearchSchema,
    snapshot_path: scratch,
    migration_path: Path.join(scratch, "migrations"),
    tenant_migration_path: Path.join(scratch, "tenant_migrations"),
    name: "add_camera_semantic_clip_search",
    # The pinned generator's no_shell mode ignores on-disk baselines.
    no_shell?: false,
    quiet: true,
    format: false
  )

  for {table, min_count, output} <- [
        {"camera_recording_policies", 2, policy_output},
        {"camera_recording_access_audits", 2, access_audit_output},
        {"storage_entitlements", 2, entitlement_output},
        {"camera_visual_index_jobs", 1, visual_job_output},
        {"camera_visual_frames", 1, visual_frame_output},
        {"camera_visual_embeddings", 1, visual_embedding_output}
      ] do
    snapshots =
      scratch
      |> Path.join("repo/platform.#{table}/*.json")
      |> Path.wildcard()
      |> Enum.sort()

    if length(snapshots) < min_count do
      raise("expected >= #{min_count} snapshots for #{table}, got: #{inspect(snapshots)}")
    end

    File.cp!(List.last(snapshots), output)
  end

  [migration] =
    Path.wildcard(Path.join(scratch, "migrations/*_add_camera_semantic_clip_search.exs"))

  File.write!(migration_output, [Code.format_string!(File.read!(migration)), "\n"])
after
  File.rm_rf!(scratch)
end
