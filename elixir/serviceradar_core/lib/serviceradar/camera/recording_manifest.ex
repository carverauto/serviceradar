defmodule ServiceRadar.Camera.RecordingManifest do
  @moduledoc """
  Versioned recovery metadata for one sealed recording block.

  The manifest contains no local paths, bucket names, URLs or credentials. Its
  relative object keys are derived from the block identity, independent of clock
  metadata and content, so retrying conflicting content cannot choose a new key.
  The storage binding belongs to the deployment, outside this document.

  Encoding validates metadata, not remote durability. The publisher must verify
  the referenced media and init bytes, then the manifest itself, before a fenced
  index transition. Decoding is neither authorization nor proof of those bytes.
  Callers supply the expected identity from trusted state, including its clock.

  Version 1 describes the current single-track baseline H.264 path. Missing
  analysis is explicitly unknown. Bounds match the spool's absolute ceilings;
  deployment admission may be lower. Unknown versions and fields fail closed.
  """

  alias ServiceRadar.Camera.RecordingDescriptor

  @max_json_bytes 2_097_152

  @doc "Encode a sealed internal snapshot and actual init descriptor with storage receipts."
  def encode(snapshot, format, receipts) do
    case RecordingDescriptor.from_snapshot(snapshot, format) do
      {:ok, descriptor} -> encode_descriptor(descriptor, receipts)
      _ -> {:error, :invalid_manifest}
    end
  end

  @doc """
  Encode a persisted frozen descriptor with storage receipts, without a live
  packager or local spool. Validates metadata only: the caller still owns remote
  byte verification, publication fencing and access authorization.
  """
  def encode_descriptor(descriptor, %{init: init_receipt, media: media_receipt}) do
    case RecordingDescriptor.validate(descriptor) do
      :ok ->
        manifest =
          descriptor
          |> Map.update!("init", &object(&1, init_receipt))
          |> Map.update!("media", &object(&1, media_receipt))

        with :ok <- validate(manifest),
             manifest = put_object_keys(manifest),
             {:ok, bytes} <- Jason.encode(canonical(manifest)),
             true <- byte_size(bytes) <= @max_json_bytes do
          {:ok, bytes}
        else
          _ -> {:error, :invalid_manifest}
        end

      _ ->
        {:error, :invalid_manifest}
    end
  end

  def encode_descriptor(_, _), do: {:error, :invalid_manifest}

  @doc "Decode a bounded manifest and require the caller's exact persisted identity."
  def decode(bytes, expected_identity)
      when is_binary(bytes) and byte_size(bytes) <= @max_json_bytes do
    with {:ok, %{"version" => 1} = manifest} <- Jason.decode(bytes),
         true <- manifest["identity"] == expected_identity,
         :ok <- validate(manifest),
         true <- put_object_keys(manifest) == manifest do
      {:ok, manifest}
    else
      {:ok, %{"version" => _}} -> {:error, :unsupported_manifest_version}
      _ -> {:error, :invalid_manifest}
    end
  end

  def decode(_, _), do: {:error, :invalid_manifest}

  defp validate(%{"init" => init, "media" => media} = manifest) do
    if valid_object?(init) and valid_object?(media) do
      manifest
      |> Map.put("init", Map.take(init, ~w(length sha256)))
      |> Map.put("media", Map.take(media, ~w(length sha256)))
      |> RecordingDescriptor.validate()
    else
      {:error, :invalid_manifest}
    end
  end

  defp validate(_), do: {:error, :invalid_manifest}

  defp object(metadata, receipt) when is_map(receipt) do
    Map.merge(metadata, %{
      "key" => nil,
      "etag" => Map.get(receipt, :etag),
      "version_id" => Map.get(receipt, :version_id)
    })
  end

  defp object(_, _), do: nil

  defp put_object_keys(manifest) do
    manifest
    |> put_in(["init", "key"], RecordingDescriptor.object_key(manifest["identity"], :init))
    |> put_in(["media", "key"], RecordingDescriptor.object_key(manifest["identity"], :media))
  end

  defp valid_object?(
         %{"key" => key, "length" => _, "sha256" => _, "etag" => etag, "version_id" => version} =
           object
       ) do
    map_size(object) == 5 and (is_nil(key) or text?(key, 128)) and valid_receipt?(etag, version)
  end

  defp valid_object?(_), do: false

  defp valid_receipt?(etag, version) do
    (is_nil(etag) or strong_etag?(etag)) and
      (is_nil(version) or (version != "null" and text?(version, 1024))) and
      (not is_nil(etag) or not is_nil(version))
  end

  defp strong_etag?(value),
    do:
      is_binary(value) and byte_size(value) <= 258 and
        Regex.match?(~r/\A"[\x21\x23-\x7e]+"\z/, value)

  defp text?(value, max) when is_binary(value),
    do: byte_size(value) in 1..max and String.valid?(value) and String.printable?(value)

  defp text?(_, _), do: false

  defp canonical(value) when is_map(value) do
    value
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
