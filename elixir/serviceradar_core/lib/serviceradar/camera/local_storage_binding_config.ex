defmodule ServiceRadar.Camera.LocalStorageBindingConfig do
  @moduledoc """
  Bounded identity of one provisioned local-storage binding generation.

  The provisioning adapter must validate the opaque provider resource reference
  and compute the digest of the complete canonical provider configuration and
  failure profile before calling the binding resource. Parsing proves neither
  that the resource exists nor that its storage is qualified.
  """

  alias ServiceRadar.Camera.ArchiveCanonicalJSON

  @fields ~w(schema_version storage_id generation provider_resource_ref profile_sha256)
  @max_generation 9_223_372_036_854_775_807

  def attributes(%{"schema_version" => 1} = document) when map_size(document) == 5 do
    with true <- Enum.sort(Map.keys(document)) == Enum.sort(@fields),
         true <- uuid?(document["storage_id"]),
         true <- generation?(document["generation"]),
         true <- reference?(document["provider_resource_ref"]),
         true <- digest?(document["profile_sha256"]) do
      bytes = ArchiveCanonicalJSON.encode(["nvr-local-storage-binding-v1", document])

      {:ok,
       %{
         schema_version: 1,
         storage_id: document["storage_id"],
         generation: document["generation"],
         provider_resource_ref: document["provider_resource_ref"],
         profile_sha256: document["profile_sha256"],
         binding_sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
       }}
    else
      _ -> {:error, :invalid_local_storage_binding}
    end
  end

  def attributes(_), do: {:error, :invalid_local_storage_binding}

  defp uuid?(id) when is_binary(id) and byte_size(id) == 36, do: Ecto.UUID.cast(id) == {:ok, id}

  defp uuid?(_), do: false
  defp generation?(value), do: is_integer(value) and value in 1..@max_generation

  # Opaque references are retained as identity, never interpreted as paths or URLs.
  defp reference?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: Regex.match?(~r/\A[!-~]+\z/, value)

  defp reference?(_), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp digest?(_), do: false
end
