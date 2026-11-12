defmodule ServiceRadar.Camera.LocalPublicationIntents do
  @moduledoc """
  Reconciles a bounded local intent against original frozen recording authority.

  A trusted Core caller supplies bytes, never a current recorder lease as a
  substitute for historical authority. The returned canonical bytes acknowledge
  only intent acceptance, after the immutable row commits. Qualified storage and
  local-copy publication remain separate steps. No network or filesystem I/O
  occurs inside the transaction. Deployment recovery state is checked before the
  transaction and before returning the acknowledgement. Closure after admission
  withholds the reply but does not undo a committed receipt.
  Ambient transactions are refused so no acknowledgement precedes its commit.
  """
  alias ServiceRadar.Camera.LocalPublicationIntent
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Repo
  alias ServiceRadarRecordingControl.RecoveryGate
  alias ServiceRadarRecordingMetadata.LocalPublicationAcknowledgement
  alias ServiceRadarRecordingMetadata.LocalPublicationIntent, as: Codec

  require Ash.Query

  def accept(bytes, opts \\ []) do
    with {:ok, document} <- Codec.decode(bytes) do
      accept_bytes(document, bytes, opts)
    end
  end

  @doc "Accept only the storage lifetime bound to an authenticated workload by the caller."
  def accept_from_storage(bytes, storage_id, opts \\ []) do
    with {:ok, document} <- Codec.decode(bytes),
         true <-
           document["storage_id"] == storage_id || {:error, :local_publication_storage_mismatch} do
      accept_bytes(document, bytes, opts)
    end
  end

  defp accept_bytes(document, bytes, opts) do
    gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)

    if Repo.in_transaction?() do
      {:error, :ambient_transaction}
    else
      with {:ok, _receipt} <-
             RecoveryGate.with_ready(gate, fn ->
               accept_document(document, digest(bytes), opts)
             end) do
        LocalPublicationAcknowledgement.encode(bytes)
      end
    end
  end

  defp accept_document(document, sha, opts) do
    RecordingBlocks.with_frozen(
      document["recording_block_id"],
      fn block ->
        with :ok <- matches_block(document, block) do
          acknowledge(document, sha, opts)
        end
      end,
      opts
    )
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
