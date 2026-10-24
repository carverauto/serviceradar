defmodule ServiceRadar.Camera.ArchiveUploads do
  @moduledoc """
  Prepares immutable upload intent under the current historical block lease.

  Object keys, lengths and digests come only from the locked frozen descriptor
  and bound destination. An exact retry returns the retained intent, including
  after lease replacement. Preparation neither sends bytes nor authorizes a
  future request. Provider qualification and dispatch are separate boundaries.
  """
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveUploadIntent
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingDescriptor
  alias ServiceRadar.Repo

  require Ash.Query

  def prepare(lease, role, opts \\ []) do
    cond do
      Repo.in_transaction?() -> {:error, :ambient_transaction}
      role not in [:init, :media] -> {:error, :invalid_object_role}
      true -> RecordingBlocks.with_current_upload(lease, &prepare_locked(&1, role, opts), opts)
    end
  end

  defp prepare_locked(%{archive_binding_id: nil}, _role, _opts),
    do: {:error, :archive_binding_required}

  defp prepare_locked(block, role, opts) do
    with {:ok, %ArchiveBinding{} = binding} <-
           Ash.get(ArchiveBinding, block.archive_binding_id, opts) do
      object = Map.fetch!(block.descriptor, Atom.to_string(role))

      attributes = %{
        recording_block_id: block.id,
        archive_binding_id: binding.id,
        descriptor_sha256: block.descriptor_sha256,
        destination_sha256: binding.destination_sha256,
        object_role: role,
        object_key: RecordingDescriptor.object_key(block.descriptor["identity"], role),
        byte_length: object["length"],
        object_sha256: object["sha256"]
      }

      case ArchiveUploadIntent
           |> Ash.Query.filter(recording_block_id == ^block.id and object_role == ^role)
           |> Ash.read_one(opts) do
        {:ok, nil} ->
          ArchiveUploadIntent
          |> Ash.Changeset.for_create(:prepare, attributes)
          |> Ash.create(opts)

        {:ok, retained} ->
          if Map.take(retained, Map.keys(attributes)) == attributes,
            do: {:ok, retained},
            else: {:error, :archive_upload_intent_conflict}

        {:error, _} = error ->
          error
      end
    end
  end
end
