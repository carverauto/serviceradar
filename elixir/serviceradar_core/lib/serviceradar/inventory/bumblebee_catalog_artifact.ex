defmodule ServiceRadar.Inventory.BumblebeeCatalogArtifact do
  @moduledoc """
  Builds and uploads immutable Bumblebee catalog artifacts to datasvc object storage.
  """

  alias ServiceRadar.Sync.Client, as: SyncClient

  @storage_backend "datasvc_object_store"
  @content_type "application/json"
  @default_timeout 30_000

  @spec materialize(String.t(), [map()], map(), keyword()) :: {:ok, map()} | {:error, term()}
  def materialize(snapshot_ref, entries, metadata, opts \\ [])
      when is_binary(snapshot_ref) and is_list(entries) and is_map(metadata) do
    payload = build_payload(snapshot_ref, entries, metadata)
    data = Jason.encode!(payload)
    sha256 = sha256(data)
    object_key = object_key(snapshot_ref, sha256)
    upload_object = Keyword.get(opts, :upload_object, &default_upload_object/3)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    object_metadata = %Proto.ObjectMetadata{
      key: object_key,
      content_type: @content_type,
      sha256: sha256,
      total_size: byte_size(data),
      attributes:
        compact_map(%{
          "catalog_snapshot_ref" => snapshot_ref,
          "catalog_version" => Map.get(metadata, "catalog_version"),
          "source_revision" => Map.get(metadata, "source_revision"),
          "schema_version" => Map.get(metadata, "schema_version"),
          "entry_count" => Integer.to_string(length(entries)),
          "storage_backend" => @storage_backend
        })
    }

    with {:ok, _response} <- upload_object.(object_metadata, data, timeout: timeout) do
      {:ok,
       %{
         "object_key" => object_key,
         "content_sha256" => sha256,
         "object_size_bytes" => byte_size(data),
         "content_type" => @content_type,
         "storage_backend" => @storage_backend,
         "entry_count" => length(entries)
       }}
    end
  end

  defp build_payload(snapshot_ref, entries, metadata) do
    %{
      "schema_version" => "serviceradar.bumblebee.catalog.v1",
      "snapshot_ref" => snapshot_ref,
      "catalog_version" => Map.get(metadata, "catalog_version"),
      "source_revision" => Map.get(metadata, "source_revision"),
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "entries" => Enum.map(entries, &artifact_entry/1)
    }
  end

  defp artifact_entry(entry) do
    compact_map(%{
      "catalog_id" => Map.fetch!(entry, :catalog_id),
      "ecosystem" => Map.fetch!(entry, :ecosystem),
      "package_name" => Map.fetch!(entry, :package_name),
      "affected_versions" => Map.get(entry, :affected_versions, []),
      "severity" => Map.fetch!(entry, :severity),
      "source_url" => Map.get(entry, :source_url),
      "metadata" => Map.get(entry, :metadata, %{})
    })
  end

  defp object_key(snapshot_ref, sha256) do
    "bumblebee/catalogs/#{safe_segment(snapshot_ref)}/#{sha256}.json"
  end

  defp safe_segment(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "catalog"
      segment -> segment
    end
  end

  defp sha256(data) do
    :sha256
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
  end

  defp default_upload_object(metadata, data, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    ServiceRadar.DataService.Client.with_channel(
      fn channel ->
        SyncClient.upload_object(channel, metadata, data, timeout: timeout)
      end,
      timeout: timeout
    )
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
