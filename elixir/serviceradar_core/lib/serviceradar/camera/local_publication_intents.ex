defmodule ServiceRadar.Camera.LocalPublicationIntents do
  @moduledoc """
  Reconciles a bounded local intent against original frozen recording authority.

  A trusted Core caller supplies bytes, never a current recorder lease as a
  substitute for historical authority. The returned immutable row acknowledges
  only intent acceptance. Qualified storage and local-copy publication remain
  separate steps. No network or filesystem I/O occurs inside the transaction.
  """
  alias ServiceRadar.Camera.LocalPublicationIntent
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadarRecordingMetadata.LocalPublicationIntent, as: Codec

  require Ash.Query

  def accept(bytes, opts \\ []) do
    with {:ok, document} <- Codec.decode(bytes) do
      RecordingBlocks.with_frozen(
        document["recording_block_id"],
        fn block ->
          with :ok <- matches_block(document, block) do
            acknowledge(document, digest(bytes), opts)
          end
        end,
        opts
      )
    end
  end

  defp matches_block(document, block) do
    if document["storage_id"] == block.storage_id and document["block_id"] == block.block_key and
         document["descriptor_sha256"] == block.descriptor_sha256 and
         document["descriptor"] == block.descriptor,
       do: :ok,
       else: {:error, :local_publication_authority_mismatch}
  end

  defp acknowledge(document, sha, opts) do
    id = document["operation_id"]
    block_id = document["recording_block_id"]

    with {:ok, existing} <-
           LocalPublicationIntent
           |> Ash.Query.filter(id == ^id or recording_block_id == ^block_id)
           |> Ash.read(opts) do
      case existing do
        [] ->
          create(document, sha, opts)

        [%{id: ^id, recording_block_id: ^block_id, intent_sha256: ^sha} = receipt] ->
          {:ok, receipt}

        _ ->
          {:error, :local_publication_intent_conflict}
      end
    end
  end

  defp create(document, sha, opts) do
    LocalPublicationIntent
    |> Ash.Changeset.for_create(:acknowledge, %{
      id: document["operation_id"],
      recording_block_id: document["recording_block_id"],
      storage_id: document["storage_id"],
      block_key: document["block_id"],
      descriptor_sha256: document["descriptor_sha256"],
      intent_sha256: sha
    })
    |> Ash.create(opts)
  end

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
