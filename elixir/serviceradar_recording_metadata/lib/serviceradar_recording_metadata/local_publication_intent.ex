defmodule ServiceRadarRecordingMetadata.LocalPublicationIntent do
  @moduledoc """
  Portable v1 local publication intent, bounded to 64 KiB of canonical JSON.

  Encoding validates metadata correlation only. Core must reconcile it against
  frozen recording authority; neither decoding nor acknowledgement verifies
  storage durability, media bytes or playback availability.
  """
  alias ServiceRadarRecordingMetadata.CanonicalJSON
  alias ServiceRadarRecordingMetadata.Descriptor

  @max_bytes 65_536
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  def encode(descriptor, storage_id, reference) do
    with :ok <- valid_reference(reference),
         true <- uuid?(storage_id) || {:error, :invalid_publication_intent},
         {:ok, descriptor_bytes} <- Descriptor.encode(descriptor),
         true <- digest(descriptor_bytes) == reference.descriptor_sha256 || {:error, :descriptor_digest_mismatch},
         {:ok, bytes} <-
           CanonicalJSON.encode(%{
             "version" => 1,
             "storage_id" => storage_id,
             "block_id" => Descriptor.block_key(descriptor["identity"]),
             "operation_id" => reference.operation_id,
             "recording_block_id" => reference.recording_block_id,
             "descriptor_sha256" => reference.descriptor_sha256,
             "descriptor" => descriptor
           }),
         true <- byte_size(bytes) <= @max_bytes || {:error, :publication_intent_too_large} do
      {:ok, bytes}
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@max_bytes do
    with {:ok, %{"version" => 1} = document} <- Jason.decode(bytes),
         {:ok, ^bytes} <- encode(document["descriptor"], document["storage_id"], reference(document)) do
      {:ok, document}
    else
      _ -> {:error, :invalid_publication_intent}
    end
  end

  def decode(_), do: {:error, :invalid_publication_intent}

  defp reference(document) do
    %{
      operation_id: document["operation_id"],
      recording_block_id: document["recording_block_id"],
      descriptor_sha256: document["descriptor_sha256"]
    }
  end

  defp valid_reference(%{operation_id: operation, recording_block_id: block, descriptor_sha256: sha} = reference)
       when map_size(reference) == 3 and is_binary(sha) and byte_size(sha) == 64 do
    if uuid?(operation) and uuid?(block) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha),
      do: :ok,
      else: {:error, :invalid_publication_reference}
  end

  defp valid_reference(_), do: {:error, :invalid_publication_reference}
  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
