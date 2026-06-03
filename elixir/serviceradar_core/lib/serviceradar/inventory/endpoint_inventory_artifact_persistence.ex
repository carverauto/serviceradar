defmodule ServiceRadar.Inventory.EndpointInventoryArtifactPersistence do
  @moduledoc false

  import Ecto.Query

  alias ServiceRadar.Inventory.EndpointInventoryArtifactStore
  alias ServiceRadar.Inventory.EndpointInventoryPayload, as: Payload
  alias ServiceRadar.Repo

  def maybe_upload(payload, context, opts) do
    case Payload.map_value(payload, :sbom) do
      sbom when map_size(sbom) > 0 ->
        artifact_hash = context.artifact_hash

        if artifact_hash do
          case artifact_content_by_hash(artifact_hash) do
            nil ->
              upload_sbom_artifact(payload, context, sbom, opts)

            content ->
              {:ok, artifact_from_content(content, context)}
          end
        else
          upload_sbom_artifact(payload, context, sbom, opts)
        end

      _sbom ->
        {:ok, existing_artifact_ref(payload)}
    end
  end

  def apply_metadata(context, nil), do: context

  def apply_metadata(context, artifact) do
    artifact_hash =
      context.artifact_hash || Map.get(artifact, :artifact_hash) || Map.get(artifact, :sha256)

    %{context | artifact_hash: artifact_hash}
  end

  def replace(scan_ref, _context, nil) do
    old_content_refs = scan_artifact_content_refs(scan_ref)
    delete_scan_rows("endpoint_inventory_artifacts", scan_ref)
    refresh_artifact_content_counts(old_content_refs)
  end

  def replace(scan_ref, context, artifact) do
    old_content_refs = scan_artifact_content_refs(scan_ref)
    delete_scan_rows("endpoint_inventory_artifacts", scan_ref)
    content = upsert_artifact_content(context, artifact)

    row = %{
      scan_ref: scan_ref,
      artifact_content_ref: content.id,
      agent_id: context.agent_id,
      device_uid: context.device_uid,
      artifact_hash: content.artifact_hash,
      object_key: Map.fetch!(artifact, :object_key),
      bucket: Map.get(artifact, :bucket),
      domain: Map.get(artifact, :domain),
      content_type: Map.get(artifact, :content_type, "application/json"),
      format: Map.get(artifact, :format, "CycloneDX"),
      spec_version: Map.get(artifact, :spec_version),
      sha256: Map.fetch!(artifact, :sha256),
      size_bytes: Map.get(artifact, :size_bytes, 0),
      storage_backend: Map.get(artifact, :storage_backend, "datasvc_object_store"),
      uploaded_at: Map.get(artifact, :uploaded_at) || context.now,
      reused_content: Map.get(artifact, :reused_content, false) || content.reused?,
      metadata: artifact_provenance_metadata(context, artifact, content),
      inserted_at: context.now
    }

    Repo.insert_all("endpoint_inventory_artifacts", [row], prefix: "platform")
    refresh_artifact_content_counts(Enum.uniq([content.id | old_content_refs]))
  end

  defp upload_sbom_artifact(payload, context, sbom, opts) do
    artifact = Payload.map_value(payload, :artifact)

    EndpointInventoryArtifactStore.upload_sbom(
      context.agent_id,
      context.scan_id,
      sbom,
      opts
      |> Keyword.put(:expected_sha256, Payload.string_value(artifact, :sha256))
      |> Keyword.put(:artifact_hash, context.artifact_hash)
    )
  end

  defp existing_artifact_ref(payload) do
    artifact = Payload.map_value(payload, :artifact)

    object_key = Payload.string_value(artifact, :object_key)
    sha256 = Payload.string_value(artifact, :sha256)

    if object_key && sha256 do
      %{
        object_key: object_key,
        bucket: Payload.string_value(artifact, :bucket),
        domain: Payload.string_value(artifact, :domain),
        content_type: Payload.string_value(artifact, :content_type) || "application/json",
        format: Payload.string_value(artifact, :format) || "CycloneDX",
        spec_version: Payload.string_value(artifact, :spec_version),
        sha256: sha256,
        size_bytes: Payload.integer_value(artifact, :size_bytes, 0),
        storage_backend:
          Payload.string_value(artifact, :storage_backend) || "datasvc_object_store",
        uploaded_at: Payload.unix_datetime(artifact, :uploaded_at_unix),
        metadata: Payload.map_value(artifact, :metadata)
      }
    end
  end

  defp artifact_content_by_hash(nil), do: nil
  defp artifact_content_by_hash(""), do: nil

  defp artifact_content_by_hash(artifact_hash) do
    Repo.one(
      from(c in "endpoint_inventory_artifact_contents",
        where: c.artifact_hash == ^artifact_hash,
        select: %{
          id: c.id,
          artifact_hash: c.artifact_hash,
          object_key: c.object_key,
          bucket: c.bucket,
          domain: c.domain,
          content_type: c.content_type,
          format: c.format,
          spec_version: c.spec_version,
          sha256: c.sha256,
          size_bytes: c.size_bytes,
          storage_backend: c.storage_backend,
          first_uploaded_at: c.first_uploaded_at,
          metadata: c.metadata
        },
        limit: 1
      ),
      prefix: "platform"
    )
  end

  defp artifact_from_content(content, context) do
    %{
      artifact_content_ref: content.id,
      artifact_hash: content.artifact_hash,
      object_key: content.object_key,
      bucket: content.bucket,
      domain: content.domain,
      content_type: content.content_type,
      format: content.format,
      spec_version: content.spec_version,
      sha256: content.sha256,
      size_bytes: content.size_bytes,
      storage_backend: content.storage_backend,
      uploaded_at: content.first_uploaded_at || context.now,
      reused_content: true,
      metadata: Map.get(content, :metadata, %{})
    }
  end

  defp upsert_artifact_content(context, artifact) do
    artifact_hash = artifact_hash_for(context, artifact)
    existing = artifact_content_by_hash(artifact_hash)

    row = %{
      artifact_hash: artifact_hash,
      object_key: Map.fetch!(artifact, :object_key),
      bucket: Map.get(artifact, :bucket),
      domain: Map.get(artifact, :domain),
      content_type: Map.get(artifact, :content_type, "application/json"),
      format: Map.get(artifact, :format, "CycloneDX"),
      spec_version: Map.get(artifact, :spec_version),
      sha256: Map.fetch!(artifact, :sha256),
      size_bytes: Map.get(artifact, :size_bytes, 0),
      storage_backend: Map.get(artifact, :storage_backend, "datasvc_object_store"),
      first_uploaded_at: Map.get(artifact, :uploaded_at) || context.now,
      last_referenced_at: context.now,
      reference_count: 0,
      metadata: artifact_content_metadata(artifact),
      inserted_at: context.now,
      updated_at: context.now
    }

    {_, [%{id: id}]} =
      Repo.insert_all("endpoint_inventory_artifact_contents", [row],
        prefix: "platform",
        on_conflict:
          {:replace,
           [
             :object_key,
             :bucket,
             :domain,
             :content_type,
             :format,
             :spec_version,
             :sha256,
             :size_bytes,
             :storage_backend,
             :last_referenced_at,
             :metadata,
             :updated_at
           ]},
        conflict_target: [:artifact_hash],
        returning: [:id]
      )

    %{id: id, artifact_hash: artifact_hash, reused?: not is_nil(existing)}
  end

  defp artifact_hash_for(context, artifact) do
    context.artifact_hash || Map.get(artifact, :artifact_hash) || Map.fetch!(artifact, :sha256)
  end

  defp artifact_content_metadata(artifact) do
    artifact_hash = Map.get(artifact, :artifact_hash) || Map.get(artifact, :sha256)

    artifact
    |> Map.get(:metadata, %{})
    |> Map.drop(["agent_id", "scan_id", :agent_id, :scan_id])
    |> Map.merge(%{
      "source" => "endpoint_inventory",
      "artifact_hash" => artifact_hash
    })
    |> Payload.compact_map()
  end

  defp artifact_provenance_metadata(context, artifact, content) do
    artifact
    |> Map.get(:metadata, %{})
    |> Map.merge(%{
      "agent_id" => context.agent_id,
      "scan_id" => context.scan_id,
      "upload_reason" => context.upload_reason,
      "artifact_hash" => content.artifact_hash,
      "artifact_content_ref" => encode_uuid(content.id),
      "reused_content" => Map.get(artifact, :reused_content, false) || content.reused?
    })
    |> Payload.compact_map()
  end

  defp encode_uuid(uuid) when is_binary(uuid) and byte_size(uuid) == 16 do
    case Ecto.UUID.load(uuid) do
      {:ok, encoded} -> encoded
      :error -> Base.encode16(uuid, case: :lower)
    end
  end

  defp encode_uuid(uuid), do: uuid

  defp scan_artifact_content_refs(scan_ref) do
    Repo.all(
      from(a in "endpoint_inventory_artifacts",
        where: a.scan_ref == ^scan_ref and not is_nil(a.artifact_content_ref),
        select: a.artifact_content_ref
      ),
      prefix: "platform"
    )
  end

  defp refresh_artifact_content_counts(content_refs) do
    content_refs
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn content_ref ->
      count =
        Repo.one!(
          from(a in "endpoint_inventory_artifacts",
            where: a.artifact_content_ref == ^content_ref,
            select: count(a.id)
          ),
          prefix: "platform"
        )

      Repo.update_all(
        from(c in "endpoint_inventory_artifact_contents", where: c.id == ^content_ref),
        [
          set: [
            reference_count: count,
            last_referenced_at: if(count > 0, do: DateTime.utc_now()),
            updated_at: DateTime.utc_now()
          ]
        ],
        prefix: "platform"
      )
    end)
  end

  defp delete_scan_rows(table, scan_ref) do
    query = from(r in table, where: r.scan_ref == ^scan_ref)
    Repo.delete_all(query, prefix: "platform")
  end
end
