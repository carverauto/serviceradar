defmodule ServiceRadar.Inventory.EndpointInventoryArtifactStore do
  @moduledoc """
  Uploads raw endpoint inventory SBOM artifacts to datasvc object storage.
  """

  alias ServiceRadar.Sync.Client, as: SyncClient

  @content_type "application/json"
  @default_timeout 30_000
  @format "CycloneDX"
  @storage_backend "datasvc_object_store"

  @spec upload_sbom(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def upload_sbom(agent_id, scan_id, sbom, opts \\ [])

  def upload_sbom(agent_id, scan_id, sbom, opts)
      when is_binary(agent_id) and is_binary(scan_id) and is_map(sbom) do
    data = Jason.encode!(sbom)
    sha256 = sha256(data)
    artifact_hash = Keyword.get(opts, :artifact_hash) || sha256
    expected_sha256 = Keyword.get(opts, :expected_sha256)

    with :ok <- validate_expected_sha256(expected_sha256, sha256),
         {:ok, object_key} <- object_key(artifact_hash) do
      upload_object = Keyword.get(opts, :upload_object, &default_upload_object/3)
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      metadata = %Proto.ObjectMetadata{
        key: object_key,
        content_type: @content_type,
        sha256: sha256,
        total_size: byte_size(data),
        attributes:
          compact_map(%{
            "agent_id" => agent_id,
            "scan_id" => scan_id,
            "artifact_hash" => artifact_hash,
            "format" => @format,
            "spec_version" => string_value(sbom, "specVersion"),
            "storage_backend" => @storage_backend
          })
      }

      with {:ok, _response} <- upload_object.(metadata, data, timeout: timeout) do
        {:ok,
         %{
           object_key: object_key,
           content_type: @content_type,
           format: @format,
           spec_version: string_value(sbom, "specVersion"),
           artifact_hash: artifact_hash,
           sha256: sha256,
           size_bytes: byte_size(data),
           storage_backend: @storage_backend,
           uploaded_at: DateTime.utc_now()
         }}
      end
    end
  end

  def upload_sbom(_agent_id, _scan_id, _sbom, _opts), do: {:error, :invalid_sbom_artifact}

  defp validate_expected_sha256(nil, _actual), do: :ok
  defp validate_expected_sha256("", _actual), do: :ok
  defp validate_expected_sha256(actual, actual), do: :ok

  defp validate_expected_sha256(expected, actual),
    do: {:error, {:sha256_mismatch, expected, actual}}

  defp object_key(artifact_hash) do
    case safe_artifact_hash(artifact_hash) do
      {:ok, hash} -> {:ok, "endpoint-inventory/by-hash/#{hash}.cdx.json"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sha256(data) do
    :sha256
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
  end

  defp safe_artifact_hash(value) do
    hash =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if Regex.match?(~r/^[a-f0-9]{64}$/, hash) do
      {:ok, hash}
    else
      {:error, {:invalid_artifact_hash, value}}
    end
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

  defp string_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp string_value(_map, _key), do: nil
end
