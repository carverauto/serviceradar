defmodule ServiceRadarRecordingMetadata.LocalPublicationAcknowledgement do
  @moduledoc """
  Canonical acknowledgement of one exact local publication intent.

  Core emits these bytes after committing intent acceptance. The digest binds
  every intent field, including storage lifetime and historical authority. This
  codec checks correlation, not origin: a trusted authenticated control caller
  must supply the response. It is not a signature, qualified-copy registration,
  playback permission or deletion authority.
  """
  alias ServiceRadarRecordingMetadata.CanonicalJSON
  alias ServiceRadarRecordingMetadata.LocalPublicationIntent

  def encode(intent_bytes) do
    with {:ok, intent} <- LocalPublicationIntent.decode(intent_bytes) do
      CanonicalJSON.encode(%{
        "version" => 1,
        "kind" => "intent_accepted",
        "operation_id" => intent["operation_id"],
        "intent_sha256" => Base.encode16(:crypto.hash(:sha256, intent_bytes), case: :lower)
      })
    end
  end

  def validate(bytes, intent_bytes) when is_binary(bytes) and byte_size(bytes) in 1..512 do
    case encode(intent_bytes) do
      {:ok, ^bytes} -> :ok
      _ -> {:error, :invalid_publication_acknowledgement}
    end
  end

  def validate(_, _), do: {:error, :invalid_publication_acknowledgement}
end
