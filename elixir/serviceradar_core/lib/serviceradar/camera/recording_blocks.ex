defmodule ServiceRadar.Camera.RecordingBlocks do
  @moduledoc """
  Freezes historical recording authority and leases work on that exact block.

  Freeze locks ingest owner, recorder claim, then block and rechecks the original
  live recorder/relay fence before commit. Upload operations lock only the frozen
  block: later recorder generations neither grant nor revoke this authority.
  Every uploader retains its fresh token; expired tokens are never refetched.

  No object I/O belongs inside these transactions. An upload lease grants work on
  the frozen descriptor, not an archive receipt, availability or reclamation.
  Unfrozen blocks cannot be recovered or uploaded by this API.
  """
  import Ash.Expr

  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingDescriptor

  require Ash.Query

  @max_epoch 9_223_372_036_854_775_807

  def freeze(ingest, claim, block, descriptor, opts \\ []) do
    with {:ok, bytes} <- RecordingDescriptor.encode(descriptor) do
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      RecorderOwnership.with_current(
        ingest,
        claim,
        fn owner, current ->
          with {:ok, retained} <- lock(block.id, opts),
               true <-
                 original_recorder?(retained, owner, current) ||
                   {:error, :recording_block_mismatch},
               true <-
                 descriptor["identity"] == RecordingBlock.identity(retained) ||
                   {:error, :recording_block_mismatch} do
            freeze_descriptor(retained, descriptor, sha, opts)
          end
        end,
        opts
      )
    end
  end

  def acquire_upload(block_id, token, ttl_ms, opts \\ []) do
    with {:ok, token} <- Ecto.UUID.cast(token), :ok <- ttl(ttl_ms) do
      transaction(fn ->
        with {:ok, block} <- lock(block_id, opts),
             :ok <- uploadable(block),
             :ok <- available(block, token),
             {:ok, claimed} <-
               update(
                 block,
                 :claim_upload,
                 %{
                   upload_token: token,
                   upload_epoch: block.upload_epoch + 1,
                   upload_expires_at: DateTime.add(block.database_now, ttl_ms, :millisecond)
                 },
                 opts
               ) do
          current_upload(claimed, opts)
        end
      end)
    else
      :error -> {:error, :invalid_upload_token}
      {:error, _} = error -> error
    end
  end

  def renew_upload(lease, ttl_ms, opts \\ []) do
    with :ok <- ttl(ttl_ms) do
      with_current_upload(
        lease,
        fn block ->
          update(
            block,
            :renew_upload,
            %{upload_expires_at: DateTime.add(block.database_now, ttl_ms, :millisecond)},
            opts
          )
        end,
        opts
      )
    end
  end

  def release_upload(lease, opts \\ []) do
    transaction(fn ->
      with {:ok, block} <- lock(lease.id, opts),
           :ok <- matches(lease, block),
           {:ok, released} <- update(block, :release_upload, %{}, opts),
           true <- live?(block, released.database_now) || {:error, :upload_lease_lost} do
        {:ok, :released}
      end
    end)
  end

  @doc """
  Fence short CNPG work; never run external I/O here. The initially locked row's
  deadline bounds this operation even if its callback renews the lease. A later
  operation may use a legitimately renewed current row under the same handle.
  """
  def with_current_upload(lease, fun, opts \\ []) when is_function(fun, 1) do
    transaction(fn ->
      with {:ok, block} <- lock(lease.id, opts),
           :ok <- matches(lease, block),
           {:ok, result} <- publication_result(fun.(block)),
           {:ok, current} <- current_upload(lease, opts),
           true <- live?(block, current.database_now) || {:error, :upload_lease_lost} do
        result
      end
    end)
  end

  defp freeze_descriptor(%{state: :open_local} = block, descriptor, sha, opts) do
    block
    |> Ash.Changeset.for_update(:freeze, %{descriptor: descriptor, descriptor_sha256: sha})
    |> Ash.Changeset.filter(expr(state == :open_local))
    |> Ash.update(opts)
  end

  defp freeze_descriptor(
         %{descriptor: descriptor, descriptor_sha256: sha} = block,
         descriptor,
         sha,
         _opts
       ),
       do: {:ok, block}

  defp freeze_descriptor(_, _, _, _), do: {:error, :recording_descriptor_conflict}

  defp original_recorder?(block, owner, claim) do
    block.ingest_owner_id == owner.id and block.ingest_epoch == owner.epoch and
      block.recorder_claim_id == claim.id and block.recorder_epoch == claim.recorder_epoch and
      block.relay_session_id == owner.relay_session_id and
      block.media_ingest_id == claim.media_ingest_id and
      block.storage_id == claim.storage_id and block.camera_source_id == owner.camera_source_id and
      block.stream_profile_id == owner.stream_profile_id
  end

  defp uploadable(%{state: state, descriptor: descriptor, descriptor_sha256: sha})
       when state in [:sealed, :uploading] and is_map(descriptor) and is_binary(sha), do: :ok

  defp uploadable(_), do: {:error, :recording_block_unfrozen}

  defp available(block, token) do
    cond do
      live?(block, block.database_now) -> {:error, :upload_already_owned}
      block.upload_token == token -> {:error, :upload_token_reused}
      block.upload_epoch == @max_epoch -> {:error, :upload_epoch_exhausted}
      true -> :ok
    end
  end

  defp lock(id, opts) do
    case RecordingBlock
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.lock(:for_update)
         |> Ash.read_one(opts) do
      {:ok, %RecordingBlock{} = block} -> Ash.load(block, :database_now, opts)
      {:ok, nil} -> {:error, :recording_block_not_found}
      {:error, _} = error -> error
    end
  end

  defp current_upload(lease, opts) do
    with {:ok, block} <-
           RecordingBlock
           |> Ash.Query.filter(id == ^lease.id)
           |> Ash.Query.load(:database_now)
           |> Ash.read_one(opts),
         :ok <- matches(lease, block),
         do: {:ok, block}
  end

  defp matches(lease, %RecordingBlock{} = block) do
    if lease.upload_token == block.upload_token and lease.upload_epoch == block.upload_epoch and
         lease.descriptor_sha256 == block.descriptor_sha256 and live?(block, block.database_now),
       do: :ok,
       else: {:error, :upload_lease_lost}
  end

  defp matches(_, _), do: {:error, :upload_lease_lost}

  defp live?(%{state: :uploading, upload_expires_at: %DateTime{} = expiry}, now),
    do: DateTime.after?(expiry, now)

  defp live?(_, _), do: false

  defp update(block, action, attrs, opts) do
    epoch = block.upload_epoch

    block
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.Changeset.filter(expr(upload_epoch == ^epoch))
    |> Ash.update(Keyword.put(opts, :load, [:database_now]))
  end

  defp ttl(ms) when is_integer(ms) and ms in 1..300_000, do: :ok
  defp ttl(_), do: {:error, :invalid_ttl}
  defp publication_result(:ok), do: {:ok, :ok}
  defp publication_result({:ok, _} = result), do: {:ok, result}
  defp publication_result({:error, _} = error), do: error
  defp publication_result(_), do: {:error, :invalid_recording_publication_result}

  defp transaction(fun) do
    [RecordingBlock]
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(
             field: :recording_block,
             value: reason,
             message: "block operation refused"
           )}

        result ->
          result
      end
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, %InvalidArgument{field: :recording_block, value: reason}} ->
        {:error, reason}

      {:error,
       %Ash.Error.Invalid{errors: [%InvalidArgument{field: :recording_block, value: reason}]}} ->
        {:error, reason}

      error ->
        error
    end
  end
end
